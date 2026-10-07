import SwiftUI


struct ModeSwitcherView: View {
    @StateObject private var stateModel = IslandStateModel.shared
    
    var body: some View {
        HStack(spacing: 30) {
            ModeButton(
                iconName: "music.note",
                title: "Media",
                isSelected: stateModel.currentMode == .media,
                action: {
                    withAnimation {
                        stateModel.currentMode = .media
                        stateModel.state = .expanded
                    }
                }
            )
            
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
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 40)
    }
}

struct ModeButton: View {
    let iconName: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovering = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 24))
                    .foregroundColor(isSelected ? .white : .gray)
                
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? .white : .gray)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(isSelected ? 0.2 : (isHovering ? 0.1 : 0.0)))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
