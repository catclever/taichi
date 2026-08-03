import SwiftUI
import Cocoa

struct IslandView: View {
    @ObservedObject var mediaObserver = MediaObserver.shared
    @ObservedObject var stateModel = IslandStateModel.shared
    @ObservedObject var lyricManager = LyricManager.shared
    
    @State private var trackChangeTimer: Timer?
    @State private var hoverTimer: Timer?
    @State private var currentArtwork: NSImage?
    @State private var waveformColor: Color = .orange
    
    @State private var timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    @State private var localElapsedTime: Double = 0.0
    
    var body: some View {
        ZStack {
            // Base Background (The Notch)
            NotchShape(topCornerRadius: cornerRadii.top, bottomCornerRadius: cornerRadii.bottom)
                .fill(stateModel.state == .expanded ? Color.black.opacity(stateModel.isPinned ? 0.8 : 0.9) : Color.black)
                .frame(width: stateModel.capsuleWidth, height: stateModel.capsuleHeight)
            
            // Content
            Group {
                switch stateModel.state {
                case .idle:
                    if stateModel.isLyricPinned {
                        lyricPinnedContent
                    } else {
                        idleContent
                    }
                case .trackChanged:
                    if stateModel.isLyricPinned {
                        lyricPinnedContent
                    } else {
                        trackChangedContent
                    }
                case .expanded:
                    ExpandedPanelView()
                }
            }
            .frame(width: stateModel.capsuleWidth, height: stateModel.capsuleHeight)
            .clipShape(NotchShape(topCornerRadius: cornerRadii.top, bottomCornerRadius: cornerRadii.bottom))
        }
        .overlay(
            Color.clear
                .frame(width: stateModel.capsuleWidth, height: 100) // Extends high up
                .offset(y: -50),
            alignment: .top
        )
        .contentShape(Rectangle())
        .animation(.spring(response: 0.4, dampingFraction: 0.7, blendDuration: 0), value: stateModel.capsuleWidth)
        .animation(.spring(response: 0.4, dampingFraction: 0.7, blendDuration: 0), value: stateModel.capsuleHeight)
        .animation(.spring(response: 0.4, dampingFraction: 0.7, blendDuration: 0), value: stateModel.state)
        .onChange(of: stateModel.isHovering) { isHovering in
            handleHover(isHovering)
        }
        .onTapGesture {
            if !mediaObserver.state.isPlaying && stateModel.state != .expanded {
                withAnimation {
                    stateModel.state = .expanded
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // Fill the hosting view to position notch
        .onChange(of: mediaObserver.state.title) { _ in
            handleTrackChange()
        }
        .onChange(of: mediaObserver.state.artworkData) { data in
            updateArtwork(data: data)
        }
        .onChange(of: stateModel.isLyricPinned) { _ in
            updateStateDimensions()
        }
        .onReceive(timer) { _ in
            guard stateModel.isLyricPinned else { return }
            let actualTime = mediaObserver.state.currentElapsedTime
            if actualTime > mediaObserver.state.duration && mediaObserver.state.duration > 0 {
                localElapsedTime = mediaObserver.state.duration
            } else {
                localElapsedTime = actualTime
            }
        }
        .onAppear {
            updateStateDimensions()
            updateArtwork(data: mediaObserver.state.artworkData)
        }
        .onChange(of: stateModel.state) { _ in
            updateStateDimensions()
        }
        .onChange(of: mediaObserver.state.isPlaying) { _ in
            updateStateDimensions()
        }
    }
    
    private func updateStateDimensions() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7, blendDuration: 0)) {
            if !mediaObserver.state.isPlaying && stateModel.state != .expanded {
                stateModel.capsuleWidth = baseNotchWidth
                stateModel.capsuleHeight = baseNotchHeight
                return
            }
            
            if mediaObserver.state.title.isEmpty {
                stateModel.capsuleWidth = baseNotchWidth
                stateModel.capsuleHeight = baseNotchHeight
                return
            }
            
            switch stateModel.state {
            case .idle:
                if stateModel.isLyricPinned {
                    stateModel.capsuleWidth = baseNotchWidth + (200 * notchScale)
                    stateModel.capsuleHeight = hasPhysicalNotch ? baseNotchHeight + (26 * notchScale) : baseNotchHeight
                } else {
                    stateModel.capsuleWidth = baseNotchWidth + 80
                    stateModel.capsuleHeight = baseNotchHeight
                }
            case .trackChanged:
                if stateModel.isLyricPinned {
                    stateModel.capsuleWidth = baseNotchWidth + (200 * notchScale)
                } else {
                    stateModel.capsuleWidth = baseNotchWidth + (100 * notchScale)
                }
                stateModel.capsuleHeight = hasPhysicalNotch ? baseNotchHeight + (26 * notchScale) : baseNotchHeight
            case .expanded:
                stateModel.capsuleWidth = 380
                stateModel.capsuleHeight = 160
            }
        }
    }
    
    private var currentScreen: NSScreen? {
        let screens = NSScreen.screens
        if stateModel.activeScreenIndex < screens.count {
            return screens[stateModel.activeScreenIndex]
        }
        return NSScreen.main
    }
    
    private var hasPhysicalNotch: Bool {
        return (currentScreen?.safeAreaInsets.top ?? 0) > 0
    }
    
    private var baseNotchWidth: CGFloat {
        if let screen = currentScreen {
            if hasPhysicalNotch, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let w = screen.frame.width - left.width - right.width
                return w > 0 ? w : 190
            }
        }
        return 190
    }
    
    private var baseNotchHeight: CGFloat {
        if let screen = currentScreen {
            let inset = screen.safeAreaInsets.top
            return inset > 0 ? inset : 38
        }
        return 38
    }
    
    private var notchScale: CGFloat {
        return baseNotchHeight / 38.0
    }
    
    private var cornerRadii: (top: CGFloat, bottom: CGFloat) {
        let baseRadius = baseNotchHeight / 3
        return (top: baseRadius - 4, bottom: baseRadius)
    }
    
    // MARK: - Views
    private var idleContent: some View {
        HStack {
            if !mediaObserver.state.title.isEmpty {
                // Left: Spinning Record
                if let img = currentArtwork {
                    SpinningRecord(image: img, isPlaying: mediaObserver.state.isPlaying)
                        .frame(width: 26 * notchScale, height: 26 * notchScale) // Increased from 20
                        .padding(.leading, 12 * notchScale)
                }
                
                if !hasPhysicalNotch && stateModel.isLyricPinned {
                    lyricAndPlayButtonView
                } else {
                    Spacer() // Center is the physical notch
                }
                
                // Right: Waveform and App Icon (Clickable for Play/Pause)
                Button(action: { mediaObserver.sendTargetedCommand(2) }) {
                    ZStack {
                        // App Icon (highly transparent)
                        if let appIcon = getAppIcon(bundleId: mediaObserver.state.bundleIdentifier) {
                            Image(nsImage: appIcon)
                                .resizable()
                                .frame(width: 26 * notchScale, height: 26 * notchScale) // Increased from 20
                                .opacity(0.3)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                .id(mediaObserver.state.bundleIdentifier)
                        }
                        
                        // Waveform (hidden or static when paused)
                        if mediaObserver.state.isPlaying {
                            WaveformView(color: waveformColor, notchScale: notchScale)
                                .frame(width: 30 * notchScale, height: 16 * notchScale)
                        } else {
                            // Show static waveform or play icon when paused
                            Image(systemName: "play.fill")
                                .font(.system(size: 14 * notchScale))
                                .foregroundColor(waveformColor)
                        }
                    }
                    .frame(width: 30 * notchScale, height: 26 * notchScale)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.trailing, 12 * notchScale)
            } else {
                // Not playing and no track: just empty spacer to keep the notch shape
                Spacer()
            }
        }
        .frame(width: stateModel.capsuleWidth, height: baseNotchHeight, alignment: .center)
    }
            

    
    private var trackChangedContent: some View {
        VStack(spacing: 0) {
            // Top section: Re-use the idle layout so record and waveform stay visible
            idleContent
            
            // Bottom section: Expanded text content (centered in the added vertical space)
            HStack {
                Spacer()
                Text("\(mediaObserver.state.title) - \(mediaObserver.state.artist)")
                    .font(.system(size: 13 * notchScale, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Button(action: { mediaObserver.sendTargetedCommand(2) }) { // Play/Pause
                    Image(systemName: mediaObserver.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13 * notchScale))
                        .foregroundColor(.white)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 8 * notchScale)

                Spacer()
            }
            .frame(height: 26 * notchScale) // Fill the added vertical space
            .padding(.horizontal, 20 * notchScale)
        }
        .frame(width: stateModel.capsuleWidth, height: stateModel.capsuleHeight)
    }
    
    private var lyricAndPlayButtonView: some View {
        HStack {
            Spacer()
            
            let lyrics = lyricManager.currentLyrics
            let currentIndex = lyrics.lastIndex(where: { $0.time <= localElapsedTime + 0.5 }) ?? 0
            
            if lyrics.isEmpty {
                Text("\(mediaObserver.state.title) - \(mediaObserver.state.artist)")
                    .font(.system(size: 13 * notchScale, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(lyrics[currentIndex].text)
                    .font(.system(size: 13 * notchScale, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            
            // Show the play/pause button only if hovered and there IS a physical notch
            if stateModel.state == .trackChanged && hasPhysicalNotch {
                Button(action: { mediaObserver.sendTargetedCommand(2) }) {
                    Image(systemName: mediaObserver.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13 * notchScale))
                        .foregroundColor(.white)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 8 * notchScale)
            }
            
            Spacer()
        }
    }
    
    private var lyricPinnedContent: some View {
        VStack(spacing: 0) {
            idleContent
            
            if hasPhysicalNotch {
                lyricAndPlayButtonView
                    .frame(height: 26 * notchScale)
                    .padding(.horizontal, 20 * notchScale)
            }
        }
        .frame(width: stateModel.capsuleWidth, height: stateModel.capsuleHeight)
    }
    
    // MARK: - Logic
    
    private func handleHover(_ isHovering: Bool) {
        hoverTimer?.invalidate()
        if isHovering {
            guard !mediaObserver.state.title.isEmpty else { return } // Only expand if there's a song
            guard mediaObserver.state.isPlaying else { return } // Do not expand on hover when paused
            
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                Task { @MainActor in
                    if self.stateModel.state == .idle {
                        withAnimation {
                            self.stateModel.state = .trackChanged
                        }
                    }
                    
                    // Schedule expansion after another 1.0s
                    self.hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                        Task { @MainActor in
                            withAnimation {
                                self.stateModel.state = .expanded
                            }
                        }
                    }
                }
            }
        } else {
            // Mouse left the interactive area
            if stateModel.state == .expanded {
                if !stateModel.isPinned {
                    hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
                        Task { @MainActor in
                            withAnimation {
                                self.stateModel.state = .idle
                            }
                        }
                    }
                }
            } else if stateModel.state == .trackChanged {
                withAnimation {
                    stateModel.state = .idle
                }
            }
        }
    }
    
    private func handleTrackChange() {
        guard !mediaObserver.state.title.isEmpty else { return }
        guard mediaObserver.state.isPlaying else { return }
        
        // Don't interrupt expanded view
        if stateModel.state == .expanded { return }
        
        withAnimation {
            stateModel.state = .trackChanged
        }
        
        trackChangeTimer?.invalidate()
        trackChangeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            Task { @MainActor in
                withAnimation {
                    // Only go back to idle if we haven't been manually expanded
                    if self.stateModel.state == .trackChanged {
                        self.stateModel.state = .idle
                    }
                }
            }
        }
    }
    
    private func updateArtwork(data: Data?) {
        guard let data = data, let image = NSImage(data: data) else {
            if let fallback = NSImage(named: NSImage.applicationIconName) {
                currentArtwork = fallback
            }
            waveformColor = .orange
            return
        }
        currentArtwork = image
        
        // Extract color async
        DispatchQueue.global(qos: .userInitiated).async {
            let color = image.extractAverageColor(minBrightness: 0.6)
            DispatchQueue.main.async {
                self.waveformColor = Color(nsColor: color)
            }
        }
    }
    
    private func getAppIcon(bundleId: String) -> NSImage? {
        guard !bundleId.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - Components

struct SpinningRecord: View {
    let image: NSImage
    var duration: Double = 3.0
    var isPlaying: Bool = true
    
    @State private var rotation: Double = 0
    @State private var timer: Timer? = nil
    
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 1)) // record groove
            .rotationEffect(.degrees(rotation))
            .onChange(of: isPlaying) { playing in
                updateTimer(playing)
            }
            .onAppear {
                updateTimer(isPlaying)
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }
    
    private func updateTimer(_ playing: Bool) {
        if playing {
            if timer == nil {
                let fps = 60.0
                let interval = 1.0 / fps
                let degreesPerTick = 360.0 / duration / fps
                timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                    Task { @MainActor in
                        rotation += degreesPerTick
                        if rotation >= 360 { rotation -= 360 }
                    }
                }
                RunLoop.main.add(timer!, forMode: .common)
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}

struct WaveformView: View {
    var color: Color
    var notchScale: CGFloat = 1.0
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 3 * notchScale) {
            ForEach(0..<4) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3 * notchScale, height: isAnimating ? CGFloat.random(in: 5...20) * notchScale : 5 * notchScale)
                    .animation(.easeInOut(duration: 0.3).repeatForever().delay(Double(i) * 0.1), value: isAnimating)
            }
        }
        .onAppear {
            isAnimating = true
        }
    }
}

// MARK: - Image Color Extraction
extension NSImage {
    func extractAverageColor(minBrightness: CGFloat) -> NSColor {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .orange
        }
        
        let width = cgImage.width
        let height = cgImage.height
        let totalPixels = width * height
        
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return .orange
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let data = context.data else { return .orange }
        
        let pointer = data.bindMemory(to: UInt32.self, capacity: totalPixels)
        var totalRed: UInt64 = 0
        var totalGreen: UInt64 = 0
        var totalBlue: UInt64 = 0
        
        for i in 0..<totalPixels {
            let color = pointer[i]
            totalRed += UInt64(color & 0xFF)
            totalGreen += UInt64((color >> 8) & 0xFF)
            totalBlue += UInt64((color >> 16) & 0xFF)
        }
        
        let r = CGFloat(totalRed) / CGFloat(totalPixels) / 255.0
        let g = CGFloat(totalGreen) / CGFloat(totalPixels) / 255.0
        let b = CGFloat(totalBlue) / CGFloat(totalPixels) / 255.0
        
        var color = NSColor(red: r, green: g, blue: b, alpha: 1.0)
        
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        
        if v < minBrightness {
            let scale = v > 0 ? (minBrightness / v) : 1.0
            color = NSColor(hue: h, saturation: s / scale, brightness: minBrightness, alpha: a)
        }
        return color
    }
}
