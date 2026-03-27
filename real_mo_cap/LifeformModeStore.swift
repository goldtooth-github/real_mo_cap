import Foundation
import Combine

// Lightweight active version (was only in unused_old before)
final class LifeformModeStore: ObservableObject {
    enum Mode: String { case singleInstance, multiInstance }
    @Published var mode: Mode = .singleInstance
}
