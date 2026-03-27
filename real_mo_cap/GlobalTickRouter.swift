import Foundation
import Combine

// GlobalTickRouter subscribes once to MIDIClockCenter and republishes tick & phase.
// LifeformsPageView sets activeTab; views can optionally read it for gating.
final class GlobalTickRouter: ObservableObject {
    // Singleton access to avoid relying solely on Environment injection after revert
    static let shared = GlobalTickRouter()

    @Published var tick: UInt64 = 0
    @Published var phase: Double = 0.0
    @Published var activeTab: Int = 0
    // Downsampled tick for MIDI/UI updates to reduce SwiftUI churn
    @Published var ccTick: UInt64 = 0
    private(set) var ccDivisor: Int = 1 // emit every 2 ticks by default

    private var cancellable: AnyCancellable?

    init(clock: MIDIClockCenter = .shared) {
        cancellable = clock.$tick.combineLatest(clock.$phase)
            .sink { [weak self] t, p in
                guard let self = self else { return }
                self.tick = t
                self.phase = p
                if self.ccDivisor <= 1 || (t % UInt64(self.ccDivisor) == 0) {
                    self.ccTick = t
                }
            }
    }

    func setCCDivisor(_ newValue: Int) {
        let clamped = max(1, min(64, newValue))
        ccDivisor = clamped
    }
}
