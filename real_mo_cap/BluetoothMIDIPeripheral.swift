import Foundation
import CoreBluetooth
import UIKit
import Combine

// MARK: - BluetoothMIDIPeripheral
//
// BLE MIDI Peripheral (iOS) — informed by two reference implementations:
//
// 1. stuffmatic/zephyr-ble-midi (github.com/stuffmatic/zephyr-ble-midi)
//    Gold-standard C implementation for Zephyr RTOS (14★, actively maintained).
//    Key patterns adopted:
//      - Three-state model: NOT_CONNECTED → CONNECTED → READY
//      - READY = CCC notify enabled (midi_ccc_cfg_changed)
//      - on_connected/on_disconnected via bt_conn callbacks
//      - Context reset on each new connection
//      - 7.5 ms connection interval for low latency
//      - MTU-aware packet sizing (MTU - 3)
//      - Read callback returns empty payload (spec section 3)
//
// 2. kshoji/BLE-MIDI-for-Android (github.com/kshoji/BLE-MIDI-for-Android)
//    Android BLE MIDI library (135★, long-lived, proven production use).
//    Key patterns adopted:
//      - Device Information Service (0x180A) with manufacturer + model
//      - Explicit CCC descriptor (0x2902) on MIDI characteristic
//      - onConnectionStateChange for connect/disconnect lifecycle
//      - Per-device tracking via BluetoothDevice address
//      - MTU negotiation → buffer size = max(20, mtu-3)
//
// Also referenced:
//   - AudioKit/AudioKit (11k★): uses Apple's CABTMIDICentralViewController
//   - orchetect/MIDIKit (331★): pure CoreMIDI wrapper, no BLE peripheral
//
// CBPeripheralManager Limitations vs. reference impls:
//   - No on_connected/on_disconnected equivalent (Zephyr bt_conn_cb)
//   - No onConnectionStateChange equivalent (Android BluetoothGattServerCallback)
//   - We detect connection via: didReceiveRead, didSubscribeTo, didReceiveWrite
//   - We detect disconnect via: didUnsubscribeFrom, interaction timeout watchdog
//   - macOS MIDI Studio uses implicit notification path (no formal CCC subscribe)

class BluetoothMIDIPeripheral: NSObject, CBPeripheralManagerDelegate {

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Public / Static API
    // ═══════════════════════════════════════════════════════════════

    static var instance: BluetoothMIDIPeripheral?

    static var shared: BluetoothMIDIPeripheral {
        if let inst = instance { return inst }
        fatalError("BluetoothMIDIPeripheral.shared accessed before init. Call ensureStarted().")
    }

    @discardableResult
    static func ensureStarted() -> BluetoothMIDIPeripheral {
        if let inst = instance {
            inst.enqueue { if inst.peripheralManager == nil { inst.bootBluetooth() } }
            return inst
        }
        let p = BluetoothMIDIPeripheral()
        instance = p
        p.enqueue { p.bootBluetooth() }
        return p
    }

    static func start() { _ = ensureStarted() }
    static func stop() { instance?.enqueue { instance?.shutdown() } }
    static func restartAdvertising() {
        _ = ensureStarted()
        instance?.enqueue { instance?.fullRebuild(reason: "user requested restart") }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Public State
    // ═══════════════════════════════════════════════════════════════

    /// Maps to Zephyr ble_midi_ready_state_t.
    /// .subscribed = READY (data can flow). Kept as "subscribed" for caller compat.
    enum PublicState: String { case idle, starting, advertising, subscribed, stopping }

    @Published private(set) var publicState: PublicState = .idle
    @Published private(set) var isAdvertisingPublished: Bool = false

    static let stateChangedNotification = Notification.Name("BLEStateChangedNotification")
    static var currentPublicState: PublicState? { instance?.publicState }
    static var statePublisher: AnyPublisher<PublicState, Never>? {
        instance?.$publicState.eraseToAnyPublisher()
    }
    static var timeRemainingPublisher: AnyPublisher<TimeInterval, Never>? {
        instance?.$advertisingTimeRemaining.eraseToAnyPublisher()
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Configuration
    // ═══════════════════════════════════════════════════════════════

    /// Watchdog interval — 1s for smooth countdown display.
    static var watchdogInterval: TimeInterval = 1

    /// Advertising window (seconds). After this duration, advertising stops automatically
    /// to save battery. User must tap "Enable BLE" again to re-advertise.
    /// Set to 0 to disable (advertise indefinitely).
    static var advertisingTimeout: TimeInterval = 60

    // Legacy compat (callers reference these)
    static var stopAdvertisingOnFirstSubscribe = true
    static var stopAdvertisingAfterSubscribe: Bool = false
    static var autoRestartAdvertising = true
    static var restartDebounce: TimeInterval = 3
    static var enableBackoff = true
    static var baseBackoff: TimeInterval = 1
    static var maxBackoff: TimeInterval = 60

    // ═══════════════════════════════════════════════════════════════
    // MARK: - UUIDs
    // ═══════════════════════════════════════════════════════════════

    // Standard BLE MIDI Service & Characteristic (same across all reference impls)
    private let midiServiceUUID        = CBUUID(string: "03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
    private let midiCharacteristicUUID = CBUUID(string: "7772E5DB-3868-4112-A1A9-F2669D106BF3")

    // Note: Android ref (kshoji) adds Device Information Service (0x180A) with
    // manufacturer name + model number. iOS blocks third-party apps from registering
    // reserved Bluetooth SIG service UUIDs, so we cannot add 0x180A here.
    // The local name in advertising data serves the same purpose for macOS MIDI Studio.

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Internals
    // ═══════════════════════════════════════════════════════════════

    private var peripheralManager: CBPeripheralManager?
    private var midiCharacteristic: CBMutableCharacteristic?
    private var servicesAdded: Int = 0    // count of services confirmed via didAdd
    private let servicesNeeded: Int = 1   // MIDI service only (Device Info blocked by iOS)

    // Subscriber tracking (for auto-toggle only)
    private var hasFormalSubscriber: Bool = false

    // Advertising timeout tracking
    private var advertisingStartedAt: Date?

    /// Seconds remaining in the advertising window. Published for UI countdown.
    @Published private(set) var advertisingTimeRemaining: TimeInterval = 0

    // Auto-toggle: macOS implicit notification path workaround
    private var didAutoToggle: Bool = false

    // Packet queue (flow control)
    // Ref: Zephyr uses ring_buf + atomic waiting_for_notif_buf flag
    // Ref: Android uses notifyCharacteristicChanged return value
    private var pendingPackets: [Data] = []
    private let maxPendingPackets = 64

    // Serial queue (Zephyr: single-threaded BLE callbacks; Android: GATT server callback thread)
    private let workQueue = DispatchQueue(label: "ble.midi.peripheral", qos: .userInitiated)

    // Single watchdog timer (consolidates previous 3 timers)
    private var watchdogTimer: Timer?

    // Identity
    private let instanceID = UUID()
    private let advertisedLocalName: String

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Init
    // ═══════════════════════════════════════════════════════════════

    private override init() {
        let short = instanceID.uuidString.prefix(4)
        advertisedLocalName = "Lifeform MIDI BLE-\(short)"
        super.init()

        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate),
                                               name: UIApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)

        log("Init id=\(instanceID) name=\(advertisedLocalName)")
        startWatchdog()
    }

    deinit { watchdogTimer?.invalidate() }

    private func enqueue(_ block: @escaping () -> Void) {
        workQueue.async(execute: block)
    }

    private func log(_ msg: String) {
        print("[BLE MIDI] \(msg)")
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Lifecycle
    // ═══════════════════════════════════════════════════════════════

    private func bootBluetooth() {
        guard peripheralManager == nil else { return }
        log("Starting CBPeripheralManager...")
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: workQueue,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: true]
        )
    }

    private func shutdown() {
        log("Shutdown")
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        peripheralManager?.delegate = nil
        peripheralManager = nil
        resetConnectionState()
        midiCharacteristic = nil
        servicesAdded = 0
        advertisingStartedAt = nil
        advertisingTimeRemaining = 0
        publishState(.idle)
    }

    private func resetConnectionState() {
        hasFormalSubscriber = false
        didAutoToggle = false
        pendingPackets.removeAll()
    }

    /// Full teardown + rebuild. Ref: Zephyr dynamic service re-registration.
    private func fullRebuild(reason: String) {
        guard let pm = peripheralManager, pm.state == .poweredOn else { return }
        log("Rebuild: \(reason)")
        pm.stopAdvertising()
        pm.removeAllServices()
        midiCharacteristic = nil
        servicesAdded = 0
        resetConnectionState()
        publishState(.idle)
        addServices()
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Service Setup
    // ═══════════════════════════════════════════════════════════════

    private func addServices() {
        guard let pm = peripheralManager, pm.state == .poweredOn else { return }
        guard servicesAdded == 0, midiCharacteristic == nil else { return }

        // Note: Device Information Service (0x180A) cannot be added on iOS —
        // reserved Bluetooth SIG UUIDs are blocked. Android ref (kshoji) adds it
        // for device identification, but on iOS the advertising local name suffices.

        // ── BLE MIDI Service ─────────────────────────────────────
        // Properties match both reference impls:
        //   Zephyr:  BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY | BT_GATT_CHRC_WRITE_WITHOUT_RESP
        //   Android: PROPERTY_NOTIFY | PROPERTY_READ | PROPERTY_WRITE_NO_RESPONSE
        // value: nil → dynamic (reads handled via delegate → empty response per spec)
        let characteristic = CBMutableCharacteristic(
            type: midiCharacteristicUUID,
            properties: [.read, .notify, .writeWithoutResponse],
            value: nil,
            permissions: [.readable, .writeable]
        )
        // Note: CoreBluetooth auto-creates the CCC descriptor (0x2902) for
        // characteristics with .notify. Android adds it explicitly:
        //   new BluetoothGattDescriptor(DESCRIPTOR_CLIENT_CHARACTERISTIC_CONFIGURATION, ...)
        // We don't add it manually — doing so causes CBErrorInvalidParameters on iOS.
        midiCharacteristic = characteristic

        let midiService = CBMutableService(type: midiServiceUUID, primary: true)
        midiService.characteristics = [characteristic]
        pm.add(midiService)

        log("Adding MIDI service")
    }

    private func startAdvertisingIfReady() {
        guard let pm = peripheralManager, pm.state == .poweredOn else { return }
        guard servicesAdded >= servicesNeeded, midiCharacteristic != nil else { return }
        guard !pm.isAdvertising else { return }

        pm.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [midiServiceUUID],
            CBAdvertisementDataLocalNameKey: advertisedLocalName
        ])
        // Only set the start time if not already set (e.g. during auto-toggle resume)
        if advertisingStartedAt == nil {
            advertisingStartedAt = Date()
        }
        log("startAdvertising name=\(advertisedLocalName) timeout=\(Self.advertisingTimeout > 0 ? "\(Int(Self.advertisingTimeout))s" : "none")")
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - State Publishing
    // ═══════════════════════════════════════════════════════════════

    // Simplified: no connection tracking. The peripheral advertises for 60s,
    // data flows whenever a central reads/writes/subscribes, and the only
    // state transitions are idle ↔ advertising (controlled by timeout or user tap).
    //
    // When a central actually interacts (read/subscribe/write), we stop
    // advertising and return to idle — the connection has been made.

    private func centralDidConnect(reason: String) {
        log("Central connected (\(reason)) — cancelling advertising timer")
        // Do NOT call peripheralManager?.stopAdvertising() here.
        // On iOS, stopAdvertising() after a central is connected can disrupt
        // the GATT notification state, causing updateValue to silently fail.
        // Advertising will stop naturally when the 60s timeout expires,
        // or CoreBluetooth will stop it implicitly once a connection is active.
        advertisingStartedAt = nil
        DispatchQueue.main.async { [weak self] in
            self?.advertisingTimeRemaining = 0
        }
        publishState(.idle)
    }

    private func publishState(_ newState: PublicState) {
        let advFlag = peripheralManager?.isAdvertising == true
        let apply = { [weak self] in
            guard let self else { return }
            self.publicState = newState
            self.isAdvertisingPublished = advFlag
            NotificationCenter.default.post(
                name: Self.stateChangedNotification,
                object: self,
                userInfo: [
                    "state": newState.rawValue,
                    "advertising": advFlag
                ]
            )
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Watchdog (replaces Zephyr's on_disconnected)
    // ═══════════════════════════════════════════════════════════════

    // Single timer replaces the previous three (watchdog + subscriptionCheck + subscriptionWatchdog).
    // Ref impls don't poll — they have on_disconnected callbacks. We must poll because
    // CBPeripheralManager has no disconnect callback.

    private func startWatchdog() {
        DispatchQueue.main.async { [weak self] in
            self?.watchdogTimer?.invalidate()
            self?.watchdogTimer = Timer.scheduledTimer(
                withTimeInterval: Self.watchdogInterval,
                repeats: true
            ) { [weak self] _ in
                self?.enqueue { self?.watchdogTick() }
            }
        }
    }

    private func watchdogTick() {
        // ── Advertising timeout ──────────────────────────────────
        if let pm = peripheralManager, pm.isAdvertising,
           Self.advertisingTimeout > 0,
           let started = advertisingStartedAt {
            let elapsed = Date().timeIntervalSince(started)
            let remaining = max(0, Self.advertisingTimeout - elapsed)
            let remainingSnap = remaining
            DispatchQueue.main.async { [weak self] in
                self?.advertisingTimeRemaining = remainingSnap
            }
            if remaining <= 0 {
                log("Advertising timeout (\(Int(Self.advertisingTimeout))s) — stopping")
                pm.stopAdvertising()
                advertisingStartedAt = nil
                DispatchQueue.main.async { [weak self] in
                    self?.advertisingTimeRemaining = 0
                }
                publishState(.idle)
                return
            }
        } else {
            // Not advertising — zero out remaining
            if advertisingTimeRemaining != 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.advertisingTimeRemaining = 0
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Auto-Toggle (macOS implicit notification workaround)
    // ═══════════════════════════════════════════════════════════════

    // macOS MIDI Studio reads the MIDI characteristic but never writes the CCC
    // descriptor. After the first read we rebuild the GATT service so the
    // implicit notification path is established. This is equivalent to
    // Zephyr's dynamic service re-registration (CONFIG_BT_GATT_DYNAMIC_DB).

    private func performAutoToggle() {
        guard !didAutoToggle else { return }
        didAutoToggle = true
        log("Auto-toggle: rebuilding to establish implicit notification path...")

        guard let pm = peripheralManager, pm.state == .poweredOn else { return }

        pm.stopAdvertising()
        pm.removeAllServices()
        midiCharacteristic = nil
        servicesAdded = 0

        workQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.log("Auto-toggle: rebuilding services...")
            self.addServices()
            // The rebuild IS the connection event — the Mac will reconnect
            // and start receiving notifications. Cancel the advertising timer
            // so the 60s timeout doesn't kill the connection later.
            self.centralDidConnect(reason: "auto-toggle rebuild complete")
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Sending Data
    // ═══════════════════════════════════════════════════════════════

    // Ref Zephyr: send_packet → bt_gatt_notify_cb
    // Ref Android: notifyCharacteristicChanged
    //
    // IMPORTANT: We do NOT gate sends on hasFormalSubscriber.
    // macOS MIDI Studio never formally subscribes (no CCC write) but
    // updateValue still works via Apple's implicit notification path.
    // Ref Zephyr gates on READY state; we just send whenever possible.

    func sendMIDIData(_ bytes: [UInt8]) {
        enqueue { self.send(bytes) }
    }

    private func send(_ bytes: [UInt8]) {
        guard let pm = peripheralManager else {
            log("_send: peripheralManager is nil — dropped")
            return
        }
        guard let ch = midiCharacteristic else {
            log("_send: midiCharacteristic is nil — dropped")
            return
        }
        let data = packBLE(bytes)
        if !pm.updateValue(data, for: ch, onSubscribedCentrals: nil) {
            bufferPacket(data)
        }
    }

    /// BLE MIDI packet: [timestampHigh, timestampLow, ...midiBytes]
    /// Ref: Zephyr ble_midi_writer / Android MidiOutputDevice.transferData
    /// Ref: Zephyr caps packet size to MTU-3 (typically 20+ bytes).
    private func packBLE(_ midi: [UInt8]) -> Data {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let ts = UInt16(ms & 0x3FFF)
        let hi: UInt8 = 0x80 | UInt8((ts >> 7) & 0x7F)
        let lo: UInt8 = 0x80 | UInt8(ts & 0x7F)
        var pkt: [UInt8] = [hi, lo]
        pkt.append(contentsOf: midi)
        return Data(pkt)
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Flow Control
    // ═══════════════════════════════════════════════════════════════

    // Ref Zephyr: ring_buf + waiting_for_notif_buf atomic flag
    // Ref Zephyr: on_notify_done clears waiting_for_notif_buf → retry
    // Our equivalent: peripheralManagerIsReady(toUpdateSubscribers:) → flushPending

    private func bufferPacket(_ data: Data) {
        if pendingPackets.count >= maxPendingPackets {
            pendingPackets.removeFirst(pendingPackets.count - maxPendingPackets + 1)
        }
        pendingPackets.append(data)
    }

    private func flushPending() {
        guard let pm = peripheralManager, let ch = midiCharacteristic else { return }
        while !pendingPackets.isEmpty {
            let pkt = pendingPackets.removeFirst()
            if !pm.updateValue(pkt, for: ch, onSubscribedCentrals: nil) {
                pendingPackets.insert(pkt, at: 0)
                break
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - App Lifecycle
    // ═══════════════════════════════════════════════════════════════

    @objc private func appWillTerminate() { Self.stop() }

    @objc private func appDidBecomeActive() {
        enqueue { [weak self] in
            self?.startAdvertisingIfReady()
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - CBPeripheralManagerDelegate
    // ═══════════════════════════════════════════════════════════════

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        log("peripheralManagerDidUpdateState = \(peripheral.state.rawValue)")
        switch peripheral.state {
        case .poweredOn:
            addServices()
        default:
            peripheral.stopAdvertising()
            publishState(.idle)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService, error: Error?) {
        if let error {
            log("Error adding service \(service.uuid): \(error.localizedDescription)")
            return
        }
        servicesAdded += 1
        log("Service added (\(servicesAdded)/\(servicesNeeded)): \(service.uuid)")
        if servicesAdded >= servicesNeeded {
            startAdvertisingIfReady()
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager,
                                              error: Error?) {
        if let error {
            log("Advertising error: \(error.localizedDescription)")
        } else {
            log("Advertising started")
            publishState(.advertising)
        }
    }

    // ── Subscribe / Unsubscribe ─────────────────────────────────
    // Maps to Zephyr: midi_ccc_cfg_changed (CCC descriptor write)
    // Maps to Android: onDescriptorWriteRequest for 0x2902

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == midiCharacteristicUUID else { return }
        hasFormalSubscriber = true
        log("Central SUBSCRIBED: \(central.identifier.uuidString.prefix(8)) maxLen=\(central.maximumUpdateValueLength)")
        centralDidConnect(reason: "subscribe")
        flushPending()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == midiCharacteristicUUID else { return }
        hasFormalSubscriber = false
        log("Central UNSUBSCRIBED: \(central.identifier.uuidString.prefix(8))")
    }

    // ── Read Request ────────────────────────────────────────────
    // Maps to Zephyr: midi_read_cb → return 0 (empty payload, spec section 3)
    // Maps to Android: onCharacteristicReadRequest → sendResponse(empty)
    //
    // macOS MIDI Studio issues reads on connect. This is our connection signal
    // when the central doesn't formally subscribe via CCC.

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == midiCharacteristicUUID else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
            return
        }

        // Ref Zephyr: "Respond with empty payload as per section 3 of the spec."
        request.value = Data()
        peripheral.respond(to: request, withResult: .success)
        log("Read request from \(request.central.identifier.uuidString.prefix(8))")

        // Auto-toggle for macOS implicit notification path.
        // The first read triggers a GATT rebuild which drops the connection.
        // macOS will reconnect after rebuild. centralDidConnect is called
        // inside performAutoToggle once the rebuild completes.
        if !didAutoToggle {
            workQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.performAutoToggle()
            }
        } else {
            // Subsequent reads — keep the advertising timer cancelled
            centralDidConnect(reason: "read request")
        }
    }

    // ── Write Request ───────────────────────────────────────────
    // Maps to Zephyr: midi_write_cb → ble_midi_parse_packet
    // Maps to Android: onCharacteristicWriteRequest → incomingData

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        var gotMIDI = false
        for req in requests {
            if req.characteristic.uuid == midiCharacteristicUUID {
                gotMIDI = true
                if let data = req.value { handleIncomingMIDI(data) }
            }
            peripheral.respond(to: req, withResult: .success)
        }
        if gotMIDI { centralDidConnect(reason: "write request") }
        flushPending()
    }

    // ── Flow Control ────────────────────────────────────────────
    // Maps to Zephyr: on_notify_done → clear waiting_for_notif_buf → retry

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        log("Ready to update (pending=\(pendingPackets.count))")
        flushPending()
    }

    // ═══════════════════════════════════════════════════════════════
    // MARK: - Incoming MIDI
    // ═══════════════════════════════════════════════════════════════

    private func handleIncomingMIDI(_ data: Data) {
        let bytes = [UInt8](data)
        // Identity Request: F0 7E <deviceId> 06 01 F7
        guard bytes.count >= 6,
              bytes.first == 0xF0,
              bytes[1] == 0x7E,
              bytes[3] == 0x06,
              bytes[4] == 0x01,
              bytes.last == 0xF7 else { return }

        let deviceId = bytes[2]
        let reply: [UInt8] = [
            0xF0, 0x7E, deviceId, 0x06, 0x02,
            0x00, 0x00, 0x66,       // manufacturer ID
            0x00, 0x01,             // family
            0x00, 0x01,             // model
            0x00, 0x00, 0x00, 0x01, // version
            0xF7
        ]
        log("Identity request from deviceId=\(deviceId), replying")
        sendMIDIData(reply)
    }
}
