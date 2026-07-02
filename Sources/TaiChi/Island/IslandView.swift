import SwiftUI
import Cocoa

enum IslandState {
    case idle // When nothing is playing or playing normally
    case trackChanged // Temporarily expanded for 5s
    case expanded // Clicked (lyrics later)
}

struct IslandView: View {
    @ObservedObject var mediaObserver = MediaObserver.shared
    
    @State private var state: IslandState = .idle
    @State private var trackChangeTimer: Timer?
    @State private var currentArtwork: NSImage?
    @State private var waveformColor: Color = .orange // Default fallback
    
    // Smooth transitions
    @Namespace private var islandNamespace
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Main Island Background
                NotchShape(topCornerRadius: cornerRadii.top, bottomCornerRadius: cornerRadii.bottom)
                    .fill(Color.black)
                    .frame(width: capsuleWidth, height: capsuleHeight)
                    .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
                
                // Content based on state
                if state == .idle {
                    idleContent
                        .matchedGeometryEffect(id: "content", in: islandNamespace)
                } else if state == .trackChanged {
                    trackChangedContent
                        .matchedGeometryEffect(id: "content", in: islandNamespace)
                } else {
                    // Expanded (Lyrics, not implemented yet)
                    Text("Lyrics Space")
                        .foregroundColor(.white)
                        .matchedGeometryEffect(id: "content", in: islandNamespace)
                }
            }
            .animation(.interpolatingSpring(stiffness: 300, damping: 20), value: state)
            
            Spacer() // Push everything to the top
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: mediaObserver.state.title) { _ in
            handleTrackChange()
        }
        .onChange(of: mediaObserver.state.artworkData) { newData in
            updateArtwork(data: newData)
        }
        .onAppear {
            updateArtwork(data: mediaObserver.state.artworkData)
            if !mediaObserver.state.title.isEmpty {
                handleTrackChange()
            }
        }
    }
    
    // MARK: - Dimensions
    private var baseNotchWidth: CGFloat {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main {
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                let w = screen.frame.width - left.width - right.width
                return w > 0 ? w : 190
            }
        }
        return 190
    }

    private var capsuleWidth: CGFloat {
        if !mediaObserver.state.isPlaying { return baseNotchWidth }
        switch state {
        case .idle: return baseNotchWidth + 80
        case .trackChanged: return baseNotchWidth + 80 // Same as playing idle width
        case .expanded: return 300
        }
    }
    
    private var baseNotchHeight: CGFloat {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main {
            let inset = screen.safeAreaInsets.top
            return inset > 0 ? inset : 38
        }
        return 38
    }
    
    private var cornerRadii: (top: CGFloat, bottom: CGFloat) {
        let baseRadius = baseNotchHeight / 3
        return (top: baseRadius - 4, bottom: baseRadius)
    }

    private var capsuleHeight: CGFloat {
        if !mediaObserver.state.isPlaying { return baseNotchHeight }
        switch state {
        case .idle: return baseNotchHeight
        case .trackChanged: return baseNotchHeight + 26 // Expand vertically just enough for text
        case .expanded: return 120
        }
    }
    
    // MARK: - Views
    private var idleContent: some View {
        HStack {
            if mediaObserver.state.isPlaying {
                // Left: Spinning Record
                if let img = currentArtwork {
                    SpinningRecord(image: img)
                        .frame(width: 20, height: 20) // Smaller to avoid being cramped
                        .padding(.leading, 12)
                }
                
                Spacer() // Center is the physical notch
                
                // Right: Waveform and App Icon
                ZStack {
                    // App Icon (highly transparent)
                    if let appIcon = getAppIcon(bundleId: mediaObserver.state.bundleIdentifier) {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 20, height: 20)
                            .opacity(0.3)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .id(mediaObserver.state.bundleIdentifier)
                    }
                    
                    // Waveform
                    WaveformView(color: waveformColor)
                        .frame(width: 30, height: 16)
                }
                .padding(.trailing, 12)
            } else {
                // Not playing: just empty spacer to keep the notch shape
                Spacer()
            }
        }
        .frame(width: capsuleWidth, height: baseNotchHeight, alignment: .top)
    }
            

    
    private var trackChangedContent: some View {
        VStack(spacing: 0) {
            // Top section: Re-use the idle layout so record and waveform stay visible
            idleContent
            
            // Bottom section: Expanded text content (centered in the added vertical space)
            HStack {
                Spacer()
                Text("\(mediaObserver.state.title) - \(mediaObserver.state.artist)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .frame(height: 26) // Fill the added vertical space
            .padding(.horizontal, 20)
        }
        .frame(width: capsuleWidth, height: capsuleHeight)
    }
    
    // MARK: - Logic
    private func handleTrackChange() {
        guard !mediaObserver.state.title.isEmpty else { return }
        guard mediaObserver.state.isPlaying else { return }
        
        withAnimation {
            state = .trackChanged
        }
        
        trackChangeTimer?.invalidate()
        trackChangeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            Task { @MainActor in
                withAnimation {
                    self.state = .idle
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
    @State private var rotation: Double = 0
    
    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 1)) // record groove
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

struct WaveformView: View {
    var color: Color
    @State private var isAnimating = false
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: isAnimating ? CGFloat.random(in: 5...20) : 5)
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
