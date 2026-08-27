import SwiftUI
import Cocoa

struct MultiAppListView: View {
    @ObservedObject var mediaObserver = MediaObserver.shared
    @ObservedObject var stateModel = IslandStateModel.shared
    
    var body: some View {
        VStack(spacing: 0) {
            let activeApps = mediaObserver.activeMediaApps.filter { app in
                getEffectivePlayState(app) != "unknown"
            }
            ForEach(activeApps) { app in
                let effectiveState = getEffectivePlayState(app)
                HStack(spacing: 12) {
                    if let appIcon = getAppIcon(bundleId: app.bundleIdentifier) {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 24, height: 24)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 24, height: 24)
                            .cornerRadius(6)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        if let title = app.title, !title.isEmpty {
                            Text(title)
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    
                    Spacer()
                    
                    if effectiveState == "playing" || effectiveState == "paused" {
                        Button(action: {
                            mediaObserver.toggleApp(bundleId: app.bundleIdentifier)
                        }) {
                            Image(systemName: effectiveState == "playing" ? "pause.fill" : "play.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                
                if app.id != mediaObserver.activeMediaApps.last?.id {
                    Divider()
                        .background(Color.white.opacity(0.1))
                        .padding(.horizontal, 16)
                }
            }
        }
        .padding(.vertical, 10)
    }
    
    private func getAppIcon(bundleId: String) -> NSImage? {
        guard !bundleId.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
    
    private func getEffectivePlayState(_ app: ActiveMediaApp) -> String {
        if app.playStateString == "playing" || app.playStateString == "paused" {
            return app.playStateString
        }
        if app.bundleIdentifier == mediaObserver.state.bundleIdentifier && (!mediaObserver.state.title.isEmpty || mediaObserver.state.isPlaying) {
            return mediaObserver.state.isPlaying ? "playing" : "paused"
        }
        return "unknown"
    }
}
