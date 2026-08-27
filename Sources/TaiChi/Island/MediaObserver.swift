import Foundation
import SwiftUI
import Combine

struct ActiveMediaApp: Equatable, Identifiable {
    var id: String { bundleIdentifier }
    var bundleIdentifier: String
    var name: String
    var isPlaying: Bool
    var playStateString: String = "unknown"
    var title: String?
}

struct MediaState: Equatable {
    var title: String = ""
    var artist: String = ""
    var isPlaying: Bool = false
    var artworkData: Data? = nil
    var bundleIdentifier: String = ""
    var duration: Double = 0
    var elapsedTime: Double = 0
    var lastElapsedTimeUpdate: Date = Date()
    var mediaType: String? = nil
    var debugInfo: String = ""
    
    var currentElapsedTime: Double {
        guard duration > 0 else { return 0 }
        if isPlaying {
            return min(duration, elapsedTime + Date().timeIntervalSince(lastElapsedTimeUpdate))
        } else {
            return elapsedTime
        }
    }
}

class MediaObserver: ObservableObject, @unchecked Sendable {
    static let shared = MediaObserver()
    @Published var state = MediaState()
    @Published var activeMediaApps: [ActiveMediaApp] = []
    
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    private var pollerTimer: Timer?
    
    init() {
        startStreaming()
        startPoller()
    }
    
    deinit {
        stopStreaming()
    }
    
    private func startStreaming() {
        guard let resourcePath = Bundle.module.resourcePath else { return }
        let adapterPath = resourcePath + "/MediaRemoteAdapter/mediaremote-adapter.pl"
        let frameworkPath = resourcePath + "/MediaRemoteAdapter/MediaRemoteAdapter.framework"
        
        process = Process()
        process?.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process?.arguments = [adapterPath, frameworkPath, "stream"]
        
        pipe = Pipe()
        process?.standardOutput = pipe
        
        pipe?.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.processData(data)
        }
        
        do {
            try process?.run()
        } catch {
            print("Failed to run perl script: \(error)")
        }
    }
    
    private func stopStreaming() {
        process?.terminate()
        pipe?.fileHandleForReading.readabilityHandler = nil
    }
    
    private func startPoller() {
        pollerTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollMediaApps()
        }
    }
    
    private func stopPoller() {
        pollerTimer?.invalidate()
        pollerTimer = nil
    }
    
    private func pollMediaApps() {
        Task { @MainActor in
            let configuredApps = TaiChiSettings.shared.mediaApps
            guard !configuredApps.isEmpty else {
                if !self.activeMediaApps.isEmpty {
                    self.activeMediaApps = []
                }
                return
            }
            
            // Background the heavy lifting
            Task.detached {
                self.performPolling(configuredApps: configuredApps)
            }
        }
    }
    
    private func performPolling(configuredApps: [MediaApp]) {
        let runningApps = NSWorkspace.shared.runningApplications
        var newActiveApps: [ActiveMediaApp] = []
        
        for app in configuredApps {
            if runningApps.contains(where: { $0.bundleIdentifier == app.id }) {
                // Determine play state via AppleScript
                let scriptSource = """
                tell application id "\(app.id)"
                    set playState to player state as string
                    set trackName to name of current track as string
                    return playState & "|" & trackName
                end tell
                """
                
                var isPlaying = false
                var title: String? = nil
                var playStateString = "unknown"
                
                if let script = NSAppleScript(source: scriptSource) {
                    var errorInfo: NSDictionary?
                    let result = script.executeAndReturnError(&errorInfo)
                    
                    if errorInfo == nil, let output = result.stringValue {
                        let parts = output.components(separatedBy: "|")
                        if parts.count >= 1 {
                            playStateString = parts[0].lowercased()
                            isPlaying = playStateString == "playing"
                        }
                        if parts.count >= 2 {
                            title = parts[1]
                        }
                    }
                }
                
                newActiveApps.append(ActiveMediaApp(bundleIdentifier: app.id, name: app.name, isPlaying: isPlaying, playStateString: playStateString, title: title))
            }
        }
        
        DispatchQueue.main.async {
            self.activeMediaApps = newActiveApps
        }
    }
    
    private func processData(_ data: Data) {
        buffer.append(data)
        
        // Split by newline
        while let range = buffer.firstRange(of: Data("\n".utf8)) {
            let lineData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            
            if let str = String(data: lineData, encoding: .utf8), !str.isEmpty {
                parseJSON(str)
            }
        }
    }
    
    private struct StreamMessage: Decodable {
        let type: String?
        let diff: Bool?
        let payload: AdapterPayload?
    }

    private struct AdapterPayload: Decodable {
        let bundleIdentifier: String?
        let playing: Bool?
        let title: String?
        let artist: String?
        let duration: Double?
        let elapsedTime: Double?
        let playbackRate: Double?
        let artworkData: String?
        let mediaType: String?
    }
    
    private func parseJSON(_ jsonStr: String) {
        guard let data = jsonStr.data(using: .utf8) else { return }
        do {
            let decoder = JSONDecoder()
            let message = try decoder.decode(StreamMessage.self, from: data)
            guard message.type == "data", let payload = message.payload else { return }
            
            DispatchQueue.main.async {
                var newState = self.state
                
                if let title = payload.title { newState.title = title }
                if let artist = payload.artist { newState.artist = artist }
                if let duration = payload.duration { newState.duration = duration }
                if let elapsedTime = payload.elapsedTime {
                    newState.elapsedTime = elapsedTime
                    newState.lastElapsedTimeUpdate = Date()
                }
                if let playing = payload.playing {
                    newState.isPlaying = playing
                    newState.lastElapsedTimeUpdate = Date() // Reset on play/pause too to keep it accurate
                }
                if let bundle = payload.bundleIdentifier { newState.bundleIdentifier = bundle }
                if let mediaType = payload.mediaType { newState.mediaType = mediaType }
                
                if let base64 = payload.artworkData {
                    if base64.isEmpty {
                        newState.artworkData = nil
                    } else if let imgData = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) {
                        newState.artworkData = imgData
                    }
                }
                
                if let rate = payload.playbackRate {
                    newState.isPlaying = rate > 0
                }
                
                newState.debugInfo = "Stream [diff:\(message.diff ?? false)] - Playing: \(newState.isPlaying)"
                
                self.state = newState
            }
        } catch {
            print("Error parsing json: \(error)")
        }
    }
    
    func sendCommand(_ commandId: Int, targetBundleId: String? = nil) {
        guard let resourcePath = Bundle.module.resourcePath else { return }
        
        let process = Process()
        
        if let targetBundleId = targetBundleId, !targetBundleId.isEmpty {
            let mrTargetPath = resourcePath + "/MediaRemoteAdapter/mr_target"
            process.executableURL = URL(fileURLWithPath: mrTargetPath)
            process.arguments = ["\(commandId)", targetBundleId]
        } else {
            let adapterPath = resourcePath + "/MediaRemoteAdapter/mediaremote-adapter.pl"
            let frameworkPath = resourcePath + "/MediaRemoteAdapter/MediaRemoteAdapter.framework"
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [adapterPath, frameworkPath, "send", "\(commandId)"]
        }
        
        do {
            try process.run()
        } catch {
            print("Failed to run sendCommand: \(error)")
        }
    }
    
    func toggleApp(bundleId: String) {
        let supportedApps = ["com.apple.Music", "com.spotify.client", "com.netease.163music", "com.tencent.QQMusicMac"]
        if supportedApps.contains(bundleId) {
            let scriptSource = "tell application id \"\(bundleId)\" to playpause"
            if let script = NSAppleScript(source: scriptSource) {
                var errorInfo: NSDictionary?
                script.executeAndReturnError(&errorInfo)
                if errorInfo == nil {
                    return
                } else {
                    print("⚠️ [MediaObserver] toggleApp AppleScript failed for \(bundleId): \(errorInfo?.description ?? "unknown error").")
                }
            }
        }
        
        // 1. Try custom cyber media handler (registered by frontend)
        if let script = ServerManager.shared.getCyberMediaHandler(appId: bundleId, command: "playpause") {
            DispatchQueue.global().async {
                _ = ServerManager.shared.evaluateCyberScript(appId: bundleId, script: script)
            }
            return
        }
        
        // 2. Fallback to targeted MR command
        sendCommand(2, targetBundleId: bundleId.isEmpty ? nil : bundleId)
    }
    
    func sendTargetedCommand(_ commandId: Int) {
        let bundleId = state.bundleIdentifier ?? ""
        
        let commandKey: String
        switch commandId {
        case 2: commandKey = "playpause"
        case 4: commandKey = "next"
        case 5: commandKey = "prev"
        default: commandKey = ""
        }
        
        // 1. Check custom cyber media handler (registered by frontend)
        if !commandKey.isEmpty && !bundleId.isEmpty {
            if let script = ServerManager.shared.getCyberMediaHandler(appId: bundleId, command: commandKey) {
                print("✅ [MediaObserver] Executing registered cyber media handler for '\(commandKey)' on \(bundleId)")
                DispatchQueue.global().async {
                    _ = ServerManager.shared.evaluateCyberScript(appId: bundleId, script: script)
                }
                return
            }
        }
        
        let supportedApps = ["com.apple.Music", "com.spotify.client", "com.netease.163music", "com.tencent.QQMusicMac"]
        
        // 2. If it's a supported app, try AppleScript first
        if supportedApps.contains(bundleId) {
            let scriptCommand: String
            switch commandId {
            case 2: scriptCommand = "playpause"
            case 4: scriptCommand = "next track"
            case 5: scriptCommand = "previous track"
            default: scriptCommand = ""
            }
            
            if !scriptCommand.isEmpty {
                let scriptSource = "tell application id \"\(bundleId)\" to \(scriptCommand)"
                if let script = NSAppleScript(source: scriptSource) {
                    var errorInfo: NSDictionary?
                    script.executeAndReturnError(&errorInfo)
                    if errorInfo == nil {
                        print("✅ [MediaObserver] Successfully sent targeted command '\(scriptCommand)' to \(bundleId)")
                        return
                    } else {
                        print("⚠️ [MediaObserver] Targeted AppleScript failed for \(bundleId): \(errorInfo?.description ?? "unknown error"). Falling back to MR.")
                    }
                }
            }
        }
        
        // 3. Fallback to targeted MR command, no global broadcast
        print("ℹ️ [MediaObserver] Sending targeted MR command \(commandId) to \(bundleId.isEmpty ? "global" : bundleId)")
        sendCommand(commandId, targetBundleId: bundleId.isEmpty ? nil : bundleId)
    }
    
    func seek(to time: Double) {
        guard let resourcePath = Bundle.module.resourcePath else { return }
        let adapterPath = resourcePath + "/MediaRemoteAdapter/mediaremote-adapter.pl"
        let frameworkPath = resourcePath + "/MediaRemoteAdapter/MediaRemoteAdapter.framework"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [adapterPath, frameworkPath, "seek", "\(time)"]
        
        do {
            try process.run()
        } catch {
            print("Failed to run seek: \(error)")
        }
    }
}
