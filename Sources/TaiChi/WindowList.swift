import Cocoa
import ApplicationServices
import ScreenCaptureKit

struct WindowInfo: Identifiable, Equatable {
    var id: CGWindowID
    var pid: pid_t
    var appBundleID: String
    var title: String
    var bounds: CGRect
    var image: NSImage?
    var layer: Int
}

@MainActor
class WindowManager {
    static let shared = WindowManager()
    
    func getWindows(for pids: [pid_t]) async -> [WindowInfo] {
        var windows: [WindowInfo] = []
        
        let logFile = URL(fileURLWithPath: "/tmp/taichi_debug.log")
        var logOutput = "--- getWindows start ---\n"
        defer { try? logOutput.append(to: logFile) }
        
        if !PermissionsManager.shared.hasAccessibility {
            logOutput += "No Accessibility permissions\n"
            return windows
        }
        
        // 1. Primary: Use SCShareableContent if Screen Recording is allowed (most accurate, no duplicates)
        if PermissionsManager.shared.hasScreenRecording {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                for window in content.windows {
                    if window.windowLayer < 0 || window.windowLayer > 100 { continue }
                    guard let ownerPID = window.owningApplication?.processID, pids.contains(ownerPID) else { continue }
                    
                    let bounds = window.frame
                    // macOS shrinks windows on other Spaces to tiny thumbnails, filter them out
                    if bounds.width < 100 || bounds.height < 50 { continue }
                    
                    let app = NSRunningApplication(processIdentifier: ownerPID)
                    let appBundleID = app?.bundleIdentifier ?? ""
                    let title = window.title ?? ""
                    if title.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                    
                    if appBundleID == "com.apple.finder" {
                        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(bounds) }) {
                            if bounds.width >= screen.frame.width - 20 && bounds.height >= screen.frame.height - 20 {
                                continue
                            }
                        }
                    }
                    
                    logOutput += "SC Found: \(title), Bounds: \(bounds)\n"
                    windows.append(WindowInfo(id: window.windowID, pid: ownerPID, appBundleID: appBundleID, title: title, bounds: bounds, image: app?.icon, layer: window.windowLayer))
                }
                
                if !windows.isEmpty {
                    logOutput += "SCShareableContent returned \(windows.count) windows successfully.\n"
                    return windows
                }
            } catch {
                logOutput += "SCShareableContent failed: \(error)\n"
            }
        }
        
        // 2. Fallback: Get real windows on the current Space via AXUIElement
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let appName = app.localizedName ?? "App"
            let appBundleID = app.bundleIdentifier ?? ""
            let appIcon = app.icon
            
            let axApp = AXUIElementCreateApplication(pid)
            // Prevent deadlocks: set a short timeout for AX API calls
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
               let axWindows = value as? [AXUIElement] {
                for axWindow in axWindows {
                    var subroleRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                       let subrole = subroleRef as? String {
                        if subrole != kAXStandardWindowSubrole {
                            continue
                        }
                    }
                    
                    var titleRef: CFTypeRef?
                    var title = ""
                    if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                       let t = titleRef as? String {
                        title = t
                    }
                    
                    if title.isEmpty { title = "\(appName) 窗口" }
                    
                    var posRef: CFTypeRef?
                    var sizeRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
                    AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
                    var pos = CGPoint.zero
                    var size = CGSize.zero
                    
                    if let p = posRef, CFGetTypeID(p) == AXValueGetTypeID() {
                        let axValue = p as! AXValue
                        AXValueGetValue(axValue, .cgPoint, &pos)
                    }
                    if let s = sizeRef, CFGetTypeID(s) == AXValueGetTypeID() {
                        let axValue = s as! AXValue
                        AXValueGetValue(axValue, .cgSize, &size)
                    }
                    
                    let bounds = CGRect(origin: pos, size: size)
                    
                    if appBundleID == "com.apple.finder" {
                        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(bounds) }) {
                            if bounds.width >= screen.frame.width - 20 && bounds.height >= screen.frame.height - 20 {
                                continue
                            }
                        }
                    }
                    
                    var hasher = Hasher()
                    hasher.combine(pid)
                    hasher.combine(title)
                    hasher.combine(bounds.origin.x)
                    hasher.combine(bounds.origin.y)
                    let dummyID = CGWindowID(UInt32(truncatingIfNeeded: hasher.finalize()))
                    
                    let isDuplicate = windows.contains { w in
                        w.pid == pid && abs(w.bounds.origin.x - bounds.origin.x) < 5 && abs(w.bounds.origin.y - bounds.origin.y) < 5 && w.title == title
                    }
                    if isDuplicate { continue }
                    
                    logOutput += "AX Found: \(title), Bounds: \(bounds)\n"
                    windows.append(WindowInfo(id: dummyID, pid: pid, appBundleID: appBundleID, title: title, bounds: bounds, image: appIcon, layer: 0))
                }
            }
        }
        
        // 3. Fallback: CGWindowList if no screen recording permission or SCShareableContent failed
        if let windowInfoList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                for info in windowInfoList {
                    guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0 && layer <= 100,
                          let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                          pids.contains(ownerPID),
                          let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                          let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                          let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                        continue
                    }
                    
                    let isOnScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
                    if isOnScreen { continue } // Handled by AX
                    
                    // macOS shrinks windows on other Spaces to tiny thumbnails
                    // We CANNOT filter by 200x200, otherwise we delete real windows.
                    // Filter out extreme garbage like 64x64 icons.
                    if bounds.width < 100 || bounds.height < 50 { continue }
                    
                    let isDuplicate = windows.contains { w in
                        w.pid == ownerPID && abs(w.bounds.origin.x - bounds.origin.x) < 20 && abs(w.bounds.origin.y - bounds.origin.y) < 20
                    }
                    if isDuplicate { continue }
                    
                    let app = NSRunningApplication(processIdentifier: ownerPID)
                    let appName = app?.localizedName ?? "App"
                    let appBundleID = app?.bundleIdentifier ?? ""
                    
                    var title = (info[kCGWindowName as String] as? String) ?? ""
                    if title.trimmingCharacters(in: .whitespaces).isEmpty {
                        title = "\(appName) 窗口"
                    }
                    
                    if appBundleID == "com.apple.finder" {
                        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(bounds) }) {
                            if bounds.width >= screen.frame.width - 20 && bounds.height >= screen.frame.height - 20 {
                                continue
                            }
                        }
                    }
                    
                    logOutput += "CG Found Offscreen: \(title), Bounds: \(bounds)\n"
                    windows.append(WindowInfo(id: windowID, pid: ownerPID, appBundleID: appBundleID, title: title, bounds: bounds, image: app?.icon, layer: layer))
                }
            }
        
        return windows
    }
    
    // =========================================================================================
    // [BUG FIX: AXUIElement Unresponsiveness / Main Thread Freeze]
    // Problem:
    // When activating a specific window of an app (like VS Code), the method iterates over all 
    // `AXUIElement` windows for that process to find the one matching the target bounds.
    // However, some apps (like Electron apps) have notoriously broken or huge accessibility trees.
    // Attempting to query `kAXWindowsAttribute` or individual window attributes without a timeout 
    // would block the main thread for 6+ seconds per call, causing the entire UI to freeze 
    // when tapping on an app's icon.
    //
    // Method/Logic:
    // Added `AXUIElementSetMessagingTimeout(axApp, 0.5)` immediately after creating the
    // `AXUIElement` for the application. This ensures that any subsequent AX calls that hang
    // will bail out after 500ms, falling back gracefully rather than locking up the launcher.
    //
    // Caveats for future development:
    // - Always pair `AXUIElementCreateApplication` with `AXUIElementSetMessagingTimeout` 
    //   when running on the main thread, especially when targeting third-party apps.
    //
    // [Bug Fix Document]
    // 问题：点击太极中的某些应用（如 VS Code）的特定窗口图标时，整个太极界面会完全卡死数秒。
    // 原因：在通过 `activateWindow` 尝试前置指定窗口时，代码调用了无障碍 API (`AXUIElement`) 来遍历应用窗口。由于 VS Code 等 Electron 应用的无障碍树非常庞大且容易阻塞，默认的 AX 通信超时时间过长，直接阻塞了太极的主线程。
    // 修复逻辑：在创建了进程的 `axApp` 节点后，强制设置 `AXUIElementSetMessagingTimeout(axApp, 0.5)`，将无障碍 API 的通信超时限制为 500 毫秒，防止由于目标应用无响应而拖死整个启动器。
    // 注意事项：后续凡是在主线程涉及跨进程的 `AXUIElement` 查询操作，必须显式设定较短的超时时间。
    // =========================================================================================
    func activateWindow(pid: pid_t, title: String, bounds: CGRect) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let appBundleID = app.bundleIdentifier ?? ""
        
        let appName = app.localizedName ?? ""
        var raised = false
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5) // 500ms timeout to prevent hanging on unresponsive apps
        var value: CFTypeRef?
        
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        if result == .success, let axWindows = value as? [AXUIElement] {
            for axWindow in axWindows {
                var positionRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
                   AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success {
                    var position = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
                    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                    
                    let axFrame = CGRect(origin: position, size: size)
                    if abs(axFrame.origin.x - bounds.origin.x) < 5 &&
                       abs(axFrame.origin.y - bounds.origin.y) < 5 &&
                       abs(axFrame.width - bounds.width) < 5 &&
                       abs(axFrame.height - bounds.height) < 5 {
                        
                        // Un-minimize if needed
                        var isMinimized: CFTypeRef?
                        if AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &isMinimized) == .success, let minimized = isMinimized as? Bool, minimized {
                            AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                        }
                        
                        // Force main and focused attributes first
                        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, true as CFTypeRef)
                        AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, true as CFTypeRef)
                        
                        // Raise the window
                        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                        
                        raised = true
                        break
                    }
                }
            }
        }
        
        if !title.isEmpty && !title.hasSuffix(" 窗口") {
            // AppleScript fallback to force space switch
            var scriptSource = ""
            var shouldRunScript = false
            
            if appBundleID == "com.apple.finder" {
                scriptSource = """
                tell application "Finder"
                    set targetWindow to first window whose name is "\(title)"
                    set index of targetWindow to 1
                    activate
                end tell
                """
                shouldRunScript = true
            } else if !raised {
                scriptSource = """
                tell application "System Events"
                    set targetApp to first application process whose unix id is \(pid)
                    try
                        perform action "AXRaise" of window "\(title)" of targetApp
                    end try
                end tell
                """
                shouldRunScript = true
            }
            
            if shouldRunScript, let script = NSAppleScript(source: scriptSource) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
            }
        }
        
        // Unhide and Activate the app AFTER raising the window.
        // This forces macOS to switch to the Space where the raised/main window resides!
        app.unhide()
        app.activate(options: [.activateIgnoringOtherApps])
    }
}
