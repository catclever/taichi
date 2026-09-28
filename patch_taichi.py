import re

with open("Sources/TaiChi/TaiChi.swift", "r") as f:
    content = f.read()

content = content.replace("customWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]", "customWindow.collectionBehavior = [.stationary, .ignoresCycle]")

with open("Sources/TaiChi/TaiChi.swift", "w") as f:
    f.write(content)
