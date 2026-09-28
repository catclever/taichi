import Cocoa

func simulateMediaKey() {
    let keyCode: Int32 = 16 // Play/Pause
    
    // Get current CGEvent location
    let cgLoc = CGEvent(source: nil)?.location ?? .zero
    
    let eventDown = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00), timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: Int((keyCode << 16) | 0x0A), data2: -1)
    
    if let cgEvent = eventDown?.cgEvent {
        cgEvent.location = cgLoc
        cgEvent.post(tap: .cghidEventTap)
        print("Posted down at \(cgLoc)")
    }
}

simulateMediaKey()
