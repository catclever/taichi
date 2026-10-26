import SwiftUI

struct MutagenPanelView: View {
    @StateObject private var mutagenManager = MutagenManager.shared
    @State private var timer: Timer?
    @State private var activeActionSessionId: String? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerBar
            
            ScrollView {
                if mutagenManager.sessions.isEmpty {
                    Text("No active sessions")
                        .foregroundColor(.gray)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    VStack(spacing: 8) {
                        ForEach(mutagenManager.sessions) { session in
                            sessionCard(for: session)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            mutagenManager.fetchSessions()
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                Task { @MainActor in
                    mutagenManager.fetchSessions()
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
    
    private var headerBar: some View {
        HStack {
            Text("Mutagen")
                .font(.headline)
                .foregroundColor(.white)
            
            Spacer()
            
            HStack(spacing: 10) {
                Button(action: {
                    mutagenManager.resumeAll()
                }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(PlainButtonStyle())
                .help("全部开始")
                
                Button(action: {
                    mutagenManager.pauseAll()
                }) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(PlainButtonStyle())
                .help("全部暂停")
                
                Button(action: {
                    MutagenWindowManager.shared.show()
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.gray)
                }
                .buttonStyle(PlainButtonStyle())
                .help("配置")
            }
        }
        .padding(.horizontal)
        .padding(.top, 16)
    }
    
    @ViewBuilder
    private func sessionCard(for session: MutagenSession) -> some View {
        HStack {
            Text(session.name ?? session.identifier)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
            
            Spacer()
            
            if activeActionSessionId == session.id {
                actionButtons(for: session)
            } else {
                statusBadge(for: session)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal)
        .contentShape(Rectangle())
        .onTapGesture {
            activeActionSessionId = (activeActionSessionId == session.id) ? nil : session.id
        }
    }
    
    @ViewBuilder
    private func actionButtons(for session: MutagenSession) -> some View {
        HStack(spacing: 12) {
            Button(action: {
                mutagenManager.togglePause(session: session)
            }) {
                Image(systemName: (session.paused == true) ? "play.fill" : "pause.fill")
                    .foregroundColor(.white)
            }
            .buttonStyle(PlainButtonStyle())
            
            Button(action: {
                mutagenManager.terminateAndArchive(session: session)
                activeActionSessionId = nil
            }) {
                Image(systemName: "stop.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(PlainButtonStyle())
            
            Button(action: {
                MutagenWindowManager.shared.show(for: session.id)
            }) {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.gray)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
    
    @ViewBuilder
    private func statusBadge(for session: MutagenSession) -> some View {
        if session.hasConflicts {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                Text("\(session.conflictCount)")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(.red)
        } else {
            HStack(spacing: 4) {
                let isWatching = session.status?.lowercased().contains("watching") ?? false
                Text(session.status ?? "Unknown")
                    .font(.caption)
                    .foregroundColor(isWatching ? .green : .orange)
                
                if session.paused == true {
                    Text("(Paused)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }
}
