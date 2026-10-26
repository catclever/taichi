import Cocoa
import SwiftUI
import Combine

// =========================================================================================
// [BUG FIX: Menu Bar Lyric Floating Overlay Window & Power Optimization]
// 1. Problem:
//    Previously, dynamic scrolling text and subviews were embedded directly inside NSStatusItem.button.
//    Updating subview frames at 10Hz forced AppKit to trigger `-[NSStatusItem _updateReplicants]`
//    (CPU software snapshotting via `CALayer.renderInContext:`) and continuous XPC fence syncs
//    to ControlCenter and WindowServer on every frame, resulting in unacceptable battery drain and CPU load.
// 2. Resolution:
//    - Replaced in-button subviews with a lightweight, GPU-accelerated borderless Floating Overlay Window (`NSPanel`).
//    - The overlay window is configured with `.statusBar` level, clear background, non-activating panel,
//      and `ignoresMouseEvents = true` so user clicks pass directly through to `NSStatusItem.button`.
//    - When paused, the overlay window is hidden via `orderOut(nil)`, timers are stopped, and the status item
//      shows a static "♪" symbol with variable width.
//    - When playing, the status item length is fixed to 150pt (acting as a transparent click receptor),
//      and the overlay window tracks the button's screen coordinates, rendering lyrics via GPU/Metal.
// 3. Caveats:
//    - The overlay window must track screen frame changes when displays reconfigure or status items move.
//    - `ignoresMouseEvents = true` must be maintained so clicking the lyric still triggers the player popover.
// =========================================================================================

class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

class PassThroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

@MainActor
class MenuBarLyricManager: NSObject {
    static let shared = MenuBarLyricManager()
    
    private var statusItem: NSStatusItem?
    private var overlayWindow: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var lyricTimer: Timer?
    
    private var currentFullLyric: String = ""
    
    private var isScrolling: Bool = false
    private var scrollOffset: CGFloat = 0.0
    private var textWidth: CGFloat = 0.0
    
    private var clipView: PassThroughView?
    private var lyricLabel: PassThroughTextField?
    
    private var popover: NSPopover?
    private var popoverEventMonitor: Any?
    
    private override init() {
        super.init()
        setupObservers()
        NotificationCenter.default.addObserver(self, selector: #selector(handleScreenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleScreenParametersChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }
    
    @objc private func handleScreenParametersChanged() {
        updateOverlayPosition()
    }
    
    private func setupObservers() {
        TaiChiSettings.shared.$showMenuBarLyrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                guard let self = self else { return }
                if show {
                    self.createStatusItem()
                } else {
                    self.removeStatusItem()
                }
                self.evaluateTimer()
            }
            .store(in: &cancellables)
            
        MediaObserver.shared.$state
            .map { $0.isPlaying }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPlaying in
                guard let self = self else { return }
                if !isPlaying {
                    self.stopTimer()
                    self.updateLyric()
                } else {
                    self.evaluateTimer()
                }
            }
            .store(in: &cancellables)
    }
    
    private func evaluateTimer() {
        let shouldRun = TaiChiSettings.shared.showMenuBarLyrics && MediaObserver.shared.state.isPlaying
        if shouldRun {
            if lyricTimer == nil {
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.updateLyric()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                lyricTimer = timer
            }
        } else {
            stopTimer()
        }
    }
    
    private func stopTimer() {
        lyricTimer?.invalidate()
        lyricTimer = nil
    }
    
    private func setupOverlayWindow() {
        if overlayWindow != nil { return }
        
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        
        let cv = PassThroughView(frame: .zero)
        cv.wantsLayer = true
        cv.layer?.masksToBounds = true
        cv.layer?.backgroundColor = NSColor.clear.cgColor
        cv.autoresizingMask = [.width, .height]
        
        let label = PassThroughTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false
        
        cv.addSubview(label)
        panel.contentView = cv
        
        self.clipView = cv
        self.lyricLabel = label
        self.overlayWindow = panel
    }
    
    private func updateOverlayPosition() {
        guard let button = statusItem?.button, let win = button.window else { return }
        
        // Mirror the exact appearance and dynamically compute high-contrast text color without any background plate
        if let overlay = overlayWindow {
            if overlay.appearance != button.effectiveAppearance {
                overlay.appearance = button.effectiveAppearance
            }
            let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let targetColor = isDark ? NSColor.white.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.90)
            if lyricLabel?.textColor != targetColor {
                lyricLabel?.textColor = targetColor
            }
        }
        
        let buttonFrameInWin = button.convert(button.bounds, to: nil)
        let screenFrame = win.convertToScreen(buttonFrameInWin)
        if let overlay = overlayWindow {
            if overlay.frame != screenFrame {
                overlay.setFrame(screenFrame, display: true)
            }
            clipView?.frame = overlay.contentView?.bounds ?? .zero
        }
    }
    
    private func createStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.autosaveName = "TaiChiMenuBarLyrics" 
            if let button = statusItem?.button {
                button.action = #selector(handleStatusItemClick)
                button.target = self
                button.title = "♪"
                button.subviews.forEach { $0.removeFromSuperview() }
            }
            setupOverlayWindow()
        }
        updateLyric() // initial
    }
    
    private func removeStatusItem() {
        stopTimer()
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        clipView = nil
        lyricLabel = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
    
    private func updateLyric() {
        guard let item = statusItem, let button = item.button else { return }
        
        let mediaState = MediaObserver.shared.state
        if !mediaState.isPlaying {
            overlayWindow?.orderOut(nil)
            stopTimer()
            if currentFullLyric != "TaiChi" {
                currentFullLyric = "TaiChi"
                button.title = "♪"
                item.length = NSStatusItem.variableLength
            }
            return
        }
        
        let fixedWidth: CGFloat = 150
        if item.length != fixedWidth {
            item.length = fixedWidth
        }
        if button.title != "" {
            button.title = ""
        }
        
        setupOverlayWindow()
        updateOverlayPosition()
        if overlayWindow?.isVisible != true {
            overlayWindow?.orderFront(nil)
        }
        
        let lyrics = LyricManager.shared.currentLyrics
        var newLyric = ""
        
        if lyrics.isEmpty {
            newLyric = "\(mediaState.title) - \(mediaState.artist)"
        } else {
            let actualTime = mediaState.currentElapsedTime
            let currentIndex = lyrics.lastIndex(where: { $0.time <= actualTime + 0.5 }) ?? 0
            if currentIndex >= 0 && currentIndex < lyrics.count {
                newLyric = lyrics[currentIndex].text
            }
        }
        
        if newLyric != currentFullLyric {
            currentFullLyric = newLyric
            setDisplayText(newLyric)
        } else if isScrolling {
            scrollOffset += 1.5
            let distance = textWidth - fixedWidth + 15
            if scrollOffset > distance {
                scrollOffset = -15 // Wait at the beginning before repeating
            }
            if scrollOffset > 0 {
                lyricLabel?.frame.origin.x = 5 - scrollOffset
            }
        }
    }
    
    private func setDisplayText(_ text: String) {
        guard let cv = clipView, let lbl = lyricLabel else { return }
        
        // Cancel active animations just in case
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        lbl.animator().frame.origin.x = lbl.frame.origin.x
        NSAnimationContext.endGrouping()
        lbl.layer?.removeAllAnimations()
        
        let fixedWidth: CGFloat = 150
        let displayStr = text.isEmpty ? " ♪ " : " \(text) "
        lbl.stringValue = displayStr
        lbl.sizeToFit()
        
        // Center vertically in overlay container
        lbl.frame.origin.y = (cv.bounds.height - lbl.frame.height) / 2
        
        if text.isEmpty || text == "TaiChi" {
            lbl.frame.origin.x = (cv.bounds.width - lbl.frame.width) / 2
            self.isScrolling = false
        } else {
            self.textWidth = lbl.frame.width
            lbl.lineBreakMode = .byClipping
            lbl.frame.size.width = max(textWidth, fixedWidth)
            
            if textWidth > fixedWidth {
                self.isScrolling = true
                self.scrollOffset = -15 // Start with a small delay
                lbl.frame.origin.x = 5
            } else {
                self.isScrolling = false
                lbl.frame.origin.x = (fixedWidth - textWidth) / 2
            }
        }
    }
    
    @objc private func handleStatusItemClick() {
        guard let button = statusItem?.button else { return }
        
        let clickCount = NSApp.currentEvent?.clickCount ?? 1
        if clickCount == 2 {
            popover?.performClose(nil)
            let bundleId = MediaObserver.shared.state.bundleIdentifier
            if !bundleId.isEmpty {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
                }
            }
            return
        }
        
        if !MediaObserver.shared.isPlaybackControlSupported() {
            return
        }
        
        if popover == nil {
            let p = NSPopover()
            p.contentSize = NSSize(width: 240, height: 60)
            p.behavior = .transient
            
            let host = NSHostingController(rootView: MenuBarPlayerView())
            p.contentViewController = host
            self.popover = p
            
            popoverEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let strongSelf = self, strongSelf.popover?.isShown == true {
                    strongSelf.popover?.performClose(event)
                }
            }
        }
        
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

struct MenuBarPlayerView: View {
    @ObservedObject var observer = MediaObserver.shared
    
    var body: some View {
        HStack(spacing: 20) {
            Button(action: { observer.sendTargetedCommand(5) }) { // Prev
                Image(systemName: "backward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .focusable(false)
            
            Button(action: { observer.sendTargetedCommand(2) }) { // Play/Pause
                Image(systemName: observer.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            .focusable(false)
            
            Button(action: { observer.sendTargetedCommand(4) }) { // Next
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .focusable(false)
            
            if let isLiked = observer.state.isLiked {
                Button(action: { observer.sendTargetedCommand(6) }) { // Toggle Like
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundColor(isLiked ? .red : .primary)
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
        }
        .padding()
        .frame(width: 240, height: 60)
    }
}
