import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 400),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        
        let view = NSHostingView(rootView: ZStack {
            Color.clear
            Circle().fill(Color.red).frame(width: 100, height: 100)
        }.frame(maxWidth: .infinity, maxHeight: .infinity))
        
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        
        // Print message
        print("Window shown. Click outside the red circle but inside the 400x400 area.")
        print("If it clicks through to terminal, transparency works!")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
