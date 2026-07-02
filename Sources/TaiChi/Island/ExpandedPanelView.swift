import SwiftUI
import Combine

struct ExpandedPanelView: View {
    @ObservedObject var mediaObserver = MediaObserver.shared
    @ObservedObject var lyricManager = LyricManager.shared
    @ObservedObject var stateModel = IslandStateModel.shared
    
    @State private var showingControls = false
    @State private var isDraggingProgress = false
    @State private var dragProgress: Double = 0.0
    
    @State private var timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    @State private var localElapsedTime: Double = 0.0
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 20) {
                // Left: CD Player
                ZStack {
                    Circle()
                        .fill(Color.black)
                        .frame(width: 80, height: 80)
                    
                    if let data = mediaObserver.state.artworkData, let img = NSImage(data: data) {
                        SpinningRecord(image: img, duration: 11.4, isPlaying: mediaObserver.state.isPlaying)
                            .frame(width: 76, height: 76)
                    } else {
                        SpinningRecord(image: NSImage(named: NSImage.applicationIconName) ?? NSImage(), duration: 11.4, isPlaying: mediaObserver.state.isPlaying)
                            .frame(width: 76, height: 76)
                    }
                    
                    // Tonearm
                    TonearmView(isPlaying: mediaObserver.state.isPlaying)
                        .frame(width: 40, height: 80)
                        .offset(x: 20, y: -20)
                }
                .onTapGesture {
                    // Play/Pause
                    mediaObserver.sendCommand(2) // 2 is kMRATogglePlayPause
                }
                .padding(.leading, 20)
                
                // Middle/Right: Lyrics and Controls
                VStack(alignment: .leading, spacing: 10) {
                    // Main Content Area (Click to toggle)
                    ZStack(alignment: .leading) {
                        if showingControls {
                            // Playback Controls
                            HStack(spacing: 30) {
                                Spacer()
                                Button(action: { mediaObserver.sendCommand(5) }) { // Previous
                                    Image(systemName: "backward.fill")
                                        .font(.title2)
                                        .foregroundColor(.white)
                                }.buttonStyle(PlainButtonStyle())
                                
                                Button(action: { mediaObserver.sendCommand(2) }) { // Play/Pause
                                    Image(systemName: mediaObserver.state.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.title)
                                        .foregroundColor(.white)
                                }.buttonStyle(PlainButtonStyle())
                                
                                Button(action: { mediaObserver.sendCommand(4) }) { // Next
                                    Image(systemName: "forward.fill")
                                        .font(.title2)
                                        .foregroundColor(.white)
                                }.buttonStyle(PlainButtonStyle())
                                Spacer()
                            }
                        } else {
                            // Lyrics View
                            if lyricManager.currentLyrics.isEmpty {
                                // Default to Title + Artist
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(mediaObserver.state.title)
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Text(mediaObserver.state.artist)
                                        .font(.system(size: 14, weight: .regular))
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                }
                            } else {
                                // Synchronized Lyrics
                                LyricsDisplayView(lyrics: lyricManager.currentLyrics, currentTime: localElapsedTime)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 60, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingControls.toggle()
                        }
                    }
                    
                    // Progress Bar
                    HStack {
                        Text(formatTime(localElapsedTime))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                        
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.2))
                                    .frame(height: 4)
                                
                                let progress = mediaObserver.state.duration > 0 ? (isDraggingProgress ? dragProgress : localElapsedTime) / mediaObserver.state.duration : 0
                                
                                Capsule().fill(Color.white)
                                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(progress))), height: 4)
                            }
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        isDraggingProgress = true
                                        let percent = min(max(0, value.location.x / geo.size.width), 1.0)
                                        dragProgress = percent * mediaObserver.state.duration
                                    }
                                    .onEnded { value in
                                        let percent = min(max(0, value.location.x / geo.size.width), 1.0)
                                        let targetTime = percent * mediaObserver.state.duration
                                        mediaObserver.seek(to: targetTime)
                                        localElapsedTime = targetTime
                                        isDraggingProgress = false
                                    }
                            )
                        }
                        .frame(height: 10)
                        
                        Text(formatTime(mediaObserver.state.duration))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.trailing, 20)
            }
            .padding(.top, 38)
            .padding(.bottom, 20)
            
            // Pin Button
            Button(action: {
                withAnimation {
                    stateModel.isPinned.toggle()
                }
            }) {
                Image(systemName: stateModel.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10))
                    .foregroundColor(stateModel.isPinned ? .white : .gray.opacity(0.5))
                    .rotationEffect(.degrees(30))
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 16)
            .padding(.top, 16)
        }
        .frame(width: stateModel.capsuleWidth, height: stateModel.capsuleHeight)
        .onReceive(timer) { _ in
            guard !isDraggingProgress else { return }
            
            // Sync with the actual computed time every tick
            let actualTime = mediaObserver.state.currentElapsedTime
            
            // If the song just ended, avoid continuing past duration
            if actualTime > mediaObserver.state.duration && mediaObserver.state.duration > 0 {
                localElapsedTime = mediaObserver.state.duration
            } else {
                localElapsedTime = actualTime
            }
        }
        .onChange(of: mediaObserver.state.title) { _ in
            lyricManager.fetchLyrics(title: mediaObserver.state.title, artist: mediaObserver.state.artist)
            localElapsedTime = mediaObserver.state.currentElapsedTime
        }
        .onAppear {
            localElapsedTime = mediaObserver.state.currentElapsedTime
            if !mediaObserver.state.title.isEmpty {
                lyricManager.fetchLyrics(title: mediaObserver.state.title, artist: mediaObserver.state.artist)
            }
        }
    }
    
    private func formatTime(_ time: Double) -> String {
        guard time > 0 && !time.isNaN else { return "0:00" }
        let m = Int(time) / 60
        let s = Int(time) % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct TonearmView: View {
    var isPlaying: Bool
    
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                path.move(to: CGPoint(x: w/2, y: 10))
                path.addLine(to: CGPoint(x: w/2 + 10, y: h/2))
                path.addLine(to: CGPoint(x: w/2 - 5, y: h - 10))
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            
            // Stylus head
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white)
                .frame(width: 8, height: 16)
                .rotationEffect(.degrees(-30))
                .position(x: geo.size.width/2 - 5, y: geo.size.height - 10)
            
            // Pivot
            Circle()
                .fill(Color.gray)
                .frame(width: 12, height: 12)
                .position(x: geo.size.width/2, y: 10)
        }
        .rotationEffect(.degrees(isPlaying ? 20 : 0), anchor: UnitPoint(x: 0.5, y: 0.1))
        .animation(.easeInOut(duration: 0.5), value: isPlaying)
    }
}

struct LyricsDisplayView: View {
    let lyrics: [LyricLine]
    let currentTime: Double
    
    var body: some View {
        let currentIndex = lyrics.lastIndex(where: { $0.time <= currentTime + 0.5 }) ?? 0
        
        VStack(alignment: .leading, spacing: 4) {
            if currentIndex > 0 {
                Text(lyrics[currentIndex - 1].text)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            
            Text(lyrics[currentIndex].text)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
            
            if currentIndex < lyrics.count - 1 {
                Text(lyrics[currentIndex + 1].text)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: currentIndex)
    }
}
