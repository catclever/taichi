import Foundation
import Cocoa
import SwiftUI

@MainActor
class PassThroughHostingView<Content: SwiftUI.View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil // Never intercept clicks
    }
}

@MainActor
public class IslandManager: NSObject, NSWindowDelegate {
    public static let shared = IslandManager()
    
    private var window: NSPanel?
    private var hostingView: NSHostingView<IslandView>?
    
    private override init() {
        super.init()
    }
    
    public func setup() {
        guard window == nil else { return }
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 100), // Base size, SwiftUI will resize
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        panel.delegate = self
        
        // Disable mouse interaction completely so it doesn't block settings/other windows below it.
        panel.ignoresMouseEvents = true
        
        let islandView = IslandView()
        let hostingView = PassThroughHostingView(rootView: islandView)
        // Make the hosting view transparent
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        self.hostingView = hostingView
        self.window = panel
        
        positionWindow()
        
        // Listen to screen changes to reposition
        NotificationCenter.default.addObserver(self, selector: #selector(positionWindow), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        
        panel.makeKeyAndOrderFront(nil)
        
        // Add to CGSSpace to immune against Mission Control space switching
        NotchSpaceManager.shared.notchSpace.windows.insert(panel)
    }
    
    @objc private func positionWindow() {
        guard let window = window, let screen = NSScreen.screens.first else { return }
        
        // The screen with the notch is typically the built-in screen.
        // If there's a notch, safeAreaInsets.top is > 0 (typically 32 or 38).
        let notchHeight = screen.safeAreaInsets.top
        
        // Detect if the display is being mirrored
        let mainDisplayId = CGMainDisplayID()
        let isMirrored = CGDisplayIsInMirrorSet(mainDisplayId) != 0
        
        if notchHeight <= 0 || isMirrored {
            window.alphaValue = 0.0 // Hide on non-notch screens or when mirrored
        } else {
            window.alphaValue = 1.0
        }
        
        let width: CGFloat = 800
        let height: CGFloat = 200 // Allow enough height for expansion
        
        let x = screen.frame.origin.x + (screen.frame.width - width) / 2
        
        // We want the TOP of our 200-height panel to be exactly at the top of the screen.
        // screen.frame.maxY is the top of the screen.
        let y = screen.frame.maxY - height
        
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
}
