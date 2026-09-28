import Cocoa

let loc = NSEvent.mouseLocation
print("NSEvent location: \(loc)")

if let cgEvent = CGEvent(source: nil) {
    print("CGEvent location: \(cgEvent.location)")
}
