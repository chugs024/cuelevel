import SwiftUI
import StoreKit

// CueLevel Pro: a one-time purchase through the App Store. Quick levelling (automatic level, Even out, trimming) is free;
// Pro adds the hands-on editor: the fader, clip gain sections, editing Even out's sections, trims and fades.
// One purchase unlocks Pro on iPhone, iPad and Mac (the same App Store app), and Restore brings it back on a new device.

@MainActor
final class ProStore: ObservableObject {
    static let productID = "com.cuelevel.app.pro"

    @Published private(set) var isPro = false
    @Published private(set) var product: Product?
    @Published private(set) var purchasing = false
    @Published var message: String?
    private var updates: Task<Void, Never>?

    init() {
        // Purchases made elsewhere (another device, Ask to Buy approved later, a refund) arrive here.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let transaction) = result { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh(); await loadProduct() }
    }
    deinit { updates?.cancel() }

    /// Price as the App Store shows it in the buyer's currency, e.g. "$29.99".
    var price: String { product?.displayPrice ?? "" }

    func loadProduct() async {
        do { product = try await Product.products(for: [Self.productID]).first }
        catch { product = nil }
    }

    func refresh() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil { owned = true }
        }
        isPro = owned || Self.simulatorDemo
    }
    /// The build server's screenshots unlock Pro with a launch argument, on the simulator only.
    private static var simulatorDemo: Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains("-pro")
        #else
        return false
        #endif
    }

    func buy() async {
        message = nil
        if product == nil { await loadProduct() }
        guard let product else { message = "The App Store isn't reachable right now. Check your connection and try again."; return }
        purchasing = true
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else { message = "The App Store couldn't confirm this purchase. Try Restore purchase."; return }
                await transaction.finish()
                isPro = true
            case .pending:
                message = "Waiting for approval. Pro unlocks as soon as the purchase is approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "The purchase didn't go through: \(error.localizedDescription)"
        }
    }

    func restore() async {
        message = nil
        purchasing = true
        defer { purchasing = false }
        do { try await AppStore.sync() } catch { message = "Couldn't reach the App Store to restore: \(error.localizedDescription)"; return }
        await refresh()
        if !isPro { message = "No Pro purchase was found for this Apple Account." }
    }
}

/// What Pro adds, and the button to buy it.
struct ProView: View {
    @EnvironmentObject var pro: ProStore
    @Environment(\.dismiss) private var dismiss
    var onUnlocked: () -> Void = {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            LogoMark().frame(width: 34)
                            Text("CueLevel Pro").font(.readout(26)).foregroundStyle(Theme.bone)
                        }
                        Text("Quick levelling stays free. Pro hands you the controls when a cue needs a person's ear.")
                            .font(.system(size: 16)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        feature("slider.vertical.3", "Your own fader", "Set a cue's level yourself, with its loudness and loudest peak shown as you move it.")
                        feature("waveform.path", "Clip gain on the waveform", "Turn any stretch up or down: drag its line, drag its edges, zoom in to the word.")
                        feature("wand.and.rays", "Edit what Even out did", "Move, resize, retune or remove the stretches CueLevel evened out.")
                        feature("scissors", "Trims and fades", "Set the in and out points and fade lengths by hand.")
                        feature("arrow.uturn.backward", "Hear it before you save", "Play the cue with your changes, undo and redo, then level it.")
                    }
                    .padding(16).background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))

                    VStack(spacing: 10) {
                        Button {
                            Task { await pro.buy(); if pro.isPro { onUnlocked(); dismiss() } }
                        } label: {
                            if pro.purchasing { ProgressView().tint(Theme.onGood) }
                            else { Text(pro.price.isEmpty ? "Unlock Pro" : "Unlock Pro for \(pro.price)") }
                        }
                        .buttonStyle(CLButton(kind: .hero)).disabled(pro.purchasing)
                        Text("One payment. No subscription. Unlocks Pro on your iPhone, iPad and Mac.")
                            .font(.system(size: 13)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        if let message = pro.message {
                            Text(message).font(.system(size: 14)).foregroundStyle(Theme.changed).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button("Restore purchase") { Task { await pro.restore(); if pro.isPro { onUnlocked(); dismiss() } } }
                            .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.good).disabled(pro.purchasing)
                        HStack(spacing: 16) {
                            Link("Terms", destination: URL(string: "https://cuelevel.com/terms.html")!)
                            Link("Privacy", destination: URL(string: "https://cuelevel.com/privacy.html")!)
                        }.font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(20).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(Theme.base.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } } }
            .task { if pro.product == nil { await pro.loadProduct() } }
        }
        .tint(Theme.good)
        .preferredColorScheme(.dark)
    }

    func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.good).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Theme.bone)
                Text(detail).font(.system(size: 14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
