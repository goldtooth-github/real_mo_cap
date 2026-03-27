import Foundation
import Combine
//import os.log

// Global MIDI clock center publishing ticks & beat phase.
// Provides a single high-priority DispatchSourceTimer to minimize jitter versus multiple per-view timers.
final class MIDIClockCenter: ObservableObject {
    static let shared = MIDIClockCenter()

    // Published values for observers (SwiftUI/Combine)
    @Published private(set) var tick: UInt64 = 0            // Monotonic tick counter
    @Published private(set) var phase: Double = 0.0         // 0.0..<1.0 within current beat
    @Published private(set) var bpm: Double = 240.0
    @Published private(set) var ppq: Int = 24               // pulses per quarter note

    //private let log = Logger(subsystem: "universa.midi", category: "MIDIClockCenter")

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "MIDIClockCenter.timer", qos: .userInteractive)
    private let lock = NSLock()

    private init() {
        startTimer()
    }

    // MARK: - Public API
    func setBPM(_ newValue: Double) {
        let clamped = max(10.0, min(400.0, newValue))
        guard clamped != bpm else { return }
        bpm = clamped
        restartTimer()
    }

    func setPPQ(_ newValue: Int) {
        let clamped = max(1, min(960, newValue))
        guard clamped != ppq else { return }
        ppq = clamped
        restartTimer()
    }

    // Convenience for external re-sync without changing bpm/ppq
    func resync() {
        DispatchQueue.main.async { [weak self] in
            self?.tick = 0; self?.phase = 0
        }
    }

    // MARK: - Timer lifecycle
    private func restartTimer() {
        stopTimer()
        startTimer()
    }

    private func startTimer() {
        let interval = (60.0 / bpm) / Double(ppq) // seconds per tick
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Zero leeway for tighter scheduling (slightly higher power usage)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .nanoseconds(0))
        t.setEventHandler { [weak self] in self?.handleTick() }
        timer = t
        t.resume()
    }

    private func stopTimer() {
        timer?.setEventHandler {} // break retain cycles safely
        timer?.cancel()
        timer = nil
    }

    private func handleTick() {
        // Compute next tick/phase off main quickly
        lock.lock()
        let next = tick &+ 1
        let ticksPerBeat = UInt64(ppq)
        let newPhase = Double(next % ticksPerBeat) / Double(ticksPerBeat)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tick = next
            self.phase = newPhase
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
