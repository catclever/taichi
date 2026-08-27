with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/ServerManager.swift", "r") as f:
    content = f.read()

# Fix evaluateCyberScript
old_sync = """        let activeInjectedAppIDs = DispatchQueue.main.sync {
            TaiChiSettings.shared.activeInjectedApps.map { $0.id }
        }"""
new_sync = """        var activeInjectedAppIDs: [String] = []
        if Thread.isMainThread {
            activeInjectedAppIDs = TaiChiSettings.shared.activeInjectedApps.map { $0.id }
        } else {
            DispatchQueue.main.sync {
                activeInjectedAppIDs = TaiChiSettings.shared.activeInjectedApps.map { $0.id }
            }
        }"""
content = content.replace(old_sync, new_sync)

# Fix evaluateCyberMediaCommand and add getCyberMediaHandler
old_eval_media = """    func evaluateCyberMediaCommand(appId: String, command: String) -> Bool {
        var script: String? = nil
        DispatchQueue.main.sync {
            script = self.cyberMediaHandlers[appId]?[command]
        }
        guard let s = script else { return false }
        let (success, _, _) = evaluateCyberScript(appId: appId, script: s)
        return success
    }"""

new_eval_media = """    func getCyberMediaHandler(appId: String, command: String) -> String? {
        if Thread.isMainThread {
            return self.cyberMediaHandlers[appId]?[command]
        } else {
            var script: String? = nil
            DispatchQueue.main.sync {
                script = self.cyberMediaHandlers[appId]?[command]
            }
            return script
        }
    }
    
    func evaluateCyberMediaCommand(appId: String, command: String) -> Bool {
        guard let s = getCyberMediaHandler(appId: appId, command: command) else { return false }
        let (success, _, _) = evaluateCyberScript(appId: appId, script: s)
        return success
    }"""
content = content.replace(old_eval_media, new_eval_media)

with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/ServerManager.swift", "w") as f:
    f.write(content)
