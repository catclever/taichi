import SwiftUI

enum MonitoredAppsMode {
    case windows
    case apps
}

struct MonitoredAppsOverlay: View {
    @ObservedObject var settings = TaiChiSettings.shared
    var orbRadius: CGFloat
    var isRevealed: Bool
    
    @Binding var mode: MonitoredAppsMode
    @Binding var activeView: HubDimension
    
    @State private var windows: [WindowInfo] = []
    @State private var scrollOffset: Int = 0
    let maxVisible = 7
    
    var visibleItems: [WindowInfo] {
        let maxOffset = max(0, windows.count - maxVisible)
        let safeOffset = min(max(0, scrollOffset), maxOffset)
        let end = min(safeOffset + maxVisible, windows.count)
        return Array(windows[safeOffset..<end])
    }
    
    var groupedApps: [String: [WindowInfo]] {
        Dictionary(grouping: windows, by: { $0.appBundleID })
    }
    
    var appList: [String] {
        Array(groupedApps.keys).sorted()
    }
    
    var body: some View {
        ZStack {
            if mode == .windows {
                if windows.isEmpty {
                    VStack {
                        Image(systemName: "square.dashed")
                            .foregroundColor(.white.opacity(0.3))
                        Text("无监控窗口")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.35))
                    }
                } else {
                    if windows.count > maxVisible {
                        ScrollCatcherView { delta in
                            let direction = delta > 0 ? -1 : 1
                            withAnimation(.easeInOut(duration: 0.2)) {
                                let maxOffset = max(0, windows.count - maxVisible)
                                scrollOffset = max(0, min(maxOffset, scrollOffset + direction))
                            }
                        }
                        .frame(width: orbRadius * 2 + 100, height: orbRadius * 2 + 100)
                    }
                    
                    let items = visibleItems
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, window in
                        OrbitalWindowIcon(
                            window: window,
                            index: index,
                            totalVisible: items.count,
                            orbRadius: orbRadius,
                            isRevealed: isRevealed,
                            onTap: {
                                WindowManager.shared.activateWindow(pid: window.pid, title: window.title, bounds: window.bounds)
                                NotificationCenter.default.post(name: .hideTaiChi, object: nil)
                            }
                        )
                    }
                }
            } else {
                let apps = appList
                ForEach(Array(apps.enumerated()), id: \.element) { index, bundleID in
                    OrbitalGroupedAppIcon(
                        bundleID: bundleID,
                        windows: groupedApps[bundleID] ?? [],
                        index: index,
                        totalVisible: apps.count,
                        orbRadius: orbRadius,
                        isRevealed: isRevealed,
                        onTap: {
                            // Expand back to windows, maybe scroll to this app
                            if let firstIndex = windows.firstIndex(where: { $0.appBundleID == bundleID }) {
                                scrollOffset = firstIndex
                            }
                            withAnimation(.spring()) {
                                mode = .windows
                            }
                        }
                    )
                }
            }
        }
        .onAppear {
            refreshWindows()
        }
    }
    
    private func refreshWindows() {
        Task {
            let runningApps = NSWorkspace.shared.runningApplications
            let monitoredPIDs = settings.monitoredApps.compactMap { app in
                runningApps.first(where: { $0.bundleIdentifier == app.id })?.processIdentifier
            }
            
            var fetchedWindows = await WindowManager.shared.getWindows(for: monitoredPIDs)
            
            fetchedWindows.sort { w1, w2 in
                if w1.appBundleID == w2.appBundleID {
                    return false
                }
                return w1.appBundleID < w2.appBundleID
            }
            
            await MainActor.run {
                self.windows = fetchedWindows
            }
        }
    }
}

struct OrbitalWindowIcon: View {
    var window: WindowInfo
    var index: Int
    var totalVisible: Int
    var orbRadius: CGFloat
    var isRevealed: Bool
    var onTap: () -> Void
    
    @State private var isHovered = false
    
    var angleRadians: Double {
        let startDeg = -190.0
        let availableArc = 200.0 // -190 to 10
        let idealStep = 28.0
        let step = totalVisible <= 1 ? 0.0 : min(idealStep, availableArc / Double(totalVisible - 1))
        let deg = startDeg + step * Double(index)
        return deg * .pi / 180.0
    }
    
    var iconOffset: CGSize {
        if isRevealed {
            return CGSize(
                width: cos(angleRadians) * orbRadius,
                height: sin(angleRadians) * orbRadius
            )
        } else {
            return .zero
        }
    }
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(Material.ultraThinMaterial)
                    .frame(width: 42, height: 42)
                    .shadow(color: .black.opacity(0.2), radius: 4)
                
                if let img = window.image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                }
            }
            
            Text(window.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 85)
                .shadow(color: .black.opacity(0.8), radius: 1)
        }
        .opacity(isHovered ? 1.0 : 0.8)
        .scaleEffect(isHovered ? 1.15 : 1.0)
        .offset(iconOffset)
        .scaleEffect(isRevealed ? 1.0 : 0.1)
        .opacity(isRevealed ? 1.0 : 0.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7).delay(Double(index) * 0.05), value: isRevealed)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        // ⚠️ 防御性注释：绝不允许使用 .onTapGesture，必须使用 DragGesture 绕过 macOS 焦点吞噬机制，实现无焦点第一下点击必中！
        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in onTap() })
    }
}

struct OrbitalGroupedAppIcon: View {
    var bundleID: String
    var windows: [WindowInfo]
    var index: Int
    var totalVisible: Int
    var orbRadius: CGFloat
    var isRevealed: Bool
    var onTap: () -> Void
    
    @State private var isHovered = false
    
    var angleRadians: Double {
        let startDeg = -190.0
        let availableArc = 200.0 // -190 to 10
        let idealStep = 28.0
        let step = totalVisible <= 1 ? 0.0 : min(idealStep, availableArc / Double(totalVisible - 1))
        let deg = startDeg + step * Double(index)
        return deg * .pi / 180.0
    }
    
    var iconOffset: CGSize {
        if isRevealed {
            return CGSize(
                width: cos(angleRadians) * orbRadius,
                height: sin(angleRadians) * orbRadius
            )
        } else {
            return .zero
        }
    }
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(Material.ultraThinMaterial)
                    .frame(width: 42, height: 42)
                    .shadow(color: .black.opacity(0.2), radius: 4)
                
                if let img = windows.first?.image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                }
                
                Text("\(windows.count)")
                    .font(.caption2.bold())
                    .foregroundColor(.white)
                    .padding(4)
                    .background(Color.red)
                    .clipShape(Circle())
                    .offset(x: 18, y: -18)
            }
        }
        .opacity(isHovered ? 1.0 : 0.8)
        .scaleEffect(isHovered ? 1.15 : 1.0)
        .offset(iconOffset)
        .scaleEffect(isRevealed ? 1.0 : 0.1)
        .opacity(isRevealed ? 1.0 : 0.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7).delay(Double(index) * 0.05), value: isRevealed)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        // ⚠️ 防御性注释：绝不允许使用 .onTapGesture，必须使用 DragGesture 绕过 macOS 焦点吞噬机制，实现无焦点第一下点击必中！
        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in onTap() })
    }
}

struct PresetPathsOverlay: View {
    @ObservedObject var settings = TaiChiSettings.shared
    var orbRadius: CGFloat
    var isRevealed: Bool
    
    var body: some View {
        ZStack {
            ForEach(Array(settings.commonPaths.enumerated()), id: \.element.id) { index, path in
                OrbitalPathIcon(
                    path: path,
                    index: index,
                    totalVisible: settings.commonPaths.count,
                    orbRadius: orbRadius,
                    isRevealed: isRevealed,
                    onTap: {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path.path))
                        NotificationCenter.default.post(name: .hideTaiChi, object: nil)
                    }
                )
            }
            
            if settings.commonPaths.isEmpty {
                VStack {
                    Image(systemName: "folder.badge.minus")
                        .foregroundColor(.white.opacity(0.3))
                    Text("无预设路径")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.35))
                }
            }
        }
    }
}

struct OrbitalPathIcon: View {
    var path: CommonPath
    var index: Int
    var totalVisible: Int
    var orbRadius: CGFloat
    var isRevealed: Bool
    var onTap: () -> Void
    
    @State private var isHovered = false
    
    var angleRadians: Double {
        let startDeg = -190.0
        let availableArc = 200.0 // -190 to 10
        let idealStep = 28.0
        let step = totalVisible <= 1 ? 0.0 : min(idealStep, availableArc / Double(totalVisible - 1))
        let deg = startDeg + step * Double(index)
        return deg * .pi / 180.0
    }
    
    var iconOffset: CGSize {
        if isRevealed {
            return CGSize(
                width: cos(angleRadians) * orbRadius,
                height: sin(angleRadians) * orbRadius
            )
        } else {
            return .zero
        }
    }
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Material.ultraThinMaterial)
                .frame(width: 42, height: 42)
                .shadow(color: .black.opacity(0.2), radius: 4)
            
            Image(nsImage: NSWorkspace.shared.icon(forFile: path.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 36, height: 36)
        }
        .opacity(isHovered ? 1.0 : 0.8)
        .scaleEffect(isHovered ? 1.15 : 1.0)
        .offset(iconOffset)
        .scaleEffect(isRevealed ? 1.0 : 0.1)
        .opacity(isRevealed ? 1.0 : 0.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7).delay(Double(index) * 0.05), value: isRevealed)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in onTap() })
    }
}
