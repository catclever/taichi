import SwiftUI
import Combine

// =========================================================================================
// [BUG FIX: Standalone Lyric View Inactive Timer Lifecycle & Battery Drain]
// 1. Problem:
//    `StandaloneLyricView` previously kept a 10Hz timer running unconditionally whenever
//    `isPlaying && shouldShowLyrics`, even when lyrics were NOT pinned or NOT detached to an external screen.
//    Because the lyric window existed with `alphaValue = 0.0`, the timer ticked continuously in the background,
//    wasting CPU cycles and triggering SwiftUI view graph invalidations.
// 2. Resolution:
//    - In `startTimer()`, strictly guard against `stateModel.isLyricPinned && stateModel.isLyricDetached`.
//    - Added reactive `.onChange(of: stateModel.isLyricPinned)` and `.onChange(of: stateModel.isLyricDetached)`
//      listeners that immediately cancel and nullify the timer (`stopTimer()`) when not detached and pinned.
// 3. Caveats:
//    - `localElapsedTime` resumes seamlessly when re-pinned or re-detached by syncing with
//      `mediaObserver.state.elapsedTime`.
// =========================================================================================

// =========================================================================================
// [FEATURE: Paused vs Stopped Lyric Visibility]
// 1. Paused:
//    - `shouldShowLyrics` remains true (lyrics visible if detached and pinned).
//    - Display timer remains stopped (frozen at current elapsed time) while paused.
//    - Marquee text scrolling is paused.
// 2. Stopped:
//    - `shouldShowLyrics` returns false, window fades out.
// =========================================================================================

struct StandaloneLyricView: View {
    @ObservedObject var stateModel = IslandStateModel.shared
    @ObservedObject var mediaObserver = MediaObserver.shared
    
    @ObservedObject private var lyricManager = LyricManager.shared
    
    // Smooth time progression
    @State private var localElapsedTime: Double = 0
    @State private var timer: AnyCancellable?
    
    var hasPhysicalNotch: Bool {
        guard let lIndex = stateModel.lyricScreenIndex, lIndex < NSScreen.screens.count else { return false }
        let screen = NSScreen.screens[lIndex]
        return screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil
    }
    
    var notchScale: CGFloat {
        if hasPhysicalNotch {
            return 1.0 // Base scale
        } else {
            return 0.9
        }
    }
    
    var baseNotchWidth: CGFloat {
        return hasPhysicalNotch ? 160 : 180
    }
    
    var baseNotchHeight: CGFloat {
        return hasPhysicalNotch ? 36 : 38
    }

    private var shouldShowLyrics: Bool {
        guard mediaObserver.state.status != .stopped else { return false }
        
        let mediaApps = TaiChiSettings.shared.mediaApps
        let hasLyricApps = mediaApps.contains(where: { $0.isLyricSupported })
        
        if hasLyricApps {
            if let currentApp = mediaApps.first(where: { $0.id == mediaObserver.state.bundleIdentifier }) {
                if !currentApp.isLyricSupported {
                    return false
                }
            } else {
                return false
            }
        }
        
        if let type = mediaObserver.state.mediaType, type == "Video" {
            return false
        }
        return true
    }

    var body: some View {
        ZStack {
            let cornerRadii = getCornerRadii()
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .frame(width: baseNotchWidth + (80 * notchScale), height: baseNotchHeight - 8)
                .clipShape(NotchShape(topCornerRadius: cornerRadii.top, bottomCornerRadius: cornerRadii.bottom))

            HStack {
                Spacer()
                
                let lyrics = lyricManager.currentLyrics
                let currentIndex = lyrics.lastIndex(where: { $0.time <= localElapsedTime + 0.5 }) ?? 0
                
                if lyrics.isEmpty {
                    MarqueeText(
                        text: "\(mediaObserver.state.title) - \(mediaObserver.state.artist)",
                        font: .system(size: 13 * notchScale, weight: .medium),
                        foregroundColor: .primary,
                        velocity: 30.0,
                        isPlaying: mediaObserver.state.isPlaying
                    )
                } else {
                    MarqueeText(
                        text: lyrics[currentIndex].text,
                        font: .system(size: 13 * notchScale, weight: .bold),
                        foregroundColor: .primary,
                        velocity: 30.0,
                        isPlaying: mediaObserver.state.isPlaying
                    )
                }
                
                Spacer()
            }
            .padding(.horizontal, 20 * notchScale)
            .frame(width: baseNotchWidth + (80 * notchScale), height: baseNotchHeight - 8)
            .clipShape(NotchShape(topCornerRadius: cornerRadii.top, bottomCornerRadius: cornerRadii.bottom))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(shouldShowLyrics ? 1 : 0)
        .animation(.easeInOut, value: shouldShowLyrics)
        .onAppear {
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
        .onChange(of: mediaObserver.state.elapsedTime) { newValue in
            localElapsedTime = newValue
        }
        .onChange(of: mediaObserver.state.isPlaying) { _ in
            startTimer()
        }
        .onChange(of: mediaObserver.state.status) { _ in
            startTimer()
        }
        .onChange(of: shouldShowLyrics) { _ in
            startTimer()
        }
        .onChange(of: stateModel.isLyricPinned) { pinned in
            if !(pinned && stateModel.isLyricDetached) {
                stopTimer()
            } else {
                startTimer()
            }
        }
        .onChange(of: stateModel.isLyricDetached) { detached in
            if !(stateModel.isLyricPinned && detached) {
                stopTimer()
            } else {
                startTimer()
            }
        }
        .onTapGesture(count: 2) {
            cycleLyricScreen()
        }
    }
    
    private func cycleLyricScreen() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let nextIndex = ((stateModel.lyricScreenIndex ?? stateModel.activeScreenIndex) + 1) % screens.count
        
        if nextIndex == stateModel.activeScreenIndex {
            stateModel.lyricScreenIndex = nil // Merge back
            stateModel.savedLyricScreenName = nil
        } else {
            stateModel.lyricScreenIndex = nextIndex
            stateModel.savedLyricScreenName = screens[nextIndex].localizedName
        }
    }
    
    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
    
    private func startTimer() {
        stopTimer()
        guard stateModel.isLyricPinned && stateModel.isLyricDetached && mediaObserver.state.isPlaying && shouldShowLyrics else { return }
        timer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                localElapsedTime += 0.1
            }
    }

    private func getCornerRadii() -> (top: CGFloat, bottom: CGFloat) {
        let baseRadius = baseNotchHeight / 3
        return (top: baseRadius - 4, bottom: baseRadius)
    }
}
