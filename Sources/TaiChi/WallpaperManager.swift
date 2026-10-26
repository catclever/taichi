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
    
    private var lastFetchAttempts: [String: Date] = [:]
    private func setupTimerLoop() {
        autoChangeTask?.cancel()
        
        autoChangeTask = Task {
            // Wait a few seconds for initialization on launch
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            
            while !Task.isCancelled {
                let isEngineEnabled = await MainActor.run { TaiChiSettings.shared.isWallpaperEngineEnabled }
                let config = await MainActor.run { TaiChiSettings.shared.wallpaperEngineConfig }
                
                if isEngineEnabled && config.enableAutoChange == true {
                    var screens = await MainActor.run { TaiChiSettings.shared.connectedScreens }
                    if screens.isEmpty {
                        if let fetched = try? await HSManager.shared.fetchScreens() {
                            screens = fetched
                            await MainActor.run { TaiChiSettings.shared.connectedScreens = fetched }
                        }
                    }
                    let historyMap = await MainActor.run { TaiChiSettings.shared.wallpaperHistory }
                    let now = Date()
                    var screensToFetch: [ScreenInfo] = []
                    
                    for screen in screens {
                        let history = historyMap[screen.uuid] ?? []
                        if shouldUpdateWallpaper(for: screen, history: history, config: config, now: now) {
                            print("🚨 [WallpaperManager] Loop triggered fetch for: \(screen.name) (uuid: \(screen.uuid))")
                            screensToFetch.append(screen)
                        }
                    }
                    
                    if !screensToFetch.isEmpty {
                        await triggerAutoChange(for: screensToFetch)
                    }
                }
                
                await processEaglePendingQueue()
                
                // Sleep for 7200 seconds (2 hours) and check again
                try? await Task.sleep(nanoseconds: 7200 * 1_000_000_000)
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
            let now = Date()
            var screensToFetch: [ScreenInfo] = []
            
            for screen in screens {
                let history = historyMap[screen.uuid] ?? []
                if shouldUpdateWallpaper(for: screen, history: history, config: config, now: now) {
                    screensToFetch.append(screen)
                } else {
                    // Restore the last known wallpaper for this screen
                    if let lastEntry = history.last {
                        let cacheDir = ("~/.cache/taichi/wallpapers/" as NSString).expandingTildeInPath
                        let destPath = (cacheDir as NSString).appendingPathComponent("\(lastEntry.photoId).jpg")
                        if FileManager.default.fileExists(atPath: destPath) {
                            await applyLocalWallpaper(path: destPath, photoId: lastEntry.photoId, screenUUID: screen.uuid, channelName: lastEntry.channelName ?? "unknown", title: lastEntry.title, updateTimestamp: false)
                        } else {
                            screensToFetch.append(screen)
                        }
                    } else {
                        screensToFetch.append(screen)
                    }
                }
            }
            
            if !screensToFetch.isEmpty {
                await triggerAutoChange(for: screensToFetch)
            }
        }
    }
    
    private func shouldUpdateWallpaper(for screen: ScreenInfo, history: [WallpaperHistoryEntry], config: WallpaperEngineConfig, now: Date) -> Bool {
        let lastTimestamp = history.last?.timestamp ?? Date.distantPast
        let elapsed = now.timeIntervalSince(lastTimestamp)
        
        let lastAttempt = lastFetchAttempts[screen.uuid] ?? Date.distantPast
        if now.timeIntervalSince(lastAttempt) < 900 {
            return false // Debounce: skip if attempted within last 15 mins
        }
        
        let screenConfig = config.screens?[screen.uuid] ?? config.screens?[screen.name]
        
        if let isEnabled = screenConfig?.enabled, !isEnabled {
            return false
        }
        
        // 1. Check interval condition
        let intervalMinutes = screenConfig?.intervalMinutes ?? config.globalIntervalMinutes ?? 1440
        if intervalMinutes > 0 {
            let intervalSeconds = max(60, intervalMinutes * 60)
            
            if elapsed >= Double(intervalSeconds) {
                lastFetchAttempts[screen.uuid] = now
                return true
            }
        }
        
        // 2. Check daily fixed time config
        let autoConfig = screenConfig?.autoTimeConfig ?? config.autoTimeConfig
        if let autoConfig = autoConfig, 
           let times = autoConfig.times,
           let threshold = autoConfig.checkThresholdSeconds {
            
            if let targetedScreens = autoConfig.screens, !targetedScreens.isEmpty {
                if !targetedScreens.contains(screen.uuid) && !targetedScreens.contains(screen.name) {
                    return false
                }
            }
            
            let calendar = Calendar.current
            let condition = autoConfig.condition ?? "later"
            var timeMatched = false
            
            for timeStr in times {
                let components = timeStr.split(separator: ":")
                if components.count == 2,
                   let hour = Int(components[0]),
                   let minute = Int(components[1]),
                   let targetDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) {
                    
                    if condition == "earlier" {
                        if now < targetDate {
                            timeMatched = true
                            break
                        }
                    } else {
                        // "later"
                        if now >= targetDate && lastTimestamp < targetDate {
                            timeMatched = true
                            break
                        }
                    }
                }
            }
            
            if timeMatched && elapsed >= Double(threshold) {
                lastFetchAttempts[screen.uuid] = now
                return true
            }
        }
        
        return false
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
            guard let url = URL(string: urlString) else { return }
            var request = URLRequest(url: url)
            request.setValue("Client-ID \(apiKey)", forHTTPHeaderField: "Authorization")
            
            let (data, _) = try await URLSession.shared.data(for: request)
            
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
                    let (tempURL, imgResponse) = try await URLSession.shared.download(from: url)
                    guard let httpResp = imgResponse as? HTTPURLResponse, httpResp.statusCode == 200 else {
                        print("❌ WallpaperManager: URLSession download failed with non-200 status")
                        return
                    }
                    if FileManager.default.fileExists(atPath: destPath) {
                        try FileManager.default.removeItem(atPath: destPath)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destURL)
                }
            } catch {
                print("❌ WallpaperManager: Download failed: \(error)")
                return
            }
        }
        
        await applyLocalWallpaper(path: destPath, photoId: photoId, screenUUID: screenUUID, channelName: channelName, title: title)
    }

    private func applyLocalWallpaper(path: String, photoId: String, screenUUID: String, channelName: String, title: String? = nil, updateTimestamp: Bool = true) async {
        do {
            let screenName = await MainActor.run {
                TaiChiSettings.shared.connectedScreens.first(where: { $0.uuid == screenUUID })?.name
            }
            var params: [String: Any] = [
                "screenUUID": screenUUID,
                "path": path
            ]
            if let name = screenName {
                params["screenName"] = name
            }
            try await HSManager.shared.sendAction(action: "setWallpaper", params: params)
            
            let now = Date()
            await MainActor.run {
                var historyMap = TaiChiSettings.shared.wallpaperHistory
                var history = historyMap[screenUUID] ?? []
                if history.last?.photoId != photoId {
                    let ts = updateTimestamp ? now : (history.last?.timestamp ?? now)
                    history.append(WallpaperHistoryEntry(photoId: photoId, timestamp: ts, channelName: channelName, title: title))
                    if history.count > 100 { history.removeFirst() }
                    historyMap[screenUUID] = history
                    TaiChiSettings.shared.wallpaperHistory = historyMap
                } else {
                    if updateTimestamp {
                        // Update timestamp even if it's the same photo
                        history[history.count - 1].timestamp = now
                        historyMap[screenUUID] = history
                        TaiChiSettings.shared.wallpaperHistory = historyMap
                    }
                }
            }
        } catch {
            print("❌ WallpaperManager: Failed to apply wallpaper via HS: \(error)")
        }
    }

    // =============================================================================
    // [BUG FIX DOCUMENTATION - Task fix_wallpaper_target_screen_mapping_003]
    // 1. Problem Fixed:
    //    When running paper.change() on an external screen (e.g. "2490W1"), if targetScreens
    //    was empty or screenUUID was synthetic/unmatched in connectedScreens, forceChange
    //    fell back to `triggerAutoChange(for: targetScreens.isEmpty ? nil : targetScreens)`,
    //    which defaulted to updating all screens or the primary built-in screen.
    // 2. Resolution:
    //    - Updated forceChange signature to (screenUUID: String? = nil, screenName: String? = nil).
    //    - Checked whether a specific screen was requested (non-empty screenUUID or screenName).
    //    - Matched candidates against both uuid and name of connected screens.
    //    - If specific screen was requested and targetScreens is empty, actively fetched latest screens
    //      via HSManager.shared.fetchScreens() and re-filtered.
    //    - If still empty after refresh, logged a warning and returned immediately instead of falling
    //      back to nil.
    //    - Only invoked triggerAutoChange(for: nil) when no specific screen was requested.
    // 3. Caveats:
    //    Keep revertToPrevious and saveCurrent consistent with dual screenUUID/screenName matching.
    // =============================================================================
    func forceChange(screenUUID: String? = nil, screenName: String? = nil) async {
        var screens = await MainActor.run { TaiChiSettings.shared.connectedScreens }
        
        let hasUUID = screenUUID != nil && !screenUUID!.isEmpty
        let hasName = screenName != nil && !screenName!.isEmpty
        let isSpecificRequested = hasUUID || hasName
        
        if isSpecificRequested {
            var targetScreens = screens.filter { screen in
                (hasUUID && (screen.uuid == screenUUID || screen.name == screenUUID)) ||
                (hasName && (screen.uuid == screenName || screen.name == screenName))
            }
            
            if targetScreens.isEmpty {
                if let fetched = try? await HSManager.shared.fetchScreens(), !fetched.isEmpty {
                    screens = fetched
                    await MainActor.run { TaiChiSettings.shared.connectedScreens = fetched }
                    targetScreens = screens.filter { screen in
                        (hasUUID && (screen.uuid == screenUUID || screen.name == screenUUID)) ||
                        (hasName && (screen.uuid == screenName || screen.name == screenName))
                    }
                }
            }
            
            if targetScreens.isEmpty {
                print("⚠️ [WallpaperManager] Specific screen requested (UUID: \(screenUUID ?? "nil"), Name: \(screenName ?? "nil")) but not found among connected screens. Aborting forceChange to prevent misapplying wallpaper.")
                return
            }
            
            await triggerAutoChange(for: targetScreens)
        } else {
            if screens.isEmpty {
                if let fetched = try? await HSManager.shared.fetchScreens(), !fetched.isEmpty {
                    screens = fetched
                    await MainActor.run { TaiChiSettings.shared.connectedScreens = fetched }
                }
            }
            await triggerAutoChange(for: nil)
        }
    }
    
    func revertToPrevious(screenUUID: String? = nil, screenName: String? = nil) async {
        var screens = await MainActor.run { TaiChiSettings.shared.connectedScreens }
        
        let hasUUID = screenUUID != nil && !screenUUID!.isEmpty
        let hasName = screenName != nil && !screenName!.isEmpty
        let isSpecificRequested = hasUUID || hasName
        
        let targetScreens: [ScreenInfo]
        if isSpecificRequested {
            var filtered = screens.filter { screen in
                (hasUUID && (screen.uuid == screenUUID || screen.name == screenUUID)) ||
                (hasName && (screen.uuid == screenName || screen.name == screenName))
            }
            if filtered.isEmpty {
                if let fetched = try? await HSManager.shared.fetchScreens(), !fetched.isEmpty {
                    screens = fetched
                    await MainActor.run { TaiChiSettings.shared.connectedScreens = fetched }
                    filtered = screens.filter { screen in
                        (hasUUID && (screen.uuid == screenUUID || screen.name == screenUUID)) ||
                        (hasName && (screen.uuid == screenName || screen.name == screenName))
                    }
                }
            }
            if filtered.isEmpty {
                print("⚠️ [WallpaperManager] Specific screen requested (UUID: \(screenUUID ?? "nil"), Name: \(screenName ?? "nil")) but not found for revertToPrevious.")
                return
            }
            targetScreens = filtered
        } else {
            if screens.isEmpty {
                if let fetched = try? await HSManager.shared.fetchScreens(), !fetched.isEmpty {
                    screens = fetched
                    await MainActor.run { TaiChiSettings.shared.connectedScreens = fetched }
                }
            }
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
    
    func saveCurrent(screenUUID: String? = nil, screenName: String? = nil) async {
        var (screens, useEagle, eagleSkipLocalSave) = await MainActor.run {
            (TaiChiSettings.shared.connectedScreens, TaiChiSettings.shared.useEagleForWallpapers, TaiChiSettings.shared.eagleSkipLocalSave)
        }
        let hasUUID = screenUUID != nil && !screenUUID!.isEmpty
        let hasName = screenName != nil && !screenName!.isEmpty
        let isSpecificRequested = hasUUID || hasName
        
        let targetScreens: [ScreenInfo]
        if isSpecificRequested {
            var filtered = screens.filter { screen in
                (hasUUID && (screen.uuid == screenUUID || screen.name == screenUUID)) ||
                (hasName && (screen.uuid == screenName || screen.name == screenName))
            }
            if filtered.isEmpty {
                if let fetched = try? await HSManager.shared.fetchScreens(), !fetched.isEmpty {
                    screens = fetched
                    await MainActor.run { TaiChiSettings.shared.connectedScreens = fetched }
                    filtered = screens.filter { screen in
                        (hasUUID && (screen.uuid == screenUUID || screen.name == screenUUID)) ||
                        (hasName && (screen.uuid == screenName || screen.name == screenName))
                    }
                }
            }
            if filtered.isEmpty {
                print("⚠️ [WallpaperManager] Specific screen requested (UUID: \(screenUUID ?? "nil"), Name: \(screenName ?? "nil")) but not found for saveCurrent.")
                return
            }
            targetScreens = filtered
        } else {
            targetScreens = screens
        }
        
        let saveDir = await MainActor.run { TaiChiSettings.shared.wallpaperSaveDir }
        try? FileManager.default.createDirectory(atPath: saveDir, withIntermediateDirectories: true)
        
        let eagleRunning = NSWorkspace.shared.runningApplications.contains {
            $0.localizedName?.lowercased() == "eagle" || $0.bundleIdentifier?.lowercased().contains("eagle") == true
        }
        
        for screen in targetScreens {
            let currentEntry = await MainActor.run {
                TaiChiSettings.shared.wallpaperHistory[screen.uuid]?.last
            }
            if let entry = currentEntry {
                let photoId = entry.photoId
                let channelStr = entry.channelName ?? "unknown"
                
                let cacheDir = ("~/.cache/taichi/wallpapers/" as NSString).expandingTildeInPath
                let srcPath = (cacheDir as NSString).appendingPathComponent("\(photoId).jpg")
                
                if FileManager.default.fileExists(atPath: srcPath) {
                    var pushedToEagle = false
                    
                    if useEagle {
                        if eagleRunning {
                            pushedToEagle = await pushToEagle(path: srcPath, entry: entry, channel: channelStr)
                        }
                        
                        if !pushedToEagle {
                            // If Eagle is not running or push fails (e.g. SMB library disconnected), add to pending queue
                            await MainActor.run {
                                var pending = TaiChiSettings.shared.eaglePendingTasks
                                if !pending.contains(where: { $0.photoId == entry.photoId }) {
                                    pending.append(entry)
                                    TaiChiSettings.shared.eaglePendingTasks = pending
                                }
                            }
                            print("⚠️ WallpaperManager: Added \(photoId) to Eagle pending queue.")
                        }
                    }
                    
                    var shouldSaveLocal = true
                    if pushedToEagle && eagleSkipLocalSave {
                        shouldSaveLocal = false
                    }
                    
                    if shouldSaveLocal {
                        // 存储到本地目录逻辑
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
                        let destPath = (saveDir as NSString).appendingPathComponent(fileName)
                        
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
    
    private func getOrCreateEagleWallpaperFolderId() async -> String? {
        guard let listUrl = URL(string: "http://localhost:41595/api/folder/list") else { return nil }
        
        do {
            var request = URLRequest(url: listUrl)
            request.timeoutInterval = 2.0
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let folders = json["data"] as? [[String: Any]] {
                
                func findFolderId(in list: [[String: Any]], targetName: String) -> String? {
                    for f in list {
                        let name = (f["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if name?.caseInsensitiveCompare(targetName) == .orderedSame {
                            if let id = f["id"] as? String { return id }
                        }
                        if let children = f["children"] as? [[String: Any]],
                           let childId = findFolderId(in: children, targetName: targetName) {
                            return childId
                        }
                    }
                    return nil
                }
                
                if let foundId = findFolderId(in: folders, targetName: "wallpaper") {
                    return foundId
                }
            }
        } catch {
            print("⚠️ WallpaperManager: Failed to list Eagle folders: \(error.localizedDescription)")
        }
        
        guard let createUrl = URL(string: "http://localhost:41595/api/folder/create") else { return nil }
        do {
            var request = URLRequest(url: createUrl)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 2.0
            let body: [String: Any] = ["folderName": "wallpaper"]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let folderData = json["data"] as? [String: Any],
               let newId = folderData["id"] as? String {
                return newId
            }
        } catch {
            print("⚠️ WallpaperManager: Failed to create Eagle folder: \(error.localizedDescription)")
        }
        
        return nil
    }
    
    private func pushToEagle(path: String, entry: WallpaperHistoryEntry, channel: String) async -> Bool {
        guard let url = URL(string: "http://localhost:41595/api/item/addFromPath") else { return false }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let name = (entry.title?.isEmpty == false) ? entry.title! : entry.photoId
        let website = "https://unsplash.com/photos/\(entry.photoId)"
        
        // 映射特定标签，不加默认的 Wallpaper / TaiChi
        var tags: [String] = []
        let lowerChannel = channel.lowercased()
        if lowerChannel.contains("hot_girl") || lowerChannel.contains("bikini") {
            tags.append("Girls")
        } else if lowerChannel.contains("cat") || lowerChannel.contains("animal") {
            tags.append("Animals")
        }
        
        var body: [String: Any] = [
            "path": path,
            "name": name,
            "tags": tags,
            "website": website,
            "annotation": entry.title ?? ""
        ]
        
        // 自动归类到 Eagle 中的 "wallpaper" 文件夹
        if let folderId = await getOrCreateEagleWallpaperFolderId() {
            body["folderId"] = folderId
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            // 设置一个较短的超时时间，防止Eagle假死导致卡住
            request.timeoutInterval = 3.0
            
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("✅ WallpaperManager: Successfully pushed wallpaper \(entry.photoId) to Eagle (tags: \(tags))!")
                return true
            } else {
                print("❌ WallpaperManager: Failed to push to Eagle, response: \(response)")
                return false
            }
        } catch {
            print("❌ WallpaperManager: Error pushing to Eagle: \(error.localizedDescription)")
            return false
        }
    }
    
    private func processEaglePendingQueue() async {
        let (useEagle, pendingTasks) = await MainActor.run {
            (TaiChiSettings.shared.useEagleForWallpapers, TaiChiSettings.shared.eaglePendingTasks)
        }
        guard useEagle, !pendingTasks.isEmpty else { return }
        
        let eagleRunning = NSWorkspace.shared.runningApplications.contains {
            $0.localizedName?.lowercased() == "eagle" || $0.bundleIdentifier?.lowercased().contains("eagle") == true
        }
        guard eagleRunning else { return }
        
        var remainingTasks: [WallpaperHistoryEntry] = []
        var processedCount = 0
        let cacheDir = ("~/.cache/taichi/wallpapers/" as NSString).expandingTildeInPath
        
        for entry in pendingTasks {
            let channelStr = entry.channelName ?? "unknown"
            let srcPath = (cacheDir as NSString).appendingPathComponent("\(entry.photoId).jpg")
            
            if FileManager.default.fileExists(atPath: srcPath) {
                let success = await pushToEagle(path: srcPath, entry: entry, channel: channelStr)
                if success {
                    processedCount += 1
                } else {
                    remainingTasks.append(entry)
                }
            } else {
                // If original file is missing, we drop it to avoid infinite retries
                print("⚠️ WallpaperManager: Dropping pending task \(entry.photoId) because source image is missing.")
            }
        }
        
        if processedCount > 0 || remainingTasks.count < pendingTasks.count {
            await MainActor.run {
                TaiChiSettings.shared.eaglePendingTasks = remainingTasks
            }
            print("✅ WallpaperManager: Processed \(processedCount) pending Eagle tasks.")
        }
    }
}
