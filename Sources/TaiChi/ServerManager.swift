import Foundation
import Swifter

class ServerManager: @unchecked Sendable {
    static let shared = ServerManager()
    
    private let server = HttpServer()
    private var stateCache: [String: String] = [:]
    private let cacheQueue = DispatchQueue(label: "com.taichi.cache")
    
    private var scriptCache: [String: (response: String, expireAt: Date)] = [:]
    private let scriptCacheQueue = DispatchQueue(label: "com.taichi.scriptcache")
    
    private var isRunning = false
    
    private init() {
        setupRoutes()
    }
    
    @MainActor
    func start() {
        guard !isRunning else { return }
        
        // Load configurations on start
        let port = in_port_t(TaiChiSettings.shared.httpPort)
        do {
            try server.start(port)
            isRunning = true
            print("🚀 TaiChi Gateway started on port \(port)")
        } catch {
            print("❌ Failed to start TaiChi Gateway: \(error)")
        }
    }
    
    func stop() {
        if isRunning {
            server.stop()
            isRunning = false
            print("🛑 TaiChi Gateway stopped")
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
            
            return nil
        }
        
        // 1. Core State API (GET/POST /api/var/:key)
        server["/api/var/:key"] = { [weak self] request in
            return self?.handleVarRequest(request) ?? .internalServerError
        }
        
        // 2. Scripting API (GET /api/script/:name)
        server["/api/script/:name"] = { [weak self] request in
            return self?.handleScriptRequest(request) ?? .internalServerError
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
            cacheQueue.sync { stateCache[key] = bodyString }
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
        guard let name = request.params[":name"] else {
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
        
        let scriptsDir = DispatchQueue.main.sync {
            (TaiChiSettings.shared.scriptsPath as NSString).expandingTildeInPath
        }
        let fm = FileManager.default
        
        let extensions = ["js", "py", "sh"]
        var scriptFile: String? = nil
        
        for ext in extensions {
            let path = (scriptsDir as NSString).appendingPathComponent("\(name).\(ext)")
            if fm.fileExists(atPath: path) {
                scriptFile = path
                break
            }
        }
        
        guard let scriptPath = scriptFile else {
            return jsonResponse(["error": "Script not found: \(name)"], statusCode: 404)
        }
        
        let process = Process()
        
        // Execute via bash login shell so it inherits user's PATH (e.g. nvm, brew python)
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        
        var command = ""
        if scriptPath.hasSuffix(".js") {
            command = "node \"\(scriptPath)\""
        } else if scriptPath.hasSuffix(".py") {
            command = "python3 \"\(scriptPath)\""
        } else if scriptPath.hasSuffix(".sh") {
            command = "sh \"\(scriptPath)\""
        }
        
        process.arguments = ["-l", "-c", command]
        
        var env = ProcessInfo.processInfo.environment
        for (key, value) in request.queryParams {
            env["QUERY_\(key)"] = value
        }
        process.environment = env
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            if process.terminationStatus == 0 {
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
                    }
                } else if ttl == 0 {
                    // Explicitly clear cache if ttl is 0
                    scriptCacheQueue.sync {
                        scriptCache.removeValue(forKey: cacheKey)
                    }
                }
                
                if finalOutput.hasPrefix("{") || finalOutput.hasPrefix("[") {
                    return jsonResponse(finalOutput)
                }
                return jsonResponse(["success": true, "output": finalOutput])
            } else {
                return jsonResponse(["error": "Script execution failed", "code": process.terminationStatus], statusCode: 500)
            }
        } catch {
            return jsonResponse(["error": "Failed to run process", "details": error.localizedDescription], statusCode: 500)
        }
    }
}
