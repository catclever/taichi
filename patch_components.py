import sys

with open("Sources/TaiChi/Components_orb_button_clicks.swift.draft", "r") as f:
    content = f.read()

# 1. Update double click logic
old_double_click = """            if isDoubleClick {
                clickTask?.cancel()
                if shouldShowApp {
                    // Icon = App -> Double = Settings
                    openSettings()
                } else {
                    // Icon = TaiChi -> Double = App (if available)
                    if let app = lastApp {
                        onOpenApp?(app)
                    } else {
                        openSettings()
                    }
                }
            } else {"""
new_double_click = """            if isDoubleClick {
                clickTask?.cancel()
                openSettings()
            } else {"""
content = content.replace(old_double_click, new_double_click)

# 2. Append RightClick views at the bottom
right_click_code = """
struct RightClickCatcherView: NSViewRepresentable {
    var onRightClick: () -> Void
    func makeNSView(context: Context) -> RightClickNSView {
        let view = RightClickNSView()
        view.onRightClick = onRightClick
        return view
    }
    func updateNSView(_ nsView: RightClickNSView, context: Context) {}
}

class RightClickNSView: NSView {
    var onRightClick: (() -> Void)?
    override func rightMouseUp(with event: NSEvent) {
        onRightClick?()
    }
}
"""
content += "\n" + right_click_code

# 3. Add RightClickCatcherView background to SettingsButton's ZStack
old_zstack_end = """            }
            .scaleEffect(isHovered ? 1.1 : 1.0)"""
new_zstack_end = """            }
            .background(RightClickCatcherView {
                if shouldShowApp {
                    openSettings()
                } else {
                    if let app = lastApp {
                        onOpenApp?(app)
                    } else {
                        openSettings()
                    }
                }
            })
            .scaleEffect(isHovered ? 1.1 : 1.0)"""
content = content.replace(old_zstack_end, new_zstack_end)

with open("Sources/TaiChi/Components_orb_button_clicks.swift.draft", "w") as f:
    f.write(content)

