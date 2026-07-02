import Cocoa
import SwiftUI

class PassThroughHostingView<Content: SwiftUI.View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view == self ? nil : view
    }
}
