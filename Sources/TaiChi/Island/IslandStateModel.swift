import Foundation
import Combine
import SwiftUI
import AppKit


enum IslandMode: String, Equatable {
    case media
    case disk
    case mutagen
}

enum IslandState: Equatable {
    case idle
    case trackChanged
    case expanded
    case multiAppList
    case modeSwitcher
    case notification
}

@MainActor
class IslandStateModel: ObservableObject {
    static let shared = IslandStateModel()
    
    @Published var state: IslandState = .idle
    @Published var currentMode: IslandMode = .media
    @Published var notificationText: String?
    
    func showNotification(text: String, mode: IslandMode) {
        self.notificationText = text
        self.currentMode = mode
        self.state = .notification
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.state == .notification && self.notificationText == text {
                if !self.isHovering {
                    withAnimation {
                        self.state = .idle
                        self.notificationText = nil
                    }
                }
            }
        }
    }
    @Published var capsuleWidth: CGFloat = 160
    @Published var capsuleHeight: CGFloat = 36
    @Published var isHovering: Bool = false
    @Published var isNotchHovered: Bool = false
    @Published public var isCenterNotchHovered: Bool = false
    @Published public var isHoveringIcons: Bool = false
    @Published var isPinned: Bool = false
    
    @Published var isLyricPinned: Bool {
        didSet {
            UserDefaults.standard.set(isLyricPinned, forKey: "isLyricPinned")
        }
    }
    
    @Published var activeScreenIndex: Int = 0
    
    @Published var lyricScreenIndex: Int? = nil // nil means attached to main island
    
    @Published var savedLyricScreenName: String? {
        didSet {
            if let name = savedLyricScreenName {
                UserDefaults.standard.set(name, forKey: "savedLyricScreenName")
            } else {
                UserDefaults.standard.removeObject(forKey: "savedLyricScreenName")
            }
        }
    }
    
    var isLyricDetached: Bool {
        return lyricScreenIndex != nil && lyricScreenIndex != activeScreenIndex
    }
    
    private init() {
        self.isLyricPinned = UserDefaults.standard.bool(forKey: "isLyricPinned")
        self.savedLyricScreenName = UserDefaults.standard.string(forKey: "savedLyricScreenName")
    }
    
    public func isLocationInPhysicalNotch(_ location: NSPoint) -> Bool {
        let screens = NSScreen.screens
        guard activeScreenIndex < screens.count else { return false }
        let screen = screens[activeScreenIndex]
        
        let hasNotch = screen.safeAreaInsets.top > 0
        let notchHeight: CGFloat = hasNotch ? screen.safeAreaInsets.top : 38
        let notchWidth: CGFloat = {
            if hasNotch,
               let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea {
                let w = screen.frame.width - left.width - right.width
                if w > 0 { return w }
            }
            return 190
        }()
        
        let minX = screen.frame.midX - (notchWidth / 2)
        let maxX = screen.frame.midX + (notchWidth / 2)
        let minY = screen.frame.maxY - notchHeight
        let maxY = screen.frame.maxY
        
        return location.x >= minX && location.x <= maxX && location.y >= minY && location.y <= maxY
    }
}
