import re

with open("Sources/TaiChi/Island/IslandManager.swift", "r") as f:
    content = f.read()

# Replace NSHostingView(rootView: with AcceptingFirstMouseHostingView(rootView:
content = content.replace("let hostView = NSHostingView(rootView:", "let hostView = AcceptingFirstMouseHostingView(rootView:")

with open("Sources/TaiChi/Island/IslandManager.swift", "w") as f:
    f.write(content)
print("Patched IslandManager.swift with AcceptingFirstMouseHostingView")
