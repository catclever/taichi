import Foundation
import Combine
import SwiftUI

enum IslandState: Equatable {
    case idle
    case trackChanged
    case expanded
    case multiAppList
}

@MainActor
class IslandStateModel: ObservableObject {
    static let shared = IslandStateModel()
    
    @Published var state: IslandState = .idle
    @Published var capsuleWidth: CGFloat = 160
    @Published var capsuleHeight: CGFloat = 36
    @Published var isHovering: Bool = false
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
