import re

with open("Sources/TaiChi/Island/IslandManager.swift", "r") as f:
    content = f.read()

# Replace NSWindow( with NSPanel(
content = content.replace("let panel = NSWindow(", "let panel = NSPanel(")

# Replace makeKeyAndOrderFront(nil) with orderFront(nil)
content = content.replace("panel.makeKeyAndOrderFront(nil)", "panel.orderFront(nil)")

# Also, update the property declarations just to be safe (not strictly required if type inferred, but good practice)
# private var window: NSWindow? -> private var window: NSPanel?
content = content.replace("private var window: NSWindow?", "private var window: NSPanel?")
content = content.replace("private var lyricWindow: NSWindow?", "private var lyricWindow: NSPanel?")
content = content.replace("private var multiAppListWindow: NSWindow?", "private var multiAppListWindow: NSPanel?")

with open("Sources/TaiChi/Island/IslandManager.swift", "w") as f:
    f.write(content)
print("Patched IslandManager.swift")
