import Foundation
import Combine

final class InteractionLock: ObservableObject {
    @Published private(set) var isLocked: Bool = false
    @Published private(set) var ownerID: UUID? = nil

    func lock(owner: UUID) {
        // Allow re-lock by same owner or set if free
        if ownerID == nil || ownerID == owner {
            ownerID = owner
            if !isLocked { isLocked = true }
        }
    }

    func unlock(owner: UUID) {
        // Only owner can unlock
        if ownerID == owner {
            ownerID = nil
            if isLocked { isLocked = false }
        }
    }

    func forceUnlock() {
        ownerID = nil
        isLocked = false
    }
}