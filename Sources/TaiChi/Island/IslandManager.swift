import Cocoa
import SwiftUI
import Combine
import os.log

@MainActor
public class IslandManager: NSObject, NSWindowDelegate {
    public static let shared = IslandManager()
    
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    
    private var lyricWindow: NSWindow?
    private var lyricHostingView: NSHostingView<AnyView>?
    
    private var multiAppListWindow: NSWindow?
    private var multiAppListHostingView: NSHostingView<AnyView>?
    
    private var cancellables = Set<AnyCancellable>()
    private var hoverTimer: Timer?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var pausedStartTime: Date?
    private var lastIsVisibleDueToApps: Bool = true
    
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
        guard stateModel.state == .multiAppList else { return }
        
        let location = NSEvent.mouseLocation
        
        let inMultiApp = multiAppListWindow?.frame.contains(location) ?? false
        let inMain = window?.frame.contains(location) ?? false
        
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
            
        startGlobalHoverTimer()
    }
    
    private func setupMainWindow() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        panel.delegate = self
        
        let islandView = IslandView().environmentObject(IslandStateModel.shared)
        let hostView = NSHostingView(rootView: AnyView(islandView))
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostView
        
        self.hostingView = hostView
        self.window = panel
        
        panel.makeKeyAndOrderFront(nil)
        NotchSpaceManager.shared.notchSpace.windows.insert(panel)
    }
    
    private func setupLyricWindow() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        
        let lyricView = StandaloneLyricView().environmentObject(IslandStateModel.shared)
        let hostView = NSHostingView(rootView: AnyView(lyricView))
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostView
        
        self.lyricHostingView = hostView
        self.lyricWindow = panel
        
        panel.makeKeyAndOrderFront(nil)
        NotchSpaceManager.shared.notchSpace.windows.insert(panel)
    }
    
    private func setupMultiAppListWindow() {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
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
        
        let hostView = NSHostingView(rootView: AnyView(listView))
        hostView.autoresizingMask = [.width, .height]
        
        visualEffect.addSubview(hostView)
        
        panel.contentView = visualEffect
        
        self.multiAppListHostingView = hostView
        self.multiAppListWindow = panel
        
        panel.makeKeyAndOrderFront(nil)
        NotchSpaceManager.shared.notchSpace.windows.insert(panel)
    }
    
    private func startGlobalHoverTimer() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkMouseHover()
            }
        }
    }
    
    private func isIslandVisibleDueToApps() -> Bool {
        let hasActiveApps = !MediaObserver.shared.activeMediaApps.isEmpty
        let isPlaying = MediaObserver.shared.state.isPlaying
        
        if isPlaying || !hasActiveApps {
            pausedStartTime = nil
            return hasActiveApps
        }
        
        if pausedStartTime == nil {
            pausedStartTime = Date()
        }
        
        if let startTime = pausedStartTime, Date().timeIntervalSince(startTime) > 600 { // 10 minutes
            return false
        }
        
        return true
    }
    
    private func checkMouseHover() {
        let mouseLocation = NSEvent.mouseLocation
        let stateModel = IslandStateModel.shared
        let screens = NSScreen.screens
        
        var isMainHovered = false
        var isLyricHovered = false
        var isMultiAppHovered = false
        
        let isVisibleDueToApps = isIslandVisibleDueToApps()
        
        if stateModel.activeScreenIndex < screens.count {
            let mainScreen = screens[stateModel.activeScreenIndex]
            
            var hitWidth = stateModel.capsuleWidth
            var hitHeight = stateModel.capsuleHeight
            
            if stateModel.state == .expanded { 
                hitWidth += 40
                hitHeight += 10 
            }
            
            let minX = mainScreen.frame.midX - (hitWidth / 2)
            let maxX = mainScreen.frame.midX + (hitWidth / 2)
            let minY = mainScreen.frame.maxY - hitHeight
            
            isMainHovered = mouseLocation.x >= minX && mouseLocation.x <= maxX && mouseLocation.y >= minY
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
        
        if stateModel.isHovering != isMainHovered || visibilityChanged {
            stateModel.isHovering = isMainHovered
            DispatchQueue.main.async { [weak self] in
                self?.positionWindow()
            }
        }
        
        setPanelFocusedState(isMainHovered || isMultiAppHovered)
        
        if let lyricWindow = lyricWindow {
            if lyricWindow.ignoresMouseEvents != !isLyricHovered {
                lyricWindow.ignoresMouseEvents = !isLyricHovered
            }
        }
        if let multiAppListWindow = multiAppListWindow {
            if multiAppListWindow.ignoresMouseEvents {
                multiAppListWindow.ignoresMouseEvents = false
            }
        }
    }
    
    @objc private func positionWindow() {
        guard let window = window else { return }
        
        let stateModel = IslandStateModel.shared
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        
        // --- 1. Determine Target Screen ---
        // Prioritize built-in screen (notch) first.
        // If not found, fallback to the main screen (screens[0])
        var targetScreen: NSScreen = screens[0]
        var targetIndex = 0
        
        // Find built-in screen (often has a subpixel layout or specific localized name, but checking for notch area is more reliable if available. For simplicity, we check if there's a screen with origin 0,0 usually built-in, or just default to 0. A more robust way is checking for safe area insets).
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
        
        // Only show if:
        // 1. Not mirrored (or if we want to show on mirror, adjust this)
        // 2. Either something is playing/paused OR user is hovering
        let shouldShow = isIslandVisibleDueToApps()
        let isVisible = !isMirrored && (shouldShow || stateModel.isHovering)
        
        window.alphaValue = isVisible ? 1.0 : 0.0
        
        let width: CGFloat = 800
        let height: CGFloat = 200
        let x = targetScreen.frame.origin.x + (targetScreen.frame.width - width) / 2
        let y = targetScreen.frame.maxY - height
        
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        
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
            
            if stateModel.isLyricPinned, isDetached, let lIndex = targetLyricIndex, lIndex < screens.count {
                let lScreen = screens[lIndex]
                let lX = lScreen.frame.origin.x + (lScreen.frame.width - width) / 2
                let lY = lScreen.frame.maxY - height
                lyricWindow.setFrame(NSRect(x: lX, y: lY, width: width, height: height), display: true)
                lyricWindow.alphaValue = isMirrored ? 0.0 : 1.0
            } else {
                lyricWindow.alphaValue = 0.0
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
                
                multiAppWindow.alphaValue = isMirrored ? 0.0 : 1.0
            } else {
                multiAppWindow.alphaValue = 0.0
            }
        }
    }
    
    public func setPanelFocusedState(_ focused: Bool) {
        guard let window = window else { return }
        
        let shouldShow = isIslandVisibleDueToApps()
        let isMirrored = IslandStateModel.shared.activeScreenIndex >= NSScreen.screens.count
        let isVisible = !isMirrored && (shouldShow || IslandStateModel.shared.isHovering)
        
        if isVisible {
            if !focused && IslandStateModel.shared.isPinned {
                window.alphaValue = 0.5
            } else {
                window.alphaValue = 1.0
            }
        } else {
            window.alphaValue = 0.0
        }
        
        if window.ignoresMouseEvents {
            window.ignoresMouseEvents = false
        }
    }
}
