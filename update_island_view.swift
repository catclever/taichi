import Foundation

let path = "/Users/kael/Projects/taichi_launcher/Sources/TaiChi/Island/IslandView.swift"
var content = try! String(contentsOfFile: path, encoding: .utf8)

// 1. updateStateDimensions
let oldDims = """
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
"""

let newDims = """
            case .idle:
                if stateModel.isLyricPinned && !stateModel.isLyricDetached {
                    stateModel.capsuleWidth = baseNotchWidth + (200 * notchScale)
                    stateModel.capsuleHeight = hasPhysicalNotch ? baseNotchHeight + (26 * notchScale) : baseNotchHeight
                } else {
                    stateModel.capsuleWidth = baseNotchWidth + 80
                    stateModel.capsuleHeight = baseNotchHeight
                }
            case .trackChanged:
                if stateModel.isLyricPinned && !stateModel.isLyricDetached {
                    stateModel.capsuleWidth = baseNotchWidth + (200 * notchScale)
                } else {
                    stateModel.capsuleWidth = baseNotchWidth + (100 * notchScale)
                }
                stateModel.capsuleHeight = hasPhysicalNotch ? baseNotchHeight + (26 * notchScale) : baseNotchHeight
"""
content = content.replacingOccurrences(of: oldDims, with: newDims)

// 2. Body view
let oldBody1 = """
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
"""

let newBody1 = """
                case .idle:
                    if stateModel.isLyricPinned && !stateModel.isLyricDetached {
                        lyricPinnedContent
                    } else {
                        idleContent
                    }
                case .trackChanged:
                    if stateModel.isLyricPinned && !stateModel.isLyricDetached {
                        lyricPinnedContent
                    } else {
                        trackChangedContent
                    }
"""
content = content.replacingOccurrences(of: oldBody1, with: newBody1)

// 3. inline lyric in idleContent (if no physical notch)
let oldIdleLyric = """
                if !hasPhysicalNotch && stateModel.isLyricPinned {
                    lyricAndPlayButtonView
                } else {
                    Spacer() // Center is the physical notch
                }
"""

let newIdleLyric = """
                if !hasPhysicalNotch && stateModel.isLyricPinned && !stateModel.isLyricDetached {
                    lyricAndPlayButtonView
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { cycleLyricScreen() }
                } else {
                    Spacer() // Center is the physical notch
                }
"""
content = content.replacingOccurrences(of: oldIdleLyric, with: newIdleLyric)

// 4. Double tap on lyricPinnedContent
let oldLyricPinnedContent = """
    private var lyricPinnedContent: some View {
        VStack(spacing: 0) {
            idleContent
            
            lyricAndPlayButtonView
                .frame(height: 26 * notchScale) // Same as track changed
                .padding(.horizontal, 20 * notchScale)
        }
        .frame(width: stateModel.capsuleWidth, height: stateModel.capsuleHeight)
    }
"""

let newLyricPinnedContent = """
    private var lyricPinnedContent: some View {
        VStack(spacing: 0) {
            idleContent
            
            lyricAndPlayButtonView
                .frame(height: 26 * notchScale) // Same as track changed
                .padding(.horizontal, 20 * notchScale)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    cycleLyricScreen()
                }
        }
        .frame(width: stateModel.capsuleWidth, height: stateModel.capsuleHeight)
    }
    
    private func cycleLyricScreen() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let nextIndex = ((stateModel.lyricScreenIndex ?? stateModel.activeScreenIndex) + 1) % screens.count
        
        if nextIndex == stateModel.activeScreenIndex {
            stateModel.lyricScreenIndex = nil // Merge back
        } else {
            stateModel.lyricScreenIndex = nextIndex
        }
    }
"""
content = content.replacingOccurrences(of: oldLyricPinnedContent, with: newLyricPinnedContent)

try! content.write(toFile: path, atomically: true, encoding: .utf8)
print("Updated IslandView.swift")
