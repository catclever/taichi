import sys

with open("Sources/TaiChi/Island/IslandView_mutagen_panel.swift.draft", "r") as f:
    content = f.read()

replacement1 = """
                    if stateModel.currentMode == .media {
                        ExpandedPanelView()
                    } else if stateModel.currentMode == .disk {
                        MountPanelView()
                    } else if stateModel.currentMode == .mutagen {
                        MutagenPanelView()
                    }
"""
content = content.replace("""
                    if stateModel.currentMode == .media {
                        ExpandedPanelView()
                    } else {
                        MountPanelView()
                    }
""", replacement1)

replacement2 = """
            case .expanded:
                stateModel.capsuleWidth = 380
                if stateModel.currentMode == .disk {
                    stateModel.capsuleHeight = 200
                } else if stateModel.currentMode == .mutagen {
                    stateModel.capsuleHeight = 250
                } else {
                    stateModel.capsuleHeight = 160
                }
"""
content = content.replace("""
            case .expanded:
                stateModel.capsuleWidth = 380
                stateModel.capsuleHeight = stateModel.currentMode == .disk ? 200 : 160
""", replacement2)

with open("Sources/TaiChi/Island/IslandView_mutagen_panel.swift.draft", "w") as f:
    f.write(content)
