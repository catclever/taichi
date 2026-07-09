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
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self = self, let window = self.window, event.window == window else { return event }
                let locationInView = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(locationInView) {
                    if event.deltaY != 0 {
                        self.onScroll?(event.deltaY)
                        return nil
                    } else if event.deltaX != 0 {
                        self.onScroll?(event.deltaX)
                        return nil
                    }
                }
                return event
            }
        } else if window == nil && monitor != nil {
            NSEvent.removeMonitor(monitor!)
            monitor = nil
        }
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Return nil so this view never intercepts mouse clicks, 
        // allowing SwiftUI's onTapGesture to work on sibling views.
        return nil
    }
}
