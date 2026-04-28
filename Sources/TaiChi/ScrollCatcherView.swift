import SwiftUI
import Cocoa

struct ScrollCatcherView: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollNSView {
        let view = ScrollNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollNSView, context: Context) {}
}

class ScrollNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if event.deltaY != 0 {
            onScroll?(event.deltaY)
        } else if event.deltaX != 0 {
            onScroll?(event.deltaX)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
