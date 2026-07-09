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
                    .allowsHitTesting(false)
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
                if apps.isEmpty {
                    VStack {
                        Image(systemName: "square.dashed")
                            .foregroundColor(.white.opacity(0.3))
                        Text("无监控应用")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .allowsHitTesting(false)
                } else {
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
        }
        .onAppear {
            refreshWindows()
        }
    }
    
    private func refreshWindows() {
        Task {
            let runningApps = NSWorkspace.shared.runningApplications
            let combinedApps = settings.monitoredApps
            var uniqueAppIDs = Set<String>()
            var uniqueApps = [MonitoredApp]()
            for app in combinedApps {
                if !uniqueAppIDs.contains(app.id) {
                    uniqueAppIDs.insert(app.id)
                    uniqueApps.append(app)
                }
            }
            
            // =========================================================================================
            // [BUG FIX: Missing Child Process Windows for Monitored Apps]
            // Problem:
            // When querying windows for apps like VS Code, the application spawns multiple child
            // processes that share the same `bundleIdentifier` (e.g., `com.microsoft.VSCode`). 
            // The original code used `runningApps.first(where:)` to grab the PID of the app.
            // If the first process returned happened to be a background helper (without UI windows),
            // `SCShareableContent` would find exactly 0 windows for that PID, causing the app
            // to completely disappear from the Monitored Apps overlay.
            //
            // Method/Logic:
            // Replaced `.compactMap` and `.first(where:)` with `.flatMap` and `.filter`.
            // This collects the PIDs of *all* running processes that match the `bundleIdentifier`,
            // ensuring that whichever process actually owns the on-screen windows is included
            // in the array passed to `SCShareableContent` / `CGWindowListCopyWindowInfo`.
            //
            // Caveats for future development:
            // - Always assume macOS applications (especially Electron apps) might distribute their
            //   UI across multiple processes sharing the same bundle ID. Never rely on the first match.
            //
            // [Bug Fix Document]
            // 问题：将 VS Code 添加到监控应用后，经常出现监控面板里刷不出 VS Code 任何窗口的情况。
            // 原因：VS Code 拥有大量同 Bundle ID 的子进程。原逻辑只抓取了匹配该 ID 的**第一个**进程的 PID 进行窗口查询。如果运气不好抓到了 GPU 辅助进程，系统自然查不到任何属于它的窗口。
            // 修复逻辑：将查找逻辑改为获取所有匹配该 Bundle ID 的进程的 PID 集合，统一打包发给屏幕内容截取 API，确保不会漏掉真正拥有界面的那个主进程。
            // 注意事项：以后处理进程到窗口的映射时，必须考虑多进程架构（如 Chrome/Electron）的特点，全面拉取 PID 集合。
            // =========================================================================================
            let monitoredPIDs = uniqueApps.flatMap { app in
                runningApps.filter({ $0.bundleIdentifier == app.id }).map({ $0.processIdentifier })
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
                        .overlay(
                            Group {
                                if TaiChiSettings.shared.activeInjectedApps.contains(where: { $0.id == window.appBundleID }) {
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
        .onTapGesture {
            onTap()
        }
    }
}

struct OrbitalGroupedAppIcon: View {
    @ObservedObject var settings = TaiChiSettings.shared
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
                        .overlay(
                            Group {
                                if settings.activeInjectedApps.contains(where: { $0.id == bundleID }) {
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
        .onTapGesture {
            onTap()
        }
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
        let endDeg = 10.0
        let availableArc = 200.0 // -190 to 10
        let idealStep = 28.0
        let step = totalVisible <= 1 ? 0.0 : min(idealStep, availableArc / Double(totalVisible - 1))
        let deg = endDeg - step * Double(totalVisible - 1 - index)
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
                
                Image(nsImage: NSWorkspace.shared.icon(forFile: path.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
            }
            
            Text(path.name)
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
        .onTapGesture {
            onTap()
        }
    }
}
