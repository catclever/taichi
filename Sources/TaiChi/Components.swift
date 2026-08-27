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
    @State private var hoverTimer: Timer?
    @State private var lastClickTime = Date.distantPast
    @State private var clickTask: Task<Void, Never>?
    
    var shouldShowApp: Bool {
        return lastApp != nil && !showTaiChi
    }
    
    var body: some View {
        Button(action: {
            let now = Date()
            let isDoubleClick = now.timeIntervalSince(lastClickTime) < 0.3
            
            if isDoubleClick {
                clickTask?.cancel()
                if shouldShowApp {
                    // Icon = App -> Double = Settings
                    openSettings()
                } else {
                    // Icon = TaiChi -> Double = App (if available)
                    if let app = lastApp {
                        onOpenApp?(app)
                    } else {
                        openSettings()
                    }
                }
            } else {
                // Single click
                if lastApp == nil {
                    // No app available, single click is settings instantly (no need to wait for double click)
                    openSettings()
                } else {
                    // There IS a lastApp, so double click does something different. We MUST wait to differentiate.
                    clickTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if !Task.isCancelled {
                            if shouldShowApp {
                                // Icon = App -> Single = App
                                if let app = lastApp {
                                    onOpenApp?(app)
                                }
                            } else {
                                // Icon = TaiChi -> Single = Settings
                                openSettings()
                            }
                        }
                    }
                }
            }
            lastClickTime = now
        }) {
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
                        .rotationEffect(.degrees(isHovered ? 180 : 0))
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
                }
            }
            .scaleEffect(isHovered ? 1.1 : 1.0)
            .contentShape(Circle())
            .onHover { hovering in
                isHovered = hovering
                hoverTimer?.invalidate()
                if hovering && shouldShowApp {
                    hoverTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
                        Task { @MainActor in
                            withAnimation {
                                self.showTaiChi = true
                            }
                        }
                    }
                } else if !hovering {
                    showTaiChi = false
                }
            }
        }
        .buttonStyle(.plain)
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
