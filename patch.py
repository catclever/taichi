with open("Sources/TaiChi/SettingsView.swift", "r") as f:
    content = f.read()

content = content.replace("SystemSettingsTab()", "SystemSettingsTab(hasMutagen: $hasMutagen)")
content = content.replace(
    "struct SystemSettingsTab: View {\\n    @ObservedObject var settings",
    "struct SystemSettingsTab: View {\\n    @Binding var hasMutagen: Bool\\n    @ObservedObject var settings"
)

with open("Sources/TaiChi/SettingsView_mutagen_panel.swift.draft", "w") as f:
    f.write(content)
