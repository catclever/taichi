import Cocoa
import ApplicationServices

@MainActor
class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()
    
    @Published var hasAccessibility: Bool = false
    @Published var hasScreenRecording: Bool = false
    
    private var timer: Timer?
    
    private init() {
        checkPermissions()
        
        // [Bug Fix Document]
        // 问题：应用在后台闲置时耗电过高，原因之一是定时器无限轮询。
        // 修复逻辑：一旦检测到无障碍和录屏权限均已获取，立刻执行 `timer?.invalidate()` 销毁定时器，停止无效的心跳检测。
        // 注意事项：后续如果有新增其他需要长期监控的权限，可以按需重启定时器，但必须保证成功后及时销毁，切忌无限轮询。
        // Auto-refresh permission status until both are granted
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermissions()
                if self?.hasAccessibility == true && self?.hasScreenRecording == true {
                    self?.timer?.invalidate()
                    self?.timer = nil
                }
            }
        }
    }
    
    func checkPermissions() {
        checkAccessibility()
        checkScreenRecording()
    }
    
    private func checkAccessibility() {
        hasAccessibility = AXIsProcessTrusted()
    }
    
    private func checkScreenRecording() {
        hasScreenRecording = CGPreflightScreenCaptureAccess()
    }
    
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true]
        hasAccessibility = AXIsProcessTrustedWithOptions(options as CFDictionary)
        // macOS will automatically add the app to the list and show the popup.
    }
    
    // [Bug Fix Document]
    // 问题：太极在首次请求录屏权限时，系统不弹窗，且未将应用添加至系统设置的录屏权限清单中。
    // 原因：
    // 1. 较新的 macOS 不仅要求通过 `CGRequestScreenCaptureAccess()` 发起请求，还要求 `Info.plist` 中必须包含 `NSScreenCaptureUsageDescription` 描述（在 build_app.sh 中修复）。
    // 2. 在部分场景下，纯预检请求可能依旧被系统丢弃。必须附加一次实质性的截图（或图像流捕获）行为才能强制唤起系统弹窗并注册到列表中。
    // 3. SettingsView 原先的“去授权”按钮仅打开了系统设置页面，未实际调用过 `requestScreenRecording`。
    // 修复逻辑：
    // 在调用 `CGRequestScreenCaptureAccess()` 的同时，执行一次基于 `CGWindowListCreateImage` 的空截图探测，强行触发系统层面的权限注册。同时补充了 Info.plist 的声明，并在 UI 层绑定了实际调用。
    // 注意事项：不要移除 `CGWindowListCreateImage` 探测，否则在 macOS 14.4+ 上可能再次遭遇静默授权失败问题。
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        // Force macOS to add the app to the Screen Recording permissions list by attempting a capture
        let _ = CGWindowListCreateImage(CGRect.null, .optionOnScreenOnly, kCGNullWindowID, .boundsIgnoreFraming)
        hasScreenRecording = CGPreflightScreenCaptureAccess()
    }
    
    func openSystemPreferences(pane: String) {
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }
}
