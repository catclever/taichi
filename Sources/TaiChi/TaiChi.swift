import Cocoa
import SwiftUI
import Combine

@main
struct TaiChiApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// 可配置参数模型 (供后续随时调整)
// [Bug Fix Document]
// 问题：太极窗口在无焦点（非活跃）状态下，第一下点击能量球或悬浮图标没有响应，必须点第二下才生效。
// 原因：因为 TaiChiWindow 设置了非激活面板 (`nonactivatingPanel`)，macOS 默认行为是“吞噬”首次鼠标点击来赋予窗口焦点 (First-Mouse Problem)，导致 SwiftUI 手势无法接收到事件。
// 修复逻辑：自定义 NSHostingView 并重写 `acceptsFirstMouse` 强制返回 true，让其在无焦点状态下依然直接接收首次点击。
// 注意事项：不要擅自改回普通的 NSHostingView；同时需要配合 `canBecomeKey = false` 来确保点击穿透。
class AcceptingFirstMouseHostingView<Content: SwiftUI.View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
}

struct TaiChiConfig {
    var triggerEdgeHeight: CGFloat = 10.0 // 屏幕底部多少像素内算作触发区
    var triggerCenterWidth: CGFloat = 500.0 // 触发区允许的左右宽度 (屏幕中心点向两侧延伸)
    var hoverShowDelay: TimeInterval = 0.4 // 在触发区停留多久后显示
    var hoverHideDelay: TimeInterval = 0.6 // 离开区域多久后隐藏
    var hubSize: CGFloat = 200.0 // 能量球大小
}

class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var window: NSWindow!
    
    // 状态与全局监听
    var config = TaiChiConfig()
    var isVisible: Bool = false {
        didSet {
            NotificationCenter.default.post(name: .orbVisibilityChanged, object: isVisible)
        }
    }
    
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var showTimer: Timer?
    private var hideTimer: Timer?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let contentView = TaiChiOverlayView(config: config)

        let initialScreen = NSScreen.main ?? NSScreen.screens.first!
        let windowWidth: CGFloat = initialScreen.frame.width
        let windowHeight: CGFloat = config.hubSize * 2 + 80 // 足够容纳球体 + 轨道图标
        
        let windowRect = NSRect(x: initialScreen.frame.minX, y: initialScreen.frame.minY, width: windowWidth, height: windowHeight)

        let customWindow = TaiChiWindow(
            contentRect: windowRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        customWindow.isReleasedWhenClosed = false
        customWindow.isOpaque = false
        customWindow.backgroundColor = .clear
        customWindow.hasShadow = false
        customWindow.level = .floating
        customWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        
        let hostingView = AcceptingFirstMouseHostingView(rootView: contentView)
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        customWindow.contentView = hostingView
        
        customWindow.makeKeyAndOrderFront(nil)
        self.window = customWindow
        
        NotificationCenter.default.addObserver(forName: .hideTaiChi, object: nil, queue: .main) { [weak self] _ in
            self?.isVisible = false
            self?.showTimer?.invalidate()
            self?.showTimer = nil
            self?.hideTimer?.invalidate()
            self?.hideTimer = nil
        }
        
        setupMouseTracking()
    }
    
    private func setupMouseTracking() {
        let handler: (NSEvent) -> Void = { [weak self] (event: NSEvent) in
            DispatchQueue.main.async {
                self?.handleMouseMoved(location: NSEvent.mouseLocation)
            }
        }
        
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler)
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            handler(event)
            return event
        }
    }
    
    @MainActor
    private func handleMouseMoved(location: NSPoint) {
        // 找到鼠标当前所在的屏幕
        guard let currentScreen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) else { return }
        
        let currentScreenFrame = currentScreen.frame
        
        // 判断是否在触发区域（基于当前屏幕的坐标系）
        let isAtBottomEdge = location.y <= currentScreenFrame.minY + config.triggerEdgeHeight
        let isWithinHorizontalRange = abs(location.x - currentScreenFrame.midX) <= (config.triggerCenterWidth / 2)
        
        // 判定鼠标是否在能量球的显示区域内 (如果已经显示，判断逻辑依赖能量球所在的屏幕)
        let orbScreen = self.window.screen ?? currentScreen
        let orbScreenFrame = orbScreen.frame
        // 扩大悬停判定区以覆盖轨道图标的高度 (hubSize/2 + 80)
        let hoverZoneRadius = config.hubSize / 2 + 80
        let isOverOrb = isVisible && (location.y <= orbScreenFrame.minY + hoverZoneRadius && abs(location.x - orbScreenFrame.midX) <= hoverZoneRadius)

        if (isAtBottomEdge && isWithinHorizontalRange) || isOverOrb {
            hideTimer?.invalidate()
            hideTimer = nil
            
            if !isVisible && showTimer == nil {
                showTimer = Timer.scheduledTimer(withTimeInterval: config.hoverShowDelay, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        // 在唤起前，将窗口瞬移到鼠标触发的当前屏幕
                        self.moveToScreenFrame(currentScreenFrame)
                        self.isVisible = true
                        self.showTimer = nil
                    }
                }
            }
        } else {
            showTimer?.invalidate()
            showTimer = nil
            
            if isVisible && hideTimer == nil {
                hideTimer = Timer.scheduledTimer(withTimeInterval: config.hoverHideDelay, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.isVisible = false
                        self?.hideTimer = nil
                    }
                }
            }
        }
    }
    
    @MainActor
    private func moveToScreenFrame(_ screenFrame: NSRect) {
        // 确保隐藏状态下瞬移，这样不会造成视觉割裂
        let windowWidth = screenFrame.width
        let windowHeight = config.hubSize * 2 + 80
        let windowRect = NSRect(x: screenFrame.minX, y: screenFrame.minY, width: windowWidth, height: windowHeight)
        self.window.setFrame(windowRect, display: false)
    }
}

extension Notification.Name {
    static let orbVisibilityChanged = Notification.Name("orbVisibilityChanged")
    static let hideTaiChi = Notification.Name("hideTaiChi")
}

// 自定义 Window，实现点击穿透和无焦点点击
class TaiChiWindow: NSWindow {
    override var canBecomeKey: Bool { return false }
}

// MARK: - Views


struct TaiChiOverlayView: View {
    var config: TaiChiConfig
    @State private var isVisible: Bool = false
    @State private var activeView: HubDimension = .defaultApps
    
    @ObservedObject private var settings = TaiChiSettings.shared
    @State private var combinedApps: [CombinedApp] = []
    @State private var appScrollOffset: Int = 0
    @State private var clickRotation: Double = 0
    @State private var monitoredAppsMode: MonitoredAppsMode = .windows
    let maxVisibleApps = 7
    
    var orbitalRadius: CGFloat { config.hubSize / 2 + 35 }
    var orbSinkOffset: CGFloat { config.hubSize * 0.25 }
    
    var visibleApps: [CombinedApp] {
        if combinedApps.isEmpty { return [] }
        let startIndex = min(appScrollOffset, max(0, combinedApps.count - maxVisibleApps))
        let endIndex = min(startIndex + maxVisibleApps, combinedApps.count)
        return Array(combinedApps[startIndex..<endIndex])
    }
    
    var body: some View {
        VStack {
            Spacer()
            
            ZStack {
                // Background circle
                Circle()
                    .fill(Material.ultraThin)
                    .opacity(0.85)
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                // ⚠️ 极其重要的防御性注释：
                // 绝不允许改回 `.onTapGesture`！
                // 因为太极是一个没有标题栏且不会抢夺系统焦点的悬浮面板 (`nonactivatingPanel`)。
                // 如果使用 `.onTapGesture`，由于 macOS 的 First-Mouse 吞噬机制，第一下点击会被操作系统拦截用于赋予窗口焦点，导致点击失效（必须点两下）。
                // 使用 `DragGesture(minimumDistance: 0)` 极具侵略性，它会无视窗口焦点状态，强行拦截第一下点击并瞬间触发交互。触之即发，第一下必中！
                .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                guard let dimension = resolveDimension(at: value.location, hubSize: config.hubSize) else {
                                    print("Ignored background tap: clicking on an orbital icon")
                                    return
                                }
                                print("Triggered: \(dimension.rawValue)")
                                
                                if dimension == .missionControl {
                                    openMissionControl()
                                    NotificationCenter.default.post(name: .hideTaiChi, object: nil)
                                    return
                                }
                                
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                    if dimension == .monitoredApps {
                                        clickRotation += 180
                                        if activeView == .monitoredApps {
                                            if monitoredAppsMode == .windows {
                                                monitoredAppsMode = .apps
                                            } else {
                                                monitoredAppsMode = .windows
                                            }
                                        } else {
                                            activeView = .monitoredApps
                                            monitoredAppsMode = .windows
                                        }
                                    } else if dimension == .presetPaths {
                                        clickRotation -= 180
                                        activeView = dimension
                                    } else {
                                        activeView = dimension
                                        if dimension == .defaultApps {
                                            refreshApps()
                                        }
                                    }
                                }
                            }
                    )
                
                FluidCoreView()
                    .rotationEffect(.degrees(clickRotation))
                    .allowsHitTesting(false)
                
                // ⚠️ 位置记录注释：
                // 将设置按钮刚好卡在屏幕物理底边（呈现被切掉一半的高级隐藏效果）。
                // config.hubSize / 2 代表面板的最底边，而 orbSinkOffset 是面板下沉的距离。
                // 两者相减即为刚好贴着屏幕下边缘的位置。
                SettingsButton()
                    .offset(y: config.hubSize / 2 - orbSinkOffset)
                
                if activeView == .defaultApps {
                    if combinedApps.isEmpty && isVisible {
                        VStack(spacing: 4) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 16))
                                .foregroundColor(.white.opacity(0.3))
                            Text("无应用")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.35))
                        }
                    } else {
                        // Hover scroll areas if needed
                        if combinedApps.count > maxVisibleApps {
                            HStack {
                                ScrollTriggerArea(isLeft: true) { hovering in
                                    if hovering && appScrollOffset > 0 {
                                        withAnimation { appScrollOffset -= 1 }
                                    }
                                }
                                Spacer()
                                ScrollTriggerArea(isLeft: false) { hovering in
                                    if hovering && appScrollOffset < combinedApps.count - maxVisibleApps {
                                        withAnimation { appScrollOffset += 1 }
                                    }
                                }
                            }
                            .frame(width: orbitalRadius * 2 + 100, height: orbitalRadius * 2 + 100)
                        }
                        
                        ForEach(Array(visibleApps.enumerated()), id: \.element.id) { index, app in
                            OrbitalAppIcon(
                                app: app,
                                index: index,
                                totalVisible: visibleApps.count,
                                orbRadius: orbitalRadius,
                                isRevealed: isVisible,
                                onTap: {
                                    handleAppTap(app)
                                }
                            )
                        }
                    }
                } else if activeView == .monitoredApps {
                    MonitoredAppsOverlay(orbRadius: orbitalRadius, isRevealed: isVisible, mode: $monitoredAppsMode, activeView: $activeView)
                } else if activeView == .presetPaths {
                    PresetPathsOverlay(orbRadius: orbitalRadius, isRevealed: isVisible)
                }
            }
            .frame(width: config.hubSize, height: config.hubSize)
            .offset(y: isVisible ? orbSinkOffset : config.hubSize + 50)
            .animation(.spring(response: 0.4, dampingFraction: 0.7, blendDuration: 0), value: isVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .orbVisibilityChanged)) { notification in
            guard let visible = notification.object as? Bool else { return }
            if visible {
                activeView = .defaultApps
                refreshApps()
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isVisible = visible
            }
        }
    }
    
    private func refreshApps() {
        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var result: [CombinedApp] = []
        
        for app in runningApps {
            if app.isHidden {
                result.append(CombinedApp(id: "run_\(app.processIdentifier)", runningApp: app, isHidden: true, isOpen: true))
            }
        }
        
        for resident in settings.residentApps {
            let isRunning = runningApps.contains { $0.bundleIdentifier == resident.id }
            if !isRunning {
                result.append(CombinedApp(id: "res_\(resident.id)", residentApp: resident, isHidden: false, isOpen: false))
            }
        }
        
        combinedApps = result
        appScrollOffset = 0
    }
    
    private func handleAppTap(_ app: CombinedApp) {
        if let runningApp = app.runningApp {
            runningApp.unhide()
            runningApp.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        } else if let resident = app.residentApp {
            NSWorkspace.shared.open(URL(fileURLWithPath: resident.path))
        }
        NotificationCenter.default.post(name: .hideTaiChi, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            refreshApps()
        }
    }
    
    private func openMissionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.launchApplication("Mission Control")
        }
    }
}

enum HubDimension: String {
    case missionControl = "调度中心"
    case defaultApps = "常驻应用"
    case monitoredApps = "监控应用"
    case presetPaths = "预设路径"
}

func resolveDimension(at location: CGPoint, hubSize: CGFloat) -> HubDimension? {
    let center = CGPoint(x: hubSize / 2, y: hubSize / 2) 
    let dx = location.x - center.x
    let dy = center.y - location.y 
    
    let distance = sqrt(dx*dx + dy*dy)
    
    let orbitalRadius = hubSize / 2 + 35
    if distance > orbitalRadius - 25 {
        return nil
    }
    
    if distance < 45 { return .defaultApps } // About 1/3 of radius
    
    var angle = atan2(dy, dx) * 180 / .pi
    if angle < 0 { angle += 360 }
    
    if angle >= 51 && angle <= 129 { return .missionControl }
    if angle > 129 && angle < 225 { return .monitoredApps }
    if angle >= 315 || angle < 51 { return .presetPaths }
    
    return .defaultApps 
}

struct FluidCoreView: View {
    @State private var autoRotation: Double = 0
    @State private var breathingScale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            // 能量团 A (阳)
            Circle()
                .fill(Color.cyan.opacity(0.5))
                .blur(radius: 20)
                .offset(x: -15, y: -15)
                .scaleEffect(breathingScale)
            
            // 能量团 B (阴)
            Circle()
                .fill(Color.purple.opacity(0.4))
                .blur(radius: 20)
                .offset(x: 15, y: 15)
                .scaleEffect(2.0 - breathingScale)
        }
        .rotationEffect(.degrees(autoRotation))
        .mask(Circle())
        .onAppear {
            withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                autoRotation = 360
            }
            withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
                breathingScale = 1.3
            }
        }
    }
}
