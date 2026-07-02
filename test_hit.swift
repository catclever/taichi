import Cocoa
import SwiftUI

class PassThroughPanel: NSPanel {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil // Never accept clicks
    }
}
