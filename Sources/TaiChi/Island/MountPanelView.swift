import SwiftUI

struct MountPanelView: View {
    @StateObject private var diskMonitor = DiskMonitorManager.shared
    
    var body: some View {
        VStack(spacing: 8) {
            Text("Mount Status")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 4) {
                    if diskMonitor.targets.isEmpty {
                        Text("No active mounts")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                            .padding(.top, 10)
                    } else {
                        ForEach(diskMonitor.targets) { target in
                            HStack {
                                Circle()
                                    .fill(statusColor(for: target.state))
                                    .frame(width: 8, height: 8)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(target.id)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.white)
                                    Text(target.type.rawValue.uppercased())
                                        .font(.system(size: 10))
                                        .foregroundColor(.gray)
                                }
                                
                                Spacer()
                                
                                if target.state == .retrying {
                                    Text("Retrying...")
                                        .font(.system(size: 10))
                                        .foregroundColor(.yellow)
                                } else {
                                    Button(action: {
                                        if target.state == .connected {
                                            diskMonitor.disconnect(id: target.id)
                                        } else {
                                            diskMonitor.connect(id: target.id)
                                        }
                                    }) {
                                        Text(target.state == .connected ? "Disconnect" : "Connect")
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(target.state == .connected ? Color.red.opacity(0.3) : Color.blue.opacity(0.3))
                                            .cornerRadius(6)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }
    
    private func statusColor(for state: MountState) -> Color {
        switch state {
        case .connected: return .green
        case .disconnected: return .red
        case .retrying: return .yellow
        }
    }
}
