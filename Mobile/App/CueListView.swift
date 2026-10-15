import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The show: every cue with where it is, and the actions that work on the whole show.

struct RootView: View {
    @EnvironmentObject var store: CueStore
    @EnvironmentObject var pro: ProStore
    @State private var importing = false
    @State private var settingsOpen = false
    @State private var column = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $column) {
            CueListView(importing: $importing, settingsOpen: $settingsOpen)
                .navigationSplitViewColumnWidth(min: 320, ideal: 360)
        } detail: {
            if let id = store.selection, store.cue(id) != nil {
                CueDetailView(id: id)
            } else {
                EmptyDetail(importing: $importing)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Theme.good)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.add(urls) }
        }
        .sheet(isPresented: $settingsOpen) { SettingsView().environmentObject(store).environmentObject(pro) }
        .sheet(isPresented: Binding(get: { !store.confirming.isEmpty }, set: { if !$0 { store.confirming = [] } })) {
            TypeConfirmSheet().environmentObject(store)
        }
        .alert("CueLevel", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

enum CueFilter: String, CaseIterable { case all = "All", attention = "Needs a look", done = "Done" }

struct CueListView: View {
    @EnvironmentObject var store: CueStore
    @Binding var importing: Bool
    @Binding var settingsOpen: Bool
    @State private var filter = CueFilter.all
    @State private var exporting = false

    var shown: [MobileCue] {
        store.cues.filter { c in
            switch filter {
            case .all: return true
            case .attention: return c.stage.wantsAttention
            case .done: return c.stage.isDone
            }
        }
    }

    var body: some View {
        Group {
            if store.cues.isEmpty {
                Onboarding(importing: $importing)
            } else {
                List(selection: $store.selection) {
                    Section {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { _, cue in
                            CueRow(cue: cue, number: (store.cues.firstIndex { $0.id == cue.id } ?? 0) + 1)
                                .tag(cue.id)
                                .listRowBackground(store.selection == cue.id ? Theme.raised : Theme.base)
                                .listRowSeparatorTint(Theme.line)
                                .swipeActions {
                                    Button(role: .destructive) { store.remove([cue.id]) } label: { Label("Remove", systemImage: "trash") }
                                }
                                .contextMenu {
                                    Button { store.requestLevel([cue.id]) } label: { Label(cue.output == nil ? "Level this cue" : "Level again", systemImage: "slider.horizontal.3") }
                                        .disabled(cue.analysis == nil)
                                    if let url = store.outputURL(cue) { ShareLink(item: url) { Label("Share levelled copy", systemImage: "square.and.arrow.up") } }
                                    Button(role: .destructive) { store.remove([cue.id]) } label: { Label("Remove", systemImage: "trash") }
                                }
                        }
                    } header: { header }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .safeAreaInset(edge: .bottom) { bottomBar }
            }
        }
        .background(Theme.base.ignoresSafeArea())
        .sheet(isPresented: $exporting) { ExportPicker(urls: store.levelledURLs).ignoresSafeArea() }
        .navigationTitle("CueLevel")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { settingsOpen = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Show settings")
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) { LogoMark().frame(width: 20, height: 20); Text("CueLevel").font(.system(size: 17, weight: .semibold)) }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !store.levelledURLs.isEmpty {
                    Menu {
                        Button { exporting = true } label: { Label("Save to a folder…", systemImage: "folder") }
                        ShareLink(items: store.levelledURLs) { Label("Share…", systemImage: "square.and.arrow.up") }
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Levelled cues")
                }
                Button { importing = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add cues")
            }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cues").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.bone)
                let done = store.cues.filter { $0.stage.isDone }.count
                Text("\(store.cues.count) cue\(store.cues.count == 1 ? "" : "s"), \(done) done").font(.system(size: 14)).foregroundStyle(Theme.muted)
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(CueFilter.allCases, id: \.self) { f in
                    let count = f == .attention ? store.cues.filter { $0.stage.wantsAttention }.count : f == .done ? store.cues.filter { $0.stage.isDone }.count : 0
                    Button { filter = f } label: {
                        Text(f == .all ? f.rawValue : "\(f.rawValue) \(count)")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(filter == f ? Theme.bone : Theme.muted)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(filter == f ? Theme.raised : .clear))
                            .overlay(Capsule().stroke(Theme.line2, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 8)
        .textCase(nil)
    }

    var bottomBar: some View {
        VStack(spacing: 8) {
            if !store.status.isEmpty {
                Text(store.status).font(.system(size: 13)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading)
            }
            // What Level all will treat each cue as, with the ones CueLevel couldn't tell about called out.
            let pending = store.levelAllIDs.compactMap { store.cue($0) }.filter { $0.analysis != nil }
            if !pending.isEmpty {
                let counts = [ContentMode.voice, .mixed, .music].compactMap { m -> String? in
                    let n = pending.filter { store.mode(for: $0) == m }.count
                    return n == 0 ? nil : "\(n) \(m.label.lowercased())"
                }
                let check = pending.filter { store.needsTypeCheck($0) }.count
                HStack(spacing: 8) {
                    Text("Level as: " + counts.joined(separator: ", ")).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.8)
                    if check > 0 {
                        Label("\(check) to check", systemImage: "exclamationmark.circle.fill").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.changed)
                    }
                    Spacer()
                    Button("Review types") { store.confirming = pending.map(\.id) }.font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.good)
                }
            }
            HStack(spacing: 10) {
                if store.busy {
                    Button { store.stop() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(CLButton(kind: .secondary))
                }
                let ids = store.levelAllIDs.filter { id in store.cue(id)?.analysis != nil }
                Button { store.requestLevel(ids) } label: {
                    Text(ids.isEmpty ? "All cues levelled" : "Level all (\(ids.count))")
                }
                .buttonStyle(CLButton(kind: .hero))
                .disabled(ids.isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }
}

struct CueRow: View {
    @EnvironmentObject var store: CueStore
    let cue: MobileCue
    let number: Int
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(String(format: "%02d", number)).font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.dim).frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if cue.isVideo { Image(systemName: "film").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                    Text(cue.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.bone).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    if cue.analysis != nil {
                        if store.needsTypeCheck(cue) {
                            Label("Check type", systemImage: "exclamationmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(Theme.changed)
                        } else {
                            Text(store.mode(for: cue).label).foregroundStyle(Theme.text)
                        }
                    }
                    if let d = cue.analysis?.info.duration { Text(clock(d)) }
                    if let l = cue.shownLoudness { Text("\(lufsText(l)) LUFS") }
                    if cue.state == .failed { Text(cue.message).lineLimit(1).foregroundStyle(Theme.hot.opacity(0.9)) }
                }
                .font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.muted)
                MiniRuler(lufs: cue.shownLoudness, target: store.settings.target).frame(maxWidth: 200)
            }
            Spacer(minLength: 8)
            StageLabel(cue: cue, target: store.settings.target, progress: store.progress[cue.id])
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(cue.name), \(cue.stageText(target: store.settings.target))")
    }
}

/// First run: what CueLevel does, in three steps, and the one button that starts it.
struct Onboarding: View {
    @Binding var importing: Bool
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                LogoMark().frame(width: 52, height: 52).padding(.top, 28)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Level your show's cues").font(.readout(30)).foregroundStyle(Theme.bone)
                    Text("Every cue comes out at the same loudness for the PA, with nothing else about it changed.")
                        .font(.system(size: 16)).foregroundStyle(Theme.text)
                }
                VStack(spacing: 12) {
                    step(1, "Add your cues", "Pick audio or video from Files, iCloud Drive or another app. Each one is measured as it arrives.")
                    step(2, "Check the plan", "CueLevel shows what it would change in each cue and why, before it changes anything.")
                    step(3, "Level and share", "Levelled copies land in Files › CueLevel › Levelled. Your originals are never changed.")
                }
                Button { importing = true } label: { Label("Add cues", systemImage: "plus") }.buttonStyle(CLButton(kind: .hero))
                Text("WAV, AIFF, MP3, M4A, FLAC, MOV and MP4, or a whole folder.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
        }
    }
    func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.base)
                .frame(width: 26, height: 26).background(Circle().fill(Theme.bone))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.bone)
                Text(detail).font(.system(size: 14)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14).background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
    }
}

struct EmptyDetail: View {
    @EnvironmentObject var store: CueStore
    @Binding var importing: Bool
    var body: some View {
        VStack(spacing: 14) {
            LogoMark().frame(width: 44, height: 44)
            Text(store.cues.isEmpty ? "Add cues to begin" : "Select a cue").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.bone)
            if store.cues.isEmpty { Button { importing = true } label: { Label("Add cues", systemImage: "plus") }.buttonStyle(CLButton(kind: .primary)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.base.ignoresSafeArea())
    }
}

/// Copies the levelled files to a folder the person picks (on a Mac this is the usual Save panel's folder choice).
struct ExportPicker: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: urls, asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
