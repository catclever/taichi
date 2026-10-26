import SwiftUI


enum AppWindowState {
    case activeVisible
    case offscreen
    case windowless
    case hidden
    case notRunning
}

struct CombinedApp: Identifiable {
    var id: String
    var runningApp: NSRunningApplication?
    var residentApp: ResidentApp?
    var windowState: AppWindowState
}

struct OrbitalAppIcon: View {
    var app: CombinedApp
    var index: Int
    var totalVisible: Int // max 7
    var orbRadius: CGFloat
    var isRevealed: Bool
    var onTap: () -> Void
    
    @State private var isHovered = false
    
    var angleRadians: Double {
        let startDeg = -160.0
        let availableArc = 140.0 // -160 to -20
        let idealStep = 25.0
        let step = totalVisible <= 1 ? 0.0 : min(idealStep, availableArc / Double(totalVisible - 1))
        let deg = startDeg + step * Double(index)
        return deg * .pi / 180.0
    }
    
    var iconOffset: CGSize {
        CGSize(
            width: cos(angleRadians) * orbRadius,
            height: sin(angleRadians) * orbRadius
        )
    }
    
    var displayOpacity: Double {
        switch app.windowState {
        case .activeVisible: return 1.0
        case .offscreen: return 1.0 // 展示为实色
        case .windowless, .hidden: return 0.4
        case .notRunning: return 0.5
        }
    }
    
    var isGrayscale: Bool {
        switch app.windowState {
        case .windowless, .notRunning: return true
        default: return false
        }
    }
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Material.ultraThinMaterial)
                .frame(width: 42, height: 42)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isHovered ? 0.3 : 0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            
            if let icon = getIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
                    .grayscale(isGrayscale ? 0.99 : 0) // 置灰
                    .overlay(
                        Group {
                            if let bundleID = app.residentApp?.id ?? app.runningApp?.bundleIdentifier,
                               TaiChiSettings.shared.activeInjectedApps.contains(where: { $0.id == bundleID }) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.yellow)
                                    .padding(2)
                                    .background(Circle().fill(Color.black.opacity(0.7)))
                                    .offset(x: 4, y: -4)
                                    .contextMenu {
                                        Button("重新注入 (Re-inject)") {
                                            ServerManager.shared.reinjectApp(appId: bundleID)
                                        }
                                    }
                            }
                        },
                        alignment: .topTrailing
                    )
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .opacity(isHovered ? 1.0 : displayOpacity)
        .frame(width: 50)
        .scaleEffect(isHovered ? 1.12 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .offset(iconOffset)
        .scaleEffect(isRevealed ? 1.0 : 0.1)
        .opacity(isRevealed ? 1.0 : 0.0)
        .animation(
            .spring(response: 0.4, dampingFraction: 0.7).delay(Double(index) * 0.06),
            value: isRevealed
        )
        .onHover { isHovered = $0 }
        // ⚠️ 防御性注释：绝不允许使用 .onTapGesture，必须使用 DragGesture 绕过 macOS 焦点吞噬机制，实现无焦点第一下点击必中！
        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in onTap() })
    }
    
    func getIcon() -> NSImage? {
        if let app = app.runningApp {
            return app.icon
        }
        if let path = app.residentApp?.path {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return nil
    }
}

struct SettingsButton: View {
    var lastApp: CombinedApp?
    var onOpenApp: ((CombinedApp) -> Void)?
    
    @State private var isHovered = false
    @State private var showTaiChi = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var lastClickTime = Date.distantPast
    @State private var clickTask: Task<Void, Never>?
    @State private var rotationCount: Int = 0
    
    var shouldShowApp: Bool {
        return lastApp != nil && !showTaiChi
    }
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Material.thinMaterial) // 参考图中的浅色通透毛玻璃
                .frame(width: 40, height: 40)
            .overlay(
                Circle().stroke(Color.white.opacity(isHovered ? 0.3 : 0.12), lineWidth: 1)
            )
            
            if shouldShowApp, let app = lastApp {
                Image(nsImage: app.runningApp?.icon ?? NSWorkspace.shared.icon(forFile: app.residentApp?.path ?? ""))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
            } else {
                YinYangIcon()
                    .frame(width: 20, height: 20)
                    .rotationEffect(.degrees(Double(rotationCount) * 180))
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: rotationCount)
            }
        }
        .overlay(
            MouseInteractionView(
                onLeftClick: {
                    if lastApp == nil {
                        openSettings()
                    } else {
                        if shouldShowApp {
                            if let app = lastApp { onOpenApp?(app) }
                        } else {
                            openSettings()
                        }
                    }
                },
                onDoubleClick: {
                    openSettings()
                },
                onRightClick: {
                    if shouldShowApp {
                        openSettings()
                    } else {
                        if let app = lastApp { onOpenApp?(app) } else { openSettings() }
                    }
                }
            )
        )
        .scaleEffect(isHovered ? 1.1 : 1.0)
        .contentShape(Circle())
        .onHover { hovering in
            isHovered = hovering
            hoverTask?.cancel()
            
            if hovering {
                if !shouldShowApp {
                    rotationCount += 1
                } else {
                    hoverTask = Task {
                        do {
                            try await Task.sleep(nanoseconds: 2_000_000_000)
                            await MainActor.run {
                                withAnimation {
                                    self.showTaiChi = true
                                    self.rotationCount += 1
                                }
                            }
                        } catch {
                            // Task cancelled
                        }
                    }
                }
            } else {
                showTaiChi = false
            }
        }
    }
    
    private func openSettings() {
        SettingsWindowManager.shared.show()
        NotificationCenter.default.post(name: NSNotification.Name("hideTaiChi"), object: nil)
    }
}

// 纯手绘的精美太极图标
struct YinYangIcon: View {
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: size/2, y: size/2)
            
            // 亮侧：更亮（纯白），更不透明
            let lightColor = Color.white
            let lightOpacity: Double = 0.98
            let lightGray = lightColor.opacity(lightOpacity)
            
            // 暗侧：更偏灰（调高白度），更透明
            let darkColor = Color(white: 0.55)
            let darkOpacity: Double = 0.55
            let darkGray = darkColor.opacity(darkOpacity)
            
            // 顶部圆点 (位于暗区)：对面的颜色(亮)，当前区域的透明度(暗)
            let topDotColor = lightColor.opacity(darkOpacity)
            
            // 底部圆点 (位于亮区)：对面的颜色(暗)，当前区域的透明度(亮)
            let bottomDotColor = darkColor.opacity(lightOpacity)
            
            ZStack {
                // 右半部分 (亮) - 包含底部突起和顶部内凹
                Path { path in
                    path.addArc(center: center, radius: size/2, startAngle: .degrees(270), endAngle: .degrees(90), clockwise: false)
                    path.addArc(center: CGPoint(x: size/2, y: size*3/4), radius: size/4, startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: false)
                    path.addArc(center: CGPoint(x: size/2, y: size/4), radius: size/4, startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
                }
                .fill(lightGray)
                
                // 左半部分 (暗) - 包含顶部突起和底部内凹
                Path { path in
                    path.addArc(center: center, radius: size/2, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
                    path.addArc(center: CGPoint(x: size/2, y: size/4), radius: size/4, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                    path.addArc(center: CGPoint(x: size/2, y: size*3/4), radius: size/4, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
                }
                .fill(darkGray)
                
                // 顶部圆点 (位于暗区)
                Circle()
                    .fill(topDotColor)
                    .frame(width: size/6, height: size/6)
                    .offset(y: -size/4)
                
                // 底部圆点 (位于亮区)
                Circle()
                    .fill(bottomDotColor)
                    .frame(width: size/6, height: size/6)
                    .offset(y: size/4)
            }
        }
    }
}

struct ScrollTriggerArea: View {
    var isLeft: Bool
    var onHover: (Bool) -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: 60, height: 100)
            .overlay(
                Image(systemName: isLeft ? "chevron.left" : "chevron.right")
                    .font(.title)
                    .foregroundColor(.white.opacity(isHovered ? 0.8 : 0.3))
                    .shadow(color: .black.opacity(0.5), radius: 2)
            )
            .onHover { hovering in
                isHovered = hovering
                onHover(hovering)
            }
    }
}


struct RightClickCatcherView: NSViewRepresentable {
    var onRightClick: () -> Void
    func makeNSView(context: Context) -> RightClickNSView {
        let view = RightClickNSView()
        view.onRightClick = onRightClick
        return view
    }
    func updateNSView(_ nsView: RightClickNSView, context: Context) {}
}

class RightClickNSView: NSView {
    var onRightClick: (() -> Void)?
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    override func rightMouseDown(with event: NSEvent) {}
    
    override func rightMouseUp(with event: NSEvent) {
        onRightClick?()
    }
}

// [Bug Fix Document]
// 问题：在 SwiftUI 中使用 `Button` 嵌套 `NSView`，会导致内部/背后的其他指针事件（如右键点击）被强制吞噬。即使加上 `acceptsFirstMouse`，系统也无法稳定传递 `rightMouseUp`。此外，通过 Task 延迟算时间差来区分单击和双击，既不精准也不优雅。
// 修复逻辑：
// 1. 彻底抛弃 SwiftUI 原生的 `Button`，直接使用底层的 `NSView` 作为事件拦截器，并以 `.overlay` 的形式覆盖在交互区域上。
// 2. 在原生的 `mouseDown` 中，直接利用系统 API `event.clickCount == 2` 来可靠、精准地识别双击。
// 3. 必须重写 `acceptsFirstMouse` 返回 `true`，以绕过 macOS 的 First-Mouse 焦点吞噬机制，实现无焦点情况下的“触之即发”。
// 注意事项：后续遇到类似“需要无焦点即刻响应，并且同时兼容区分左/右/双击”的悬浮窗交互，请直接使用这个 `MouseInteractionView`。
struct MouseInteractionView: NSViewRepresentable {
    var onLeftClick: () -> Void
    var onDoubleClick: () -> Void
    var onRightClick: () -> Void
    
    func makeNSView(context: Context) -> MouseInteractionNSView {
        let view = MouseInteractionNSView()
        view.onLeftClick = onLeftClick
        view.onDoubleClick = onDoubleClick
        view.onRightClick = onRightClick
        return view
    }
    func updateNSView(_ nsView: MouseInteractionNSView, context: Context) {
        nsView.onLeftClick = onLeftClick
        nsView.onDoubleClick = onDoubleClick
        nsView.onRightClick = onRightClick
    }
}

class MouseInteractionNSView: NSView {
    var onLeftClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var clickTask: Task<Void, Never>?
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
    
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            clickTask?.cancel()
            onDoubleClick?()
        } else {
            clickTask?.cancel()
            clickTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    if !Task.isCancelled {
                        await MainActor.run { self.onLeftClick?() }
                    }
                } catch {}
            }
        }
    }
    
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) { onRightClick?() }
}
