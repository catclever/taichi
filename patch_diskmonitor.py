with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/Island/DiskMonitorManager.swift", "r") as f:
    content = f.read()

content = content.replace("IslandManager.shared.pushState(.text(\"✅ 已连接: \\(targets[index].id)\"))", "print(\"✅ 已连接: \\(targets[index].id)\")")
content = content.replace("IslandManager.shared.pushState(.text(\"⚠️ 断开: \\(targets[index].id)\"))", "print(\"⚠️ 断开: \\(targets[index].id)\")")

content = content.replace("self?.handleMountEvent(url: volumeURL)", "Task { @MainActor in self?.handleMountEvent(url: volumeURL) }")
content = content.replace("self?.handleUnmountEvent(url: volumeURL)", "Task { @MainActor in self?.handleUnmountEvent(url: volumeURL) }")

with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/Island/DiskMonitorManager.swift", "w") as f:
    f.write(content)
