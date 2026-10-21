import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Drag and drop: drop audio, video or whole folders anywhere on CueLevel to add them (from Finder on a Mac, or from
// Files and other apps on iPad), and drag a levelled cue out of the list straight into Finder, QLab or Files.

enum DropImport {
    static let types: [UTType] = [.fileURL, .folder, .audiovisualContent, .audio, .movie]

    /// Turns dropped items into file URLs CueLevel can copy in. Finder and Files give the file itself; other apps may
    /// only give a copy, which is kept in a temporary folder until CueLevel has copied it.
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var found: [URL] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await fileURL(provider) {
                found.append(url); continue
            }
            for type in [UTType.movie, .audio, .audiovisualContent, .folder] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                if let url = await copy(provider, type: type) { found.append(url) }
                break
            }
        }
        return found
    }

    private static func fileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url?.isFileURL == true ? url : nil) }
        }
    }

    private static func copy(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { done in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { done.resume(returning: nil); return }
                // The provided file only exists inside this callback: copy it somewhere CueLevel owns first.
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Dropped/\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = provider.suggestedName.map { $0 + "." + (url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension) } ?? url.lastPathComponent
                let target = folder.appendingPathComponent(name)
                do { try FileManager.default.copyItem(at: url, to: target); done.resume(returning: target) } catch { done.resume(returning: nil) }
            }
        }
    }
}

/// Makes a view a drop target for cues, with a clear highlight while something is dragged over it.
struct CueDropTarget: ViewModifier {
    @EnvironmentObject var store: CueStore
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .onDrop(of: DropImport.types, isTargeted: $targeted) { providers in
                Task { @MainActor in
                    let urls = await DropImport.urls(from: providers)
                    if urls.isEmpty { store.error = "Those items aren't audio or video files CueLevel can level." } else { store.add(urls) }
                }
                return true
            }
            .overlay {
                if targeted {
                    ZStack {
                        Theme.base.opacity(0.78)
                        VStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 40, weight: .medium)).foregroundStyle(Theme.good)
                            Text("Drop to add cues").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.bone)
                            Text("Audio, video or whole folders. Your originals are never changed.").font(.system(size: 14)).foregroundStyle(Theme.muted)
                        }
                        .padding(28)
                        .background(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.good, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

extension View {
    func acceptsDroppedCues() -> some View { modifier(CueDropTarget()) }

    /// Lets a levelled cue be dragged out as its file (into Finder, QLab, Files or another app).
    @ViewBuilder func draggableLevelledFile(_ url: URL?) -> some View {
        if let url, FileManager.default.fileExists(atPath: url.path) {
            onDrag {
                let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
                provider.suggestedName = url.deletingPathExtension().lastPathComponent
                return provider
            }
        } else {
            self
        }
    }
}
