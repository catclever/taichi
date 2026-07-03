import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings = TaiChiSettings.shared
    @State private var hasHammerspoon: Bool = false
    @State private var selectedTab: String = "basic"
    
    var body: some View {
        TabView(selection: $selectedTab) {
            BasicFeaturesTab(selectedTab: $selectedTab)
                .tabItem {
                    Label("基础功能", systemImage: "square.grid.2x2.fill")
                }
                .tag("basic")
            
            if hasHammerspoon {
                HammerspoonTab()
                    .tabItem {
                        Label("Hammerspoon", systemImage: "hammer.fill")
                    }
                    .tag("hs")
            }
                
            SystemSettingsTab()
                .tabItem {
                    Label("系统配置", systemImage: "gearshape.fill")
                }
                .tag("system")
        }
        .padding()
        .frame(width: 600, height: 600)
        .onAppear {
            checkHammerspoon()
        }
    }
    
    private func checkHammerspoon() {
        if let _ = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.hammerspoon.Hammerspoon") {
            hasHammerspoon = true
        } else {
            hasHammerspoon = false
        }
    }
}

// MARK: - Tab 1: 基础功能 (全局滚动)
struct BasicFeaturesTab: View {
    @Binding var selectedTab: String
    @ObservedObject var settings = TaiChiSettings.shared
    @ObservedObject var permissions = PermissionsManager.shared
    
    var body: some View {
        List {
            // 常驻应用
            Section(header: HStack {
                Text("常驻应用").font(.headline)
                Spacer()
                Button(action: { addApp { settings.residentApps.append($0 as! ResidentApp) } }) {
                    Image(systemName: "plus")
                }.buttonStyle(.borderless)
            }) {
                if settings.residentApps.isEmpty {
                    Text("暂无配置").foregroundColor(.secondary).italic()
                } else {
                    ForEach(settings.residentApps) { app in
                        AppRow(name: app.name, path: app.path) {
                            settings.residentApps.removeAll { $0.id == app.id }
                        }
                    }
                    .onDelete { settings.residentApps.remove(atOffsets: $0) }
                    .onMove { settings.residentApps.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            
            // 多窗口应用
            Section(header: HStack {
                Text("多窗口应用").font(.headline)
                if !permissions.hasAccessibility {
                    Button(action: {
                        selectedTab = "system"
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("点击修复权限")
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                    }.buttonStyle(.borderless)
                }
                Spacer()
                Button(action: { addApp { settings.monitoredApps.append($0 as! MonitoredApp) } }) {
                    Image(systemName: "plus")
                }.buttonStyle(.borderless)
            }) {
                if settings.monitoredApps.isEmpty {
                    Text("暂无配置").foregroundColor(.secondary).italic()
                } else {
                    ForEach(settings.monitoredApps) { app in
                        AppRow(name: app.name, path: app.path) {
                            settings.monitoredApps.removeAll { $0.id == app.id }
                        }
                    }
                    .onDelete { settings.monitoredApps.remove(atOffsets: $0) }
                    .onMove { settings.monitoredApps.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            
            // 常用路径
            Section(header: HStack {
                Text("常用路径").font(.headline)
                Spacer()
                Button(action: {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        settings.commonPaths.append(CommonPath(name: url.lastPathComponent, path: url.path))
                    }
                }) {
                    Image(systemName: "plus")
                }.buttonStyle(.borderless)
            }) {
                if settings.commonPaths.isEmpty {
                    Text("暂无配置").foregroundColor(.secondary).italic()
                } else {
                    ForEach(settings.commonPaths) { pathItem in
                        AppRow(name: pathItem.name, path: pathItem.path) {
                            settings.commonPaths.removeAll { $0.id == pathItem.id }
                        }
                    }
                    .onDelete { settings.commonPaths.remove(atOffsets: $0) }
                    .onMove { settings.commonPaths.move(fromOffsets: $0, toOffset: $1) }
                }
            }
        }
    }
    
    private func addApp(completion: @escaping (Any) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        if panel.runModal() == .OK, let url = panel.url {
            let bundle = Bundle(url: url)
            let id = bundle?.bundleIdentifier ?? url.lastPathComponent
            let name = bundle?.infoDictionary?["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
            
            let compStr = String(describing: completion)
            if compStr.contains("ResidentApp") {
                completion(ResidentApp(id: id, name: name, path: url.path))
            } else if compStr.contains("MonitoredApp") {
                completion(MonitoredApp(id: id, name: name, path: url.path))
            } else {
                completion(FloatingApp(id: id, name: name, path: url.path))
            }
        }
    }
}

struct AppRow: View {
    var name: String
    var path: String
    var onDelete: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal").foregroundColor(.gray)
            Text(name)
            Spacer()
            Text(path).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.plain).foregroundColor(.red)
        }
        .contentShape(Rectangle())
    }
}


// MARK: - Tab 2: Hammerspoon
struct HammerspoonTab: View {
    @ObservedObject var settings = TaiChiSettings.shared
    @State private var showDeployAlert = false
    @State private var showUnsavedAlert = false
    
    var body: some View {
        VStack(spacing: 0) {
            // 后台隐藏一个视图用于挂载 NSWindowDelegate
            WindowCloseInterceptor(isModified: $settings.isHSConfigModified) {
                showUnsavedAlert = true
            }
            .frame(width: 0, height: 0)
            
            // 将功能列表放进 List 中，保持全局滚动的优雅
            List {
                Section(header: Text("全局快捷操作").font(.headline)) {
                    Toggle("激活寻星镜功能 (Inspector)", isOn: $settings.isTelescopeEnabled)
                    if settings.isTelescopeEnabled {
                        HStack {
                            Text("寻星镜触发快捷键:")
                            Spacer()
                            HotkeyRecorder(config: $settings.hotkeyTelescope)
                        }
                    }
                }
                
                Section(header: Text("悬浮应用管理 (Floating Apps)").font(.headline)) {
                    Toggle("激活悬浮应用管理功能", isOn: $settings.isFloatingFeatureEnabled)
                    if settings.isFloatingFeatureEnabled {
                        HStack {
                            Text("钉住/解钉 快捷键:")
                            Spacer()
                            HotkeyRecorder(config: $settings.hotkeyTogglePin)
                        }
                        HStack {
                            Text("全局显隐 快捷键:")
                            Spacer()
                            HotkeyRecorder(config: $settings.hotkeyToggleAll)
                        }
                    }
                }
                
                if settings.isFloatingFeatureEnabled {
                    Section(header: HStack {
                        Text("悬浮应用白名单").font(.headline)
                        Spacer()
                        Button(action: {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.allowedContentTypes = [.application]
                            if panel.runModal() == .OK, let url = panel.url {
                                let bundle = Bundle(url: url)
                                let id = bundle?.bundleIdentifier ?? url.lastPathComponent
                                let name = bundle?.infoDictionary?["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
                                settings.floatingApps.append(FloatingApp(id: id, name: name, path: url.path))
                            }
                        }) {
                            Image(systemName: "plus")
                        }.buttonStyle(.borderless)
                    }) {
                        if settings.floatingApps.isEmpty {
                            Text("暂无配置").foregroundColor(.secondary).italic()
                        } else {
                            ForEach(settings.floatingApps) { app in
                                AppRow(name: app.name, path: app.path) {
                                    settings.floatingApps.removeAll { $0.id == app.id }
                                }
                            }
                            .onDelete { settings.floatingApps.remove(atOffsets: $0) }
                            .onMove { settings.floatingApps.move(fromOffsets: $0, toOffset: $1) }
                        }
                    }
                }
                
                WallpaperEngineSection()
            }
            
            Divider()
            
            HStack {
                Spacer()
                Button("确认并应用配置") {
                    let _ = HSDeployer.shared.deployScripts(to: settings.hsConfigPath)
                    HSManager.shared.initialize(taichiPort: settings.httpPort)
                    if settings.isHSConfigModified {
                        HSManager.shared.reloadHammerspoonWithDebounce()
                        settings.isHSConfigModified = false
                    }
                    showDeployAlert = true
                }
                .buttonStyle(BorderedButtonStyle())
                .foregroundColor(settings.isHSConfigModified ? .white : .primary)
                .background(settings.isHSConfigModified ? Color.accentColor : Color.clear)
                .cornerRadius(6)
                .padding()
                .alert("部署完成", isPresented: $showDeployAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    Text("脚本已成功部署并更新。")
                }
                .alert("检测到未保存的配置", isPresented: $showUnsavedAlert) {
                    Button("放弃修改", role: .destructive) {
                        settings.isHSConfigModified = false
                        if let window = NSApp.windows.first(where: { $0.title == "Settings" || $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }) {
                            window.close()
                        }
                    }
                    Button("保存并重载", role: .cancel) {
                        let _ = HSDeployer.shared.deployScripts(to: settings.hsConfigPath)
                        HSManager.shared.initialize(taichiPort: settings.httpPort)
                        HSManager.shared.reloadHammerspoonWithDebounce()
                        settings.isHSConfigModified = false
                        showDeployAlert = true
                    }
                } message: {
                    Text("是否要应用这些配置？")
                }
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

// MARK: - Hotkey Recorder Component
struct HotkeyRecorder: View {
    @Binding var config: HotkeyConfig
    @StateObject private var vm = HotkeyRecorderViewModel()
    
    var body: some View {
        Button(action: {
            if vm.isRecording {
                vm.stopRecording()
            } else {
                vm.startRecording { newConfig in
                    self.config = newConfig
                }
            }
        }) {
            Text(vm.isRecording ? "监听中... (按任意组合键)" : "\(config.modifiers.joined(separator: "+")) + \(config.key)")
                .frame(width: 150)
        }
        .buttonStyle(.bordered)
        .foregroundColor(vm.isRecording ? .red : .primary)
    }
}

class HotkeyRecorderViewModel: ObservableObject {
    @Published var isRecording = false
    var monitor: Any?
    
    func startRecording(onComplete: @escaping (HotkeyConfig) -> Void) {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            var mods: [String] = []
            if event.modifierFlags.contains(.command) { mods.append("cmd") }
            if event.modifierFlags.contains(.control) { mods.append("ctrl") }
            if event.modifierFlags.contains(.option) { mods.append("alt") }
            if event.modifierFlags.contains(.shift) { mods.append("shift") }
            
            if let chars = event.charactersIgnoringModifiers?.uppercased(), !chars.isEmpty {
                let config = HotkeyConfig(modifiers: mods, key: chars)
                onComplete(config)
                self.stopRecording()
                return nil // consume event
            }
            return event
        }
    }
    
    func stopRecording() {
        isRecording = false
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// MARK: - Tab 3: 系统配置
struct SystemSettingsTab: View {
    @ObservedObject var settings = TaiChiSettings.shared
    @ObservedObject var permissions = PermissionsManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("系统配置")
                .font(.headline)
            
            GroupBox(label: Text("底层服务配置")) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("HTTP 网关端口:")
                            .frame(width: 120, alignment: .leading)
                        TextField("端口号", value: $settings.httpPort, formatter: NumberFormatter())
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 100)
                    }
                    HStack {
                        Text("服务脚本存放目录:")
                            .frame(width: 120, alignment: .leading)
                        TextField("路径", text: $settings.scriptsPath)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    HStack {
                        Text("HS 主配置目录:")
                            .frame(width: 120, alignment: .leading)
                        TextField("路径", text: $settings.hsConfigPath)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                }
                .padding()
            }
            
            GroupBox(label: Text("实验性功能 / 音频引擎优化")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("开启音频防休眠 (Anti-Sleep Audio)", isOn: $settings.isAudioKeepAliveEnabled)
                    Text("智能防断联：仅在连接蓝牙耳机时，于后台静音运行占位音频。解决网易云等软件暂停时，导致会议软件(Zoom/腾讯会议)无声的 macOS 底层 Bug。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
            }
            
            GroupBox(label: Text("系统权限状态")) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: permissions.hasAccessibility ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(permissions.hasAccessibility ? .green : .red)
                        Text(permissions.hasAccessibility ? "辅助功能权限（已授权）" : "辅助功能权限（未授权，用于跨桌面探测）")
                        Spacer()
                        if !permissions.hasAccessibility {
                            Button("去授权") { permissions.openSystemPreferences(pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
                        }
                    }
                    
                    HStack {
                        Image(systemName: permissions.hasScreenRecording ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(permissions.hasScreenRecording ? .green : .yellow)
                        Text(permissions.hasScreenRecording ? "屏幕录制权限（已授权）" : "屏幕录制权限（未授权，用于获取真实窗口名）")
                        Spacer()
                        if !permissions.hasScreenRecording {
                            Button("去授权") { permissions.openSystemPreferences(pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }
                        }
                    }
                }
                .padding()
            }
            
            Spacer()
        }
        .padding()
    }
}

struct WallpaperEngineSection: View {
    @ObservedObject var settings = TaiChiSettings.shared
    
    var body: some View {
        Section(header: Text("壁纸引擎 (Wallpaper Engine)").font(.headline)) {
            Toggle("激活壁纸引擎服务", isOn: $settings.isWallpaperEngineEnabled)
            if settings.isWallpaperEngineEnabled {
                let expandedScriptsPath = (settings.scriptsPath as NSString).expandingTildeInPath
                let configPath = (expandedScriptsPath as NSString).appendingPathComponent("wallpaper.json")
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("配置文件路径:").font(.subheadline)
                        HStack {
                            Text(configPath).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("打开配置") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
                            }
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("壁纸保存路径:").font(.subheadline)
                        HStack {
                            Text(settings.wallpaperSaveDir).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("打开目录") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: settings.wallpaperSaveDir))
                            }
                            Button("更改") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.canCreateDirectories = true
                                if panel.runModal() == .OK, let url = panel.url {
                                    settings.wallpaperSaveDir = url.path
                                }
                            }
                        }
                    }
                }.padding(.top, 5)
            }
        }
    }
}

@MainActor
class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?
    
    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let settingsView = SettingsView()
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "太极设置"
        newWindow.center()
        newWindow.contentView = NSHostingView(rootView: settingsView)
        newWindow.isReleasedWhenClosed = false
        
        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Window Close Interceptor
struct WindowCloseInterceptor: NSViewRepresentable {
    @Binding var isModified: Bool
    var onCloseAttempt: () -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.setup(window: window)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isModified = isModified
        context.coordinator.onCloseAttempt = onCloseAttempt
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, NSWindowDelegate {
        var isModified: Bool = false
        var onCloseAttempt: (() -> Void)?
        weak var window: NSWindow?
        
        @MainActor
        func setup(window: NSWindow) {
            self.window = window
            window.delegate = self
        }
        
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if isModified {
                onCloseAttempt?()
                return false
            }
            return true
        }
    }
}
