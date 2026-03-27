import SwiftUI

// Shared ring buffer history for normalized 0..1 time-series values used by LFO overlays.
// Reference type + internal array reuse prevents per-tick copying and keeps allocations stable.
final class RingHistory: ObservableObject, Identifiable {
    let id = UUID()
    private(set) var values: [CGFloat]
    private(set) var head: Int = 0   // next write index
    private(set) var count: Int = 0  // number of valid samples
    @Published private(set) var revision: UInt64 = 0 // bump each append to trigger redraw in observing views
    init(capacity: Int) { values = Array(repeating: 0, count: max(1, capacity)) }
    func append(_ v: CGFloat) {
        guard !values.isEmpty else { return }
        values[head] = v
        head = (head + 1) % values.count
        if count < values.count { count += 1 }
        revision &+= 1
    }
    func forEachOrdered(_ body: (Int, CGFloat) -> Void) {
        guard count > 0 else { return }
        let cap = values.count
        let start = (head - count + cap) % cap
        for i in 0..<count {
            let idx = (start + i) % cap
            body(i, values[idx])
        }
    }
    var capacity: Int { values.count }
}
