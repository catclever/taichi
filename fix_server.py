with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/ServerManager.swift", "r") as f:
    content = f.read()

import re

# 1. Extract the closure logic into a new method `handleCyberMediaHandlers`
closure_pattern = r'server\["/api/cyber/media_handlers"\] = \{ \[weak self\] request in.*?return self\?\.jsonResponse\(\["success": true\]\)\n        \}'
# Actually, the current closure uses `return jsonResponse(...)` which caused the error.
# Let's just find the closure and replace it.
closure_pattern = r'server\["/api/cyber/media_handlers"\] = \{ \[weak self\] request in.*?return jsonResponse\(\["success": true\]\)\n        \}'

new_closure = """server["/api/cyber/media_handlers"] = { [weak self] request in
            return self?.handleCyberMediaHandlers(request) ?? .internalServerError
        }"""

content = re.sub(closure_pattern, new_closure, content, flags=re.DOTALL)

# 2. Add the method handleCyberMediaHandlers
new_method = """
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
            print("✅ [ServerManager] Registered media handlers for \\(appId)")
        }
        return jsonResponse(["success": true])
    }
"""

content = content.replace("private func handleCyberEvaluate(_ request: HttpRequest) -> HttpResponse {", new_method + "\n    private func handleCyberEvaluate(_ request: HttpRequest) -> HttpResponse {")

with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/ServerManager.swift", "w") as f:
    f.write(content)
