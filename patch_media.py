with open("Sources/TaiChi/Island/MediaObserver.swift", "r") as f:
    content = f.read()

old_sc = """    func sendCommand(_ commandId: Int, targetBundleId: String? = nil) {
        guard let resourcePath = Bundle.module.resourcePath else { return }"""

new_sc = """    func sendCommand(_ commandId: Int, targetBundleId: String? = nil) {
        guard let resourcePath = Bundle.main.resourcePath else { return }"""

content = content.replace(old_sc, new_sc)

old_st = """        // 3. Fallback to global broadcast using hardware keys (more robust than MR for suspended apps)
        print("ℹ️ [MediaObserver] Sending global broadcast command \(commandId) via hardware key simulation")
        simulateMediaKey(commandId)"""

new_st = """        if bundleId.isEmpty {
            print("ℹ️ [MediaObserver] BundleID is empty, simulating hardware media key as global fallback.")
            simulateMediaKey(commandId)
            return
        }
        
        // 3. Fallback to targeted MR command
        print("ℹ️ [MediaObserver] Sending targeted MR command \(commandId) to \(bundleId)")
        sendCommand(commandId, targetBundleId: bundleId)"""

content = content.replace(old_st, new_st)

with open("Sources/TaiChi/Island/MediaObserver.swift", "w") as f:
    f.write(content)
print("Patched Python")
