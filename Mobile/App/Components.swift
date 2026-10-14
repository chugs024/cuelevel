import SwiftUI

// Shared pieces: stage labels, rulers, the loudness readout, the waveform and the check pills.

struct StageLabel: View {
    let cue: MobileCue
    let target: Double
    var progress: Double? = nil
    var body: some View {
        HStack(spacing: 5) {
            if cue.stage == .working {
                ProgressView().controlSize(.mini).tint(Theme.muted)
                Text(progress.map { "\(Int($0 * 100))%" } ?? "Working").monospacedDigit()
            } else {
                if cue.stage == .alreadyGood { Image(systemName: "checkmark.seal.fill").font(.system(size: 12)) }
                Text(cue.stageText(target: target))
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(cue.stage == .working || cue.stage == .waiting || cue.stage == .measured ? Theme.muted : Theme.tone(cue.stageTone(target: target)))
        .lineLimit(1).fixedSize()
    }
}

/// Small ruler under each cue in the list: where the cue sits against the target.
struct MiniRuler: View {
    let lufs: Double?
    let target: Double
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised).frame(height: 3)
                if let lufs {
                    let x = Theme.position(lufs) * w, t = Theme.position(target) * w
                    Capsule().fill(Theme.tone(levelTone(lufs, target: target)).opacity(0.45))
                        .frame(width: abs(x - t), height: 3).offset(x: min(x, t))
                    Circle().fill(Theme.tone(levelTone(lufs, target: target))).frame(width: 8, height: 8).offset(x: x - 4)
                }
                Rectangle().fill(Theme.muted).frame(width: 1.5, height: 9).offset(x: Theme.position(target) * w - 0.75)
            }.frame(height: 9)
        }.frame(height: 9)
    }
}

/// The big readout: now → after, in LUFS.
struct LevelReadout: View {
    let now: Double
    let after: Double?
    let target: Double
    let note: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lufsText(now)).font(.readout(after == nil ? 46 : 30)).foregroundStyle(Theme.tone(levelTone(now, target: target)))
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text("Now").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            }
            if let after {
                Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(lufsText(after)).font(.readout(46)).foregroundStyle(Theme.tone(levelTone(after, target: target))).lineLimit(1).minimumScaleFactor(0.6)
                        Text("LUFS").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                    Text(note).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            } else {
                Text("LUFS").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// −40 to 0 LUFS, the target, and the cue's position now and after.
struct LevelRuler: View {
    let now: Double
    let after: Double?
    let target: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width, t = Theme.position(target) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.meter).frame(height: 6)
                    RoundedRectangle(cornerRadius: 4).stroke(Theme.good.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: max(8, 2 / 40 * w), height: 16).offset(x: t - max(8, 2 / 40 * w) / 2)
                    if let after {
                        let a = Theme.position(after) * w, n = Theme.position(now) * w
                        Capsule().fill(Theme.bone.opacity(0.5)).frame(width: abs(a - n), height: 3).offset(x: min(a, n))
                    }
                    Circle().fill(Theme.tone(levelTone(now, target: target))).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Theme.base, lineWidth: 2)).offset(x: Theme.position(now) * w - 7)
                    if let after {
                        Circle().fill(Theme.tone(levelTone(after, target: target))).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Theme.base, lineWidth: 2)).offset(x: Theme.position(after) * w - 8)
                    }
                    Rectangle().fill(Theme.bone).frame(width: 2, height: 22).offset(x: t - 1)
                }.frame(height: 22)
            }.frame(height: 22)
            HStack {
                ForEach([-40, -30, -20, -10, 0], id: \.self) { v in
                    Text(v == 0 ? "0" : "−\(abs(v))").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                    if v != 0 { Spacer() }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The cue's waveform as a filled envelope, its loudness over time, and the good range for its content type.
struct WaveformView: View {
    let peaks: [Float]
    var curve: [Float]? = nil
    var band: ClosedRange<Double>? = nil
    var sections: [GainRegion] = []
    var duration: Double = 0
    var playhead: Double? = nil
    var tint: Color = Theme.bone
    var body: some View {
        Canvas { g, size in
            let w = size.width, h = size.height, mid = h / 2
            // Even out's sections behind the wave.
            if duration > 0 {
                for r in sections {
                    let x0 = r.start / duration * w, x1 = r.end / duration * w
                    g.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: h)), with: .color(Theme.changed.opacity(0.10)))
                    g.stroke(Path { p in p.move(to: CGPoint(x: x0, y: 0)); p.addLine(to: CGPoint(x: x0, y: h)) }, with: .color(Theme.changed.opacity(0.5)), lineWidth: 1)
                }
            }
            if let band {
                let y = { (v: Double) in h - CGFloat(Theme.position(v)) * h }
                g.fill(Path(CGRect(x: 0, y: y(band.upperBound), width: w, height: y(band.lowerBound) - y(band.upperBound))), with: .color(Theme.good.opacity(0.10)))
            }
            if !peaks.isEmpty {
                let n = peaks.count
                var top = Path(), env = Path()
                env.move(to: CGPoint(x: 0, y: mid))
                for i in 0..<n {
                    let x = CGFloat(i) / CGFloat(max(1, n - 1)) * w
                    let a = CGFloat(min(1, peaks[i])) * (h / 2 - 2)
                    env.addLine(to: CGPoint(x: x, y: mid - a))
                }
                for i in stride(from: n - 1, through: 0, by: -1) {
                    let x = CGFloat(i) / CGFloat(max(1, n - 1)) * w
                    let a = CGFloat(min(1, peaks[i])) * (h / 2 - 2)
                    env.addLine(to: CGPoint(x: x, y: mid + a))
                }
                env.closeSubpath()
                g.fill(env, with: .color(tint.opacity(0.88)))
                top.move(to: CGPoint(x: 0, y: mid)); top.addLine(to: CGPoint(x: w, y: mid))
                g.stroke(top, with: .color(tint.opacity(0.5)), lineWidth: 0.5)
            }
            if let curve, curve.count > 1 {
                var line = Path()
                for (i, v) in curve.enumerated() {
                    let x = CGFloat(i) / CGFloat(curve.count - 1) * w
                    let y = h - CGFloat(Theme.position(Double(v))) * h
                    if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
                }
                g.stroke(line, with: .color(Theme.changed), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            }
            if let playhead, duration > 0 {
                let x = playhead / duration * w
                g.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: h)), with: .color(Theme.bone))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Wraps pills onto as many lines as they need.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { y += row + spacing; x = 0; row = 0 }
            x += s.width + spacing; row = max(row, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { y += row + spacing; x = bounds.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

struct CheckPill: View {
    let text: String
    let ok: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Theme.good : Theme.changed).frame(width: 7, height: 7)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Theme.panel)).overlay(Capsule().stroke(Theme.line, lineWidth: 1))
    }
}

/// The source checks, in a word each: what's fine is green, what deserves attention is amber.
func checkPills(_ a: Analysis) -> [(String, Bool)] {
    var list: [(String, Bool)] = []
    let clip = a.info.channels == 1 ? -3.11 : -0.1
    let clipping = (a.levels.samplePeak ?? -100) >= clip && (a.levels.peakCount ?? 0) >= 4
    list.append(clipping ? ("Probable clipping", false) : ("No clipping", true))
    list.append(abs(a.levels.dcOffset ?? 0) >= 0.001 ? ("DC offset", false) : ("No DC offset", true))
    if a.info.channels >= 2, let c = a.stereo?.correlation {
        if c < -0.1 { list.append(("Out of phase", false)) }
        else if c > 0.999 && a.info.channels == 2 { list.append(("Mono in a stereo file", false)) }
        else { list.append(("Phase OK", true)) }
    }
    if let s = a.stereo, s.headSilence >= 2 { list.append(("\(String(format: "%.1f", s.headSilence)) s silent at start", false)) }
    if let s = a.stereo, s.tailSilence >= 2 { list.append(("\(String(format: "%.1f", s.tailSilence)) s silent at end", false)) }
    if a.info.channels > 2 { list.append(("Surround, folded to stereo", false)) }
    return list
}
