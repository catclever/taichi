import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = TaiChiSettings.shared
    @ObservedObject var permissions = PermissionsManager.shared
    
    var body: some View {
        TabView {
            ResidentAppsTab()
                .tabItem {
                    Label("常驻应用", systemImage: "pin.fill")
                }
            
            MonitoredAppsTab()
                .tabItem {
                    Label("监控应用", systemImage: "eye.fill")
                }
            
            CommonPathsTab()
                .tabItem {
                    Label("常用路径", systemImage: "folder.fill")
                }
        }
        .padding()
        .frame(width: 500, height: 400)
    }
}

struct ResidentAppsTab: View {
    @ObservedObject var settings = TaiChiSettings.shared
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("配置常驻应用列表：")
                .font(.headline)
            
            List {
                ForEach(settings.residentApps) { app in
                    HStack {
                        Text(app.name)
                        Spacer()
                        Text(app.path).font(.caption).foregroundColor(.secondary)
                        Button(action: { settings.residentApps.removeAll { $0.id == app.id } }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                    }
                }
                .onDelete { indexSet in
                    settings.residentApps.remove(atOffsets: indexSet)
                }
                .onMove { indices, newOffset in
                    settings.residentApps.move(fromOffsets: indices, toOffset: newOffset)
                }
            }
            
            HStack {
                Button("添加应用...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowedContentTypes = [.application]
                    if panel.runModal() == .OK, let url = panel.url {
                        let bundle = Bundle(url: url)
                        let id = bundle?.bundleIdentifier ?? url.lastPathComponent
                        let name = bundle?.infoDictionary?["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
                        
                        if !settings.residentApps.contains(where: { $0.id == id }) {
                            settings.residentApps.append(ResidentApp(id: id, name: name, path: url.path))
                        }
                    }
                }
                Spacer()
            }
        }
        .padding()
    }
}

struct MonitoredAppsTab: View {
    @ObservedObject var settings = TaiChiSettings.shared
    @ObservedObject var permissions = PermissionsManager.shared
    
    var body: some View {
        VStack(alignment: .leading) {
            GroupBox(label: Text("系统权限状态").foregroundColor(permissions.hasAccessibility ? .secondary : .red)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("太极需要系统权限来探测跨桌面的真实窗口名字：")
                        .font(.caption)
                    
                    HStack {
                        Image(systemName: permissions.hasAccessibility ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(permissions.hasAccessibility ? .green : .red)
                        Text(permissions.hasAccessibility ? "辅助功能权限（已授权）" : "辅助功能权限（未授权）")
                        Spacer()
                        if !permissions.hasAccessibility {
                            Button("去授权") {
                                permissions.requestAccessibility()
                            }
                        }
                    }
                    
                    HStack {
                        Image(systemName: permissions.hasScreenRecording ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(permissions.hasScreenRecording ? .green : .yellow)
                        Text(permissions.hasScreenRecording ? "屏幕录制权限（已授权，上帝视角开启）" : "屏幕录制权限（未授权，无法显示跨桌面真实名字）")
                        Spacer()
                        if !permissions.hasScreenRecording {
                            Button("去授权") {
                                permissions.requestScreenRecording()
                            }
                        }
                    }
                }
            }
            
            Text("配置需要监控窗口的应用：")
                .font(.headline)
            
            List {
                ForEach(settings.monitoredApps) { app in
                    HStack {
                        Text(app.name)
                        Spacer()
                        Text(app.path).font(.caption).foregroundColor(.secondary)
                        Button(action: { settings.monitoredApps.removeAll { $0.id == app.id } }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                    }
                }
                .onDelete { indexSet in
                    settings.monitoredApps.remove(atOffsets: indexSet)
                }
                .onMove { indices, newOffset in
                    settings.monitoredApps.move(fromOffsets: indices, toOffset: newOffset)
                }
            }
            
            HStack {
                Button("添加...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowedContentTypes = [.application]
                    if panel.runModal() == .OK, let url = panel.url {
                        let bundle = Bundle(url: url)
                        let id = bundle?.bundleIdentifier ?? url.lastPathComponent
                        let name = bundle?.infoDictionary?["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
                        
                        if !settings.monitoredApps.contains(where: { $0.id == id }) {
                            settings.monitoredApps.append(MonitoredApp(id: id, name: name, path: url.path))
                        }
                    }
                }
                Spacer()
            }
        }
        .padding()
    }
}

struct CommonPathsTab: View {
    @ObservedObject var settings = TaiChiSettings.shared
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("配置常用路径：")
                .font(.headline)
            
            List {
                ForEach(settings.commonPaths) { pathItem in
                    HStack {
                        Text(pathItem.name)
                        Spacer()
                        Text(pathItem.path).font(.caption).foregroundColor(.secondary)
                        Button(action: { settings.commonPaths.removeAll { $0.id == pathItem.id } }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                    }
                }
                .onDelete { indexSet in
                    settings.commonPaths.remove(atOffsets: indexSet)
                }
                .onMove { indices, newOffset in
                    settings.commonPaths.move(fromOffsets: indices, toOffset: newOffset)
                }
            }
            
            HStack {
                Button("添加路径...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK, let url = panel.url {
                        let name = url.lastPathComponent
                        settings.commonPaths.append(CommonPath(name: name, path: url.path))
                    }
                }
                Spacer()
            }
        }
        .padding()
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
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
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
