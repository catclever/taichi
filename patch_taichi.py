with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/TaiChi.swift", "r") as f:
    content = f.read()

content = content.replace("IslandManager.shared.setup()", "IslandManager.shared.setup()\n        _ = DiskMonitorManager.shared")

with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/TaiChi.swift", "w") as f:
    f.write(content)
