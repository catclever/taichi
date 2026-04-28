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
        
        // Auto-refresh permission status
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPermissions()
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
