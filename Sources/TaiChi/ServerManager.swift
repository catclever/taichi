import Foundation
import AppKit
import Swifter

class ProxyResponse: @unchecked Sendable {
    var data: Data?
    var statusCode: Int = 500
}

class ServerManager: @unchecked Sendable {
    static let shared = ServerManager()
    
    private let server = HttpServer()
    private var stateCache: [String: String] = [:]
    private let cacheQueue = DispatchQueue(label: "com.taichi.cache")
    
    private var scriptCache: [String: (response: String, expireAt: Date)] = [:]
    private let scriptCacheQueue = DispatchQueue(label: "com.taichi.scriptcache")
    
    private var isRunning = false
    private var cleanupTimer: Timer?
    private let maxCacheItems = 1000
    
    private var workerProcess: Foundation.Process?
    private var workerPort: Int?
    
    private init() {
        setupRoutes()
    }
    
    @MainActor
    func start() {
        guard !isRunning else { return }
        
        let port = in_port_t(TaiChiSettings.shared.httpPort)
        do {
            try server.start(port)
            isRunning = true
            print("🚀 TaiChi Gateway started on port \(port)")
            
            startWorker()
            
            cleanupTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
                self?.cleanupCaches()
            }
        } catch {
            print("❌ Failed to start TaiChi Gateway: \(error)")
        }
    }
    
    func stop() {
        if isRunning {
            server.stop()
            isRunning = false
            cleanupTimer?.invalidate()
            cleanupTimer = nil
            stopWorker()
            print("🛑 TaiChi Gateway stopped")
        }
    }
    
    @MainActor
    private func startWorker() {
        let scriptsDir = (TaiChiSettings.shared.scriptsPath as NSString).expandingTildeInPath
        let workerScriptPath = (scriptsDir as NSString).appendingPathComponent(".taichi_worker.js")
        
        let workerCode = """
        const http = require('http');
        const url = require('url');
        const fs = require('fs');
        const path = require('path');
        const SCRIPTS_DIR = process.argv[2] || __dirname;
        const server = http.createServer(async (req, res) => {
            const parsedUrl = url.parse(req.url, true);
            if (!parsedUrl.pathname.startsWith('/script/')) {
                res.writeHead(404); return res.end('Not found');
            }
            const scriptName = parsedUrl.pathname.replace('/script/', '');
            let scriptPath = path.join(SCRIPTS_DIR, scriptName + '.js');
            if (!fs.existsSync(scriptPath)) {
                res.writeHead(404, { 'Content-Type': 'application/json' });
                return res.end(JSON.stringify({ error: `Script not found: ${scriptName}` }));
            }
            try {
                if (parsedUrl.query.nocache) {
                    delete require.cache[require.resolve(scriptPath)];
                }
                const scriptModule = require(scriptPath);
                let result;
                if (typeof scriptModule === 'function') {
                    result = await scriptModule(parsedUrl.query);
                } else {
                    result = scriptModule;
                }
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify(result));
            } catch (e) {
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: "Script execution failed", details: e.message, stack: e.stack }));
            }
        });
        server.listen(0, '127.0.0.1', () => {
            console.log(`READY:${server.address().port}`);
        });
        """
        
        try? workerCode.write(toFile: workerScriptPath, atomically: true, encoding: .utf8)
        
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-l", "-c", "node \"\(workerScriptPath)\" \"\(scriptsDir)\""]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        let semaphore = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let str = String(data: data, encoding: .utf8) {
                let lines = str.components(separatedBy: .newlines)
                for line in lines {
                    if line.hasPrefix("READY:") {
                        if let portStr = line.components(separatedBy: ":").last, let port = Int(portStr) {
                            self?.workerPort = port
                            print("🔥 Node Worker ready on port \(port)")
                            semaphore.signal()
                        }
                    } else if !line.isEmpty {
                        print("[Worker] \(line)")
                    }
                }
            }
        }
        
        do {
            try process.run()
            self.workerProcess = process
            _ = semaphore.wait(timeout: .now() + 5.0)
        } catch {
            print("Failed to start Node worker: \(error)")
        }
    }
    
    private func stopWorker() {
        workerProcess?.terminate()
        workerProcess = nil
        workerPort = nil
    }
    
    private func cleanupCaches() {
        let now = Date()
        
        scriptCacheQueue.sync {
            scriptCache = scriptCache.filter { $0.value.expireAt > now }
            if scriptCache.count > maxCacheItems {
                let keysToRemove = scriptCache.keys.prefix(scriptCache.count - maxCacheItems)
                for key in keysToRemove {
                    scriptCache.removeValue(forKey: key)
                }
            }
        }
        
        cacheQueue.sync {
            if stateCache.count > maxCacheItems {
                let keysToRemove = stateCache.keys.prefix(stateCache.count - maxCacheItems)
                for key in keysToRemove {
                    stateCache.removeValue(forKey: key)
                }
            }
        }
    }
    
    private func setupRoutes() {
        // Handle OPTIONS globally and catch all deep /src/ paths before routing
        server.middleware.append { [weak self] request in
            guard let self = self else { return nil }
            
            if request.method == "OPTIONS" {
                return self.jsonResponse(["status": "ok"])
            }
            
            if request.path.hasPrefix("/src/") {
                return self.handleSrcRequest(request)
            }
            
            if request.path.hasPrefix("/api/script/") {
                return self.handleScriptRequest(request)
            }
            
            return nil
        }
        
        // 1. Core State API (GET/POST /api/var/:key)
        server["/api/var/:key"] = { [weak self] request in
            return self?.handleVarRequest(request) ?? .internalServerError
        }
        
        // 2. Scripting API is now handled in middleware to support deep subpaths

        
        // 3. Launcher API (Alfred integration)
        server["/api/launcher/filter"] = { [weak self] request in
            return self?.handleLauncherFilter(request) ?? .internalServerError
        }
        
        server["/api/launcher/action"] = { [weak self] request in
            return self?.handleLauncherAction(request) ?? .internalServerError
        }
    }
    
    private func jsonResponse(_ obj: Any, statusCode: Int = 200) -> HttpResponse {
        let headers = [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
            "Content-Type": "application/json"
        ]
        
        if let str = obj as? String {
            return .raw(statusCode, "OK", headers, { writer in
                try? writer.write([UInt8](str.utf8))
            })
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
           let str = String(data: data, encoding: .utf8) {
            return .raw(statusCode, "OK", headers, { writer in
                try? writer.write([UInt8](str.utf8))
            })
        }
        
        return .internalServerError
    }
    
    private func handleVarRequest(_ request: HttpRequest) -> HttpResponse {
        guard let key = request.params[":key"] else {
            return jsonResponse(["error": "Missing key parameter"], statusCode: 400)
        }
        
        if request.method == "GET" {
            let value = cacheQueue.sync { stateCache[key] }
            if let value = value {
                // If it's already a JSON string, return directly
                if value.hasPrefix("{") || value.hasPrefix("[") {
                    return jsonResponse(value)
                } else {
                    return jsonResponse(["key": key, "value": value])
                }
            } else {
                return jsonResponse(["error": "Not found"], statusCode: 404)
            }
        } else if request.method == "POST" {
            let bodyString = String(bytes: request.body, encoding: .utf8) ?? ""
            cacheQueue.sync {
                stateCache[key] = bodyString
                if stateCache.count > maxCacheItems, let firstKey = stateCache.keys.first {
                    stateCache.removeValue(forKey: firstKey)
                }
            }
            return jsonResponse(["success": true, "key": key, "value": bodyString])
        }
        
        return jsonResponse(["error": "Method not allowed"], statusCode: 405)
    }
    
    private func handleSrcRequest(_ request: HttpRequest) -> HttpResponse {
        // Extract subpath after "/src/"
        let subpath = String(request.path.dropFirst("/src/".count))
        
        // Security check: Block path traversal and hidden files
        let pathComponents = subpath.components(separatedBy: "/")
        if pathComponents.contains(where: { $0 == ".." || $0.hasPrefix(".") }) {
            return jsonResponse(["error": "Forbidden"], statusCode: 403)
        }
        
        let scriptsDir = DispatchQueue.main.sync {
            (TaiChiSettings.shared.scriptsPath as NSString).expandingTildeInPath
        }
        
        let fileURL = URL(fileURLWithPath: scriptsDir).appendingPathComponent(subpath)
        
        do {
            let data = try Data(contentsOf: fileURL)
            let ext = fileURL.pathExtension.lowercased()
            
            var mimeType = "text/plain"
            switch ext {
            case "js", "mjs": mimeType = "application/javascript"
            case "css": mimeType = "text/css"
            case "html", "htm": mimeType = "text/html"
            case "json": mimeType = "application/json"
            case "png": mimeType = "image/png"
            case "jpg", "jpeg": mimeType = "image/jpeg"
            case "svg": mimeType = "image/svg+xml"
            default: mimeType = "text/plain"
            }
            
            let headers = [
                "Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type",
                "Content-Type": mimeType
            ]
            
            return .raw(200, "OK", headers, { writer in
                try? writer.write([UInt8](data))
            })
        } catch {
            return jsonResponse(["error": "File not found"], statusCode: 404)
        }
    }
    
    private func handleScriptRequest(_ request: HttpRequest) -> HttpResponse {
        let prefix = "/api/script/"
        guard request.path.hasPrefix(prefix) else {
            return jsonResponse(["error": "Invalid script path"], statusCode: 400)
        }
        let name = String(request.path.dropFirst(prefix.count))
        if name.isEmpty {
            return jsonResponse(["error": "Missing script name parameter"], statusCode: 400)
        }
        
        let cacheKey = "\(name)_" + request.queryParams.map { "\($0.0)=\($0.1)" }.sorted().joined(separator: "&")
        
        let cached = scriptCacheQueue.sync { scriptCache[cacheKey] }
        if let cached = cached, cached.expireAt > Date() {
            if cached.response.hasPrefix("{") || cached.response.hasPrefix("[") {
                return jsonResponse(cached.response)
            }
            return jsonResponse(["success": true, "output": cached.response, "cached": true])
        }
        
        guard let port = workerPort else {
            return jsonResponse(["error": "Node worker not ready"], statusCode: 500)
        }
        
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/script/\(name)"
        if !request.queryParams.isEmpty {
            components.queryItems = request.queryParams.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        
        guard let url = components.url else {
            return jsonResponse(["error": "Invalid URL"], statusCode: 500)
        }
        
        let semaphore = DispatchSemaphore(value: 0)
        let proxyRes = ProxyResponse()
        
        let task = URLSession.shared.dataTask(with: url) { data, res, err in
            proxyRes.data = data
            if let httpRes = res as? HTTPURLResponse {
                proxyRes.statusCode = httpRes.statusCode
            }
            semaphore.signal()
        }
        task.resume()
        
        _ = semaphore.wait(timeout: .now() + 30.0)
        
        guard let data = proxyRes.data else {
            return jsonResponse(["error": "Worker timeout or error"], statusCode: 500)
        }
        
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        if proxyRes.statusCode == 200 {
            var finalOutput = output
            var ttl: TimeInterval? = nil
            
            // Parse JSON to check for __taichi_ttl
            if let data = output.data(using: .utf8),
               var json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                
                if let ttlValue = json["__taichi_ttl"] as? Double {
                    ttl = ttlValue
                    json.removeValue(forKey: "__taichi_ttl")
                } else if let ttlValue = json["__taichi_ttl"] as? Int {
                    ttl = TimeInterval(ttlValue)
                    json.removeValue(forKey: "__taichi_ttl")
                }
                
                if ttl != nil {
                    // Re-serialize the JSON without the TTL key
                    if #available(macOS 10.15, *) {
                        if let newData = try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes]),
                           let newOutput = String(data: newData, encoding: .utf8) {
                            finalOutput = newOutput
                        }
                    } else {
                        if let newData = try? JSONSerialization.data(withJSONObject: json, options: []),
                           let newOutput = String(data: newData, encoding: .utf8) {
                            finalOutput = newOutput
                        }
                    }
                }
            }
            
            if let ttl = ttl, ttl > 0 {
                let expireAt = Date().addingTimeInterval(ttl)
                scriptCacheQueue.sync {
                    scriptCache[cacheKey] = (response: finalOutput, expireAt: expireAt)
                    if scriptCache.count > maxCacheItems, let firstKey = scriptCache.keys.first {
                        scriptCache.removeValue(forKey: firstKey)
                    }
                }
            } else if ttl == 0 {
                scriptCacheQueue.sync {
                    _ = scriptCache.removeValue(forKey: cacheKey)
                }
            }
            
            if finalOutput.hasPrefix("{") || finalOutput.hasPrefix("[") {
                return jsonResponse(finalOutput)
            }
            return jsonResponse(["success": true, "output": finalOutput])
        } else {
            return jsonResponse(["error": "Script execution failed", "output": output], statusCode: proxyRes.statusCode)
        }
    }
    
    // MARK: - Helper Methods
    
    private func findAvailablePort(startPort: Int = 9222) -> Int {
        var port = startPort
        while port < 9300 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd == -1 {
                return port
            }
            var addr = sockaddr_in()
            let addrLen = socklen_t(MemoryLayout<sockaddr_in>.stride)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = in_port_t(port).bigEndian
            
            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, addrLen)
                }
            }
            close(fd)
            if bindResult == 0 {
                return port
            }
            port += 1
        }
        return startPort
    }
    
    // MARK: - Launcher API (Alfred)
    
    private func handleLauncherFilter(_ request: HttpRequest) -> HttpResponse {
        let scriptsDir = DispatchQueue.main.sync { TaiChiSettings.shared.scriptsPath as NSString }.expandingTildeInPath
        let appsDir = (scriptsDir as NSString).appendingPathComponent("apps")
        
        var items: [[String: Any]] = []
        let fm = FileManager.default
        let query = request.queryParams.first(where: { $0.0 == "q" })?.1.lowercased() ?? ""
        
        let activeInjectedAppIDs = DispatchQueue.main.sync { 
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
        if !query.isEmpty {
            let appDirs = ["/Applications", "/System/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
            for dir in appDirs {
                let dirURL = URL(fileURLWithPath: dir)
                if let enumerator = fm.enumerator(at: dirURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let url as URL in enumerator {
                        if url.pathExtension == "app" {
                            let appName = url.deletingPathExtension().lastPathComponent.lowercased()
                            if appName.contains(query) {
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
                
                if !query.isEmpty && !appName.lowercased().contains(query) && !appId.lowercased().contains(query) {
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
                    if let app = runningApps.first(where: { $0.bundleIdentifier == appId }),
                       let port = self.getDebuggingPort(for: app.processIdentifier) {
                        subtitle += " (Port: \(port))"
                    }
                    
                    mods = [
                        "cmd": [
                            "valid": true,
                            "arg": "{\"action\":\"quit\", \"appId\":\"\(appId)\"}",
                            "subtitle": "🛑 退出该应用 (Cmd + Enter)"
                        ]
                    ]
                } else if isRunning {
                    subtitle = "⚡︎ 正在普通运行，回车将强制重启并注入"
                }
                
                var item: [String: Any] = [
                    "title": itemTitle,
                    "subtitle": subtitle,
                    "arg": "open:\(appId)",
                    "icon": ["type": "fileicon", "path": appURL.path]
                ]
                
                if let mods = mods {
                    item["mods"] = mods
                }
                
                items.append(item)
            }
        }
        
        return jsonResponse(["items": items])
    }
    
    private func handleLauncherAction(_ request: HttpRequest) -> HttpResponse {
        guard let payload = request.queryParams.first(where: { $0.0 == "payload" })?.1 else {
            return .badRequest(nil)
        }
        
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let action = json["action"],
              let appId = json["appId"] else {
            // Fallback for simple "open:appId" payloads
            let parts = payload.split(separator: ":", maxSplits: 1)
            let action = parts.count == 2 ? String(parts[0]) : "open"
            let finalAppId = parts.count == 2 ? String(parts[1]) : String(payload)
            return performLauncherAction(action: action, appId: finalAppId)
        }
        
        return performLauncherAction(action: action, appId: appId)
    }
    
    private func performLauncherAction(action: String, appId: String) -> HttpResponse {
        let finalAppId = appId
        let runningApps = NSWorkspace.shared.runningApplications
        
        if action == "quit" {
            if let appToQuit = runningApps.first(where: { $0.bundleIdentifier == finalAppId }) {
                appToQuit.terminate()
            }
            DispatchQueue.main.async { [finalAppId] in
                TaiChiSettings.shared.activeInjectedApps.removeAll(where: { $0.id == finalAppId })
            }
            return jsonResponse(["success": true, "action": "quit", "appId": finalAppId])
        }
        
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finalAppId) else {
            return jsonResponse(["error": "Application not found for bundle ID \(finalAppId)"], statusCode: 404)
        }
        
        let activeInjectedAppIDs = DispatchQueue.main.sync {
            TaiChiSettings.shared.activeInjectedApps.map { $0.id }
        }
        
        let isRunning = runningApps.contains(where: { $0.bundleIdentifier == finalAppId })
        let isInjected = activeInjectedAppIDs.contains(finalAppId)
        
        if isInjected {
            // Case A: Already injected. Just bring to front.
            if let app = runningApps.first(where: { $0.bundleIdentifier == finalAppId }) {
                app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            } else {
                // Not actually running? Clean up state.
                DispatchQueue.main.async { [finalAppId] in
                    TaiChiSettings.shared.activeInjectedApps.removeAll(where: { $0.id == finalAppId })
                }
            }
            return jsonResponse(["success": true, "action": "activate", "appId": finalAppId])
        }
        
        // Helper to launch with CDP
        let launchWithCDP: @Sendable () -> Void = { [weak self, finalAppId, appURL] in
            guard let self = self else { return }
            let targetPort = self.findAvailablePort(startPort: 9222)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--remote-debugging-port=\(targetPort)"]
            configuration.activates = true
            
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] (app: NSRunningApplication?, error: Error?) in
                if let error = error {
                    print("❌ Failed to open \(finalAppId): \(error.localizedDescription)")
                    return
                }
                
                guard let self = self, let workerPort = self.workerPort else { return }
                let appName = app?.localizedName ?? appURL.deletingPathExtension().lastPathComponent
                
                DispatchQueue.main.async { [finalAppId, appName] in
                    let monitoredApp = MonitoredApp(id: finalAppId, name: appName, path: appURL.path)
                    if !TaiChiSettings.shared.activeInjectedApps.contains(where: { $0.id == finalAppId }) {
                        TaiChiSettings.shared.activeInjectedApps.append(monitoredApp)
                    }
                }
                
                // Wait slightly to ensure app starts and CDP is up
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [finalAppId] in
                    print("🚀 \(finalAppId) launched on CDP port \(targetPort). Invoking worker...")
                    var components = URLComponents()
                    components.scheme = "http"
                    components.host = "127.0.0.1"
                    components.port = workerPort
                    components.path = "/script/apps/\(finalAppId)/worker/index"
                    components.queryItems = [URLQueryItem(name: "port", value: String(targetPort))]
                    
                    if let url = components.url {
                        let task = URLSession.shared.dataTask(with: url) { data, response, error in
                            if let error = error {
                                print("⚠️ Worker trigger failed for \(finalAppId): \(error.localizedDescription)")
                            } else if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                                print("✅ Worker trigger succeeded for \(finalAppId)")
                            } else {
                                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                                print("⚠️ Worker trigger returned status \(statusCode)")
                            }
                        }
                        task.resume()
                    }
                }
            }
        }
        
        if isRunning {
            // Case C: Running but not injected. Force quit and relaunch.
            if let appToQuit = runningApps.first(where: { $0.bundleIdentifier == finalAppId }) {
                appToQuit.terminate()
                
                // Poll until the app is actually dead, then launch
                DispatchQueue.global().async { [launchWithCDP] in
                    var attempts = 0
                    while !appToQuit.isTerminated && attempts < 20 {
                        Thread.sleep(forTimeInterval: 0.25)
                        attempts += 1
                    }
                    if !appToQuit.isTerminated {
                        appToQuit.forceTerminate()
                        Thread.sleep(forTimeInterval: 0.5)
                    }
                    launchWithCDP()
                }
            }
            return jsonResponse(["success": true, "action": "relaunch_inject", "appId": finalAppId])
        } else {
            // Case B: Not running.
            launchWithCDP()
            return jsonResponse(["success": true, "action": "launch_inject", "appId": finalAppId])
        }
    }
    
    private func getDebuggingPort(for pid: pid_t) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-ww", "-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            if let range = output.range(of: "--remote-debugging-port=(\\d+)", options: .regularExpression) {
                let match = String(output[range])
                if let port = match.split(separator: "=").last {
                    return String(port)
                }
            }
        }
        return nil
    }
} 
