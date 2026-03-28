// filepath: /Users/nick/Desktop/lifeform/dumbmachine/universa/universa/PrewarmCenter.swift
import Foundation
import CoreMIDI
#if canImport(UIKit)
import UIKit
#endif

// Centralized, idempotent prewarm for subsystems that can hitch on first interaction.
// Call PrewarmCenter.shared.run() during the splash screen to eliminate the
// first-touch hesitation on sliders/controls.
//
// Subsystems warmed:
//   1. CoreMIDI client + output port + virtual source (MIDIOutput.midiManager)
//   2. MIDI clock timer (MIDIClockCenter.shared)
//   3. Global tick router / Combine pipeline (GlobalTickRouter.shared)
//   4. UIKit haptic feedback generators (prepare() primes the Taptic Engine)
//   5. BLE peripheral manager (CBPeripheralManager allocation, no advertising)
final class PrewarmCenter {
    static let shared = PrewarmCenter()
    private var didRun = false
    private init() {}

    /// Call once during app launch (e.g. splash screen onAppear).
    /// Safe to call multiple times — only the first invocation does work.
    func run() {
        guard !didRun else { return }
        didRun = true

        // CoreMIDI must init on main thread — MIDIManager uses Timer.scheduledTimer
        // which needs a RunLoop. Background GCD threads have no RunLoop.
        DispatchQueue.main.async {
            _ = MIDIOutput.midiManager

            // Enable CoreMIDI Network Session so the Mac can receive MIDI over USB/WiFi.
            // connectionPolicy = .anyone lets the Mac connect without manual pairing on the iOS side.
            let session = MIDINetworkSession.default()
            session.isEnabled = true
            session.connectionPolicy = .anyone
        }

        // Other subsystems can init on background safely
        DispatchQueue.global(qos: .userInitiated).async {
            // MIDI clock — starts DispatchSourceTimer on its own queue.
            _ = MIDIClockCenter.shared

            // Global tick router — subscribes to clock via Combine.
            _ = GlobalTickRouter.shared

            // Haptic feedback generators — prepare() primes the Taptic Engine
            #if canImport(UIKit)
            DispatchQueue.main.async {
                let sel = UISelectionFeedbackGenerator(); sel.prepare()
                let imp = UIImpactFeedbackGenerator(style: .light); imp.prepare()
            }
            #endif
        }
    }
    }

