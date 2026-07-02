import Cocoa

class PassThroughHostingView<Content: SwiftUI.View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
