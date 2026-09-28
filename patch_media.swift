import Foundation

let path = "Sources/TaiChi/Island/MediaObserver.swift"
var content = try! String(contentsOfFile: path, encoding: .utf8)

// 1. Fix sendCommand to use Bundle.main.resourcePath directly for MediaRemoteAdapter
let oldSendCommandStart = """
    func sendCommand(_ commandId: Int, targetBundleId: String? = nil) {
        guard let resourcePath = Bundle.module.resourcePath else { return }
        
        let process = Process()
"""
let newSendCommandStart = """
    func sendCommand(_ commandId: Int, targetBundleId: String? = nil) {
        guard let mainResPath = Bundle.main.resourcePath else { return }
        let resourcePath = mainResPath
        
        let process = Process()
"""
content = content.replacingOccurrences(of: oldSendCommandStart, with: newSendCommandStart)

// 2. Fix sendTargetedCommand to use sendCommand instead of simulateMediaKey
let oldSendTargeted = """
        // 3. Fallback to global broadcast using hardware keys (more robust than MR for suspended apps)
        print("ℹ️ [MediaObserver] Sending global broadcast command \\(commandId) via hardware key simulation")
        simulateMediaKey(commandId)
"""
let newSendTargeted = """
        if bundleId.isEmpty {
            print("ℹ️ [MediaObserver] BundleID is empty, simulating hardware media key as global fallback.")
            simulateMediaKey(commandId)
            return
        }
        
        // 3. Fallback to targeted MR command
        print("ℹ️ [MediaObserver] Sending targeted MR command \\(commandId) to \\(bundleId)")
        sendCommand(commandId, targetBundleId: bundleId)
"""
content = content.replacingOccurrences(of: oldSendTargeted, with: newSendTargeted)

try! content.write(toFile: path, atomically: true, encoding: .utf8)
print("Patched MediaObserver.swift")
