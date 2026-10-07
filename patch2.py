import sys

with open("Sources/TaiChi/SettingsView.swift", "r") as f:
    content = f.read()

content = content.replace(
    "struct SystemSettingsTab: View {\n    @ObservedObject var settings = TaiChiSettings.shared",
    "struct SystemSettingsTab: View {\n    @Binding var hasMutagen: Bool\n    @ObservedObject var settings = TaiChiSettings.shared"
)

# And write it to the draft file!
with open("Sources/TaiChi/SettingsView_mutagen_panel.swift.draft", "w") as f:
    f.write(content)

