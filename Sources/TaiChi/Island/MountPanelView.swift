import SwiftUI

struct MountPanelView: View {
    @StateObject private var diskMonitor = DiskMonitorManager.shared
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Mount")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal)
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
                            MountTargetRow(target: target, diskMonitor: diskMonitor)
                        }
                    }
                }
            }
        }
    }
}

struct MountTargetRow: View {
    var target: MountTarget
    @ObservedObject var diskMonitor: DiskMonitorManager
    @State private var isProcessing = false
    
    var body: some View {
        HStack {
            Circle()
                .fill(statusColor(for: target.state))
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(target.id)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                Text(target.type.rawValue.uppercased() + (!target.isActive && target.state == .disconnected ? " · 暂停" : ""))
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            if target.state == .retrying {
                HStack(spacing: 6) {
                    Button(action: {
                        isProcessing = true
                        diskMonitor.connect(id: target.id)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            isProcessing = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            if isProcessing {
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 10, height: 10)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.yellow)
                            }
                            Text("Retrying...")
                                .font(.system(size: 10))
                                .foregroundColor(.yellow)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(Color.yellow.opacity(0.15))
                        .cornerRadius(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Click to retry now")
                    .disabled(isProcessing)
                    
                    Button(action: {
                        diskMonitor.cancelRetry(id: target.id)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Cancel retry")
                }
            } else {
                Button(action: {
                    isProcessing = true
                    if target.state == .connected {
                        diskMonitor.disconnect(id: target.id)
                    } else {
                        diskMonitor.connect(id: target.id)
                    }
                    // Timeout fallback
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        isProcessing = false
                    }
                }) {
                    HStack(spacing: 4) {
                        if isProcessing {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                        }
                        Text(target.state == .connected ? "Unmount" : "Mount")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(target.state == .connected ? Color.red.opacity(0.8) : Color.blue.opacity(0.8))
                    .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isProcessing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .onChange(of: target.state) { _ in
            isProcessing = false
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
