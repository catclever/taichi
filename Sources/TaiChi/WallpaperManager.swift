import Foundation
import AppKit

actor WallpaperManager {
    static let shared = WallpaperManager()
    
    private var downloadTask: Task<Void, Never>?
    private var autoChangeTask: Task<Void, Never>?
    
    private init() {
    }
    
    func startEngine() {
        setupTimerLoop()
    }
    
    private func setupTimerLoop() {
        autoChangeTask?.cancel()
        
        autoChangeTask = Task {
            // Wait a few seconds for initialization on launch
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            
            while !Task.isCancelled {
                let isEngineEnabled = await MainActor.run { TaiChiSettings.shared.isWallpaperEngineEnabled }
                let config = await MainActor.run { TaiChiSettings.shared.wallpaperEngineConfig }
                
                if isEngineEnabled && config.enableAutoChange == true {
                    let screens = await MainActor.run { TaiChiSettings.shared.connectedScreens }
                    let historyMap = await MainActor.run { TaiChiSettings.shared.wallpaperHistory }
                    
                    let intervalMinutes = config.globalIntervalMinutes ?? 1440
                    let intervalSeconds = max(60, intervalMinutes * 60)
                    
                    let now = Date()
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm"
                    let timeString = formatter.string(from: now)
                    
                    var screensToFetch: [ScreenInfo] = []
                    
                    for screen in screens {
                        let history = historyMap[screen.uuid] ?? []
                        let lastTimestamp = history.last?.timestamp ?? Date.distantPast
                        let elapsed = now.timeIntervalSince(lastTimestamp)
                        
                        var shouldFetch = false
                        
                        // 1. Check global interval threshold
                        if elapsed >= Double(intervalSeconds) {
                            shouldFetch = true
                        }
                        
                        // 2. Check daily fixed time config
                        if let autoConfig = config.autoTimeConfig, 
                           let times = autoConfig.times, times.contains(timeString),
                           let threshold = autoConfig.checkThresholdSeconds {
                            if elapsed >= Double(threshold) {
                                // If specific screens are targeted
                                if let targetedScreens = autoConfig.screens, !targetedScreens.isEmpty {
                                    if targetedScreens.contains(screen.uuid) || targetedScreens.contains(screen.name) {
                                        shouldFetch = true
                                    }
                                } else {
                                    shouldFetch = true
                                }
                            }
                        }
                        
                        if shouldFetch {
                            screensToFetch.append(screen)
                        }
                    }
                    
                    if !screensToFetch.isEmpty {
                        await triggerAutoChange(for: screensToFetch)
                    }
                }
                
                // Sleep for 60 seconds and check again
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }
    
    func onScreensChanged(screens: [ScreenInfo]) {
        // Called by BrainManager when HS reports screen changes
        Task {
            let isEngineEnabled = await MainActor.run { TaiChiSettings.shared.isWallpaperEngineEnabled }
            guard isEngineEnabled else { return }
            
            let config = await MainActor.run { TaiChiSettings.shared.wallpaperEngineConfig }
            let historyMap = await MainActor.run { TaiChiSettings.shared.wallpaperHistory }
            
            let intervalMinutes = config.globalIntervalMinutes ?? 1440
            let intervalSeconds = max(60, intervalMinutes * 60)
            let now = Date()
            
            var screensToFetch: [ScreenInfo] = []
            
            for screen in screens {
                let history = historyMap[screen.uuid] ?? []
                if let lastEntry = history.last {
                    let elapsed = now.timeIntervalSince(lastEntry.timestamp)
                    if elapsed >= Double(intervalSeconds) {
                        screensToFetch.append(screen)
                    } else {
                        // Restore the last known wallpaper for this screen
                        let cacheDir = ("~/.cache/taichi/wallpapers/" as NSString).expandingTildeInPath
                        let destPath = (cacheDir as NSString).appendingPathComponent("\(lastEntry.photoId).jpg")
                        if FileManager.default.fileExists(atPath: destPath) {
                            await applyLocalWallpaper(path: destPath, photoId: lastEntry.photoId, screenUUID: screen.uuid, channelName: lastEntry.channelName ?? "unknown", title: lastEntry.title)
                        } else {
                            // File missing, need to fetch
                            screensToFetch.append(screen)
                        }
                    }
                } else {
                    // No history, must fetch
                    screensToFetch.append(screen)
                }
            }
            
            if !screensToFetch.isEmpty {
                await triggerAutoChange(for: screensToFetch)
            }
        }
    }
    
    private func triggerAutoChange(for specificScreens: [ScreenInfo]? = nil) async {
        let screensToUpdate: [ScreenInfo]
        if let specific = specificScreens {
            screensToUpdate = specific
        } else {
            screensToUpdate = await MainActor.run { TaiChiSettings.shared.connectedScreens }
        }
        
        let config = await MainActor.run { TaiChiSettings.shared.wallpaperEngineConfig }
        
        print("🔍 [WallpaperManager] triggerAutoChange for screensToUpdate: \(screensToUpdate.map { $0.name })")
        for screen in screensToUpdate {
            let screenConfig = config.screens?[screen.uuid] ?? config.screens?[screen.name]
            let channels = screenConfig?.channels ?? []
            print("🔍 [WallpaperManager] Checking screen \(screen.name) (UUID: \(screen.uuid)) - channels: \(channels)")
            
            await updateWallpaper(for: screen.uuid, channels: channels, config: config)
        }
    }
    
    private func updateWallpaper(for screenUUID: String, channels: [String], config: WallpaperEngineConfig) async {
        print("🔍 [WallpaperManager] updateWallpaper for \(screenUUID)")
        var pickedChannelName: String?
        if !channels.isEmpty {
            pickedChannelName = channels.randomElement()
        } else if let allChannels = config.channels, !allChannels.isEmpty {
            pickedChannelName = allChannels.keys.randomElement()
        }
        
        print("🔍 [WallpaperManager] pickedChannelName: \(pickedChannelName ?? "nil")")
        let channelConfig = config.channels?[pickedChannelName ?? ""] ?? WallpaperEngineConfig.ChannelConfig(type: "unsplash")
        let providerType = channelConfig.type ?? "unsplash"
        print("🔍 [WallpaperManager] providerType: \(providerType)")
        
        if providerType == "custom", let customUrlStr = channelConfig.url, let url = URL(string: customUrlStr) {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let httpResp = response as? HTTPURLResponse {
                    // If it's an image directly or a redirect to an image
                    if let contentType = httpResp.value(forHTTPHeaderField: "Content-Type"), contentType.hasPrefix("image/") {
                        let photoId = UUID().uuidString
                        await downloadAndApply(url: url, photoId: photoId, screenUUID: screenUUID, channelName: pickedChannelName ?? "custom", customData: data)
                        return
                    }
                }
                
                // Otherwise, try to parse JSON
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Fallback logic for generic JSON containing an image URL
                    // Searching for keys like "url", "image", "src", "file", "pic"
                    let possibleKeys = ["url", "image", "src", "file", "pic"]
                    var foundUrlStr: String?
                    for key in possibleKeys {
                        if let v = json[key] as? String, v.hasPrefix("http") {
                            foundUrlStr = v
                            break
                        }
                    }
                    if let found = foundUrlStr, let imgUrl = URL(string: found) {
                        let photoId = UUID().uuidString
                        await downloadAndApply(url: imgUrl, photoId: photoId, screenUUID: screenUUID, channelName: pickedChannelName ?? "custom")
                        return
                    }
                }
            } catch {
                print("❌ WallpaperManager: Failed to fetch from custom provider: \(error)")
            }
            return
        }
        
        // Fallback or explicit unsplash
        let apiKey = config.sources?["unsplash"]?.key ?? ""
        print("🔍 [WallpaperManager] Unsplash API Key length: \(apiKey.count)")
        guard !apiKey.isEmpty else {
            print("❌ WallpaperManager: Unsplash API key is missing in config.sources.unsplash")
            return
        }
        
        var urlString = "https://api.unsplash.com/photos/random?orientation=landscape"
        if let query = channelConfig.query, !query.isEmpty, let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "&query=\(enc)"
        }
        if let collections = channelConfig.collections, !collections.isEmpty {
            let cols = collections.joined(separator: ",")
            urlString += "&collections=\(cols)"
        }
        if let featured = channelConfig.featured, featured {
            urlString += "&featured=true"
        }
        
        print("🔍 [WallpaperManager] Fetching Unsplash URL: \(urlString)")
        
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = ["-s", "-H", "Authorization: Client-ID \(apiKey)", urlString]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let photoId = json["id"] as? String,
               let urls = json["urls"] as? [String: Any],
               let rawUrlString = urls["raw"] as? String,
               var rawUrl = URLComponents(string: rawUrlString) {
                
                let slug = json["slug"] as? String
                let altDesc = json["alt_description"] as? String
                let photoTitle = slug ?? altDesc
                
                print("🔍 [WallpaperManager] Got Unsplash photoId: \(photoId)")
                let queryItems = [
                    URLQueryItem(name: "q", value: "100"),
                    URLQueryItem(name: "fm", value: "jpg"),
                    URLQueryItem(name: "fit", value: "max"),
                    URLQueryItem(name: "w", value: "3840")
                ]
                rawUrl.queryItems = (rawUrl.queryItems ?? []) + queryItems
                
                if let downloadUrl = rawUrl.url {
                    print("🔍 [WallpaperManager] Downloading from \(downloadUrl)")
                    await downloadAndApply(url: downloadUrl, photoId: photoId, screenUUID: screenUUID, channelName: pickedChannelName ?? "unsplash", title: photoTitle)
                }
            } else {
                let respStr = String(data: data, encoding: .utf8) ?? ""
                print("❌ WallpaperManager: Invalid JSON from Unsplash or error: \(respStr)")
            }
        } catch {
            print("❌ WallpaperManager: Failed to fetch from Unsplash: \(error)")
        }
    }
    
    private func downloadAndApply(url: URL, photoId: String, screenUUID: String, channelName: String, title: String? = nil, customData: Data? = nil) async {
        let cacheDir = ("~/.cache/taichi/wallpapers/" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        
        let fileExt = "jpg"
        let destPath = (cacheDir as NSString).appendingPathComponent("\(photoId).\(fileExt)")
        let destURL = URL(fileURLWithPath: destPath)
        
        if !FileManager.default.fileExists(atPath: destPath) {
            do {
                if let data = customData {
                    try data.write(to: destURL)
                } else {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    process.arguments = ["-s", "-L", "-o", destPath, url.absoluteString]
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        print("❌ WallpaperManager: Curl download failed with status \(process.terminationStatus)")
                        return
                    }
                }
            } catch {
                print("❌ WallpaperManager: Download failed: \(error)")
                return
            }
        }
        
        await applyLocalWallpaper(path: destPath, photoId: photoId, screenUUID: screenUUID, channelName: channelName, title: title)
    }

    private func applyLocalWallpaper(path: String, photoId: String, screenUUID: String, channelName: String, title: String? = nil) async {
        do {
            try await HSManager.shared.sendAction(action: "setWallpaper", params: [
                "screenUUID": screenUUID,
                "path": path
            ])
            
            let now = Date()
            await MainActor.run {
                var historyMap = TaiChiSettings.shared.wallpaperHistory
                var history = historyMap[screenUUID] ?? []
                if history.last?.photoId != photoId {
                    history.append(WallpaperHistoryEntry(photoId: photoId, timestamp: now, channelName: channelName, title: title))
                    if history.count > 100 { history.removeFirst() }
                    historyMap[screenUUID] = history
                    TaiChiSettings.shared.wallpaperHistory = historyMap
                } else {
                    // Update timestamp even if it's the same photo
                    history[history.count - 1].timestamp = now
                    historyMap[screenUUID] = history
                    TaiChiSettings.shared.wallpaperHistory = historyMap
                }
            }
        } catch {
            print("❌ WallpaperManager: Failed to apply wallpaper via HS: \(error)")
        }
    }

    func forceChange(screenUUID: String?) async {
        var screens = await MainActor.run { TaiChiSettings.shared.connectedScreens }
        
        if screens.isEmpty {
            if let fetched = try? await HSManager.shared.fetchScreens() {
                screens = fetched
                await MainActor.run { TaiChiSettings.shared.connectedScreens = fetched }
            }
        }
        
        let targetScreens: [ScreenInfo]
        if let uuid = screenUUID, !uuid.isEmpty {
            targetScreens = screens.filter { $0.uuid == uuid || $0.name == uuid }
        } else {
            targetScreens = screens
        }
        
        await triggerAutoChange(for: targetScreens.isEmpty ? nil : targetScreens)
    }
    
    func revertToPrevious(screenUUID: String?) async {
        var screens = await MainActor.run { TaiChiSettings.shared.connectedScreens }
        
        if screens.isEmpty {
            if let fetched = try? await HSManager.shared.fetchScreens() {
                screens = fetched
                await MainActor.run { TaiChiSettings.shared.connectedScreens = fetched }
            }
        }
        
        let targetScreens: [ScreenInfo]
        if let uuid = screenUUID, !uuid.isEmpty {
            targetScreens = screens.filter { $0.uuid == uuid || $0.name == uuid }
        } else {
            targetScreens = screens
        }
        
        for screen in targetScreens {
            let prevEntry = await MainActor.run { () -> WallpaperHistoryEntry? in
                var historyMap = TaiChiSettings.shared.wallpaperHistory
                var history = historyMap[screen.uuid] ?? []
                guard history.count >= 2 else { return nil }
                
                history.removeLast()
                let prev = history.last!
                
                historyMap[screen.uuid] = history
                TaiChiSettings.shared.wallpaperHistory = historyMap
                
                return prev
            }
            
            if let prev = prevEntry {
                let cacheDir = ("~/.cache/taichi/wallpapers/" as NSString).expandingTildeInPath
                let destPath = (cacheDir as NSString).appendingPathComponent("\(prev.photoId).jpg")
                if FileManager.default.fileExists(atPath: destPath) {
                    await applyLocalWallpaper(path: destPath, photoId: prev.photoId, screenUUID: screen.uuid, channelName: prev.channelName ?? "unknown", title: prev.title)
                }
            }
        }
    }
    
    func saveCurrent(screenUUID: String?) async {
        let screens = await MainActor.run { TaiChiSettings.shared.connectedScreens }
        let targetScreens: [ScreenInfo]
        if let uuid = screenUUID, !uuid.isEmpty {
            targetScreens = screens.filter { $0.uuid == uuid || $0.name == uuid }
        } else {
            targetScreens = screens
        }
        
        let saveDir = await MainActor.run { TaiChiSettings.shared.wallpaperSaveDir }
        try? FileManager.default.createDirectory(atPath: saveDir, withIntermediateDirectories: true)
        
        for screen in targetScreens {
            let currentEntry = await MainActor.run {
                TaiChiSettings.shared.wallpaperHistory[screen.uuid]?.last
            }
            if let entry = currentEntry {
                let photoId = entry.photoId
                let channelStr = entry.channelName ?? "unknown"
                
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd_HH-mm"
                let dateStr = formatter.string(from: entry.timestamp)
                
                var namePart = photoId
                if let t = entry.title, !t.isEmpty {
                    // Safe filename
                    let safeTitle = t.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
                    if safeTitle.contains(photoId) {
                        namePart = safeTitle
                    } else {
                        namePart = "\(safeTitle)_\(photoId)"
                    }
                }
                
                let fileName = "\(dateStr)_\(channelStr)_\(namePart).jpg"
                
                let cacheDir = ("~/.cache/taichi/wallpapers/" as NSString).expandingTildeInPath
                let srcPath = (cacheDir as NSString).appendingPathComponent("\(photoId).jpg")
                let destPath = (saveDir as NSString).appendingPathComponent(fileName)
                
                if FileManager.default.fileExists(atPath: srcPath) {
                    do {
                        if FileManager.default.fileExists(atPath: destPath) {
                            try FileManager.default.removeItem(atPath: destPath)
                        }
                        try FileManager.default.copyItem(atPath: srcPath, toPath: destPath)
                        print("✅ WallpaperManager: Saved wallpaper \(photoId) to \(destPath)")
                    } catch {
                        print("❌ WallpaperManager: Failed to save wallpaper: \(error)")
                    }
                }
            }
        }
    }
}
