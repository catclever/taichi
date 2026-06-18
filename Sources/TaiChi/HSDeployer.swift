import Foundation

@MainActor
class HSDeployer {
    static let shared = HSDeployer()
    
    private init() {}
    
    /// 部署全部 Lua 脚本和依赖
    func deployScripts(to hsConfigPath: String) -> Bool {
        let fileManager = FileManager.default
        let hsPath = (hsConfigPath as NSString).expandingTildeInPath
        
        let clientDir = (hsPath as NSString).appendingPathComponent("core/taichi_client")
        let actionsDir = (hsPath as NSString).appendingPathComponent("actions")
        let coreDir = (hsPath as NSString).appendingPathComponent("core")
        
        do {
            try fileManager.createDirectory(atPath: clientDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(atPath: actionsDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(atPath: coreDir, withIntermediateDirectories: true)
            
            // 需要拷贝的文件映射：[(源文件名, 子目录, 目标路径)]
            let filesToCopy: [(String, String, String)] = [
                ("taichi_client_init.lua", "", (clientDir as NSString).appendingPathComponent("init.lua")),
                ("inspector.lua", "", (clientDir as NSString).appendingPathComponent("inspector.lua")),
                ("paper_client.lua", "core/taichi_client", (clientDir as NSString).appendingPathComponent("paper_client.lua")),
                ("floating_action.lua", "actions", (actionsDir as NSString).appendingPathComponent("floating_action.lua")),
                ("wallpaper_action.lua", "actions", (actionsDir as NSString).appendingPathComponent("wallpaper_action.lua")),
                ("http_bus.lua", "core", (coreDir as NSString).appendingPathComponent("http_bus.lua")),
                ("event_watcher.lua", "core", (coreDir as NSString).appendingPathComponent("event_watcher.lua"))
            ]
            
            for (sourceName, subDir, targetPath) in filesToCopy {
                let fullSubDir = "Resources/Hammerspoon" + (subDir.isEmpty ? "" : "/\(subDir)")
                if let resourceURL = Bundle.module.url(forResource: sourceName, withExtension: nil, subdirectory: fullSubDir) {
                    if fileManager.fileExists(atPath: targetPath) {
                        try fileManager.removeItem(atPath: targetPath)
                    }
                    try fileManager.copyItem(at: resourceURL, to: URL(fileURLWithPath: targetPath))
                    print("✅ [HSDeployer] Copied \(sourceName) to \(targetPath)")
                } else {
                    print("⚠️ [HSDeployer] Resource not found: \(sourceName) in \(fullSubDir)")
                }
            }
            
            // 安全追加 init.lua
            return updateHSInit(hsConfigPath: hsPath)
            
        } catch {
            print("❌ [HSDeployer] Deployment failed: \(error)")
            return false
        }
    }
    
    /// 智能安全追加 init.lua
    private func updateHSInit(hsConfigPath: String) -> Bool {
        let initLuaPath = (hsConfigPath as NSString).appendingPathComponent("init.lua")
        let fileManager = FileManager.default
        
        do {
            var content = ""
            if fileManager.fileExists(atPath: initLuaPath) {
                content = try String(contentsOfFile: initLuaPath, encoding: .utf8)
            }
            
            var changed = false
            
            // 检查 taichi_env 覆盖
            let hotkeysOverride = "taichi_env.hotkeys = env.hotkeys"
            if !content.contains("taichi_env.hotkeys = env.hotkeys") {
                if let range = content.range(of: "taichi_env.security_token = env.security_token or taichi_env.security_token") {
                    content.insert(contentsOf: "\n        \(hotkeysOverride)", at: range.upperBound)
                    changed = true
                }
            }
            
            // 检查 taichi_client 初始化
            let taichiClientRequire = "_G.taichi_client = require(\"v3.core.taichi_client\")"
            if !content.contains("require(\"v3.core.taichi_client\")") {
                content += "\n\n-- [TaiChi Auto-Deploy] 初始化 TaiChi 客户端\n\(taichiClientRequire)\ntaichi_client.init(taichi_env)\ntaichi_client.bindHotkeys(taichi_env.hotkeys)\n"
                changed = true
            }
            
            // 检查 floating_action 引用
            let floatingActionRequire = "require(\"v3.actions.floating_action\")"
            if !content.contains("v3.actions.floating_action") {
                content += "\n\n-- [TaiChi Auto-Deploy] 注册 Floating Action\n\(floatingActionRequire)\n"
                changed = true
            }

            // 检查 wallpaper_action 引用
            let wallpaperActionRequire = "require(\"v3.actions.wallpaper_action\")"
            if !content.contains("v3.actions.wallpaper_action") {
                content += "\n\n-- [TaiChi Auto-Deploy] 注册 Wallpaper Action\n\(wallpaperActionRequire)\n"
                changed = true
            }
            
            // 检查 http_bus 引用
            let httpBusRequire = "local http_bus = require(\"v3.core.http_bus\")"
            if !content.contains("v3.core.http_bus") {
                content += "\n\n-- [TaiChi Auto-Deploy] 初始化 HTTP Bus\n\(httpBusRequire)\nhttp_bus.init(taichi_env)\n"
                changed = true
            }
            
            // 检查 inspector 引用
            let inspectorRequire = "local inspector = require(\"v3.core.taichi_client.inspector\")\ninspector.init(taichi_env)"
            if !content.contains("v3.core.taichi_client.inspector") {
                content += "\n\n-- [TaiChi Auto-Deploy] 注册 Inspector 寻星镜\n\(inspectorRequire)\n"
                changed = true
            }

            // 检查 paper_client 引用
            let paperClientRequire = "require(\"v3.core.taichi_client.paper_client\")"
            if !content.contains("v3.core.taichi_client.paper_client") {
                content += "\n\n-- [TaiChi Auto-Deploy] 注册 Paper 客户端\n\(paperClientRequire)\n"
                changed = true
            }
            
            // 检查 event_watcher 引用
            let eventWatcherRequire = "local event_watcher = require(\"v3.core.event_watcher\")"
            if !content.contains("-- [TaiChi Auto-Deploy] 注册事件监听器") {
                content += "\n\n-- [TaiChi Auto-Deploy] 注册事件监听器\n\(eventWatcherRequire)\nevent_watcher.init(taichi_env)\n"
                changed = true
            }
            
            if changed {
                try content.write(toFile: initLuaPath, atomically: true, encoding: .utf8)
                print("📝 [HSDeployer] Updated init.lua safely.")
            } else {
                print("✅ [HSDeployer] init.lua already contains all requirements. No changes made.")
            }
            
            return true
            
        } catch {
            print("❌ [HSDeployer] Failed to update init.lua: \(error)")
            return false
        }
    }
}
