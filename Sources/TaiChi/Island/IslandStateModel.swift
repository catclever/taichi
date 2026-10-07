import Foundation
import Combine
import SwiftUI


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
}
