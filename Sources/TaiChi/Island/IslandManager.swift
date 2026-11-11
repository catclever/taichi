import Cocoa
import SwiftUI
import Combine
import os.log

// =========================================================================================
// [BUG FIX: WindowServer Compositing, Hover Throttling & Redundant State Broadcasts]
// 1. Problem:
//    - Hidden lyric window previously kept `alphaValue = 0.0` but stayed attached to the WindowServer tree
//      (`orderFront`), forcing unnecessary WindowServer GPU composition passes.
//    - Mouse movement event monitors invoked `checkMouseHover()` on every mouse pixel movement without throttling,
//      causing high CPU wakeups during normal mouse activity.
//    - Unconditional writes to `@Published` properties (`isNotchHovered`, `isCenterNotchHovered`, `isHoveringIcons`)
//      broadcasted `objectWillChange` on every mouse event even if values were unchanged, thrashing SwiftUI views.
//    - Redundant `window.alphaValue` assignments in `setPanelFocusedState()` incurred unnecessary WindowServer IPC.
// 2. Resolution:
//    - Implemented `updateLyricWindowVisibility()` with `orderOut(nil)` upon hiding and `orderFront(nil)` before showing.
//    - Added 50ms throttling to mouse moved monitors using `lastHoverCheckTime`.
//    - Added equality guards before updating `@Published` hover states on `IslandStateModel`.
//    - Added epsilon delta check (`abs(window.alphaValue - targetAlpha) > 0.001`) before updating `window.alphaValue`.
// 3. Caveats:
//    - Ensure `orderFront(nil)` is called before adjusting alpha to 1.0 when the lyric window becomes visible.
//    - Maintain 50ms throttle threshold for smooth responsiveness without human-perceptible lag.
// =========================================================================================

@MainActor
public class IslandManager: NSObject, NSWindowDelegate {
    public static let shared = IslandManager()
    
    private var window: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    
    private var lyricWindow: NSPanel?
    private var lyricHostingView: NSHostingView<AnyView>?
    
    private var multiAppListWindow: NSPanel?
    private var multiAppListHostingView: NSHostingView<AnyView>?
    
    private var cancellables = Set<AnyCancellable>()
    private var hoverTimer: Timer?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var lastIsVisibleDueToApps: Bool = true
    
    private var lastHoverCheckTime: TimeInterval = 0
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    
    private override init() {
        super.init()
    }
    
    private func setupClickMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideClick(event: event)
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideClick(event: event)
            return event
        }
    }
    
    private func handleOutsideClick(event: NSEvent) {
        let stateModel = IslandStateModel.shared
        let location = NSEvent.mouseLocation
        
        let inMultiApp = multiAppListWindow?.frame.contains(location) ?? false
        let inMain = window?.frame.contains(location) ?? false
        
        if event.type == .rightMouseDown {
            if stateModel.isLocationInPhysicalNotch(location) {
                if stateModel.state != .modeSwitcher {
                    DispatchQueue.main.async {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            stateModel.state = .modeSwitcher
                        }
                    }
                }
                return
            }
        }
        
        if stateModel.state == .modeSwitcher {
            if !inMain {
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        stateModel.state = .idle
                    }
                }
            }
            return
        }
        
        guard stateModel.state == .multiAppList else { return }
        
        if !inMultiApp && !inMain {
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    stateModel.state = .idle
                }
            }
        }
    }
    
    public func setup() {
        guard window == nil else { return }
        
        setupMainWindow()
        setupLyricWindow()
        setupMultiAppListWindow()
        setupClickMonitors()
        
        positionWindow()
        
        NotificationCenter.default.addObserver(self, selector: #selector(positionWindow), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        
        IslandStateModel.shared.$activeScreenIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.positionWindow()
            }
            .store(in: &cancellables)
            
        IslandStateModel.shared.$lyricScreenIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.positionWindow()
            }
            .store(in: &cancellables)
            
        IslandStateModel.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.positionWindow()
            }
            .store(in: &cancellables)
            
        MediaObserver.shared.$state
            .map { "\($0.status.rawValue)|\($0.title.isEmpty)" }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.positionWindow()
            }
            .store(in: &cancellables)
            
        MediaObserver.shared.$activeMediaApps
            .map { $0.isEmpty }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.positionWindow()
            }
            .store(in: &cancellables)
            
        startGlobalHoverTimer()
    }
    
    private func setupMainWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 500, y: 1000, width: 800, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 3)
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        panel.delegate = self
        
        let islandView = IslandView().environmentObject(IslandStateModel.shared)
        let hostView = AcceptingFirstMouseHostingView(rootView: AnyView(islandView))
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostView
        
        self.hostingView = hostView
        self.window = panel
        
        panel.orderFront(nil)
        NotchSpaceManager.shared.notchSpace.windows.insert(panel)
    }
    
    private func setupLyricWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 500, y: 1000, width: 400, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 3)
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        panel.alphaValue = 0.0
        
        let lyricView = StandaloneLyricView().environmentObject(IslandStateModel.shared)
        let hostView = AcceptingFirstMouseHostingView(rootView: AnyView(lyricView))
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostView
        
        self.lyricHostingView = hostView
        self.lyricWindow = panel
        
        // Window visibility is actively managed by updateLyricWindowVisibility to avoid composition overhead
        NotchSpaceManager.shared.notchSpace.windows.insert(panel)
    }
    
    private func setupMultiAppListWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 500, y: 1000, width: 300, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 3)
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        
        let listView = MultiAppListView().environmentObject(IslandStateModel.shared)
        
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 24
        visualEffect.layer?.masksToBounds = true
        
        let hostView = AcceptingFirstMouseHostingView(rootView: AnyView(listView))
        hostView.autoresizingMask = [.width, .height]
        
        visualEffect.addSubview(hostView)
        
        panel.contentView = visualEffect
        
        self.multiAppListHostingView = hostView
        self.multiAppListWindow = panel
        
        panel.orderFront(nil)
        NotchSpaceManager.shared.notchSpace.windows.insert(panel)
    }
    
    private func startGlobalHoverTimer() {
        // [BUG FIX: High CPU Usage & 50ms Throttling]
        // Replaced unthrottled mouseMoved monitors with a 50ms rate limit to prevent CPU wakeups
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self = self else { return }
            let now = Date().timeIntervalSince1970
            guard now - self.lastHoverCheckTime > 0.05 else { return }
            self.lastHoverCheckTime = now
            Task { @MainActor in
                self.checkMouseHover()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self = self else { return event }
            let now = Date().timeIntervalSince1970
            guard now - self.lastHoverCheckTime > 0.05 else { return event }
            self.lastHoverCheckTime = now
            Task { @MainActor in
                self.checkMouseHover()
            }
            return event
        }
    }
    
    private func isIslandVisibleDueToApps() -> Bool {
        let state = MediaObserver.shared.state
        if state.status == .stopped {
            return false
        }
        return !state.title.isEmpty || state.isPlaying || !MediaObserver.shared.activeMediaApps.isEmpty
    }
    
    private func checkMouseHover() {
        let mouseLocation = NSEvent.mouseLocation
        let stateModel = IslandStateModel.shared
        let screens = NSScreen.screens
        
        var isMainHovered = false
        var isNotchHovered = false
        var isLyricHovered = false
        var isMultiAppHovered = false
        var isCenterNotchHovered = false
        var isHoveringIcons = false
        
        let isVisibleDueToApps = isIslandVisibleDueToApps()
        
        if stateModel.activeScreenIndex < screens.count {
            let mainScreen = screens[stateModel.activeScreenIndex]
            
            var hitWidth = stateModel.capsuleWidth
            var hitHeight = stateModel.capsuleHeight
            
            if stateModel.state == .expanded || stateModel.state == .modeSwitcher || stateModel.state == .trackChanged { 
                hitWidth += 40
                hitHeight += 20 
            } else if stateModel.state == .idle {
                hitHeight = min(hitHeight, 12) // Require sliding deeper into the notch (top 12px)
            }
            
            let minX = mainScreen.frame.midX - (hitWidth / 2)
            let maxX = mainScreen.frame.midX + (hitWidth / 2)
            let minY = mainScreen.frame.maxY - hitHeight
            
            // Second stage hover: Physical notch area (~36px height)
            let notchMinY = mainScreen.frame.maxY - 36
            isNotchHovered = mouseLocation.x >= minX && mouseLocation.x <= maxX && mouseLocation.y >= notchMinY
            
            // Guard @Published updates to avoid redundant view invalidation broadcasts
            if stateModel.isNotchHovered != isNotchHovered {
                stateModel.isNotchHovered = isNotchHovered
            }
            
            isMainHovered = mouseLocation.x >= minX && mouseLocation.x <= maxX && mouseLocation.y >= minY
            
            let centerMinX = mainScreen.frame.midX - 95
            let centerMaxX = mainScreen.frame.midX + 95
            isCenterNotchHovered = isMainHovered && (mouseLocation.x >= centerMinX && mouseLocation.x <= centerMaxX)
            
            let isAnyHovered = isMainHovered || isNotchHovered
            isHoveringIcons = isAnyHovered && !isCenterNotchHovered
        }
        
        if stateModel.isCenterNotchHovered != isCenterNotchHovered {
            stateModel.isCenterNotchHovered = isCenterNotchHovered
        }
        if stateModel.isHoveringIcons != isHoveringIcons {
            stateModel.isHoveringIcons = isHoveringIcons
        }
        
        if stateModel.isLyricDetached, let lIndex = stateModel.lyricScreenIndex, lIndex < screens.count {
            let lScreen = screens[lIndex]
            let hitWidth: CGFloat = 390
            let hitHeight: CGFloat = 38
            let minX = lScreen.frame.midX - (hitWidth / 2)
            let maxX = lScreen.frame.midX + (hitWidth / 2)
            let minY = lScreen.frame.maxY - hitHeight
            
            isLyricHovered = mouseLocation.x >= minX && mouseLocation.x <= maxX && mouseLocation.y >= minY
        }
        
        if stateModel.state == .multiAppList {
            if let frame = multiAppListWindow?.frame {
                isMultiAppHovered = frame.contains(mouseLocation)
            }
        }
        
        let visibilityChanged = isVisibleDueToApps != self.lastIsVisibleDueToApps
        if visibilityChanged {
            self.lastIsVisibleDueToApps = isVisibleDueToApps
        }
        
        let effectiveHover = isMainHovered || isNotchHovered
        if stateModel.isHovering != effectiveHover || visibilityChanged {
            stateModel.isHovering = effectiveHover
            DispatchQueue.main.async { [weak self] in
                self?.positionWindow()
            }
        }
        
        setPanelFocusedState(effectiveHover || isMultiAppHovered)
        
        if let lyricWindow = lyricWindow {
            let targetIgnores = !isLyricHovered
            if lyricWindow.ignoresMouseEvents != targetIgnores {
                lyricWindow.ignoresMouseEvents = targetIgnores
            }
        }
        if let multiAppListWindow = multiAppListWindow {
            if multiAppListWindow.ignoresMouseEvents {
                multiAppListWindow.ignoresMouseEvents = false
            }
        }
    }
    
    private func updateLyricWindowVisibility(isVisible: Bool, isMirrored: Bool = false) {
        guard let lyricWindow = lyricWindow else { return }
        let shouldShow = isVisible && !isMirrored
        let targetAlpha: CGFloat = shouldShow ? 1.0 : 0.0
        
        if shouldShow {
            if !lyricWindow.isVisible {
                lyricWindow.orderFront(nil)
            }
            if abs(lyricWindow.alphaValue - targetAlpha) > 0.001 {
                lyricWindow.alphaValue = targetAlpha
            }
        } else {
            if abs(lyricWindow.alphaValue - 0.0) > 0.001 {
                lyricWindow.alphaValue = 0.0
            }
            if lyricWindow.isVisible {
                lyricWindow.orderOut(nil)
            }
        }
    }
    
    @objc private func positionWindow() {
        guard let window = window else { return }
        
        let stateModel = IslandStateModel.shared
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        
        // --- 1. Determine Target Screen ---
        var targetScreen: NSScreen = screens[0]
        var targetIndex = 0
        
        if let builtInIndex = screens.firstIndex(where: { $0.frame.origin == .zero }) {
            targetScreen = screens[builtInIndex]
            targetIndex = builtInIndex
        }

        if stateModel.activeScreenIndex != targetIndex {
             DispatchQueue.main.async {
                 stateModel.activeScreenIndex = targetIndex
             }
        }
        
        // --- 2. Handle Mirroring / Visibility ---
        let mainDisplayId = CGMainDisplayID()
        let isMirrored = CGDisplayIsInMirrorSet(mainDisplayId) != 0
        
        let shouldShow = isIslandVisibleDueToApps()
        let isVisible = !isMirrored && (shouldShow || stateModel.isHovering)
        
        let targetWindowAlpha: CGFloat = isVisible ? 1.0 : 0.0
        if abs(window.alphaValue - targetWindowAlpha) > 0.001 {
            window.alphaValue = targetWindowAlpha
        }
        
        let width: CGFloat = 800
        let height: CGFloat = 200
        let x = targetScreen.frame.origin.x + (targetScreen.frame.width - width) / 2
        let y = targetScreen.frame.maxY - height
        
        let newFrame = NSRect(x: x, y: y, width: width, height: height)
        if window.frame != newFrame {
            window.setFrame(newFrame, display: true)
        }
        
        if let lyricWindow = lyricWindow {
            var targetLyricIndex = stateModel.lyricScreenIndex
            
            if targetLyricIndex == nil, let savedName = stateModel.savedLyricScreenName {
                if let foundIndex = screens.firstIndex(where: { $0.localizedName == savedName }) {
                    targetLyricIndex = foundIndex
                    DispatchQueue.main.async {
                        stateModel.lyricScreenIndex = foundIndex
                    }
                }
            } else if let index = targetLyricIndex, index < screens.count {
                let currentScreenName = screens[index].localizedName
                if stateModel.savedLyricScreenName != currentScreenName {
                    DispatchQueue.main.async {
                        stateModel.savedLyricScreenName = currentScreenName
                    }
                }
            } else if let index = targetLyricIndex, index >= screens.count {
                if let savedName = stateModel.savedLyricScreenName, let foundIndex = screens.firstIndex(where: { $0.localizedName == savedName }) {
                    targetLyricIndex = foundIndex
                    DispatchQueue.main.async {
                        stateModel.lyricScreenIndex = foundIndex
                    }
                } else {
                    targetLyricIndex = 0
                    DispatchQueue.main.async {
                        stateModel.lyricScreenIndex = 0
                        stateModel.savedLyricScreenName = screens[0].localizedName
                    }
                }
            }
            
            let isDetached = targetLyricIndex != nil && targetLyricIndex != targetIndex
            let shouldShowLyric = stateModel.isLyricPinned && isDetached && (targetLyricIndex != nil && targetLyricIndex! < screens.count)
            
            if shouldShowLyric, let lIndex = targetLyricIndex, lIndex < screens.count {
                let lScreen = screens[lIndex]
                let lX = lScreen.frame.origin.x + (lScreen.frame.width - width) / 2
                let lY = lScreen.frame.maxY - height
                let newFrame = NSRect(x: lX, y: lY, width: width, height: height)
                if lyricWindow.frame != newFrame {
                    lyricWindow.setFrame(newFrame, display: true)
                }
                updateLyricWindowVisibility(isVisible: true, isMirrored: isMirrored)
            } else {
                updateLyricWindowVisibility(isVisible: false, isMirrored: isMirrored)
            }
        }
        
        if let multiAppWindow = multiAppListWindow {
            if stateModel.state == .multiAppList {
                let mWidth: CGFloat = 300
                let activeCount = MediaObserver.shared.activeMediaApps.filter { app in
                    if app.playStateString == "playing" || app.playStateString == "paused" { return true }
                    if app.bundleIdentifier == MediaObserver.shared.state.bundleIdentifier && (!MediaObserver.shared.state.title.isEmpty || MediaObserver.shared.state.isPlaying) { return true }
                    return false
                }.count
                
                let mHeight: CGFloat = min(CGFloat(max(1, activeCount) * 44 + 20), 400)
                let padding: CGFloat = 16
                let mX = targetScreen.frame.origin.x + (targetScreen.frame.width - mWidth) / 2
                let mY = targetScreen.frame.maxY - stateModel.capsuleHeight - padding - mHeight
                multiAppWindow.setFrame(NSRect(x: mX, y: mY, width: mWidth, height: mHeight), display: true)
                
                if let host = multiAppListHostingView {
                    host.frame = NSRect(x: 0, y: 0, width: mWidth, height: mHeight)
                }
                
                let targetAlpha: CGFloat = isMirrored ? 0.0 : 1.0
                if abs(multiAppWindow.alphaValue - targetAlpha) > 0.001 {
                    multiAppWindow.alphaValue = targetAlpha
                }
            } else {
                if abs(multiAppWindow.alphaValue - 0.0) > 0.001 {
                    multiAppWindow.alphaValue = 0.0
                }
            }
        }
    }
    
    public func setPanelFocusedState(_ focused: Bool) {
        guard let window = window else { return }
        
        let shouldShow = isIslandVisibleDueToApps()
        let isMirrored = IslandStateModel.shared.activeScreenIndex >= NSScreen.screens.count
        let isVisible = !isMirrored && (shouldShow || IslandStateModel.shared.isHovering)
        
        let targetAlpha: CGFloat
        if isVisible {
            if !focused && IslandStateModel.shared.isPinned {
                targetAlpha = 0.5
            } else {
                targetAlpha = 1.0
            }
        } else {
            targetAlpha = 0.0
        }
        
        if abs(window.alphaValue - targetAlpha) > 0.001 {
            window.alphaValue = targetAlpha
        }
        
        if window.ignoresMouseEvents != !focused {
            window.ignoresMouseEvents = !focused
        }
    }
}
