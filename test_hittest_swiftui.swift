import Cocoa
import SwiftUI

class TestHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        print("hitTest returned view of type: \(type(of: view!))")
        return view == self ? nil : view
    }
}
