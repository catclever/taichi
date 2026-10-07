import sys

with open("Sources/TaiChi/Island/ModeSwitcherView_mutagen_panel.swift.draft", "r") as f:
    content = f.read()

replacement = """
            ModeButton(
                iconName: "externaldrive",
                title: "Drives",
                isSelected: stateModel.currentMode == .disk,
                action: {
                    withAnimation {
                        stateModel.currentMode = .disk
                        stateModel.state = .expanded
                    }
                }
            )
            
            if TaiChiSettings.shared.enableMutagen {
                ModeButton(
                    iconName: "arrow.triangle.2.circlepath",
                    title: "Mutagen",
                    isSelected: stateModel.currentMode == .mutagen,
                    action: {
                        withAnimation {
                            stateModel.currentMode = .mutagen
                            stateModel.state = .expanded
                        }
                    }
                )
            }
"""

content = content.replace("""
            ModeButton(
                iconName: "externaldrive",
                title: "Drives",
                isSelected: stateModel.currentMode == .disk,
                action: {
                    withAnimation {
                        stateModel.currentMode = .disk
                        stateModel.state = .expanded
                    }
                }
            )
""", replacement)

with open("Sources/TaiChi/Island/ModeSwitcherView_mutagen_panel.swift.draft", "w") as f:
    f.write(content)
