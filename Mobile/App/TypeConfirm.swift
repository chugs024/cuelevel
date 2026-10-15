import SwiftUI

// A cue's content type (voice, music + voice, or music) decides whether CueLevel evens out loud and quiet stretches
// (voice), only clear jumps (music + voice) or leaves the cue's own dynamics alone (music). CueLevel suggests one with
// its reason, and the type is always shown next to the Level button, where it can be changed; a cue CueLevel couldn't
// tell about is flagged "Check type".

extension ContentMode {
    /// What levelling does for this type, in a sentence.
    var levellingEffect: String {
        switch self {
        case .voice: return "Evens out loud and quiet lines and speakers, then one gain change to the target."
        case .mixed: return "Evens out only clear jumps between stretches, then one gain change to the target."
        case .music: return "Keeps the music's own dynamics: one gain change to the target, nothing else."
        }
    }
}

/// Three-way choice of content type, with nothing selected until it's confirmed.
struct TypePicker: View {
    @Binding var selection: ContentMode?
    var suggested: ContentMode
    var body: some View {
        HStack(spacing: 6) {
            ForEach([ContentMode.voice, .mixed, .music], id: \.self) { mode in
                let on = selection == mode
                Button { selection = mode } label: {
                    VStack(spacing: 3) {
                        Image(systemName: mode.symbol).font(.system(size: 15, weight: .semibold))
                        Text(mode.label).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Text(mode == suggested ? "Suggested" : " ").font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(on ? Theme.onGood.opacity(0.8) : Theme.good)
                    }
                    .foregroundStyle(on ? Theme.onGood : Theme.bone)
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.good : Theme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(mode == suggested && !on ? Theme.good.opacity(0.6) : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.label + (mode == suggested ? ", suggested" : ""))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Asks for the content type of every cue about to be levelled, with CueLevel's suggestions filled in.
struct TypeConfirmSheet: View {
    @EnvironmentObject var store: CueStore
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [UUID: ContentMode] = [:]

    var body: some View {
        let ids = store.confirming
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("The type decides whether CueLevel evens a cue out or keeps its own dynamics. CueLevel's picks are filled in; change any that are wrong.")
                        .font(.system(size: 14.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    ForEach(ids, id: \.self) { id in
                        if let cue = store.cue(id) { row(cue) }
                    }
                }
                .padding(16).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    store.confirmTypes(choices)
                    dismiss()
                } label: { Text(ids.count == 1 ? "Level this cue" : "Level \(ids.count) cues") }
                .buttonStyle(CLButton(kind: .hero))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.base)
            }
            .background(Theme.base.ignoresSafeArea())
            .navigationTitle("Check each cue's type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { store.confirming = []; dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { store.saveTypes(choices); dismiss() } }
            }
            .onAppear {
                for id in ids { if let c = store.cue(id) { choices[id] = c.mode ?? store.suggestion(for: c).mode } }
            }
        }
        .tint(Theme.good)
        .preferredColorScheme(.dark)
    }

    func row(_ cue: MobileCue) -> some View {
        let suggestion = store.suggestion(for: cue)
        let chosen = choices[cue.id] ?? suggestion.mode
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(cue.name).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Theme.bone).lineLimit(1)
                Spacer()
                if let a = cue.analysis { Text(clock(a.info.duration)).font(.system(size: 13).monospacedDigit()).foregroundStyle(Theme.muted) }
            }
            TypePicker(selection: Binding(get: { choices[cue.id] }, set: { choices[cue.id] = $0 }), suggested: suggestion.mode)
            Text(cue.mode == nil ? "\(suggestion.reason). " + chosen.levellingEffect : chosen.levellingEffect)
                .font(.system(size: 12.5)).foregroundStyle(cue.mode == nil && !suggestion.sure ? Theme.changed : Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
    }
}

/// "Level as": the cue's type, right above its Level button, with what that type does and why CueLevel picked it.
struct LevelAsRow: View {
    @EnvironmentObject var store: CueStore
    let cue: MobileCue
    var body: some View {
        let suggestion = store.suggestion(for: cue)
        let shown = cue.mode ?? suggestion.mode
        let unsure = cue.mode == nil && !suggestion.sure
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Level as").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.bone)
                Spacer()
                if unsure { Label("Check type", systemImage: "exclamationmark.circle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.changed) }
                else if cue.mode == nil { Text("CueLevel's pick").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted) }
            }
            TypePicker(selection: Binding(get: { shown }, set: { store.setMode(cue.id, $0) }), suggested: suggestion.mode)
            Text(cue.mode == nil ? "\(suggestion.reason). " + shown.levellingEffect : shown.levellingEffect)
                .font(.system(size: 12.5)).foregroundStyle(unsure ? Theme.changed : Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}
