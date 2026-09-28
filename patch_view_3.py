with open("Sources/TaiChi/Island/IslandView.swift", "r") as f:
    content = f.read()

import re

# Remove the isNotchHovered onChange we added previously
content = re.sub(r'        \.onChange\(of: stateModel\.isNotchHovered\) \{ isNotchHovered in.*?        \.onChange\(of: stateModel\.isHovering\)', '        .onChange(of: stateModel.isHovering)', content, flags=re.DOTALL)

# Add the logic in handleHover and a new onChange for isNotchHovered
new_onchange = """        .onChange(of: stateModel.isNotchHovered) { isNotchHovered in
            hoverTimer?.invalidate()
            if isNotchHovered && stateModel.state == .trackChanged && !mediaObserver.state.title.isEmpty {
                // Instantly expand if they actively move into the notch from stage 1?
                // Wait, if they just transitioned to stage 1, they didn't actively move into the notch.
                // Let's just use a 0.5s timer so there's a slight delay, making it feel like a smooth 2-stage interaction.
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                    Task { @MainActor in
                        if self.stateModel.isNotchHovered && self.stateModel.state == .trackChanged {
                            self.stateModel.currentMode = .media
                            withAnimation {
                                self.stateModel.state = .expanded
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: stateModel.state) { newState in
            if newState == .trackChanged && stateModel.isNotchHovered && !mediaObserver.state.title.isEmpty {
                hoverTimer?.invalidate()
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                    Task { @MainActor in
                        if self.stateModel.isNotchHovered && self.stateModel.state == .trackChanged {
                            self.stateModel.currentMode = .media
                            withAnimation {
                                self.stateModel.state = .expanded
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: stateModel.isHovering)"""

content = content.replace("        .onChange(of: stateModel.isHovering)", new_onchange)

with open("Sources/TaiChi/Island/IslandView.swift", "w") as f:
    f.write(content)
print("Patched View 3")
