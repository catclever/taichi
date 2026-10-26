import SwiftUI


struct DiskMonitorTab: View {
    @ObservedObject var settings = TaiChiSettings.shared
    @State private var showingAddAlert = false
    @State private var newRemote = ""
    @State private var isAdding = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !isAdding {
                List {
                    ForEach(settings.activeSMBMounts, id: \.id) { mount in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(mount.id).font(.headline)
                                Text(mount.remotePath).font(.caption).foregroundColor(.gray)
                            }
                            Spacer()
                            Button(action: {
                                settings.activeSMBMounts.removeAll { $0.id == mount.id }
                                DiskMonitorManager.shared.removeTarget(id: mount.id)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.vertical, 4)
                    }
                    
                    Button(action: {
                        isAdding = true
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Mount")
                        }
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.vertical, 8)
                }
                .frame(minHeight: 200)
                .border(Color.gray.opacity(0.2))
            } else {
                VStack(spacing: 16) {
                    Text("Connect to Server")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(spacing: 12) {
                        HStack {
                            Text("Address:").frame(width: 70, alignment: .trailing)
                            TextField("", text: $newRemote, prompt: Text("smb://192.168..."))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            newRemote = ""
                            isAdding = false
                        }
                        Button("Connect") {
                            guard !newRemote.isEmpty, let url = URL(string: newRemote) else { return }
                            NSWorkspace.shared.open(url)
                            
                            newRemote = ""
                            isAdding = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .frame(minHeight: 120)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
            }
        }
        .padding()
        .onAppear {
            for mount in settings.activeSMBMounts {
                DiskMonitorManager.shared.registerTarget(id: mount.id, localPath: mount.localPath, remotePath: mount.remotePath, type: .smb, isActive: true)
            }
        }
    }
}
