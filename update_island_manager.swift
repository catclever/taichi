import Foundation

let path = "/Users/kael/Projects/taichi_launcher/Sources/TaiChi/Island/IslandManager.swift"
var content = try! String(contentsOfFile: path)

// 1. Add lyric properties
content = content.replacingOccurrences(of: """
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
""", with: """
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private var lyricWindow: NSWindow?
    private var lyricHostingView: NSHostingView<AnyView>?
""")

// 2. Setup lyric window
let setupMain = """
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
"""
let setupLyric = """
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        
        let lyricPanel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        lyricPanel.level = NSWindow.Level(rawValue: Int(NSWindow.Level.mainMenu.rawValue) + 3)
        lyricPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        lyricPanel.isReleasedWhenClosed = false
        lyricPanel.backgroundColor = .clear
        lyricPanel.hasShadow = false
        lyricPanel.isOpaque = false
        lyricPanel.delegate = self
        
        let standaloneLyricView = StandaloneLyricView()
            .environmentObject(IslandStateModel.shared)
        
        let lHostingView = NSHostingView(rootView: AnyView(standaloneLyricView))
        lHostingView.layer?.backgroundColor = NSColor.clear.cgColor
        lHostingView.frame = lyricPanel.contentRect(forFrameRect: lyricPanel.frame)
        lyricPanel.contentView = lHostingView
        self.lyricHostingView = lHostingView
        self.lyricWindow = lyricPanel
        
        lyricPanel.makeKeyAndOrderFront(nil)
        lyricPanel.orderFrontRegardless()
"""
content = content.replacingOccurrences(of: setupMain, with: setupLyric)

let observeIndex = """
        IslandStateModel.shared.$activeScreenIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.positionWindow()
            }
            .store(in: &cancellables)
"""
let observeIndexes = """
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
"""
content = content.replacingOccurrences(of: observeIndex, with: observeIndexes)

let spaceMain = """
        NotchSpaceManager.shared.notchSpace.windows.insert(panel)
"""
let spaceBoth = """
        NotchSpaceManager.shared.notchSpace.windows.insert(panel)
        NotchSpaceManager.shared.notchSpace.windows.insert(lyricPanel)
"""
content = content.replacingOccurrences(of: spaceMain, with: spaceBoth)


// 3. checkMouseHover
let oldHover = """
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
"""

let newHover = """
    private func checkMouseHover() {
        let mouseLocation = NSEvent.mouseLocation
        let stateModel = IslandStateModel.shared
        let screens = NSScreen.screens
        
        var isMainHovered = false
        var isLyricHovered = false
        
        if stateModel.activeScreenIndex < screens.count {
            let mainScreen = screens[stateModel.activeScreenIndex]
            var hitWidth = stateModel.capsuleWidth
            var hitHeight = stateModel.capsuleHeight
            if stateModel.state == .expanded { hitWidth += 40; hitHeight += 10 }
            
            let minX = mainScreen.frame.midX - (hitWidth / 2)
            let maxX = mainScreen.frame.midX + (hitWidth / 2)
            let minY = mainScreen.frame.maxY - hitHeight
            
            isMainHovered = mouseLocation.x >= minX && mouseLocation.x <= maxX && mouseLocation.y >= minY
        }
        
        if stateModel.isLyricDetached, let lIndex = stateModel.lyricScreenIndex, lIndex < screens.count {
            let lScreen = screens[lIndex]
            // Lyric island is typically baseNotchWidth + 200*scale
            // We approximate hit area
            let hitWidth: CGFloat = 190 + 200
            let hitHeight: CGFloat = 38
            
            let minX = lScreen.frame.midX - (hitWidth / 2)
            let maxX = lScreen.frame.midX + (hitWidth / 2)
            let minY = lScreen.frame.maxY - hitHeight
            
            isLyricHovered = mouseLocation.x >= minX && mouseLocation.x <= maxX && mouseLocation.y >= minY
        }
        
        if stateModel.isHovering != isMainHovered {
            stateModel.isHovering = isMainHovered
        }
        
        setPanelFocusedState(isMainHovered)
        
        if let lyricWindow = lyricWindow {
            if lyricWindow.ignoresMouseEvents != !isLyricHovered {
                lyricWindow.ignoresMouseEvents = !isLyricHovered
            }
        }
    }
"""
content = content.replacingOccurrences(of: oldHover, with: newHover)


// 4. positionWindow
let oldPos = """
        let width: CGFloat = 800
        let height: CGFloat = 200 // Allow enough height for expansion
        
        let x = screen.frame.origin.x + (screen.frame.width - width) / 2
        let y = screen.frame.maxY - height
        
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
"""

let newPos = """
        let width: CGFloat = 800
        let height: CGFloat = 200 // Allow enough height for expansion
        
        let x = screen.frame.origin.x + (screen.frame.width - width) / 2
        let y = screen.frame.maxY - height
        
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        
        if let lyricWindow = lyricWindow {
            if stateModel.isLyricDetached, let lIndex = stateModel.lyricScreenIndex, lIndex < screens.count {
                let lScreen = screens[lIndex]
                let lX = lScreen.frame.origin.x + (lScreen.frame.width - width) / 2
                let lY = lScreen.frame.maxY - height
                lyricWindow.setFrame(NSRect(x: lX, y: lY, width: width, height: height), display: true)
                lyricWindow.alphaValue = isMirrored ? 0.0 : 1.0
            } else {
                lyricWindow.alphaValue = 0.0
            }
        }
    }
"""
content = content.replacingOccurrences(of: oldPos, with: newPos)

try! content.write(toFile: path, atomically: true, encoding: .utf8)
print("Updated IslandManager.swift")
