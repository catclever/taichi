import Cocoa

func simulateMediaKey() {
    let keyCode: Int32 = 16 // Play/Pause
    let loc = NSEvent.mouseLocation
    let eventDown = NSEvent.otherEvent(with: .systemDefined, location: loc, modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00), timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: Int((keyCode << 16) | 0x0A), data2: -1)
    let eventUp = NSEvent.otherEvent(with: .systemDefined, location: loc, modifierFlags: NSEvent.ModifierFlags(rawValue: 0xB00), timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: Int((keyCode << 16) | 0x0B), data2: -1)
    
    eventDown?.cgEvent?.post(tap: .cgSessionEventTap)
    eventUp?.cgEvent?.post(tap: .cgSessionEventTap)
}

simulateMediaKey()
