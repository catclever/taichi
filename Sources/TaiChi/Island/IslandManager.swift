import Cocoa
import SwiftUI
import Combine

// MARK: - Bug Fix Documentation
// 1. Problem Fixed: Transparent Panel Blocking Clicks
//    The Island's transparent window panel was intercepting mouse clicks far below the notch in the idle state.
//    Attempting to use `NSView.hitTest` within a transparent view failed because the Window Server still routes 
//    clicks to the transparent window if `ignoresMouseEvents` is false, regardless of hitTest returning nil.
// 2. Resolution:
//    We removed `PassThroughHostingView` entirely. Instead, `IslandManager` sets up a global 0.05s Timer
//    to manually check `NSEvent.mouseLocation`.
//    - If the mouse is INSIDE the dynamically calculated notch/panel area (`isInside == true`), we set `ignoresMouseEvents = false`
//      so the user can click the Island.
//    - If the mouse is OUTSIDE the area, we set `ignoresMouseEvents = true` so all clicks perfectly pass through
//      to the windows underneath. We also use this to handle the 0.5 alpha fade when the panel is pinned.
// 3. Caveats / Future Development:
//    - This timer runs continuously. It is very lightweight (0.05s intervals reading `NSEvent.mouseLocation`), 
//      but ensure it doesn't cause retain cycles or layout recalculations.
//    - `IslandView` now completely relies on `IslandStateModel.shared.isHovering` set by this timer instead of SwiftUI's `onHover`.

@MainActor
public class IslandManager: NSObject, NSWindowDelegate {
    public static let shared = IslandManager()
    
    private var window: NSPanel?
    private var hostingView: NSHostingView<IslandView>?
    private var cancellables = Set<AnyCancellable>()
    private var hoverTimer: Timer?
    
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
        
        // Use a standard NSHostingView. We handle clicks dynamically by toggling ignoresMouseEvents.
        let islandView = IslandView()
        let hostingView = NSHostingView(rootView: islandView)
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
        
        startGlobalHoverTimer()
    }
    
    private func startGlobalHoverTimer() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkMouseHover()
            }
        }
    }
    
    private func checkMouseHover() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            return
        }
        
        let stateModel = IslandStateModel.shared
        
        // Define the interactive area based on state
        var hitWidth = stateModel.capsuleWidth
        var hitHeight = stateModel.capsuleHeight
        
        // Add a buffer when expanded to avoid jitter
        if stateModel.state == .expanded {
            hitWidth += 40
            hitHeight += 10
        }
        
        let screenFrame = screen.frame
        let centerX = screenFrame.midX
        let topY = screenFrame.maxY
        
        let minX = centerX - (hitWidth / 2)
        let maxX = centerX + (hitWidth / 2)
        let minY = topY - hitHeight
        
        let isInside = mouseLocation.x >= minX && mouseLocation.x <= maxX && mouseLocation.y >= minY
        
        // Update hover state
        if stateModel.isHovering != isInside {
            stateModel.isHovering = isInside
        }
        
        // When the mouse is inside the interactive area, we catch clicks.
        // When outside, we pass clicks through to the apps behind us.
        setPanelFocusedState(isInside)
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
    
    public func setPanelFocusedState(_ focused: Bool) {
        guard let window = window else { return }
        
        if !focused && IslandStateModel.shared.isPinned {
            window.alphaValue = 0.5
        } else {
            window.alphaValue = 1.0
        }
        
        if window.ignoresMouseEvents != !focused {
            window.ignoresMouseEvents = !focused
        }
    }
}
