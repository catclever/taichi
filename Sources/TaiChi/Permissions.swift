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
    
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        hasScreenRecording = CGPreflightScreenCaptureAccess()
    }
    
    func openSystemPreferences(pane: String) {
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }
}
