import SwiftUI

// Show settings: the target every cue is levelled to, its peak ceiling, and how CueLevel treats new cues.

struct SettingsView: View {
    @EnvironmentObject var store: CueStore
    @EnvironmentObject var pro: ProStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @State private var showPro = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $store.settings.target, in: -30 ... -12, step: 0.5) {
                        row("Loudness target", "\(lufsText(store.settings.target)) LUFS")
                    }
                    Stepper(value: $store.settings.peak, in: -6 ... -1, step: 0.5) {
                        row("Peak ceiling", "\(lufsText(store.settings.peak)) dBTP")
                    }
                } header: { Text("Every cue") } footer: {
                    Text("−18 LUFS suits most venue PAs and matches CueLevel on the Mac. A cue that would go over the ceiling stays a little quieter instead of being limited.")
                }
                Section {
                    Picker("Content", selection: $store.settings.defaultMode) {
                        ForEach([ContentMode.voice, .mixed, .music], id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Even out loud and quiet stretches", isOn: $store.settings.evenOut)
                    Toggle("Trim silence at each end", isOn: $store.settings.trimSilence)
                    Toggle("Level as soon as a cue is added", isOn: $store.settings.levelOnAdd)
                } header: { Text("New cues") } footer: {
                    Text("Each cue's content type and plan can be changed on its own page. Music is never evened out.")
                }
                Section {
                    Toggle("Fold surround to stereo", isOn: $store.settings.foldsSurround)
                } header: { Text("Channels") } footer: {
                    Text(store.settings.foldsSurround
                         ? "Surround files (5.1, 7.1) are folded down to stereo for a stereo PA. Folding mixes the channels together, so those copies aren't lossless. Mono and stereo files are unchanged."
                         : "Every levelled copy has the same channels as the file you added: mono stays mono, 5.1 stays 5.1. Turn this on only if your PA plays stereo and you want surround files folded down.")
                }
                Section {
                    row("Saved to", "Files › CueLevel › Levelled")
                    Button("Remove all levelled copies", role: .destructive) { confirmClear = true }.disabled(store.levelledURLs.isEmpty)
                } header: { Text("Levelled files") } footer: {
                    Text("Audio is saved as WAV at its own sample rate; video as MOV with the picture copied untouched. Your originals are never changed.")
                }
                Section {
                    if pro.isPro {
                        Label("Pro is unlocked", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.good)
                    } else {
                        Button("Unlock CueLevel Pro") { showPro = true }
                        Button("Restore purchase") { Task { await pro.restore() } }
                        if let m = pro.message { Text(m).font(.system(size: 13)).foregroundStyle(Theme.changed) }
                    }
                } header: { Text("CueLevel Pro") } footer: {
                    Text(pro.isPro ? "Thank you. The editor, fader and section tools are yours on every device signed in to this Apple Account."
                         : "Quick levelling is free. Pro adds the editor: your own fader, clip gain sections, editing Even out, trims and fades.")
                }
                Section {
                    row("Version", (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")")
                    Link("Privacy", destination: URL(string: "https://cuelevel.com/privacy.html")!)
                    Link("Terms", destination: URL(string: "https://cuelevel.com/terms.html")!)
                    Link("Open-source licences", destination: URL(string: "https://cuelevel.com/licenses.html")!)
                    Link("Contact", destination: URL(string: "mailto:hello@cuelevel.com")!)
                } header: { Text("About") } footer: {
                    Text("CueLevel works entirely on this device. It collects no personal data.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.base.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showPro) { ProView().environmentObject(pro) }
            .confirmationDialog("Remove all levelled copies?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Remove levelled copies", role: .destructive) { store.clearLevelled() }
            } message: { Text("Your cues and originals stay. You can level them again at any time.") }
        }
        .tint(Theme.good)
        .preferredColorScheme(.dark)
    }
    func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(Theme.muted).monospacedDigit() }
    }
}

@main
struct CueLevelMobileApp: App {
    @StateObject private var store = CueStore()
    @StateObject private var pro = ProStore()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(pro)
                .preferredColorScheme(.dark)
                .onOpenURL { url in store.add([url]) }
                .task { await DemoHooks.run(store) }
        }
    }
}

/// Launch arguments used by the build server to exercise the app on the simulator and take screenshots:
/// -importFolder <path> adds every cue in a folder, -levelAll levels them, -select <n> opens cue n.
@MainActor enum DemoHooks {
    static func run(_ store: CueStore) async {
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? { args.firstIndex(of: key).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        if let folder = value("-importFolder"), store.cues.isEmpty { store.add([URL(fileURLWithPath: folder)]) }
        if args.contains("-levelAll") {
            while store.cues.contains(where: { $0.state == .queued || $0.state == .measuring }) { try? await Task.sleep(nanoseconds: 300_000_000) }
            store.levelAll()
        }
        if let n = value("-select").flatMap(Int.init), store.cues.indices.contains(n - 1) {
            store.selection = store.cues[n - 1].id
            if args.contains("-edit") { try? await Task.sleep(nanoseconds: 1_500_000_000); store.openEditorFor = store.cues[n - 1].id }
        }
    }
}
