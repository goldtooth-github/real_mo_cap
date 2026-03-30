import Foundation
import Combine

/// Singleton that manages the in-app MIDI slots clipboard (copy / paste between
/// simulations) and the "Global MIDI" override (one set of slots used everywhere).
final class MIDISlotsClipboard: ObservableObject {
    static let shared = MIDISlotsClipboard()

    // MARK: - Clipboard (copy / paste)
    /// The most recently copied slots. `nil` means nothing has been copied yet.
    @Published private(set) var copiedSlots: [MIDIParams]? = nil

    /// Copy the given slots into the clipboard.
    func copy(_ slots: [MIDIParams]) {
        copiedSlots = slots
    }

    /// Returns the clipboard contents (or nil if empty).
    func paste() -> [MIDIParams]? {
        return copiedSlots
    }

    // MARK: - Global MIDI Override
    private static let globalEnabledKey = "MIDI_GLOBAL_ENABLED"
    private static let globalSlotsKey   = "MIDI_GLOBAL_SLOTS"

    /// Whether the global MIDI override is active.
    @Published var isGlobalEnabled: Bool {
        didSet { UserDefaults.standard.set(isGlobalEnabled, forKey: Self.globalEnabledKey) }
    }

    /// The globally-shared MIDI slots (persisted in UserDefaults).
    @Published var globalSlots: [MIDIParams] {
        didSet { persistGlobalSlots() }
    }

    // MARK: - Init
    private init() {
        let enabled = UserDefaults.standard.bool(forKey: Self.globalEnabledKey)
        self.isGlobalEnabled = enabled
        if let data = UserDefaults.standard.data(forKey: Self.globalSlotsKey),
           let loaded = try? JSONDecoder().decode([MIDIParams].self, from: data) {
            self.globalSlots = loaded
        } else {
            self.globalSlots = []
        }
    }

    /// Snapshot the provided slots as the new global set and enable the override.
    func makeGlobal(_ slots: [MIDIParams]) {
        globalSlots = slots
        isGlobalEnabled = true
    }

    /// Clear the global override.
    func clearGlobal() {
        isGlobalEnabled = false
    }

    // MARK: - Persistence
    private func persistGlobalSlots() {
        if let data = try? JSONEncoder().encode(globalSlots) {
            UserDefaults.standard.set(data, forKey: Self.globalSlotsKey)
        }
    }
}
