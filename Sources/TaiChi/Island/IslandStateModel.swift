import Foundation
import Combine
import SwiftUI

enum IslandState: Equatable {
    case idle
    case trackChanged
    case expanded
}

@MainActor
class IslandStateModel: ObservableObject {
    static let shared = IslandStateModel()
    
    @Published var state: IslandState = .idle
    @Published var capsuleWidth: CGFloat = 160
    @Published var capsuleHeight: CGFloat = 36
    @Published var isHovering: Bool = false
    @Published var isPinned: Bool = false
}
