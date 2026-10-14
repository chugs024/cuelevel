import SwiftUI
import UIKit

// Touch handling for the editor's timeline, as in pro audio apps on iPad: one finger edits (drag a stretch up or down,
// drag an edge, draw a new section), two fingers scroll, pinch zooms, a tap selects or moves the playhead. On a Mac the
// trackpad or mouse wheel scrolls and a trackpad pinch zooms.

struct TimelineGestures: UIViewRepresentable {
    var onTap: (CGPoint) -> Void
    var onEdit: (UIGestureRecognizer.State, CGPoint, CGSize) -> Void
    var onScroll: (CGFloat, UIGestureRecognizer.State) -> Void
    var onZoom: (CGFloat, CGPoint, UIGestureRecognizer.State) -> Void
    var onHover: (CGPoint?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        let edit = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.edit(_:)))
        edit.maximumNumberOfTouches = 1
        edit.delegate = c
        let scroll = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.scroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.delegate = c
        let wheel = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.scroll(_:)))
        wheel.allowedScrollTypesMask = .all
        wheel.maximumNumberOfTouches = 0
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = c
        let hover = UIHoverGestureRecognizer(target: c, action: #selector(Coordinator.hover(_:)))
        [tap, edit, scroll, wheel, pinch, hover].forEach(view.addGestureRecognizer)
        c.scrollers = [scroll, pinch]
        c.editor = edit
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TimelineGestures
        var scrollers: [UIGestureRecognizer] = []
        private var lastScroll: CGFloat = 0
        private var down: CGPoint?
        weak var editor: UIPanGestureRecognizer?
        /// A second finger landing mid-edit means the person wanted to scroll or zoom: the edit is cancelled (and undone).
        private func cancelEdit() {
            guard let e = editor, e.state == .began || e.state == .changed else { return }
            e.isEnabled = false; e.isEnabled = true
        }
        init(_ parent: TimelineGestures) { self.parent = parent }

        @objc func tap(_ g: UITapGestureRecognizer) { if g.state == .ended { parent.onTap(g.location(in: g.view)) } }
        @objc func edit(_ g: UIPanGestureRecognizer) {
            // Report where the finger first touched down, then its movement from there.
            let now = g.location(in: g.view)
            let start = down ?? now
            parent.onEdit(g.state, start, CGSize(width: now.x - start.x, height: now.y - start.y))
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if g is UIPanGestureRecognizer, !scrollers.contains(g) { down = touch.location(in: g.view) }
            return true
        }
        @objc func scroll(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            // A mouse wheel scrolls vertically; treat it as moving along the cue.
            let amount = abs(t.x) >= abs(t.y) || g.numberOfTouches >= 2 ? t.x : t.y
            if g.state == .began { lastScroll = 0; if g.numberOfTouches >= 2 { cancelEdit() } }
            parent.onScroll(amount - lastScroll, g.state)
            lastScroll = amount
            if g.state == .ended || g.state == .cancelled { lastScroll = 0 }
        }
        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            if g.state == .began { cancelEdit() }
            parent.onZoom(g.scale, g.location(in: g.view), g.state)
        }
        @objc func hover(_ g: UIHoverGestureRecognizer) {
            switch g.state { case .began, .changed: parent.onHover(g.location(in: g.view)); default: parent.onHover(nil) }
        }
        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
            scrollers.contains(a) && scrollers.contains(b)
        }
        // A second finger turns an edit into a scroll: the one-finger edit gives way.
        func gestureRecognizer(_ a: UIGestureRecognizer, shouldBeRequiredToFailBy b: UIGestureRecognizer) -> Bool { false }
    }
}
