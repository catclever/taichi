import Foundation
import AppKit

actor BrainManager {
    static let shared = BrainManager()
    
    // 当前被“钉住”的应用
    private var pinnedApps: Set<String> = []
    
    // 全局显隐状态
    private var isAllFloatingAppsVisible: Bool = true
    
    // 防抖相关的 Task
    private var spaceChangeTask: Task<Void, Never>? = nil
    
    private init() {}
    
    private var floatingApps: [FloatingApp] {
        get async {
            await MainActor.run {
                TaiChiSettings.shared.floatingApps
            }
        }
    }
    
    func handleEvent(eventName: String, appName: String?, screenUUID: String?, path: String? = nil, id: String? = nil, payload: [[String: String]]? = nil) {
        print("🧠 [BrainManager] Received event: \(eventName) with appName: \(appName ?? "nil"), screenUUID: \(screenUUID ?? "nil"), path: \(path ?? "nil"), id: \(id ?? "nil")")
        
        switch eventName {
        case "togglePin":
            if let appName = appName {
                togglePin(for: appName)
            }
            
        case "toggleAllFloatingApps":
            toggleAllFloatingApps()
            
        case "spaceChanged":
            print("🚀 [BrainManager] spaceChanged event received: screenUUID=\(screenUUID ?? "nil")")
            if let screenUUID = screenUUID {
                handleSpaceChanged(screenUUID: screenUUID)
            }
            
        case "screensChanged":
            if let screensArray = payload {
                handleScreensChanged(screensArray: screensArray)
            }
            

        default:
            break
        }
    }
    
    // MARK: - Handlers
    
    private func togglePin(for appName: String) {
        if pinnedApps.contains(appName) {
            pinnedApps.remove(appName)
            Task { try? await HSManager.shared.sendAction(action: "alert", params: ["text": "📍 已解开 \(appName) 的钉子"]) }
        } else {
            pinnedApps.insert(appName)
            Task { try? await HSManager.shared.sendAction(action: "alert", params: ["text": "📌 已钉住 \(appName)"]) }
        }
    }
    
    private func toggleAllFloatingApps() {
        Task {
            isAllFloatingAppsVisible.toggle()
            let apps = await floatingApps
            
            for app in apps {
                let action = isAllFloatingAppsVisible ? "showApp" : "hideApp"
                try? await HSManager.shared.sendAction(action: action, params: ["appName": app.id])
            }
            let status = isAllFloatingAppsVisible ? "已显示" : "已隐藏"
            try? await HSManager.shared.sendAction(action: "alert", params: ["text": "👁️ 全局悬浮应用\(status)"])
        }
    }
    
    private func handleSpaceChanged(screenUUID: String) {
        // 防抖：取消之前未执行的切屏任务
        spaceChangeTask?.cancel()
        
        spaceChangeTask = Task {
            // 延迟 500ms 等待 macOS 动画和事件风暴平息
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            if Task.isCancelled { return }
            
            let apps = await floatingApps
            for app in apps {
                // 如果应用被钉住，则跳过
                if pinnedApps.contains(app.id) || pinnedApps.contains(app.name) { continue }
                
                // 通知 HS 检查并隐藏
                print("🧠 [BrainManager] Requesting HS to hide '\(app.name)' if on screen \(screenUUID)")
                try? await HSManager.shared.sendAction(action: "hideAppIfOnScreen", params: [
                    "appName": app.id,
                    "screenUUID": screenUUID
                ])
            }
        }
    }
    
    private func handleScreensChanged(screensArray: [[String: String]]) {
        let screens = screensArray.compactMap { dict -> ScreenInfo? in
            guard let uuid = dict["uuid"],
                  let name = dict["name"] else { return nil }
            return ScreenInfo(uuid: uuid, name: name)
        }
        
        Task { @MainActor in
            TaiChiSettings.shared.connectedScreens = screens
        }
        
        // Let WallpaperManager know about the new screens to sync state if needed
        Task {
            await WallpaperManager.shared.onScreensChanged(screens: screens)
        }
    }
}
