import SwiftUI

struct DiskMonitorTab: View {
    @ObservedObject var settings = TaiChiSettings.shared
    @State private var showingAddAlert = false
    @State private var newId = ""
    @State private var newRemote = ""
    @State private var newLocal = ""
    @State private var autoSyncFields = true
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
                    Text("Add New Mount")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(spacing: 12) {
                        HStack {
                            Text("Remote:").frame(width: 60, alignment: .trailing)
                            TextField("//guest:@192...", text: $newRemote)
                                .onChange(of: newRemote) { newValue in
                                    let parts = newValue.split(separator: "/", omittingEmptySubsequences: true)
                                    let shareName = String(parts.last ?? "")
                                    
                                    if autoSyncFields {
                                        newId = shareName
                                        if !shareName.isEmpty {
                                            newLocal = "/Volumes/\(shareName)"
                                        } else {
                                            newLocal = ""
                                        }
                                    } else if newId.isEmpty && newLocal.isEmpty {
                                        autoSyncFields = true
                                        newId = shareName
                                        if !shareName.isEmpty {
                                            newLocal = "/Volumes/\(shareName)"
                                        }
                                    }
                                }
                        }
                            
                        HStack {
                            Text("Name:").frame(width: 60, alignment: .trailing)
                            TextField("Name", text: $newId)
                                .onChange(of: newId) { newValue in
                                    let expectedShareName = String(newRemote.split(separator: "/", omittingEmptySubsequences: true).last ?? "")
                                    if newValue != expectedShareName && !newValue.isEmpty {
                                        autoSyncFields = false
                                    }
                                }
                        }
                            
                        HStack {
                            Text("Local:").frame(width: 60, alignment: .trailing)
                            TextField("/Volumes/...", text: $newLocal)
                                .onChange(of: newLocal) { newValue in
                                    let expectedShareName = String(newRemote.split(separator: "/", omittingEmptySubsequences: true).last ?? "")
                                    let expectedLocal = expectedShareName.isEmpty ? "" : "/Volumes/\(expectedShareName)"
                                    if newValue != expectedLocal && !newValue.isEmpty {
                                        autoSyncFields = false
                                    }
                                }
                        }
                    }
                    
                    HStack {
                        Spacer()
                        Button("Cancel") {
                            newId = ""
                            newRemote = ""
                            newLocal = ""
                            autoSyncFields = true
                            isAdding = false
                        }
                        Button("Add") {
                            guard !newId.isEmpty, !newRemote.isEmpty, !newLocal.isEmpty else { return }
                            let newMount = SMBMountConfig(id: newId, remotePath: newRemote, localPath: newLocal)
                            settings.activeSMBMounts.append(newMount)
                            DiskMonitorManager.shared.registerTarget(id: newId, localPath: newLocal, remotePath: newRemote, type: .smb, isActive: true)
                            
                            newId = ""
                            newRemote = ""
                            newLocal = ""
                            autoSyncFields = true
                            isAdding = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
                .frame(minHeight: 200)
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
