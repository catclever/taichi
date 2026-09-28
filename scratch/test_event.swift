import Cocoa

let cgLoc = CGEvent(source: nil)?.location ?? .zero
let nsLoc = NSEvent.mouseLocation

let e1 = NSEvent.otherEvent(with: .systemDefined, location: nsLoc, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: 0, data2: 0)
let e2 = NSEvent.otherEvent(with: .systemDefined, location: cgLoc, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: 0, data2: 0)

print("Screen height: \(NSScreen.main?.frame.height ?? 0)")
print("CG current: \(cgLoc)")
print("NS current: \(nsLoc)")
print("e1 (NSLoc) CGEvent location: \(e1!.cgEvent!.location)")
print("e2 (CGLoc) CGEvent location: \(e2!.cgEvent!.location)")
