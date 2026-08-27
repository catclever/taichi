with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/ServerManager.swift", "r") as f:
    content = f.read()

old_get = """    func getCyberMediaHandler(appId: String, command: String) -> String? {
        var script: String? = nil
        DispatchQueue.main.asyncAndWait {
            script = self.cyberMediaHandlers[appId]?[command]
        }
        return script
    }"""
new_get = """    func getCyberMediaHandler(appId: String, command: String) -> String? {
        return self.cyberMediaHandlers[appId]?[command]
    }"""
content = content.replace(old_get, new_get)

with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/ServerManager.swift", "w") as f:
    f.write(content)
