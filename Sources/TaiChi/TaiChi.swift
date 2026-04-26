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
        
        let hostingView = NSHostingView(rootView: contentView)
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

// 自定义 Window，实现点击穿透
class TaiChiWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
}

// MARK: - Views

// 一个单独的轨道图标项，自带 hover 缩放效果
struct OrbitalAppIcon: View {
    var app: NSRunningApplication
    var index: Int
    var total: Int
    var orbRadius: CGFloat
    var isRevealed: Bool
    var onTap: () -> Void
    
    @State private var isHovered = false
    
    // 从左侧开始排列，固定间距，如果数量过多则压缩间距
    var angleRadians: Double {
        let startDeg = -160.0
        let availableArc = 140.0 // 最多分布在 -160° 到 -20° 之间
        let idealStep = 25.0
        let step = total <= 1 ? 0.0 : min(idealStep, availableArc / Double(total - 1))
        let deg = startDeg + step * Double(index)
        return deg * .pi / 180.0
    }
    
    var iconOffset: CGSize {
        CGSize(
            width:  cos(angleRadians) * orbRadius,
            height: sin(angleRadians) * orbRadius
        )
    }
    
    var body: some View {
        // 图标 + 毛玻璃底板
        ZStack {
            // 实心毛玻璃圆形底板，确保图标清晰可辨
            Circle()
                .fill(Material.ultraThinMaterial)
                .frame(width: 50, height: 50)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isHovered ? 0.3 : 0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .opacity(isHovered ? 1.0 : 0.4)
        .frame(width: 60)
        .scaleEffect(isHovered ? 1.12 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .offset(iconOffset)
        // 入场动画：从球心方向按顺序飞出
        .scaleEffect(isRevealed ? 1.0 : 0.1)
        .opacity(isRevealed ? 1.0 : 0.0)
        .animation(
            .spring(response: 0.4, dampingFraction: 0.7).delay(Double(index) * 0.06),
            value: isRevealed
        )
        .onHover { isHovered = $0 }
        .onTapGesture { onTap() }
    }
}

struct TaiChiOverlayView: View {
    var config: TaiChiConfig
    @State private var isVisible: Bool = false
    @State private var hiddenApps: [NSRunningApplication] = []
    @State private var activeView: HubDimension = .hiddenWindows
    
    // 轨道半径 = 球的半径 + 紧凑距离（缩短到 +30，让图标紧贴球边缘）
    var orbitalRadius: CGFloat { config.hubSize / 2 + 35 }
    // 显示时球沉入底边的偏移量
    var orbSinkOffset: CGFloat { config.hubSize * 0.25 }
    
    var body: some View {
        VStack {
            Spacer()
            
            // 能量球 + 轨道图标（图标作为球的 overlay，坐标原点自动是球心）
            ZStack {
                Circle()
                    .fill(Material.ultraThin)
                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                
                FluidCoreView()
                
                // 无隐藏窗口时的空状态提示
                if isVisible && activeView == .hiddenWindows && hiddenApps.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 16))
                            .foregroundColor(.white.opacity(0.3))
                        Text("无隐藏窗口")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
            }
            // 轨道卫星图标作为 overlay，坐标原点 = 球心
            .overlay {
                if isVisible && activeView == .hiddenWindows {
                    ForEach(Array(hiddenApps.enumerated()), id: \.element.processIdentifier) { index, app in
                        OrbitalAppIcon(
                            app: app,
                            index: index,
                            total: max(hiddenApps.count, 1),
                            orbRadius: orbitalRadius,
                            isRevealed: isVisible,
                            onTap: {
                                app.unhide()
                                app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                                
                                // 点击后立刻隐藏太极
                                NotificationCenter.default.post(name: .hideTaiChi, object: nil)
                                
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    refreshHiddenApps()
                                }
                            }
                        )
                    }
                }
            }
            .frame(width: config.hubSize, height: config.hubSize)
            .offset(y: isVisible ? orbSinkOffset : config.hubSize + 50)
            .animation(.spring(response: 0.4, dampingFraction: 0.7, blendDuration: 0), value: isVisible)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        let dimension = resolveDimension(at: value.location, hubSize: config.hubSize)
                        print("Triggered: \(dimension.rawValue)")
                        
                        if dimension == .hiddenWindows {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                activeView = .hiddenWindows
                                refreshHiddenApps()
                            }
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                activeView = dimension
                            }
                        }
                    }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .orbVisibilityChanged)) { notification in
            guard let visible = notification.object as? Bool else { return }
            if visible {
                // 升起时默认扫描并展示隐藏窗口
                activeView = .hiddenWindows
                refreshHiddenApps()
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isVisible = visible
            }
        }
    }
    
    private func refreshHiddenApps() {
        hiddenApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.isHidden
        }
    }
}

enum HubDimension: String {
    case missionControl = "调度中心"
    case hiddenWindows  = "隐藏窗口"
    case finderWindows  = "访达窗口"
    case presetPaths    = "预设路径"
}

func resolveDimension(at location: CGPoint, hubSize: CGFloat) -> HubDimension {
    let center = CGPoint(x: hubSize / 2, y: hubSize / 2) 
    let dx = location.x - center.x
    let dy = center.y - location.y 
    
    let distance = sqrt(dx*dx + dy*dy)
    if distance < 45 { return .hiddenWindows } 
    
    let startAngle = -30.0 
    let sectorSize = 240.0 / 3.0 
    
    var angle = atan2(dy, dx) * 180 / .pi - startAngle
    while angle < 0 { angle += 360 }
    
    if angle < sectorSize { return .presetPaths }
    if angle < sectorSize * 2 { return .missionControl }
    if angle < sectorSize * 3 { return .finderWindows }
    
    return .hiddenWindows 
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
