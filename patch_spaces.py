import re

# 1. Patch IslandManager.swift
with open("Sources/TaiChi/Island/IslandManager.swift", "r") as f:
    island_content = f.read()

# Remove .canJoinAllSpaces
island_content = island_content.replace(".canJoinAllSpaces, ", "")

# Change initial NSRect to avoid x: 0
island_content = island_content.replace("NSRect(x: 0, y: 0, width: 800, height: 200)", "NSRect(x: 500, y: 1000, width: 800, height: 200)")
island_content = island_content.replace("NSRect(x: 0, y: 0, width: 400, height: 100)", "NSRect(x: 500, y: 1000, width: 400, height: 100)")
island_content = island_content.replace("NSRect(x: 0, y: 0, width: 300, height: 400)", "NSRect(x: 500, y: 1000, width: 300, height: 400)")

with open("Sources/TaiChi/Island/IslandManager.swift", "w") as f:
    f.write(island_content)

# 2. Patch TaiChi.swift
with open("Sources/TaiChi/TaiChi.swift", "r") as f:
    taichi_content = f.read()

# Remove .canJoinAllSpaces
taichi_content = taichi_content.replace(".canJoinAllSpaces, ", "")

with open("Sources/TaiChi/TaiChi.swift", "w") as f:
    f.write(taichi_content)

print("Patched IslandManager.swift and TaiChi.swift")
