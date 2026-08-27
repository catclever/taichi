import re

with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/ServerManager.swift", "r") as f:
    content = f.read()

# Add cyberMediaHandlers property
if "private var cyberMediaHandlers" not in content:
    content = content.replace("private var wakeObserver: NSObjectProtocol?", "private var wakeObserver: NSObjectProtocol?\n    private var cyberMediaHandlers: [String: [String: String]] = [:]\n")

# Add the new endpoint mapping
if "/api/cyber/media_handlers" not in content:
    endpoint_code = """
        // 4.5 Cyber Media Handlers Registry
        server["/api/cyber/media_handlers"] = { [weak self] request in
            guard request.method == "POST" else {
                return jsonResponse(["error": "Method Not Allowed"], statusCode: 405)
            }
            let bodyData = Data(request.body)
            guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let appId = json["appId"] as? String,
                  let handlers = json["handlers"] as? [String: String] else {
                return jsonResponse(["error": "Missing appId or handlers in JSON body"], statusCode: 400)
            }
            
            DispatchQueue.main.async {
                self?.cyberMediaHandlers[appId] = handlers
                print("✅ [ServerManager] Registered media handlers for \\(appId)")
            }
            
            return jsonResponse(["success": true])
        }
"""
    content = content.replace("server[\"/api/cyber/evaluate\"] = { [weak self] request in", endpoint_code + "\n        server[\"/api/cyber/evaluate\"] = { [weak self] request in")

# Extract logic from handleCyberEvaluate to evaluateCyberScript
if "func evaluateCyberScript" not in content:
    # Find handleCyberEvaluate function body
    match = re.search(r'private func handleCyberEvaluate.*?\{.*?guard let json =.*?(let activeInjectedAppIDs = .*?)if let error = errorResult \{', content, re.DOTALL)
    if match:
        extracted_logic = match.group(1)
        
        # Replace handleCyberEvaluate
        new_evaluate_func = """
    func evaluateCyberScript(appId: String, script: String) -> (success: Bool, result: Any?, error: String?) {
        """ + extracted_logic + """
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
        
        let (success, _, error) = evaluateCyberScript(appId: appId, script: s)
        if !success {
            print("⚠️ [ServerManager] CyberMediaCommand failed for \\(appId): \\(error ?? "")")
        }
        return success
    }

    private func handleCyberEvaluate(_ request: HttpRequest) -> HttpResponse {
        guard request.method == "POST" else {
            return jsonResponse(["error": "Method Not Allowed"], statusCode: 405)
        }
        
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
        # We need to carefully replace the whole handleCyberEvaluate block
        # Find the end of handleCyberEvaluate
        full_match = re.search(r'(private func handleCyberEvaluate.*?HttpResponse \{.*?\}\n    \})', content, re.DOTALL)
        if full_match:
            content = content.replace(full_match.group(1), new_evaluate_func)

with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/ServerManager.swift", "w") as f:
    f.write(content)
