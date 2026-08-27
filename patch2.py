import sys

with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/ServerManager.swift", "r") as f:
    content = f.read()

# 1. Add property
if "private var cyberMediaHandlers" not in content:
    content = content.replace("private var wakeObserver: NSObjectProtocol?", "private var wakeObserver: NSObjectProtocol?\n    private var cyberMediaHandlers: [String: [String: String]] = [:]")

# 2. Add endpoint
if "/api/cyber/media_handlers" not in content:
    ep = """        // 4.5 Cyber Media Handlers Registry
        server["/api/cyber/media_handlers"] = { [weak self] request in
            guard request.method == "POST" else { return jsonResponse(["error": "Method Not Allowed"], statusCode: 405) }
            let bodyData = Data(request.body)
            guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let appId = json["appId"] as? String,
                  let handlers = json["handlers"] as? [String: String] else {
                return jsonResponse(["error": "Missing payload"], statusCode: 400)
            }
            DispatchQueue.main.async {
                self?.cyberMediaHandlers[appId] = handlers
                print("✅ [ServerManager] Registered media handlers for \\(appId)")
            }
            return jsonResponse(["success": true])
        }
        
"""
    content = content.replace("server[\"/api/cyber/evaluate\"] = {", ep + "        server[\"/api/cyber/evaluate\"] = {")

# 3. Add evaluateCyberScript and evaluateCyberMediaCommand and replace handleCyberEvaluate
old_func_start = "    private func handleCyberEvaluate(_ request: HttpRequest) -> HttpResponse {"
new_logic = """
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
        
        guard let url = URL(string: "http://127.0.0.1:\\(port)/json") else { return (false, nil, "URL error") }
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
    
    func evaluateCyberMediaCommand(appId: String, command: String) -> Bool {
        var script: String? = nil
        DispatchQueue.main.sync {
            script = self.cyberMediaHandlers[appId]?[command]
        }
        guard let s = script else { return false }
        let (success, _, _) = evaluateCyberScript(appId: appId, script: s)
        return success
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
"""

# replace the entire old handleCyberEvaluate method to the end of the file
import re
idx = content.find(old_func_start)
if idx != -1:
    content = content[:idx] + new_logic + "\n}\n"

with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/ServerManager.swift", "w") as f:
    f.write(content)
