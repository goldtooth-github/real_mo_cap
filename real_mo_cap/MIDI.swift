import UIKit
import CoreMIDI

// MIDI mapping parameters used by the UI
struct MIDIParams: Identifiable, Codable, Equatable {
    // Stable identity so SwiftUI lists can diff safely
    var id: UUID = UUID()
    var channel: Int = 1
    var ccNumber: Int = 1
    var range: ClosedRange<Int> = 0...127
    var axis: String = "x"
    var coordinateName: String = ""
    var tracked: String = ""
    var inverted: Bool = false

    // Codable compatibility for previously saved data
    private enum CodingKeys: String, CodingKey { case id, channel, ccNumber, range, axis, coordinateName, tracked, rangeLower, rangeUpper, inverted }

    init() {}

    init(id: UUID = UUID(), channel: Int = 1, ccNumber: Int = 1, range: ClosedRange<Int> = 0...127, axis: String = "x", coordinateName: String = "", tracked: String = "", inverted: Bool = false) {
        self.id = id
        self.channel = channel
        self.ccNumber = ccNumber
        self.range = range
        self.axis = axis
        self.coordinateName = coordinateName
        self.tracked = tracked
        self.inverted = inverted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // If id missing in persisted data, generate one
        self.id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        self.channel = (try? container.decode(Int.self, forKey: .channel)) ?? 1
        self.ccNumber = (try? container.decode(Int.self, forKey: .ccNumber)) ?? 1
        // Accept multiple encodings for range: [lower, upper] array (preferred), ClosedRange object, or legacy lower/upper keys
        if let arr = try? container.decode([Int].self, forKey: .range), arr.count >= 2 {
            let lower = min(arr[0], arr[1])
            let upper = max(arr[0], arr[1])
            self.range = lower...upper
        } else if let r = try? container.decode(ClosedRange<Int>.self, forKey: .range) {
            self.range = r
        } else {
            let lower = (try? container.decode(Int.self, forKey: .rangeLower)) ?? 0
            let upper = (try? container.decode(Int.self, forKey: .rangeUpper)) ?? 127
            self.range = min(lower, upper)...max(lower, upper)
        }
        self.axis = (try? container.decode(String.self, forKey: .axis)) ?? "x"
        self.coordinateName = (try? container.decode(String.self, forKey: .coordinateName)) ?? ""
        self.tracked = (try? container.decode(String.self, forKey: .tracked)) ?? ""
        self.inverted = (try? container.decode(Bool.self, forKey: .inverted)) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(channel, forKey: .channel)
        try container.encode(ccNumber, forKey: .ccNumber)
        // Preferred encoding: two-element array [lower, upper]
        try container.encode([range.lowerBound, range.upperBound], forKey: .range)
        try container.encode(axis, forKey: .axis)
        try container.encode(coordinateName, forKey: .coordinateName)
        try container.encode(tracked, forKey: .tracked)
        try container.encode(inverted, forKey: .inverted)
    }

    /// Returns the value after applying inversion within the slot's range.
    /// Use this when recording sparkline history so the visual matches the sent MIDI.
    func applyInversion(_ value: Int) -> Int {
        guard inverted else { return value }
        return range.lowerBound + range.upperBound - value
    }
}

// CoreMIDI output manager with hotplug awareness
final class MIDIManager {
    static var verbose = true
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var outputPort = MIDIPortRef()
    private var destinations: [MIDIEndpointRef] = []
    private var isInitialized = false
    private var lastDestinationRefresh: CFAbsoluteTime = 0
    private var passiveRefreshTimer: Timer?

    init() { initializeMIDI() }

    deinit { passiveRefreshTimer?.invalidate() }

    private func initializeMIDI() {
        guard !isInitialized else { return }
      //  if Self.verbose { print("[MIDI] Initializing CoreMIDI client") }
        // React to device/endpoint changes so USB MIDI reappears without relaunch
        if #available(iOS 11.0, macOS 10.13, *) {
            MIDIClientCreateWithBlock("Lifeform MIDI" as CFString, &client) { [weak self] notePtr in
                guard let self = self else { return }
                let n = notePtr.pointee
              //  if Self.verbose { print("[MIDI] Notification: \(n.messageID.rawValue) -> refreshing destinations") }
                self.refreshDestinations()
            }
        } else {
            MIDIClientCreate("Lifeform MIDI" as CFString, nil, nil, &client)
        }
        MIDIOutputPortCreate(client, "Lifeform MIDI OutputPort" as CFString, &outputPort)
        MIDISourceCreate(client, "Lifeform MIDI Output" as CFString, &source)

        // Register our virtual source with the network MIDI session so that
        // macOS can see it when the iPhone is connected via USB or on the same WiFi.
        // The MIDINetworkSession must be enabled (done in PrewarmCenter) and our
        // source endpoint must be added to the session's source list.
        let session = MIDINetworkSession.default()
        session.isEnabled = true
        session.connectionPolicy = .anyone
        if source != 0 {
            // The session's sourceEndpoint is read-only — our virtual source is
            // automatically discoverable as long as the session is enabled and
            // connectionPolicy is .anyone. No further registration needed.
            // However, we also send via MIDIReceived(source, ...) which makes
            // the data available to any connected network session peer.
        }

        refreshDestinations()
        // Passive refresh every 5s until at least one destination has appeared once
        passiveRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.destinations.isEmpty { self.refreshDestinations() } else { self.passiveRefreshTimer?.invalidate() }
        }
        isInitialized = true
    }

    private func refreshDestinations(force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        if !force && now - lastDestinationRefresh < 0.5 { return } // throttle
        lastDestinationRefresh = now
        let count = MIDIGetNumberOfDestinations()
        var list: [MIDIEndpointRef] = []
        list.reserveCapacity(Int(count))
        for i in 0..<count {
            let d = MIDIGetDestination(i)
            if d != 0 { list.append(d) }
        }
        destinations = list
        if Self.verbose {
            let names = destinations.enumerated().compactMap { (idx, ep) -> String? in
                (getStringProperty(of: ep, property: kMIDIPropertyName) ?? "Endpoint#\(idx)")
            }
           // print("[MIDI] Destinations refreshed (\(destinations.count)): \(names)")
        }
    }

    private func getStringProperty(of obj: MIDIObjectRef, property: CFString) -> String? {
        var unmanaged: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(obj, property, &unmanaged)
        if status == noErr, let v = unmanaged?.takeRetainedValue() { return v as String }
        return nil
    }

    // MARK: - Public Diagnostics
    func dumpDestinations() {
        refreshDestinations(force: true)
        if destinations.isEmpty {
           // print("[MIDI] No hardware destinations available.")
        } else {
            for d in destinations {
                let name = getStringProperty(of: d, property: kMIDIPropertyName) ?? "<Unnamed>"
               // print("[MIDI] Destination: \(name)")
            }
        }
    }

    func sendTestNote(note: UInt8 = 60, velocity: UInt8 = 100, channel: Int = 1, lengthMs: Int = 250) {
        let ch = UInt8(max(0, min(15, channel - 1)))
        let on: [UInt8] = [0x90 | ch, note, velocity]
        sendMIDIMessage(on)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(lengthMs)) { [weak self] in
            let off: [UInt8] = [0x80 | ch, note, 0]
            self?.sendMIDIMessage(off)
        }
    }

    // MARK: - Sending
    func sendControlChange(channel: Int, ccNumber: Int, value: Int) {
        let status = UInt8(0xB0 | UInt8(max(0, min(15, channel - 1))))
        let cc = UInt8(max(0, min(127, ccNumber)))
        let val = UInt8(max(0, min(127, value)))
        sendMIDIMessage([status, cc, val])
    }

    func sendMIDIMessage(_ bytes: [UInt8]) {
        if destinations.isEmpty { refreshDestinations() }
        var list = MIDIPacketList()
        withUnsafeMutablePointer(to: &list) { ptr in
            let pkt = MIDIPacketListInit(ptr)
            MIDIPacketListAdd(ptr, 1024, pkt, 0, bytes.count, bytes)
            // Virtual source for other apps (Mac DAW will see this when device tethered over USB on iOS)
            MIDIReceived(source, ptr)
            var failed = false
            for d in destinations { if MIDISend(outputPort, d, ptr) != noErr { failed = true } }
           
        }
        if Self.verbose {
          //  print("[MIDI] Sent: \(bytes.map { String(format: "%02X", $0) }.joined(separator: " ")) destCount=\(destinations.count)")
        }
    }
}

struct MIDIOutput {
    static var midiManager = MIDIManager()
    static var blePeripheral: BluetoothMIDIPeripheral? { BluetoothMIDIPeripheral.instance }

    static func send(channel: Int, ccNumber: Int, value: Int) {
        midiManager.sendControlChange(channel: channel, ccNumber: ccNumber, value: value)
        let status = UInt8(0xB0 | UInt8(max(0, min(15, channel - 1))))
        let cc = UInt8(max(0, min(127, ccNumber)))
        let val = UInt8(max(0, min(127, value)))
        blePeripheral?.sendMIDIData([status, cc, val])
    }

    /// Convenience that reads inversion from the slot and flips the value
    /// within the slot's range when `inverted` is true.
    static func send(slot: MIDIParams, value: Int) {
        let v = slot.applyInversion(value)
        send(channel: slot.channel, ccNumber: slot.ccNumber, value: max(slot.range.lowerBound, min(slot.range.upperBound, v)))
    }

    // Diagnostics
   // static func dumpDestinations() { midiManager.dumpDestinations() }
 //   static func sendTestNote() { midiManager.sendTestNote() }
  //  static func setVerbose(_ v: Bool) { MIDIManager.verbose = v }
}
