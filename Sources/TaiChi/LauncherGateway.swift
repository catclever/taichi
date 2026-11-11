import Foundation
import AppKit

// MARK: - Launcher Module Handler Protocol

public protocol LauncherModuleHandler: Sendable {
    var namespace: String { get }       // e.g. "cyber", "service", "wall", "agent"
    var displayName: String { get }     // e.g. "⚡️ Cyber 注入应用"
    var subtitle: String { get }        // e.g. "管理与启动注入版 Chromium/Electron 应用"
    var iconPath: String? { get }
    
    func handleFilter(query: String) async -> [[String: Any]]
    func handleAction(arg: String) async -> Bool
}

// MARK: - Internal Sendable Box for Parallel Task Aggregation

private struct HandlerResultBox: @unchecked Sendable {
    let index: Int
    let items: [[String: Any]]
}

// MARK: - Unified Launcher Gateway

public final class LauncherGateway: @unchecked Sendable {
    public static let shared = LauncherGateway()
    
    private let lock = NSLock()
    private var handlers: [String: any LauncherModuleHandler] = [:]
    private var handlerOrder: [String] = []
    
    private init() {
        register(handler: CyberLauncherHandler())
        register(handler: ServiceLauncherHandler())
    }
    
    public func register(handler: any LauncherModuleHandler) {
        lock.lock()
        defer { lock.unlock() }
        let key = handler.namespace.lowercased()
        if handlers[key] == nil {
            handlerOrder.append(key)
        }
        handlers[key] = handler
    }
    
    public func unregister(namespace: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = namespace.lowercased()
        handlers.removeValue(forKey: key)
        handlerOrder.removeAll(where: { $0 == key })
    }
    
    public func handler(for namespace: String) -> (any LauncherModuleHandler)? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[namespace.lowercased()]
    }
    
    public var allHandlers: [any LauncherModuleHandler] {
        lock.lock()
        defer { lock.unlock() }
        return handlerOrder.compactMap { handlers[$0] }
    }
    
    public static var defaultIcon: [String: Any] {
        if let bundleAppPath = Bundle.main.bundlePath as String?, bundleAppPath.hasSuffix(".app") {
            return ["type": "fileicon", "path": bundleAppPath]
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.kael.taichi") {
            return ["type": "fileicon", "path": url.path]
        }
        let fallbackApp = (NSHomeDirectory() as NSString).appendingPathComponent("Projects/taichi_launcher/TaiChi.app")
        if FileManager.default.fileExists(atPath: fallbackApp) {
            return ["type": "fileicon", "path": fallbackApp]
        }
        return ["path": "icon.png"]
    }
    
    private func applyDefaultIcons(to items: [[String: Any]]) -> [[String: Any]] {
        return items.map { item in
            var mutable = item
            if mutable["icon"] == nil {
                mutable["icon"] = LauncherGateway.defaultIcon
            }
            return mutable
        }
    }
    
    private func makeNavigationCards() -> [[String: Any]] {
        return allHandlers.map { h in
            var card: [String: Any] = [
                "title": h.displayName,
                "subtitle": h.subtitle,
                "autocomplete": "\(h.namespace) ",
                "arg": "scope:\(h.namespace)",
                "valid": false
            ]
            if let icon = h.iconPath {
                card["icon"] = ["path": icon]
            } else {
                card["icon"] = LauncherGateway.defaultIcon
            }
            return card
        }
    }
    
    public func filter(rawQuery: String, explicitScope: String?) async -> [[String: Any]] {
        let items = await resolveFilter(rawQuery: rawQuery, explicitScope: explicitScope)
        return applyDefaultIcons(to: items)
    }
    
    private func resolveFilter(rawQuery: String, explicitScope: String?) async -> [[String: Any]] {
        var cleanQuery = rawQuery
        if let decoded = cleanQuery.removingPercentEncoding {
            cleanQuery = decoded
        }
        cleanQuery = cleanQuery.replacingOccurrences(of: "+", with: " ")
        
        var cleanScope = explicitScope
        if let s = cleanScope, let decoded = s.removingPercentEncoding {
            cleanScope = decoded
        }
        
        // Track 1: If explicitScope is provided and non-empty, look up handler directly
        if let explicitScope = cleanScope?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitScope.isEmpty {
            if let target = handler(for: explicitScope) {
                return await target.handleFilter(query: cleanQuery.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                return []
            }
        }
        
        // Track 2: Dual-track query parsing
        let trimmed = cleanQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTrimmed = trimmed.lowercased()
        
        // If empty or "tai": return navigation cards
        if lowerTrimmed.isEmpty || lowerTrimmed == "tai" {
            return makeNavigationCards()
        }
        
        var workingQuery = trimmed
        // If starts with "tai ": strip "tai ". If remaining is empty, return navigation cards
        if lowerTrimmed.hasPrefix("tai ") {
            let stripped = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty {
                return makeNavigationCards()
            }
            workingQuery = stripped
        }
        
        // Tokenize by whitespace
        let tokens = workingQuery.split(separator: " ", omittingEmptySubsequences: true)
        guard let firstToken = tokens.first else {
            return makeNavigationCards()
        }
        
        let firstTokenStr = String(firstToken).lowercased()
        if let targetHandler = handler(for: firstTokenStr) {
            // Strip first token and pass remaining query to target handler
            let remainingQuery = String(workingQuery.dropFirst(firstToken.count)).trimmingCharacters(in: .whitespaces)
            return await targetHandler.handleFilter(query: remainingQuery)
        } else {
            // First token does NOT match any namespace: parallel search all registered handlers and aggregate
            let activeHandlers = allHandlers
            let queryToSearch = workingQuery
            return await withTaskGroup(of: HandlerResultBox.self) { group in
                for (index, h) in activeHandlers.enumerated() {
                    group.addTask {
                        let res = await h.handleFilter(query: queryToSearch)
                        return HandlerResultBox(index: index, items: res)
                    }
                }
                var resultsList: [HandlerResultBox] = []
                for await box in group {
                    resultsList.append(box)
                }
                resultsList.sort { $0.index < $1.index }
                return resultsList.flatMap { $0.items }
            }
        }
    }
    
    public func handleAction(payload: String) async -> Bool {
        var cleanPayload = payload
        if let decoded = cleanPayload.removingPercentEncoding {
            cleanPayload = decoded
        }
        let trimmed = cleanPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        // 1. Navigation scope card action
        if trimmed.hasPrefix("scope:") {
            return true
        }
        
        // 2. Namespace colon syntax: <namespace>:<action>:<params>
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let ns = String(trimmed[..<colonIndex]).lowercased()
            if let targetHandler = handler(for: ns) {
                return await targetHandler.handleAction(arg: trimmed)
            }
        }
        
        // 3. JSON fallback
        if trimmed.hasPrefix("{") {
            if let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let ns = json["namespace"] as? String, let targetHandler = handler(for: ns) {
                    return await targetHandler.handleAction(arg: trimmed)
                }
            }
            // Fallback for legacy cyber JSON without namespace (e.g. {"action":"quit", "appId":"..."})
            if let cyberHandler = handler(for: "cyber") {
                return await cyberHandler.handleAction(arg: trimmed)
            }
        }
        
        // 4. Legacy format fallback (e.g. "open:<appId>" or raw appId)
        if let cyberHandler = handler(for: "cyber") {
            return await cyberHandler.handleAction(arg: trimmed)
        }
        
        return false
    }
}

// MARK: - Service Launcher Handler

public final class ServiceLauncherHandler: @unchecked Sendable, LauncherModuleHandler {
    public let namespace: String = "service"
    public let displayName: String = "🛠️ 系统服务 (Service Hub)"
    public let subtitle: String = "管理与监控 Descartes 系统服务、LaunchAgent 及后台进程"
    public let iconPath: String? = nil
    
    public init() {}
    
    public func handleFilter(query: String) async -> [[String: Any]] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        await MainActor.run {
            SystemServiceManager.shared.scanServices()
        }
        
        let managed = await MainActor.run {
            SystemServiceManager.shared.managedServices
        }
        let unmanaged = await MainActor.run {
            SystemServiceManager.shared.unmanagedDirectories
        }
        
        var items: [[String: Any]] = []
        
        // 1. Managed services
        for svc in managed {
            let name = svc.manifest.name
            let id = svc.id
            let desc = svc.manifest.description ?? ""
            let cat = svc.manifest.category ?? ""
            
            if !q.isEmpty {
                let matches = name.lowercased().contains(q)
                    || id.lowercased().contains(q)
                    || desc.lowercased().contains(q)
                    || cat.lowercased().contains(q)
                if !matches { continue }
            }
            
            let isRunning = svc.state.isRunning
            let portStr = svc.assignedPort > 0 ? "Port: \(svc.assignedPort)" : ""
            let statusDot = isRunning ? "🟢" : (svc.state.isStarting ? "🟡" : "⚪️")
            
            var title = "\(statusDot) \(name)"
            if !portStr.isEmpty {
                title += " (\(portStr))"
            }
            
            var subtitle = ""
            var actionArg = "service:start:\(id)"
            var modsDict: [String: Any] = [
                "alt+shift": [
                    "valid": true,
                    "arg": "service:ignore:\(id)",
                    "subtitle": "🚫 忽略此服务，不再出现在启动器中 (Option + Shift + Enter)"
                ],
                "alt": [
                    "valid": true,
                    "arg": "service:ignore:\(id)",
                    "subtitle": "🚫 忽略此服务 (Option + Enter)"
                ]
            ]
            
            if isRunning {
                subtitle = "⚡️ 运行中 (PID \(svc.pid ?? 0)) - 回车打开/激活"
                if svc.manifest.hasWebUI == true {
                    actionArg = "service:open:\(id)"
                } else {
                    actionArg = "service:restart:\(id)"
                }
                modsDict["cmd"] = [
                    "valid": true,
                    "arg": "service:stop:\(id)",
                    "subtitle": "🛑 停止该服务 (Cmd + Enter)"
                ]
            } else if svc.state.isStarting {
                subtitle = "⏳ 启动中..."
                actionArg = "service:stop:\(id)"
            } else {
                subtitle = "\(desc.isEmpty ? "已停止" : desc) - 回车启动服务"
                actionArg = "service:start:\(id)"
            }
            
            var item: [String: Any] = [
                "title": title,
                "subtitle": subtitle,
                "arg": actionArg,
                "mods": modsDict,
                "icon": LauncherGateway.defaultIcon
            ]
            items.append(item)
        }
        
        // 2. Unmanaged directories (for AI onboarding via Descartes Hub)
        let activeOnboardingPath = await MainActor.run {
            SystemServiceManager.shared.activeOnboardingDir?.resolvingSymlinksInPath().path
        }

        for dirURL in unmanaged {
            let dirName = dirURL.lastPathComponent
            if !q.isEmpty && !dirName.lowercased().contains(q) && !"导入".contains(q) && !"onboard".contains(q) {
                continue
            }

            let isOnboarding = (activeOnboardingPath == dirURL.resolvingSymlinksInPath().path)
            let item: [String: Any]
            if isOnboarding {
                item = [
                    "title": "🧠 AI 分析导入中: \(dirName)",
                    "subtitle": "Descartes Hub 正在深度分析项目结构并生成规范化配置...",
                    "arg": "service:noop",
                    "icon": LauncherGateway.defaultIcon
                ]
            } else {
                item = [
                    "title": "✨ 导入服务: \(dirName)",
                    "subtitle": "未配置 taichi-service.json - 回车通过 Descartes AI 智能分析与规范化",
                    "arg": "service:onboard:\(dirName)",
                    "mods": [
                        "alt+shift": [
                            "valid": true,
                            "arg": "service:ignore:\(dirName)",
                            "subtitle": "🚫 忽略此目录，不再出现在启动器中 (Option + Shift + Enter)"
                        ],
                        "alt": [
                            "valid": true,
                            "arg": "service:ignore:\(dirName)",
                            "subtitle": "🚫 忽略此目录 (Option + Enter)"
                        ]
                    ],
                    "icon": LauncherGateway.defaultIcon
                ]
            }
            items.append(item)
        }
        
        if items.isEmpty {
            if q.isEmpty {
                return [
                    [
                        "title": "系统服务列表 (Service Hub)",
                        "subtitle": "目录 ~/Library/Services 下暂无待管理或待导入服务",
                        "arg": "service:noop",
                        "valid": false,
                        "icon": LauncherGateway.defaultIcon
                    ]
                ]
            }
            return []
        }
        
        return items
    }
    
    public func handleAction(arg: String) async -> Bool {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        var action = ""
        var target = ""
        
        if trimmed.hasPrefix("service:") {
            let rest = String(trimmed.dropFirst(8)) // drops "service:"
            let parts = rest.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                action = String(parts[0])
                target = String(parts[1])
            } else if parts.count == 1 {
                action = String(parts[0])
            }
        }
        
        guard !action.isEmpty else { return true }
        
        switch action {
        case "start":
            await MainActor.run {
                SystemServiceManager.shared.startService(serviceId: target)
            }
            return true
            
        case "stop":
            await MainActor.run {
                SystemServiceManager.shared.stopService(serviceId: target)
            }
            return true
            
        case "restart":
            await MainActor.run {
                SystemServiceManager.shared.stopService(serviceId: target)
                SystemServiceManager.shared.startService(serviceId: target)
            }
            return true
            
        case "open":
            await MainActor.run {
                guard let svc = SystemServiceManager.shared.managedServices.first(where: { $0.id == target }) else { return }
                if !svc.state.isRunning {
                    SystemServiceManager.shared.startService(serviceId: target)
                }
                let port = svc.assignedPort > 0 ? svc.assignedPort : (svc.manifest.defaultPort ?? 8000)
                let path = svc.manifest.webPath ?? ""
                let urlStr = "http://127.0.0.1:\(port)\(path)"
                if let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }
            }
            return true
            
        case "onboard":
            let dirName = target
            await MainActor.run {
                let rawPath = TaiChiSettings.shared.servicesDirectoryPath
                let servicesPath = (rawPath as NSString).expandingTildeInPath
                let targetDirURL = URL(fileURLWithPath: servicesPath).appendingPathComponent(dirName)
                print("✨ [Descartes Hub] Triggering onboarding for \(targetDirURL.path)...")
                SystemServiceManager.shared.onboardService(
                    dirURL: targetDirURL,
                    onThought: { thought in
                        print("💭 [Descartes Thought]: \(thought)")
                    },
                    onLog: { log in
                        print("📝 [Descartes Log]: \(log)")
                    },
                    completion: { result in
                        switch result {
                        case .success(let msg):
                            print("✅ [Descartes Onboard Success]: \(msg)")
                        case .failure(let err):
                            print("❌ [Descartes Onboard Failure]: \(err.localizedDescription)")
                        }
                    }
                )
            }
            return true
            
        case "ignore":
            let dirOrId = target
            await MainActor.run {
                SystemServiceManager.shared.ignoreService(identifier: dirOrId)
            }
            return true

        case "noop":
            return true
            
        default:
            print("⚠️ [ServiceLauncherHandler] Unknown action: \(action)")
            return false
        }
    }
}

// MARK: - Cyber Launcher Handler

public final class CyberLauncherHandler: @unchecked Sendable, LauncherModuleHandler {
    public let namespace: String = "cyber"
    public let displayName: String = "⚡️ Cyber 注入应用"
    public let subtitle: String = "管理与启动注入版 Chromium/Electron 应用"
    public let iconPath: String? = nil
    
    public init() {}
    
    public func handleFilter(query: String) async -> [[String: Any]] {
        ServerManager.shared.refreshCyberAppsStatus()
        
        let scriptsDir = await MainActor.run {
            (TaiChiSettings.shared.scriptsPath as NSString).expandingTildeInPath
        }
        let appsDir = (scriptsDir as NSString).appendingPathComponent("apps")
        
        var items: [[String: Any]] = []
        let fm = FileManager.default
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        let activeInjectedAppIDs = await MainActor.run {
            TaiChiSettings.shared.activeInjectedApps.map { $0.id }
        }
        let runningApps = NSWorkspace.shared.runningApplications
        
        var targetAppIds = Set<String>()
        
        // 1. Add apps from appsDir (user-configured scripts)
        if let contents = try? fm.contentsOfDirectory(atPath: appsDir) {
            for appId in contents {
                var isDirectory: ObjCBool = false
                let appPath = (appsDir as NSString).appendingPathComponent(appId)
                if fm.fileExists(atPath: appPath, isDirectory: &isDirectory), isDirectory.boolValue {
                    targetAppIds.insert(appId)
                }
            }
        }
        
        // 2. Add currently active injected apps
        for appId in activeInjectedAppIDs {
            targetAppIds.insert(appId)
        }
        
        // 3. If querying, globally search for installed apps to allow ad-hoc injection
        if !q.isEmpty {
            let appDirs = ["/Applications", "/System/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
            for dir in appDirs {
                let dirURL = URL(fileURLWithPath: dir)
                if let enumerator = fm.enumerator(at: dirURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    while let url = enumerator.nextObject() as? URL {
                        if url.pathExtension == "app" {
                            let appName = url.deletingPathExtension().lastPathComponent.lowercased()
                            if appName.contains(q) {
                                // MUST be a Chromium-based app (Electron, CEF, Chrome, etc.)
                                let frameworksURL = url.appendingPathComponent("Contents/Frameworks")
                                var isChromium = false
                                if let frameworkContents = try? fm.contentsOfDirectory(atPath: frameworksURL.path) {
                                    for item in frameworkContents {
                                        if item.contains("Electron") || item.contains("Chromium") || item.contains("Chrome") || item.contains("CEF") {
                                            isChromium = true
                                            break
                                        }
                                    }
                                }
                                
                                if isChromium {
                                    if let bundleId = Bundle(url: url)?.bundleIdentifier {
                                        targetAppIds.insert(bundleId)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        for appId in targetAppIds {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appId) {
                let appName = appURL.deletingPathExtension().lastPathComponent
                
                if !q.isEmpty && !appName.lowercased().contains(q) && !appId.lowercased().contains(q) {
                    continue
                }
                
                let isInjected = activeInjectedAppIDs.contains(appId)
                let isRunning = runningApps.contains(where: { $0.bundleIdentifier == appId })
                
                var itemTitle = appName
                if isInjected {
                    itemTitle += " (Cyber 版)"
                }
                
                var subtitle = "点击启动进入 Cyber 模式"
                var mods: [String: Any]? = nil
                
                if isInjected {
                    subtitle = "⚡️ 已注入，回车直接激活窗口"
                    let app = runningApps.first(where: { $0.bundleIdentifier == appId })
                    if let port = ServerManager.shared.resolveDebuggingPort(for: appId, runningApp: app) {
                        subtitle += " (Port: \(port))"
                    }
                    
                    mods = [
                        "cmd": [
                            "valid": true,
                            "arg": "cyber:quit:\(appId)",
                            "subtitle": "🛑 退出该应用 (Cmd + Enter)"
                        ]
                    ]
                } else if isRunning {
                    subtitle = "⚡︎ 正在普通运行，回车将强制重启并注入"
                }
                
                var item: [String: Any] = [
                    "title": itemTitle,
                    "subtitle": subtitle,
                    "arg": "cyber:open:\(appId)",
                    "icon": ["type": "fileicon", "path": appURL.path]
                ]
                
                if let mods = mods {
                    item["mods"] = mods
                }
                
                items.append(item)
            }
        }
        
        items.sort { a, b in
            let titleA = a["title"] as? String ?? ""
            let titleB = b["title"] as? String ?? ""
            let injectedA = titleA.contains("(Cyber 版)")
            let injectedB = titleB.contains("(Cyber 版)")
            if injectedA != injectedB {
                return injectedA && !injectedB
            }
            return titleA.localizedStandardCompare(titleB) == .orderedAscending
        }
        
        return items
    }
    
    public func handleAction(arg: String) async -> Bool {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        
        var action = "open"
        var appId = ""
        
        if trimmed.hasPrefix("{") {
            if let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                action = json["action"] ?? "open"
                appId = json["appId"] ?? ""
            }
        } else if trimmed.hasPrefix("cyber:") {
            let rest = String(trimmed.dropFirst(6)) // drops "cyber:"
            let parts = rest.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                action = String(parts[0])
                appId = String(parts[1])
            } else if parts.count == 1 {
                action = "open"
                appId = String(parts[0])
            }
        } else if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                action = String(parts[0])
                appId = String(parts[1])
            } else {
                appId = trimmed
            }
        } else {
            appId = trimmed
        }
        
        guard !appId.isEmpty else { return false }
        return await performLauncherAction(action: action, appId: appId)
    }
    
    private func performLauncherAction(action: String, appId: String) async -> Bool {
        let finalAppId = appId
        let runningApps = NSWorkspace.shared.runningApplications
        
        if action == "quit" {
            if let appToQuit = runningApps.first(where: { $0.bundleIdentifier == finalAppId }) {
                appToQuit.terminate()
            }
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finalAppId)
            let appName = appURL?.deletingPathExtension().lastPathComponent ?? finalAppId
            await MainActor.run {
                TaiChiSettings.shared.activeInjectedApps.removeAll(where: { $0.id == finalAppId })
            }
            _ = try? await HSManager.shared.sendAction(action: "hotkey.unregister", params: ["app": appName, "profileId": "taichi_inspector"])
            return true
        }
        
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finalAppId) else {
            print("❌ Application not found for bundle ID \(finalAppId)")
            return false
        }
        
        let activeInjectedAppIDs = await MainActor.run {
            TaiChiSettings.shared.activeInjectedApps.map { $0.id }
        }
        
        let isRunning = runningApps.contains(where: { $0.bundleIdentifier == finalAppId })
        let isInjected = activeInjectedAppIDs.contains(finalAppId)
        
        if isInjected {
            // Case A: Already injected. Just bring to front.
            if let app = runningApps.first(where: { $0.bundleIdentifier == finalAppId }) {
                app.activate(options: [.activateAllWindows])
            } else {
                // Not actually running? Clean up state.
                let appName = appURL.deletingPathExtension().lastPathComponent
                await MainActor.run {
                    TaiChiSettings.shared.activeInjectedApps.removeAll(where: { $0.id == finalAppId })
                }
                _ = try? await HSManager.shared.sendAction(action: "hotkey.unregister", params: ["app": appName, "profileId": "taichi_inspector"])
            }
            return true
        }
        
        // Helper to launch with CDP
        let launchWithCDP: @Sendable () -> Void = { [weak self, finalAppId, appURL] in
            guard self != nil else { return }
            let targetPort = ServerManager.shared.findAvailablePort(startPort: 9222)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--remote-debugging-port=\(targetPort)"]
            configuration.activates = true
            
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { (app: NSRunningApplication?, error: Error?) in
                if let error = error {
                    print("❌ Failed to open \(finalAppId): \(error.localizedDescription)")
                    return
                }
                
                guard let workerPort = ServerManager.shared.workerPort else {
                    print("⚠️ ServerManager workerPort is nil")
                    return
                }
                let appName = app?.localizedName ?? appURL.deletingPathExtension().lastPathComponent
                let pid = app?.processIdentifier
                
                Task { @MainActor in
                    let monitoredApp = MonitoredApp(id: finalAppId, name: appName, path: appURL.path, pid: pid, port: targetPort)
                    if let index = TaiChiSettings.shared.activeInjectedApps.firstIndex(where: { $0.id == finalAppId }) {
                        var existingApp = TaiChiSettings.shared.activeInjectedApps[index]
                        existingApp.pid = pid
                        existingApp.port = targetPort
                        TaiChiSettings.shared.activeInjectedApps[index] = existingApp
                    } else {
                        TaiChiSettings.shared.activeInjectedApps.append(monitoredApp)
                        
                        let hotkey = TaiChiSettings.shared.hotkeyTelescope
                        Task {
                            let bindings: [[String: Any]] = [
                                [
                                    "mods": hotkey.modifiers,
                                    "key": hotkey.key,
                                    "type": "lua",
                                    "luaAction": "taichi.triggerInspector"
                                ]
                            ]
                            let params: [String: Any] = [
                                "app": appName,
                                "profileId": "taichi_inspector",
                                "bindings": bindings
                            ]
                            _ = try? await HSManager.shared.sendAction(action: "hotkey.register", params: params)
                        }
                    }
                }
                
                Task {
                    // Wait slightly to ensure app starts and CDP is up
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    print("🚀 \(finalAppId) launched on CDP port \(targetPort). Invoking worker...")
                    var components = URLComponents()
                    components.scheme = "http"
                    components.host = "127.0.0.1"
                    components.port = workerPort
                    components.path = "/script/apps/\(finalAppId)/worker/index"
                    components.queryItems = [URLQueryItem(name: "port", value: String(targetPort))]
                    
                    if let url = components.url {
                        do {
                            let (_, response) = try await URLSession.shared.data(from: url)
                            if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                                print("✅ Worker trigger succeeded for \(finalAppId)")
                            } else {
                                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                                print("⚠️ Worker trigger returned status \(statusCode)")
                            }
                        } catch {
                            print("⚠️ Worker trigger failed for \(finalAppId): \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
        
        if isRunning {
            // Case C: Running but not injected. Force quit and relaunch.
            if let appToQuit = runningApps.first(where: { $0.bundleIdentifier == finalAppId }) {
                appToQuit.terminate()
                
                Task.detached {
                    var attempts = 0
                    while !appToQuit.isTerminated && attempts < 20 {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        attempts += 1
                    }
                    if !appToQuit.isTerminated {
                        appToQuit.forceTerminate()
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    launchWithCDP()
                }
            }
            return true
        } else {
            // Case B: Not running.
            launchWithCDP()
            return true
        }
    }
}
