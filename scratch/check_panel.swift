import AppKit
let win = NSWindow(contentRect: NSRect(x:0,y:0,width:100,height:100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
let panel = NSPanel(contentRect: NSRect(x:0,y:0,width:100,height:100), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
print("win is panel?", win is NSPanel)
print("panel is panel?", panel is NSPanel)
