with open("Package.swift", "r") as f:
    content = f.read()

content = content.replace("swiftLanguageModes: [.v6]", "")

with open("Package.swift", "w") as f:
    f.write(content)
