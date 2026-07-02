import Foundation
import SwiftUI
import Combine

struct MediaState: Equatable {
    var title: String = ""
    var artist: String = ""
    var isPlaying: Bool = false
    var artworkData: Data? = nil
    var bundleIdentifier: String = ""
    var duration: Double = 0
    var elapsedTime: Double = 0
    var debugInfo: String = ""
}

class MediaObserver: ObservableObject, @unchecked Sendable {
    static let shared = MediaObserver()
    @Published var state = MediaState()
    
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    
    init() {
        startStreaming()
    }
    
    deinit {
        stopStreaming()
    }
    
    private func startStreaming() {
        guard let resourcePath = Bundle.main.resourcePath else { return }
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
                if let elapsedTime = payload.elapsedTime { newState.elapsedTime = elapsedTime }
                if let playing = payload.playing { newState.isPlaying = playing }
                if let bundle = payload.bundleIdentifier { newState.bundleIdentifier = bundle }
                
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
}
