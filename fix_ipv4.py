with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/ServerManager.swift", "r") as f:
    content = f.read()

content = content.replace("try server.start(port)", "try server.start(port, forceIPv4: true)")

with open("/Users/kael/Projects/taichi_launcher/Sources/TaiChi/ServerManager.swift", "w") as f:
    f.write(content)
