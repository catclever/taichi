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
    private var lastMouseProcessTime: TimeInterval = 0

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        ServerManager.shared.start()
        
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
    
    // [Bug Fix Document]
    // 问题：应用在后台极大占用 CPU，原因是全局鼠标移动监听 (`.mouseMoved`) 过于频繁，每次像素级移动都触发主线程的坐标计算。
    // 修复逻辑：引入 `lastMouseProcessTime` 进行节流控制 (Throttling)，将全局鼠标位置计算频率限制为最高每秒 20 次 (0.05秒间隔)。
    // 注意事项：不要去掉节流逻辑。因为对于浮窗呼出判定，50ms 的延迟不仅人眼无法感知，更能大幅节省系统资源。
    private func setupMouseTracking() {
        let handler: (NSEvent) -> Void = { [weak self] (event: NSEvent) in
            let now = ProcessInfo.processInfo.systemUptime
            guard let self = self, now - self.lastMouseProcessTime > 0.05 else { return }
            self.lastMouseProcessTime = now
            
            DispatchQueue.main.async {
                self.handleMouseMoved(location: NSEvent.mouseLocation)
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
                    .fill(Material.thinMaterial)
                    .frame(width: config.hubSize, height: config.hubSize)
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
                
                FluidCoreView(isVisible: isVisible)
                    .frame(width: config.hubSize, height: config.hubSize)
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
    
    // [Bug Fix Document]
    // 问题：常驻应用在运行时如果不处于隐藏状态，会从面板上消失，导致常驻逻辑失效。
    // 修复逻辑：重构 `refreshApps` 的展示逻辑为两步：首先将所有常驻应用按照设置里的顺序固定展示（并绑定它们当前的运行状态和隐藏状态）；然后再追加那些非常驻但处于隐藏状态的运行中应用。这样常驻应用永远可见，且位置固定。
    // 注意事项：不要直接依赖 `app.isHidden` 来过滤常驻应用。常驻应用无论处于何种状态（关闭、打开、隐藏）都必须进入 `combinedApps` 列表。
    private func refreshApps() {
        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var result: [CombinedApp] = []
        
        // 1. 优先按照设置里的顺序添加常驻应用
        for resident in settings.residentApps {
            if let runningApp = runningApps.first(where: { $0.bundleIdentifier == resident.id }) {
                // 常驻应用正在运行
                result.append(CombinedApp(id: "res_\(resident.id)", runningApp: runningApp, residentApp: resident, isHidden: runningApp.isHidden, isOpen: true))
            } else {
                // 常驻应用未运行
                result.append(CombinedApp(id: "res_\(resident.id)", residentApp: resident, isHidden: false, isOpen: false))
            }
        }
        
        // 2. 补充那些没有常驻，但是处于隐藏状态的运行中应用
        for app in runningApps {
            if app.isHidden && !settings.residentApps.contains(where: { $0.id == app.bundleIdentifier }) {
                result.append(CombinedApp(id: "run_\(app.processIdentifier)", runningApp: app, isHidden: true, isOpen: true))
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

// [Bug Fix Document]
// 问题：即使太极面板被隐藏，SwiftUI 仍然在后台持续渲染 `.repeatForever` 的动画，导致 GPU 和 CPU 持续被消耗。
// 修复逻辑：将当前面板的 `isVisible` 状态传递给 FluidCoreView。利用 `.onChange(of: isVisible)` 监听可见性：隐藏时将动画重置为初始状态并停止；显示时再恢复循环动画。
// 注意事项：SwiftUI 的浮窗应用在被 offset 或 opacity(0) 隐藏时，底层未必会暂停无限动画。所有 `.repeatForever` 必须显式绑定条件开关。
struct FluidCoreView: View {
    var isVisible: Bool
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
        .onChange(of: isVisible) { visible in
            if visible {
                withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                    autoRotation = 360
                }
                withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
                    breathingScale = 1.3
                }
            } else {
                withAnimation(.linear(duration: 0.5)) {
                    autoRotation = 0
                    breathingScale = 1.0
                }
            }
        }
        .onAppear {
            if isVisible {
                withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                    autoRotation = 360
                }
                withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
                    breathingScale = 1.3
                }
            }
        }
    }
}
