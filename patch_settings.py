import sys

with open("Sources/TaiChi/SettingsView_mutagen_panel.swift.draft", "r") as f:
    content = f.read()

replacement = """
            Section(header: Text("网络硬盘及同步 (Disk & Sync)").font(.headline)) {
                DiskMonitorTab()
                
                HStack {
                    Toggle("开启 Mutagen 同步面板", isOn: $settings.enableMutagen)
                        .disabled(!hasMutagen)
                    
                    Spacer()
                    if !hasMutagen {
                        Text("未安装 Mutagen CLI")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
"""

content = content.replace("""
            Section(header: Text("网络硬盘监控").font(.headline)) {
                DiskMonitorTab()
            }
""", replacement)

# Add state variable hasMutagen
state_replacement = """
    @State private var selectedTab: String = "basic"
    @State private var hasMutagen: Bool = false
"""
content = content.replace("""
    @State private var selectedTab: String = "basic"
""", state_replacement)

# Add check in onAppear
onAppear_replacement = """
        .onAppear {
            checkHammerspoon()
            checkMutagen()
        }
"""
content = content.replace("""
        .onAppear {
            checkHammerspoon()
        }
""", onAppear_replacement)

# Add method checkMutagen
check_mutagen_method = """
    private func checkHammerspoon() {
        if let _ = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.hammerspoon.Hammerspoon") {
            hasHammerspoon = true
        } else {
            hasHammerspoon = false
        }
    }
    
    private func checkMutagen() {
        // Use MutagenManager to check install status
        // Since we are in SettingsView which is outside Island folder, we should be able to access MutagenManager if it's public/internal
        hasMutagen = MutagenManager.shared.checkInstallStatus()
        if !hasMutagen {
            settings.enableMutagen = false
        }
    }
"""
content = content.replace("""
    private func checkHammerspoon() {
        if let _ = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.hammerspoon.Hammerspoon") {
            hasHammerspoon = true
        } else {
            hasHammerspoon = false
        }
    }
""", check_mutagen_method)


with open("Sources/TaiChi/SettingsView_mutagen_panel.swift.draft", "w") as f:
    f.write(content)
