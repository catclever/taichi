import Foundation
import AppKit

public class HSManager: @unchecked Sendable {
    public static let shared = HSManager()
    
    private(set) var securityToken: String = ""
    private let hsPort = 9999
    private let hsBundleID = "org.hammerspoon.Hammerspoon"
    
    private init() {}
    
    /// 初始化 Hammerspoon 基础设施
    @MainActor
    public func initialize(taichiPort: Int) {
        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: hsBundleID) else {
            print("⚠️ [HSManager] Hammerspoon is not installed on this machine. Doing nothing.")
            return
        }
        
        // 1. 获取或生成安全令牌
        self.securityToken = loadOrGenerateToken()
        print("🔗 [HSManager] Using security token: \(self.securityToken)")
        
        // 2. 检查并注入环境配置
        let configWritten = injectConfigIfNeeded(taichiPort: taichiPort)
        
        // 3. 根据情况拉起或重载
        let runningApps = workspace.runningApplications
        let isRunning = runningApps.contains { $0.bundleIdentifier == hsBundleID }
        
        if configWritten {
            if isRunning {
                print("🔄 [HSManager] Config changed. Hammerspoon is running, executing reload script via AppleScript...")
                let scriptSource = "tell application \"Hammerspoon\" to execute lua code \"hs.reload()\""
                var errorDict: NSDictionary?
                if let appleScript = NSAppleScript(source: scriptSource) {
                    appleScript.executeAndReturnError(&errorDict)
                    if let error = errorDict {
                        print("❌ [HSManager] AppleScript reload failed: \(error)")
                    } else {
                        print("✅ [HSManager] Hammerspoon reloaded via AppleScript.")
                    }
                }
            } else {
                launchHS(workspace: workspace, url: appURL)
            }
        } else {
            if !isRunning {
                launchHS(workspace: workspace, url: appURL)
            } else {
                print("✅ [HSManager] Config unchanged and Hammerspoon is already running. Doing nothing.")
            }
        }
    }
    
    /// 向 Hammerspoon 下发执行指令
    @discardableResult
    public func sendAction(action: String, params: [String: Any]? = nil) async throws -> Data {
        let urlString = "http://127.0.0.1:\(hsPort)/api/action"
        guard let url = URL(string: urlString) else { throw NSError(domain: "Invalid URL", code: 400, userInfo: nil) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(securityToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = ["action": action]
        if let params = params {
            body["params"] = params
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            print("⚠️ [HSManager] Action '\(action)' failed with status: \(httpResponse.statusCode)")
            throw NSError(domain: "HTTP Error", code: httpResponse.statusCode, userInfo: nil)
        } else {
            print("✅ [HSManager] Action '\(action)' sent successfully.")
        }
        return data
    }
    
    internal func fetchScreens() async throws -> [ScreenInfo] {
        let data = try await sendAction(action: "getScreens", params: [:])
        guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "Invalid Response Format", code: 500, userInfo: nil)
        }
        return jsonArray.compactMap { dict in
            guard let uuid = dict["uuid"] as? String,
                  let name = dict["name"] as? String else { return nil }
            return ScreenInfo(uuid: uuid, name: name)
        }
    }
    
    // MARK: - Private Helpers
    
    private func generateRandomToken(length: Int) -> String {
        let characters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map { _ in characters.randomElement()! })
    }
    
    private func loadOrGenerateToken() -> String {
        let fileManager = FileManager.default
        let hsDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".hammerspoon")
        let configFile = hsDir.appendingPathComponent("taichi_env.lua")
        
        if let existingContent = try? String(contentsOf: configFile, encoding: .utf8) {
            if let range = existingContent.range(of: "security_token = \"([^\"]+)\"", options: .regularExpression) {
                let match = String(existingContent[range])
                let components = match.components(separatedBy: "\"")
                if components.count >= 3 {
                    return components[1]
                }
            }
        }
        return generateRandomToken(length: 16)
    }
    
    @MainActor
    private func injectConfigIfNeeded(taichiPort: Int) -> Bool {
        let settings = TaiChiSettings.shared
        
        // 生成热键 Lua 配置
        func luaHotkey(_ hk: HotkeyConfig) -> String {
            let mods = hk.modifiers.map { "\"\($0)\"" }.joined(separator: ", ")
            return "{{\(mods)}, \"\(hk.key)\"}"
        }
        
        let hotkeysLua = """
        hotkeys = {
            togglePin = \(settings.isFloatingFeatureEnabled ? luaHotkey(settings.hotkeyTogglePin) : "nil"),
            toggleAll = \(settings.isFloatingFeatureEnabled ? luaHotkey(settings.hotkeyToggleAll) : "nil"),
            triggerInspector = \(settings.isTelescopeEnabled ? luaHotkey(settings.hotkeyTelescope) : "nil")
          }
        """
        
        // 生成 Wallpaper Channels Lua 配置
        var channelsLua = "{\n"
        for (screen, channels) in settings.wallpaperChannels {
            let channelsArray = channels.map { "\"\($0)\"" }.joined(separator: ", ")
            channelsLua += "            [\"\(screen)\"] = {\(channelsArray)},\n"
        }
        channelsLua += "          }"
        
        let configLua = """
        -- taichi_env.lua (由 TaiChi 自动生成，请勿手动修改)
        return {
          taichi_port = \(taichiPort),
          hs_port = \(hsPort),
          security_token = "\(securityToken)",
          wallpaperSaveDir = "\(settings.wallpaperSaveDir)",
          wallpaperChannels = \(channelsLua),
          \(hotkeysLua)
        }
        """
        
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let hsDir = homeDir.appendingPathComponent(".hammerspoon")
        let configFile = hsDir.appendingPathComponent("taichi_env.lua")
        
        if let existingContent = try? String(contentsOf: configFile, encoding: .utf8), existingContent == configLua {
            return false // No change needed
        }
        
        do {
            if !fileManager.fileExists(atPath: hsDir.path) {
                try fileManager.createDirectory(at: hsDir, withIntermediateDirectories: true)
            }
            try configLua.write(to: configFile, atomically: true, encoding: .utf8)
            print("📝 [HSManager] Injected config to ~/.hammerspoon/taichi_env.lua")
            return true
        } catch {
            print("❌ [HSManager] Failed to write taichi_env.lua: \(error)")
            return false
        }
    }
    
    private func launchHS(workspace: NSWorkspace, url: URL) {
        print("🚀 [HSManager] Hammerspoon is not running, launching...")
        let configuration = NSWorkspace.OpenConfiguration()
        workspace.openApplication(at: url, configuration: configuration) { _, error in
            if let error = error {
                print("❌ [HSManager] Failed to launch Hammerspoon: \(error)")
            } else {
                print("✅ [HSManager] Hammerspoon launched.")
            }
        }
    }
}
