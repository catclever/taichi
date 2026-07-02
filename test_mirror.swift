import Cocoa
import CoreGraphics

let mainDisplay = CGMainDisplayID()
let isMirror = CGDisplayIsInMirrorSet(mainDisplay)
let mirrors = CGDisplayMirrorsDisplay(mainDisplay)

print("Main display: \(mainDisplay)")
print("Is in mirror set: \(isMirror != 0)")
print("Mirrors display: \(mirrors)")

for screen in NSScreen.screens {
    print("Screen: \(screen.frame), safeArea: \(screen.safeAreaInsets.top)")
}
