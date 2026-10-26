import Foundation
import AppKit
import Swifter

class ProxyResponse: @unchecked Sendable {
    var data: Data?
    var statusCode: Int = 500
}

private class SyncBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
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
    public internal(set) var workerPort: Int?
    private var wakeObserver: NSObjectProtocol?
    private var cyberMediaHandlers: [String: [String: String]] = [:]

    
    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: "cyberMediaHandlers") as? [String: [String: String]] {
            self.cyberMediaHandlers = saved
        }
        setupRoutes()
    }
    
    @MainActor
    func start() {
        guard !isRunning else { return }
        
        let port = in_port_t(TaiChiSettings.shared.httpPort)
        do {
            try server.start(port, forceIPv4: true)
            isRunning = true
            print("🚀 TaiChi Gateway started on port \(port)")
            
            HSManager.shared.initialize(taichiPort: Int(port))
            
            startWorker()
            
            cleanupTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
                self?.cleanupCaches()
            }
            
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
                DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 3.0) {
                    self?.reinjectActiveApps()
                }
            }
            
            // Auto-discover and re-inject apps on startup
            DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.refreshCyberAppsStatus()
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
            
            if let obs = wakeObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(obs)
                wakeObserver = nil
            }
            
            stopWorker()
            
            scriptCacheQueue.sync { scriptCache.removeAll() }
            // 故意保留 stateCache 不清空，以便长线持久化状态不受网关重启影响
            
            print("🛑 TaiChi Gateway stopped")
        }
    }
    
    @MainActor
    func restart() {
        print("🔄 Restarting TaiChi Gateway...")
        stop()
        
        // Small delay to ensure port is freed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.start()
            print("✅ TaiChi Gateway restarted and cache cleared")
        }
    }
    
    // =========================================================================================
    // [BUG FIX: Node Worker Orphan Process Leaks & Auto-Termination via Pipe Closure]
    // 1. Problem:
    //    When TaiChi terminates abruptly, restarts the gateway, or crashes, previously spawned
    //    Node `.taichi_worker.js` processes could be orphaned and continue running indefinitely,
    //    wasting CPU, memory, and leaking network ports.
    // 2. Resolution:
    //    - Added `process.stdin.resume(); process.stdin.on('end', () => process.exit(0));` to the
    //      generated `.taichi_worker.js` and attached a standardInput Pipe in Swift. When the parent
    //      terminates or crashes, the OS closes the pipe, sending EOF to stdin so Node auto-exits.
    //    - In `startWorker()`, explicitly terminate any active `workerProcess` instance and execute
    //      `/usr/bin/pkill -f ".taichi_worker.js"` to terminate any preexisting orphan worker instances
    //      prior to spawning the new one.
    // 3. Caveats:
    //    - The `pkill` command returns status 1 if no process matched; this should not be treated as a failure.
    // =========================================================================================
    @MainActor
    private func startWorker() {
        let scriptsDir = (TaiChiSettings.shared.scriptsPath as NSString).expandingTildeInPath
        let workerScriptPath = (scriptsDir as NSString).appendingPathComponent(".taichi_worker.js")
        
        // Terminate any existing worker held by this manager
        if let existing = self.workerProcess, existing.isRunning {
            existing.terminate()
            self.workerProcess = nil
        }
        
        // Terminate any leftover orphaned worker processes
        let cleanup = Foundation.Process()
        cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        cleanup.arguments = ["-f", ".taichi_worker.js"]
        try? cleanup.run()
        cleanup.waitUntilExit()
        
        let workerCode = """
        const http = require('http');
        const url = require('url');
        const fs = require('fs');
        const path = require('path');
        const SCRIPTS_DIR = process.argv[2] || __dirname;

        // Auto-terminate when parent process dies or pipe closes
        process.stdin.resume();
        process.stdin.on('end', () => process.exit(0));

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
        process.arguments = ["-l", "-c", "exec node \"\(workerScriptPath)\" \"\(scriptsDir)\""]
        
        let inPipe = Pipe()
        process.standardInput = inPipe
        
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
        
        process.terminationHandler = { [weak self] process in
            print("⚠️ Node Worker terminated unexpectedly with status \(process.terminationStatus)")
            DispatchQueue.main.async {
                // Check if this is still the active process before restarting
                if self?.workerProcess == process {
                    self?.workerPort = nil
                    print("🔄 Auto-restarting Node Worker...")
                    self?.startWorker()
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
    
    func reinjectApp(appId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let runningApps = NSWorkspace.shared.runningApplications
            guard let workerPort = self.workerPort else { return }
            
            DispatchQueue.global(qos: .background).async {
                if let app = runningApps.first(where: { $0.bundleIdentifier == appId }),
                   let portStr = self.getDebuggingPort(for: app.processIdentifier),
                   let targetPort = Int(portStr) {
                    
                    print("🔄 Manual re-invoking worker for \(appId) on port \(targetPort)...")
                    var components = URLComponents()
                    components.scheme = "http"
                    components.host = "127.0.0.1"
                    components.port = workerPort
                    components.path = "/script/apps/\(appId)/worker/index"
                    components.queryItems = [URLQueryItem(name: "port", value: String(targetPort))]
                    
                    if let url = components.url {
                        let task = URLSession.shared.dataTask(with: url) { data, response, error in
                            if let error = error {
                                print("⚠️ Manual reinject failed for \(appId): \(error.localizedDescription)")
                            } else if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                                print("✅ Manual reinject succeeded for \(appId)")
                            }
                        }
                        task.resume()
                    }
                }
            }
        }
    }

    private func reinjectActiveApps() {
        print("⏰ System woke up from sleep. Re-injecting Cyber mode hooks...")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let activeApps = TaiChiSettings.shared.activeInjectedApps
            let runningApps = NSWorkspace.shared.runningApplications
            guard let workerPort = self.workerPort else { return }
            
            DispatchQueue.global(qos: .background).async {
                for monitoredApp in activeApps {
                    let finalAppId = monitoredApp.id
                    if let app = runningApps.first(where: { $0.bundleIdentifier == finalAppId }),
                       let portStr = self.getDebuggingPort(for: app.processIdentifier),
                       let targetPort = Int(portStr) {
                        
                        print("🔄 Re-invoking worker for \(finalAppId) on port \(targetPort)...")
                        var components = URLComponents()
                        components.scheme = "http"
                        components.host = "127.0.0.1"
                        components.port = workerPort
                        components.path = "/script/apps/\(finalAppId)/worker/index"
                        components.queryItems = [URLQueryItem(name: "port", value: String(targetPort))]
                        
                        if let url = components.url {
                            let task = URLSession.shared.dataTask(with: url) { data, response, error in
                                if let error = error {
                                    print("⚠️ Wake reinject failed for \(finalAppId): \(error.localizedDescription)")
                                } else if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                                    print("✅ Wake reinject succeeded for \(finalAppId)")
                                }
                            }
                            task.resume()
                        }
                    }
                }
            }
        }
    }
    
    func refreshCyberAppsStatus() {
        print("🔍 Refreshing Cyber apps status...")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let settings = TaiChiSettings.shared
            var updatedApps = [MonitoredApp]()
            
            for app in settings.activeInjectedApps {
                if let pid = app.pid, kill(pid, 0) == 0 {
                    updatedApps.append(app)
                    
                    if let workerPort = self.workerPort, let targetPort = app.port {
                        print("🔄 Re-invoking worker for \(app.id) on port \(targetPort)...")
                        
                        let hotkey = settings.hotkeyTelescope
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
                                "app": app.name,
                                "profileId": "taichi_inspector",
                                "bindings": bindings
                            ]
                            try? await HSManager.shared.sendAction(action: "hotkey.register", params: params)
                        }
                        
                        DispatchQueue.global(qos: .background).async {
                            var components = URLComponents()
                            components.scheme = "http"
                            components.host = "127.0.0.1"
                            components.port = workerPort
                            components.path = "/script/apps/\(app.id)/worker/index"
                            components.queryItems = [URLQueryItem(name: "port", value: String(targetPort))]
                            
                            if let url = components.url {
                                let task = URLSession.shared.dataTask(with: url) { _, response, error in
                                    if let error = error {
                                        print("⚠️ Refresh reinject failed for \(app.id): \(error.localizedDescription)")
                                    } else if let httpRes = response as? HTTPURLResponse, httpRes.statusCode == 200 {
                                        print("✅ Refresh reinject succeeded for \(app.id)")
                                    }
                                }
                                task.resume()
                            }
                        }
                    }
                } else {
                    print("🧹 Removing dead Cyber app: \(app.name)")
                }
            }
            
            settings.activeInjectedApps = updatedApps
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
        
        // HS Events API
        server["/api/event"] = { [weak self] request in
            guard let self = self else { return .internalServerError }
            
            // Verify Token
            if let authHeader = request.headers["authorization"],
               authHeader == "Bearer \(HSManager.shared.securityToken)" {
                // Token is valid
                return self.handleHSEventRequest(request)
            } else {
                return .unauthorized
            }
        }
        
        // 2. Scripting API is now handled in middleware to support deep subpaths

        
        // 3. Launcher API (Alfred integration)
        server["/api/launcher/filter"] = { [weak self] request in
            return self?.handleLauncherFilter(request) ?? .internalServerError
        }
        
        server["/api/launcher/action"] = { [weak self] request in
            return self?.handleLauncherAction(request) ?? .internalServerError
        }
        
        // 4. Inspector API
        server["/api/inspector/activate"] = { [weak self] request in
            return self?.handleInspectorActivate(request) ?? .internalServerError
        }
        
        // 4.5 Cyber Evaluate API
        
        // 4.5 Cyber Media Handlers Registry
        server["/api/cyber/media_handlers"] = { [weak self] request in
            return self?.handleCyberMediaHandlers(request) ?? .internalServerError
        }

        server["/api/cyber/evaluate"] = { [weak self] request in
            return self?.handleCyberEvaluate(request) ?? .internalServerError
        }
        
        // 5. External Lyrics Push API
        server["/api/lyrics/push"] = { [weak self] request in
            return self?.handleLyricsPush(request) ?? .internalServerError
        }
        
        server["/api/media/like_status"] = { [weak self] request in
            return self?.handleMediaLikeStatus(request) ?? .internalServerError
        }
        
        // 5. List Config Injection API
        server["/api/config/list/:listName"] = { [weak self] request in
            return self?.handleListConfigRequest(request) ?? .internalServerError
        }
        
        // 6. Wallpaper API
        server["/api/wallpaper/change"] = { [weak self] request in
            return self?.handleWallpaperChange(request) ?? .internalServerError
        }
        server["/api/wallpaper/previous"] = { [weak self] request in
            return self?.handleWallpaperPrevious(request) ?? .internalServerError
        }
        server["/api/wallpaper/save"] = { [weak self] request in
            return self?.handleWallpaperSave(request) ?? .internalServerError
        }
    }
    
    // MARK: - List Config API
    
    private func handleListConfigRequest(_ request: HttpRequest) -> HttpResponse {
        guard request.method == "POST" else { 
            return jsonResponse(["error": "Method Not Allowed"], statusCode: 405) 
        }
        let listName = request.params[":listName"] ?? ""
        
        let validLists = ["floatingApps", "residentApps", "monitoredApps", "commonPaths"]
        guard validLists.contains(listName) else {
            return jsonResponse(["error": "Invalid list name"], statusCode: 400)
        }
        
        let data = Data(request.body)
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let action = json["action"] as? String,
              let payload = json["payload"] else {
            return jsonResponse(["error": "Invalid JSON format or missing fields"], statusCode: 400)
        }
        
        // Helper to extract paths from payload
        var targetPaths: [String] = []
        if let pathsStr = payload as? [String] {
            targetPaths = pathsStr
        } else if let pathStr = payload as? String {
            targetPaths = [pathStr]
        } else if let obj = payload as? [String: Any], let path = obj["path"] as? String {
            targetPaths = [path]
        } else if let arr = payload as? [[String: Any]] {
            targetPaths = arr.compactMap { $0["path"] as? String }
        }
        
        guard !targetPaths.isEmpty else {
            return jsonResponse(["error": "No valid paths provided in payload"], statusCode: 400)
        }
        
        // Dispatch to MainActor to safely update TaiChiSettings
        Task {
            await updateListConfig(listName: listName, action: action, paths: targetPaths)
        }
        
        return jsonResponse(["status": "ok", "message": "List \(listName) updated with action \(action)"])
    }
    
    @MainActor
    private func updateListConfig(listName: String, action: String, paths: [String]) {
        let settings = TaiChiSettings.shared
        
        // Helper to build App item
        func buildAppItem(path: String) -> (name: String, id: String)? {
            let bundle = Bundle(path: path)
            let name = bundle?.infoDictionary?["CFBundleName"] as? String ?? bundle?.infoDictionary?["CFBundleDisplayName"] as? String ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            let id = bundle?.bundleIdentifier ?? name
            return (name, id)
        }
        
        func buildPathItem(path: String) -> (name: String, id: String)? {
            let name = (path as NSString).lastPathComponent
            return (name, path) // CommonPath doesn't really have a bundle ID, path is unique enough
        }
        
        switch listName {
        case "floatingApps":
            var current = settings.floatingApps
            if action == "replace" { current.removeAll() }
            for path in paths {
                if action == "delete" {
                    current.removeAll { $0.path == path }
                } else if action == "inject" || action == "replace" {
                    if !current.contains(where: { $0.path == path }), let item = buildAppItem(path: path) {
                        current.append(FloatingApp(id: item.id, name: item.name, path: path))
                    }
                }
            }
            settings.floatingApps = current
            
        case "residentApps":
            var current = settings.residentApps
            if action == "replace" { current.removeAll() }
            for path in paths {
                if action == "delete" {
                    current.removeAll { $0.path == path }
                } else if action == "inject" || action == "replace" {
                    if !current.contains(where: { $0.path == path }), let item = buildAppItem(path: path) {
                        current.append(ResidentApp(id: item.id, name: item.name, path: path))
                    }
                }
            }
            settings.residentApps = current
            
        case "monitoredApps":
            var current = settings.monitoredApps
            if action == "replace" { current.removeAll() }
            for path in paths {
                if action == "delete" {
                    current.removeAll { $0.path == path }
                } else if action == "inject" || action == "replace" {
                    if !current.contains(where: { $0.path == path }), let item = buildAppItem(path: path) {
                        current.append(MonitoredApp(id: item.id, name: item.name, path: path))
                    }
                }
            }
            settings.monitoredApps = current
            
        case "commonPaths":
            var current = settings.commonPaths
            if action == "replace" { current.removeAll() }
            for path in paths {
                if action == "delete" {
                    current.removeAll { $0.path == path }
                } else if action == "inject" || action == "replace" {
                    if !current.contains(where: { $0.path == path }), let item = buildPathItem(path: path) {
                        current.append(CommonPath(id: UUID(), name: item.name, path: path))
                    }
                }
            }
            settings.commonPaths = current
            
        default:
            break
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
    
    private func handleMediaLikeStatus(_ request: HttpRequest) -> HttpResponse {
        guard request.method == "POST" else { return jsonResponse(["error": "Method Not Allowed"], statusCode: 405) }
        let body = Data(request.body)
        guard let json = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any] else {
            return jsonResponse(["error": "Invalid JSON payload"], statusCode: 400)
        }
        
        let isLiked = json["isLiked"] as? Bool
        
        DispatchQueue.main.async {
            MediaObserver.shared.state.isLiked = isLiked
        }
        
        return jsonResponse(["success": true, "isLiked": isLiked as Any])
    }
    
    private func handleLyricsPush(_ request: HttpRequest) -> HttpResponse {
        let body = Data(request.body)
        guard let json = try? JSONSerialization.jsonObject(with: body, options: []) as? [String: Any],
              let title = json["title"] as? String,
              let artist = json["artist"] as? String else {
            return jsonResponse(["error": "Missing title or artist in JSON payload"], statusCode: 400)
        }
        
        if let failed = json["failed"] as? Bool, failed {
            DispatchQueue.main.async {
                LyricManager.shared.fetchLyrics(title: title, artist: artist, isFallback: true)
            }
            return jsonResponse(["status": "fallback_triggered"])
        }
        
        guard let lrc = json["lrc"] as? String else {
            return jsonResponse(["error": "Missing lrc in JSON payload"], statusCode: 400)
        }
        
        DispatchQueue.main.async {
            LyricManager.shared.pushLyrics(title: title, artist: artist, lrc: lrc)
        }
        
        return jsonResponse(["status": "success"])
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
    
    func findAvailablePort(startPort: Int = 9222) -> Int {
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
    
    // MARK: - Launcher API (Unified Gateway)
    
    private func handleLauncherFilter(_ request: HttpRequest) -> HttpResponse {
        var query = request.queryParams.first(where: { $0.0 == "q" })?.1 ?? ""
        var scope = request.queryParams.first(where: { $0.0 == "scope" })?.1
        
        if let decoded = query.removingPercentEncoding {
            query = decoded
        }
        query = query.replacingOccurrences(of: "+", with: " ")
        if let s = scope, let decoded = s.removingPercentEncoding {
            scope = decoded
        }
        
        if query.isEmpty && (scope == nil || scope?.isEmpty == true) {
            if let bodyStr = String(bytes: request.body, encoding: .utf8), !bodyStr.isEmpty,
               let data = bodyStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let q = json["q"] as? String { query = q }
                if let s = json["scope"] as? String { scope = s }
            }
        }
        
        let box = SyncBox<[[String: Any]]>([])
        let semaphore = DispatchSemaphore(value: 0)
        
        Task {
            let res = await LauncherGateway.shared.filter(rawQuery: query, explicitScope: scope)
            box.value = res
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 10.0)
        return jsonResponse(["items": box.value])
    }
    
    private func handleLauncherAction(_ request: HttpRequest) -> HttpResponse {
        var payload = request.queryParams.first(where: { $0.0 == "payload" })?.1
        if let p = payload, let decoded = p.removingPercentEncoding {
            payload = decoded
        }
        
        if payload == nil || payload?.isEmpty == true {
            if let bodyStr = String(bytes: request.body, encoding: .utf8), !bodyStr.isEmpty {
                if let data = bodyStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let p = json["payload"] as? String {
                    payload = p
                } else {
                    payload = bodyStr
                }
            }
        }
        
        guard let finalPayload = payload, !finalPayload.isEmpty else {
            return .badRequest(nil)
        }
        
        let box = SyncBox<Bool>(false)
        let semaphore = DispatchSemaphore(value: 0)
        
        Task {
            let res = await LauncherGateway.shared.handleAction(payload: finalPayload)
            box.value = res
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 10.0)
        return jsonResponse(["success": box.value])
    }
    
    func getDebuggingPort(for pid: pid_t) -> String? {
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
    
    private func handleHSEventRequest(_ request: HttpRequest) -> HttpResponse {
        let bodyBytes = request.body
        let data = Data(bodyBytes)
        
        do {
            if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let event = json["event"] as? String {
                let dataDict = json["data"] as? [String: Any]
                let appName = dataDict?["appName"] as? String ?? json["appName"] as? String
                let screenUUID = dataDict?["screenUUID"] as? String ?? json["screenUUID"] as? String
                let path = dataDict?["path"] as? String ?? json["path"] as? String
                let id = dataDict?["id"] as? String ?? json["id"] as? String
                
                var safePayload: [[String: String]]? = nil
                if event == "screensChanged", let screens = dataDict?["screens"] as? [[String: Any]] {
                    safePayload = screens.compactMap { screenDict in
                        var dict = [String: String]()
                        if let uuid = screenDict["uuid"] as? String { dict["uuid"] = uuid }
                        if let name = screenDict["name"] as? String { dict["name"] = name }
                        if let idNum = screenDict["id"] as? Int { dict["id"] = "\(idNum)" }
                        return dict
                    }
                }
                
                // 将所有事件派发给 BrainManager 处理
                Task {
                    await BrainManager.shared.handleEvent(eventName: event, appName: appName, screenUUID: screenUUID, path: path, id: id, payload: safePayload)
                }
                
                return jsonResponse(["status": "ok", "received": event])
            }
            return jsonResponse(["status": "error", "message": "Invalid JSON or missing 'event'"], statusCode: 400)
        } catch {
            return jsonResponse(["status": "error", "message": "Failed to parse JSON: \(error.localizedDescription)"], statusCode: 400)
        }
    }

    // =============================================================================
    // [BUG FIX DOCUMENTATION - Task fix_wallpaper_target_screen_mapping_003]
    // 1. Problem Fixed:
    //    Wallpaper endpoints (/api/wallpaper/change, /api/wallpaper/previous, /api/wallpaper/save)
    //    only parsed `screenUUID` from the request JSON, dropping `screenName`. When an
    //    external screen was referenced by name or had a transient UUID, WallpaperManager
    //    could not resolve the target screen.
    // 2. Resolution:
    //    Parse both `screenUUID` and `screenName` from the JSON body in handleWallpaperChange,
    //    handleWallpaperPrevious, and handleWallpaperSave, and pass both parameters to
    //    WallpaperManager.shared methods.
    // 3. Caveats:
    //    WallpaperManager methods handle dual fallback and verify target screens before
    //    triggering wallpaper updates.
    // =============================================================================
    private func handleWallpaperChange(_ request: HttpRequest) -> HttpResponse {
        guard request.method == "POST" else { return jsonResponse(["error": "Method Not Allowed"], statusCode: 405) }
        let bodyBytes = request.body
        let bodyData = Data(bodyBytes)
        var screenUUID: String? = nil
        var screenName: String? = nil
        if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            screenUUID = json["screenUUID"] as? String
            screenName = json["screenName"] as? String
        }
        
        Task {
            await WallpaperManager.shared.forceChange(screenUUID: screenUUID, screenName: screenName)
        }
        return jsonResponse(["status": "ok", "action": "change_started"])
    }
    
    private func handleWallpaperPrevious(_ request: HttpRequest) -> HttpResponse {
        guard request.method == "POST" else { return jsonResponse(["error": "Method Not Allowed"], statusCode: 405) }
        let bodyData = Data(request.body)
        var screenUUID: String? = nil
        var screenName: String? = nil
        if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            screenUUID = json["screenUUID"] as? String
            screenName = json["screenName"] as? String
        }
        
        Task {
            await WallpaperManager.shared.revertToPrevious(screenUUID: screenUUID, screenName: screenName)
        }
        return jsonResponse(["status": "ok", "action": "previous_started"])
    }
    
    private func handleWallpaperSave(_ request: HttpRequest) -> HttpResponse {
        guard request.method == "POST" else { return jsonResponse(["error": "Method Not Allowed"], statusCode: 405) }
        let bodyData = Data(request.body)
        var screenUUID: String? = nil
        var screenName: String? = nil
        if let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
            screenUUID = json["screenUUID"] as? String
            screenName = json["screenName"] as? String
        }
        
        Task {
            await WallpaperManager.shared.saveCurrent(screenUUID: screenUUID, screenName: screenName)
        }
        return jsonResponse(["status": "ok", "action": "save_started"])
    }
    
    // MARK: - Inspector Action
    
    private func handleInspectorActivate(_ request: HttpRequest) -> HttpResponse {
        guard let appId = request.queryParams.first(where: { $0.0 == "appId" })?.1 else {
            return jsonResponse(["error": "Missing appId parameter"], statusCode: 400)
        }
        
        let activeInjectedAppIDs = DispatchQueue.main.sync {
            TaiChiSettings.shared.activeInjectedApps.map { $0.id }
        }
        
        guard activeInjectedAppIDs.contains(appId) else {
            return jsonResponse(["error": "App is not injected"], statusCode: 400)
        }
        
        // Find debugging port
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: { $0.bundleIdentifier == appId }),
              let portStr = getDebuggingPort(for: app.processIdentifier),
              let port = Int(portStr) else {
            return jsonResponse(["error": "Cannot find debugging port"], statusCode: 500)
        }
        
        // 1. Fetch webSocketDebuggerUrl
        guard let url = URL(string: "http://127.0.0.1:\(port)/json") else { return .internalServerError }
        let semaphore = DispatchSemaphore(value: 0)
        var wsUrlStr: String? = nil
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }
            guard let data = data,
                  let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let firstTarget = jsonArray.first(where: { ($0["type"] as? String) == "page" }),
                  let wsUrl = firstTarget["webSocketDebuggerUrl"] as? String else {
                return
            }
            wsUrlStr = wsUrl
        }.resume()
        
        _ = semaphore.wait(timeout: .now() + 5.0)
        
        guard let wsUrlString = wsUrlStr, let wsUrl = URL(string: wsUrlString) else {
            return jsonResponse(["error": "Cannot get WebSocket URL"], statusCode: 500)
        }
        
        Task {
            try? await HSManager.shared.sendAction(action: "alert", params: ["text": "🕵️‍♀️ [寻星镜] 已激活", "duration": 2])
        }
        
        // 2. Connect WebSocket and send JS
        let jsScript = """
        (async function() {
            console.log("%c[TaiChi 寻星镜] 🕵️‍♀️ 已激活！滚轮/方向键切换DOM层级，双击确认。(若方向键无效请先单击页面获取焦点)", "color: #3186FF; font-size: 14px; font-weight: bold;");
            return new Promise((resolve) => {
                const overlay = document.createElement('div');
                overlay.style.position = 'fixed';
                overlay.style.pointerEvents = 'none';
                overlay.style.zIndex = '9999999';
                overlay.style.border = '2px dashed #3186FF';
                overlay.style.backgroundColor = 'rgba(49, 134, 255, 0.1)';
                document.body.appendChild(overlay);

                const label = document.createElement('div');
                label.style.position = 'absolute';
                label.style.bottom = '100%';
                label.style.left = '-2px';
                label.style.backgroundColor = '#3186FF';
                label.style.color = '#fff';
                label.style.padding = '2px 6px';
                label.style.fontSize = '12px';
                label.style.fontFamily = 'monospace';
                label.style.borderRadius = '4px 4px 0 0';
                label.style.whiteSpace = 'nowrap';
                overlay.appendChild(label);

                let currentPath = [];
                let depthIndex = 0;

                const updateOverlay = () => {
                    const target = currentPath[depthIndex];
                    if (target && target.getBoundingClientRect) {
                        const rect = target.getBoundingClientRect();
                        overlay.style.top = `${rect.top}px`;
                        overlay.style.left = `${rect.left}px`;
                        overlay.style.width = `${rect.width}px`;
                        overlay.style.height = `${rect.height}px`;
                        
                        let classStr = (target.className && typeof target.className === 'string') ? '.' + target.className.split(' ').filter(c=>c).join('.') : '';
                        label.textContent = `${target.tagName.toLowerCase()}${target.id ? '#' + target.id : ''}${classStr}`;
                    }
                };

                let currentTargetNode = null;
                const moveHandler = (e) => {
                    const deepest = e.composedPath()[0];
                    if (deepest === currentTargetNode) return;
                    currentTargetNode = deepest;
                    currentPath = e.composedPath().filter(node => node.nodeType === 1); // Only Element nodes
                    depthIndex = 0;
                    updateOverlay();
                };

                let accumulatedDelta = 0;
                const wheelHandler = (e) => {
                    if (currentPath.length === 0) return;
                    e.preventDefault();
                    e.stopPropagation();
                    
                    accumulatedDelta += e.deltaY;
                    if (Math.abs(accumulatedDelta) > 30) {
                        if (accumulatedDelta < 0) {
                            // Scroll UP (or Natural Scroll down): go UP the DOM tree
                            depthIndex = Math.min(depthIndex + 1, currentPath.length - 1);
                        } else {
                            // Scroll DOWN (or Natural Scroll up): go DOWN the DOM tree
                            depthIndex = Math.max(depthIndex - 1, 0);
                        }
                        accumulatedDelta = 0;
                        updateOverlay();
                    }
                };
                
                const keydownHandler = (e) => {
                    if (e.key === 'Escape') {
                        e.preventDefault();
                        e.stopPropagation();
                        cleanup();
                        resolve('__CANCELED__');
                    } else if (e.key === 'Enter') {
                        e.preventDefault();
                        e.stopPropagation();
                        const target = currentPath[depthIndex] || document.activeElement;
                        const html = target ? target.outerHTML : '';
                        cleanup();
                        resolve(html);
                    } else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
                        e.preventDefault();
                        e.stopPropagation();
                        if (currentPath.length === 0) {
                            let cur = document.activeElement || document.body;
                            let path = [];
                            while(cur && cur.nodeType === 1) { path.push(cur); cur = cur.parentElement; }
                            currentPath = path;
                            depthIndex = 0;
                        }
                        if (currentPath.length > 0) {
                            if (e.key === 'ArrowUp') {
                                depthIndex = Math.min(depthIndex + 1, currentPath.length - 1);
                            } else {
                                depthIndex = Math.max(depthIndex - 1, 0);
                            }
                            updateOverlay();
                        }
                    }
                };

                const cleanup = () => {
                    document.removeEventListener('mousemove', moveHandler);
                    document.removeEventListener('wheel', wheelHandler, { capture: true });
                    document.removeEventListener('dblclick', dblClickHandler, true);
                    document.removeEventListener('keydown', keydownHandler, true);
                    overlay.remove();
                };

                const dblClickHandler = (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    const target = currentPath[depthIndex] || e.composedPath()[0];
                    const html = target ? target.outerHTML : '';
                    cleanup();
                    resolve(html);
                };

                document.addEventListener('mousemove', moveHandler);
                document.addEventListener('wheel', wheelHandler, { capture: true, passive: false });
                document.addEventListener('dblclick', dblClickHandler, true);
                document.addEventListener('keydown', keydownHandler, true);
            });
        })();
        """
        
        let msg: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": [
                "expression": jsScript,
                "awaitPromise": true,
                "returnByValue": true
            ]
        ]
        
        guard let msgData = try? JSONSerialization.data(withJSONObject: msg),
              let msgStr = String(data: msgData, encoding: .utf8) else {
            return .internalServerError
        }
        
        let wsTask = URLSession.shared.webSocketTask(with: wsUrl)
        wsTask.resume()
        
        let wsSemaphore = DispatchSemaphore(value: 0)
        var capturedHTML: String? = nil
        
        func receiveLoop() {
            wsTask.receive { result in
                switch result {
                case .success(let message):
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let id = json["id"] as? Int, id == 1 {
                        
                        if let resultObj = json["result"] as? [String: Any],
                           let valObj = resultObj["result"] as? [String: Any],
                           let value = valObj["value"] as? String {
                            capturedHTML = value
                        }
                        wsSemaphore.signal()
                        return
                    }
                    receiveLoop()
                case .failure(_):
                    wsSemaphore.signal()
                }
            }
        }
        
        wsTask.send(.string(msgStr)) { error in
            if error != nil {
                wsSemaphore.signal()
                return
            }
            receiveLoop()
        }
        
        _ = wsSemaphore.wait(timeout: .now() + 60.0) // wait up to 60 seconds
        wsTask.cancel(with: .normalClosure, reason: nil)
        
        if let html = capturedHTML {
            if html == "__CANCELED__" {
                Task {
                    try? await HSManager.shared.sendAction(action: "alert", params: ["text": "🛑 [TaiChi 寻星镜] 已取消", "duration": 1])
                }
                return jsonResponse(["success": true, "canceled": true])
            }
            
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(html, forType: .string)
                
                Task {
                    try? await HSManager.shared.sendAction(action: "alert", params: ["text": "✅ [TaiChi 寻星镜] 目标已锁定并复制到剪贴板！", "duration": 2])
                }
            }
            return jsonResponse(["success": true, "html": html])
        } else {
            return jsonResponse(["error": "Failed to capture element"], statusCode: 500)
        }
    }
    
    // MARK: - Cyber Evaluate API
    

    func evaluateCyberScript(appId: String, script: String) -> (success: Bool, result: Any?, error: String?) {
        let activeInjectedAppIDs = DispatchQueue.main.sync {
            TaiChiSettings.shared.activeInjectedApps.map { $0.id }
        }
        guard activeInjectedAppIDs.contains(appId) else { return (false, nil, "App is not injected") }
        
        let runningApps = NSWorkspace.shared.runningApplications
        guard let app = runningApps.first(where: { $0.bundleIdentifier == appId }),
              let portStr = getDebuggingPort(for: app.processIdentifier),
              let port = Int(portStr) else {
            return (false, nil, "Cannot find debugging port")
        }
        
        guard let url = URL(string: "http://127.0.0.1:\(port)/json") else { return (false, nil, "URL error") }
        let semaphore = DispatchSemaphore(value: 0)
        var wsUrlStr: String? = nil
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            defer { semaphore.signal() }
            guard let data = data,
                  let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let firstTarget = jsonArray.first(where: { ($0["type"] as? String) == "page" }),
                  let wsUrl = firstTarget["webSocketDebuggerUrl"] as? String else { return }
            wsUrlStr = wsUrl
        }.resume()
        
        _ = semaphore.wait(timeout: .now() + 5.0)
        guard let wsUrlString = wsUrlStr, let wsUrl = URL(string: wsUrlString) else {
            return (false, nil, "Cannot get WebSocket URL")
        }
        
        let msg: [String: Any] = ["id": 1, "method": "Runtime.evaluate", "params": ["expression": script, "awaitPromise": true, "returnByValue": true]]
        guard let msgData = try? JSONSerialization.data(withJSONObject: msg),
              let msgStr = String(data: msgData, encoding: .utf8) else { return (false, nil, "JSON error") }
        
        let wsTask = URLSession.shared.webSocketTask(with: wsUrl)
        wsTask.resume()
        
        let wsSemaphore = DispatchSemaphore(value: 0)
        var scriptResult: Any? = nil
        var errorResult: String? = nil
        
        func receiveLoop() {
            wsTask.receive { result in
                switch result {
                case .success(let message):
                    if case .string(let text) = message,
                       let data = text.data(using: .utf8),
                       let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let id = jsonResponse["id"] as? Int, id == 1 {
                            if let error = jsonResponse["error"] as? [String: Any] {
                                errorResult = error["message"] as? String ?? "Unknown error"
                            } else if let resultObj = jsonResponse["result"] as? [String: Any] {
                                if let exceptionDetails = resultObj["exceptionDetails"] as? [String: Any] {
                                    errorResult = (exceptionDetails["exception"] as? [String: Any])?["description"] as? String ?? "Script threw an exception"
                                } else if let valObj = resultObj["result"] as? [String: Any] {
                                    scriptResult = valObj["value"]
                                }
                            }
                            wsSemaphore.signal()
                            return
                        }
                    }
                    receiveLoop()
                case .failure(let error):
                    errorResult = error.localizedDescription
                    wsSemaphore.signal()
                }
            }
        }
        
        wsTask.send(.string(msgStr)) { error in
            if let error = error {
                errorResult = error.localizedDescription
                wsSemaphore.signal()
                return
            }
            receiveLoop()
        }
        
        _ = wsSemaphore.wait(timeout: .now() + 10.0)
        wsTask.cancel(with: .normalClosure, reason: nil)
        
        if let error = errorResult {
            return (false, nil, error)
        }
        return (true, scriptResult, nil)
    }
    
    func getCyberMediaHandler(appId: String, command: String) -> String? {
        return self.cyberMediaHandlers[appId]?[command]
    }
    
    func evaluateCyberMediaCommand(appId: String, command: String) -> Bool {
        guard let s = getCyberMediaHandler(appId: appId, command: command) else { return false }
        let (success, _, _) = evaluateCyberScript(appId: appId, script: s)
        return success
    }

    
    private func handleCyberMediaHandlers(_ request: HttpRequest) -> HttpResponse {
        guard request.method == "POST" else { return jsonResponse(["error": "Method Not Allowed"], statusCode: 405) }
        let bodyData = Data(request.body)
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let appId = json["appId"] as? String,
              let handlers = json["handlers"] as? [String: String] else {
            return jsonResponse(["error": "Missing payload"], statusCode: 400)
        }
        DispatchQueue.main.async {
            self.cyberMediaHandlers[appId] = handlers
            UserDefaults.standard.set(self.cyberMediaHandlers, forKey: "cyberMediaHandlers")
            print("✅ [ServerManager] Registered media handlers for \(appId)")
        }
        return jsonResponse(["success": true])
    }

    private func handleCyberEvaluate(_ request: HttpRequest) -> HttpResponse {
        guard request.method == "POST" else { return jsonResponse(["error": "Method Not Allowed"], statusCode: 405) }
        let bodyData = Data(request.body)
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let appId = json["appId"] as? String,
              let script = json["script"] as? String else {
            return jsonResponse(["error": "Missing appId or script in JSON body"], statusCode: 400)
        }
        
        let (success, result, error) = evaluateCyberScript(appId: appId, script: script)
        if success {
            return jsonResponse(["success": true, "result": result ?? NSNull()])
        } else {
            return jsonResponse(["error": error ?? "Unknown error"], statusCode: 500)
        }
    }

}
