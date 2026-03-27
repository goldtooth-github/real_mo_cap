import SwiftUI
import UIKit
import SceneKit
import Foundation
import Combine
import CoreGraphics
import UniformTypeIdentifiers


// MARK: - Control Panel State
struct ControlPanelState: Codable, Equatable {
    var selection: Int
    var previousSelection: Int
    var settledSelection: Int
    var didActivateInitial: Bool
    var jellyfishPaused: Bool
    var meshbirdPaused: Bool
    var barleyPaused: Bool
    var boidsPaused: Bool
    var plantsPaused: Bool
    var wavesPaused: Bool
    var flowerPaused: Bool
    var planetsPaused: Bool
    var controlPanelVisible: Bool
    var isDisplayLockPressed: Bool
}


struct MIDIMenuView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var settingsIO: SettingsIOActions
    // Removed EnvironmentObject to avoid hard dependency when presented in sheets
    @Binding var slots: [MIDIParams]
    // Externally-supplied list of tracker names
    var trackers: [String] = ["X", "Y"]
    // Optional color to display for each tracker (e.g., Planet color)
    var trackerColors: [String: Color] = [:]
    // Optional readable color names for each tracker
    var trackerColorNames: [String: String] = [:]
    // Optional external focus index to programmatically scroll/highlight a slot
    @Binding var focusIndex: Int?
    // Optional send callback provided by the host view
    var onSend: (([MIDIParams]) -> Void)? = nil
    // Remove onImport/onExport/onReset
    private let maxSlots = 6
    
    // Local highlight state
    @State private var highlightIndex: Int? = nil
    @State private var previousCount: Int = 0
    // Replace simple bool with published BLE state tracking
    @State private var bleState: BluetoothMIDIPeripheral.PublicState = BluetoothMIDIPeripheral.currentPublicState ?? .idle
    @State private var bleStateCancellable: AnyCancellable?
    @State private var bleNotificationCancellable: AnyCancellable?
    @State private var bleTimeRemaining: TimeInterval = 0
    @State private var bleTimeCancellable: AnyCancellable?
    // Solo state is provided by host so it can gate runtime MIDI output
    @Binding var soloIndex: Int?
    
    // Control panel state binding
    @Binding var controlPanelState: ControlPanelState
    
    init(
        slots: Binding<[MIDIParams]>,
        controlPanelState: Binding<ControlPanelState>,
        trackers: [String] = ["X", "Y"],
        trackerColors: [String: Color] = [:],
        trackerColorNames: [String: String] = [:],
        focusIndex: Binding<Int?> = .constant(nil),
        soloIndex: Binding<Int?> = .constant(nil),
        onSend: (([MIDIParams]) -> Void)? = nil
    ) {
        self._slots = slots
        self._controlPanelState = controlPanelState
        self.trackers = trackers
        self.trackerColors = trackerColors
        self.trackerColorNames = trackerColorNames
        self._focusIndex = focusIndex
        self._soloIndex = soloIndex
        self.onSend = onSend
    }
    
    // Convenience overload: pass focusIndex without color maps
    init(
        slots: Binding<[MIDIParams]>,
        trackers: [String] = ["X", "Y"],
        focusIndex: Binding<Int?> = .constant(nil),
        soloIndex: Binding<Int?> = .constant(nil),
        onSend: (([MIDIParams]) -> Void)? = nil
    ) {
        self.init(
            slots: slots,
            controlPanelState: .constant(ControlPanelState(selection: 0, previousSelection: 0, settledSelection: 0, didActivateInitial: false, jellyfishPaused: false, meshbirdPaused: false, barleyPaused: false, boidsPaused: false, plantsPaused: false, wavesPaused: false, flowerPaused: false, planetsPaused: false, controlPanelVisible: true, isDisplayLockPressed: false)),
            trackers: trackers,
            trackerColors: [:],
            trackerColorNames: [:],
            focusIndex: focusIndex,
            soloIndex: soloIndex,
            onSend: onSend
        )
    }

    // Convenience overload: include color maps without requiring control panel binding
    init(
        slots: Binding<[MIDIParams]>,
        trackers: [String] = ["X", "Y"],
        trackerColors: [String: Color] = [:],
        trackerColorNames: [String: String] = [:],
        focusIndex: Binding<Int?> = .constant(nil),
        soloIndex: Binding<Int?> = .constant(nil),
        onSend: (([MIDIParams]) -> Void)? = nil
    ) {
        self.init(
            slots: slots,
            controlPanelState: .constant(ControlPanelState(selection: 0, previousSelection: 0, settledSelection: 0, didActivateInitial: false, jellyfishPaused: false, meshbirdPaused: false, barleyPaused: false, boidsPaused: false, plantsPaused: false, wavesPaused: false, flowerPaused: false, planetsPaused: false, controlPanelVisible: true, isDisplayLockPressed: false)),
            trackers: trackers,
            trackerColors: trackerColors,
            trackerColorNames: trackerColorNames,
            focusIndex: focusIndex,
            soloIndex: soloIndex,
            onSend: onSend
        )
    }
    
    private func ensureBLESubscription() {
        if bleStateCancellable == nil {
            bleStateCancellable = BluetoothMIDIPeripheral.statePublisher?
                .receive(on: RunLoop.main)
                .sink { newState in
                    bleState = newState
                }
        }
        if bleNotificationCancellable == nil {
            bleNotificationCancellable = NotificationCenter.default.publisher(for: BluetoothMIDIPeripheral.stateChangedNotification)
                .receive(on: RunLoop.main)
                .sink { note in
                    if let raw = note.userInfo?["state"] as? String,
                       let mapped = BluetoothMIDIPeripheral.PublicState(rawValue: raw) {
                        bleState = mapped
                    }
                }
        }
        if bleTimeCancellable == nil {
            bleTimeCancellable = BluetoothMIDIPeripheral.timeRemainingPublisher?
                .receive(on: RunLoop.main)
                .sink { remaining in
                    bleTimeRemaining = remaining
                }
        }
    }
    
    private func syncImmediate() {
        if let current = BluetoothMIDIPeripheral.currentPublicState { bleState = current }
    }
    
    var body: some View {
        let isMacCatalyst: Bool = {
            if #available(iOS 13.0, *) { return ProcessInfo.processInfo.isMacCatalystApp }
            return false
        }()
        let isIOSOnMac: Bool = ProcessInfo.processInfo.isiOSAppOnMac
        VStack(alignment: .leading, spacing: 12) {
            // Header stays pinned
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                Text("MIDI Parameters")
                    .font(.title)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: addSlot) {
                    Text("Add Midi Slot")
                    Label("Add", systemImage: "plus.circle").labelStyle(.iconOnly).imageScale(.large)
                }
                .disabled(slots.count >= maxSlots)
                .help(slots.count >= maxSlots ? "Maximum of \(maxSlots) slots" : "Add MIDI slot")
            }
            
            
            // Bluetooth button (hidden on Mac Catalyst)
            if !isMacCatalyst {
                HStack {
                    Button(action: toggleBLE) {
                        let advertising = bleState == .advertising || bleState == .starting
                        HStack(spacing: 6) {
                            Image(systemName: advertising
                                  ? "dot.radiowaves.left.and.right"
                                  : "antenna.radiowaves.left.and.right")
                                .foregroundColor(advertising ? .blue : .gray)
                            if advertising {
                                let secs = Int(bleTimeRemaining)
                                let mm = secs / 60
                                let ss = secs % 60
                                Text("Discoverable… \(String(format: "%d:%02d", mm, ss))")
                            } else {
                                Text("Advertise BLE MIDI")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
            
            
            Divider()
            
            // Scrollable list of slots with reader for programmatic scroll
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(slots.enumerated()), id: \.element.id) { (i, slot) in
                            let safeIndex = min(i, max(0, slots.count - 1))
                            let currentSlot = slots.indices.contains(safeIndex) && slots[safeIndex].id == slot.id ? slots[safeIndex] : (slots.first(where: { $0.id == slot.id }) ?? slot)
                            
                            MIDISlotRow(
                                index: i,
                                params: Binding(
                                    get: { currentSlot },
                                    set: { updated in
                                        // Thread-safe update by id lookup
                                        DispatchQueue.main.async {
                                            if let idx = slots.firstIndex(where: { $0.id == slot.id }),
                                               slots.indices.contains(idx) {
                                                slots[idx] = updated
                                            }
                                        }
                                    }
                                ),
                                highlight: highlightIndex == i,
                                trackers: trackers,
                                trackerColors: trackerColors,
                                trackerColorNames: trackerColorNames,
                                showRemove: slots.count > 1,
                                onRemove: {
                                    DispatchQueue.main.async {
                                        removeSlot(id: slot.id)
                                    }
                                },
                                onTrackerOpen: {
                                    withAnimation(.easeInOut) { proxy.scrollTo(slot.id, anchor: .center) }
                                },
                                // Solo wiring - use safe current index lookup
                                isSoloed: {
                                    if let currentIdx = slots.firstIndex(where: { $0.id == slot.id }) {
                                        return soloIndex == currentIdx
                                    }
                                    return false
                                }(),
                                isSoloActive: soloIndex != nil,
                                onToggleSolo: {
                                    DispatchQueue.main.async {
                                        if let currentIdx = slots.firstIndex(where: { $0.id == slot.id }) {
                                            if soloIndex == currentIdx {
                                                soloIndex = nil
                                            } else {
                                                soloIndex = currentIdx
                                            }
                                        }
                                    }
                                }
                            )
                            .id(slot.id)
                        }
                    }
                }
                .onAppear {
                    previousCount = slots.count
                    if let idx = focusIndex, slots.indices.contains(idx) {
                        DispatchQueue.main.async {
                            let targetID = slots[idx].id
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { proxy.scrollTo(targetID, anchor: .center) }
                            triggerHighlight(idx)
                            focusIndex = nil
                        }
                    }
                }
                // Auto scroll/highlight on add
                .onChange(of: slots.count) { old, new in
                    if new > old, new > 0 {
                        if let lastID = slots.last?.id {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { proxy.scrollTo(lastID, anchor: .center) }
                        }
                        triggerHighlight(max(new - 1, 0))
                    }
                    previousCount = new
                }
                // External focus/scroll highlight
                .onChange(of: focusIndex) { _, newVal in
                    guard let idx = newVal, slots.indices.contains(idx) else { return }
                    let targetID = slots[idx].id
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { proxy.scrollTo(targetID, anchor: .center) }
                    triggerHighlight(idx)
                    // reset so repeated same index works
                    focusIndex = nil
                }
            }

            // Bottom-right action bar (always shown; now always enabled)
            Divider()
            HStack(spacing: 12) {
                Text("Global Settings:")
                Link(destination: URL(string: "https://sites.google.com/view/lifeform-oscillator/home")!) {
                    Label("", systemImage: "book")
                }
                .help("Open the Lifeform Oscillator Manual")
                // Vertical divider between Manual and Load
                Divider()
                    .frame(width: 1, height: 24)
                    .background(Color.secondary.opacity(0.5))
                    .padding(.horizontal, 2)
                Button(action: {
                    let trigger = settingsIO.requestImport
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { trigger?() }
                }) {
                    HStack(spacing: 6) { Image(systemName: "folder"); Text("Load") }
                }
                Button(action: {
                    let trigger = settingsIO.requestExport
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { trigger?() }
                }) {
                    HStack(spacing: 6) { Image(systemName: "square.and.arrow.down"); Text("Save") }
                }
           
            }
            .padding(.top, 6)
        }
        .onAppear {
            // Ensure at least one slot exists and has a default tracker
            if slots.isEmpty {
                var first = MIDIParams(); first.tracked = trackers.first ?? ""; slots = [first]
            } else {
                for i in slots.indices {
                    if slots[i].tracked.isEmpty {
                        slots[i].tracked = trackers.first ?? ""
                    }
                }
            }
            ensureBLESubscription()
            syncImmediate()
            // Removed provider/applier wiring; Save/Load actions now delegate to the active simulation via settingsIO.request* hooks.
        }
         .onDisappear {
             bleStateCancellable?.cancel(); bleStateCancellable = nil
             bleNotificationCancellable?.cancel(); bleNotificationCancellable = nil
             bleTimeCancellable?.cancel(); bleTimeCancellable = nil
             // Clear solo when menu disappears so all slots are active again
             soloIndex = nil
        }
        .padding()
    }
    
    private func triggerHighlight(_ index: Int) {
        highlightIndex = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if highlightIndex == index {
                withAnimation(.easeInOut(duration: 0.2)) { highlightIndex = nil }
            }
        }
    }
    
    private func addSlot() {
        guard slots.count < maxSlots else { return }
        var newSlot = MIDIParams()
        newSlot.tracked = trackers.first ?? ""
        slots.append(newSlot)
    }
    
    private func removeSlot(at index: Int) {
        guard slots.indices.contains(index), slots.count > 1 else { return }
        slots.remove(at: index)
        // Keep soloIndex consistent after removal
        if let s = soloIndex {
            if s == index {
                soloIndex = nil
            } else if s > index {
                soloIndex = s - 1
            }
        }
    }
    
    private func removeSlot(id: UUID) {
        if let idx = slots.firstIndex(where: { $0.id == id }) {
            removeSlot(at: idx)
        }
    }
    
    private func toggleBLE() {
        // Prevent advertising on Mac Catalyst
        let isMacCatalyst: Bool = {
            if #available(iOS 13.0, *) {
                return ProcessInfo.processInfo.isMacCatalystApp
            }
            return false
        }()
        if isMacCatalyst { return }
        
        let advertising = bleState == .advertising || bleState == .starting

        if advertising {
            // Advertising → stop
            BluetoothMIDIPeripheral.stop()
            bleState = .idle
        } else {
            // Idle → start advertising
            BluetoothMIDIPeripheral.ensureStarted()
            BluetoothMIDIPeripheral.restartAdvertising()
            ensureBLESubscription()
            syncImmediate()
        }
    }
}


// MARK: - Slot Row
private struct MIDISlotRow: View {
    let index: Int
    @Binding var params: MIDIParams
    let highlight: Bool
    let trackers: [String]
    let trackerColors: [String: Color]
    let trackerColorNames: [String: String]
    let showRemove: Bool
    var onRemove: () -> Void
    var onTrackerOpen: () -> Void
    // Solo props
    let isSoloed: Bool
    let isSoloActive: Bool
    var onToggleSolo: () -> Void
    // Sweep state
    @State private var isSweeping: Bool = false
    @State private var sweepUpper: Int? = nil
    @State private var sweepTimer: Timer? = nil

    var body: some View {
        let bgOpacity: Double = (index % 2 == 0) ? 0.08 : 0.16
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("MIDI Slot \(index + 1)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(width: 75, alignment: .leading) // Fixed width for label
                
                // Solo button always at same x offset
                Button(action: onToggleSolo) {
                    HStack(spacing: 6) {
                        Image(systemName: isSoloed ? "speaker.wave.2.circle.fill" : "speaker.wave.2.circle")
                            .imageScale(.medium)
                        Text("Solo")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((isSoloed ? Color.yellow.opacity(0.25) : Color.yellow.opacity(0.08)))
                    .foregroundColor(isSoloed ? .yellow : .secondary)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help(isSoloed ? "Unsolo slot \(index + 1)" : "Solo slot \(index + 1)")
                Button(action: startSweep) {
                    Image(systemName: "arrow.forward.to.line")
                        .imageScale(.medium)
                        .foregroundColor(
                            (isSoloActive && !isSoloed) ? Color.gray :
                            (isSweeping ? Color.gray : Color.blue)
                        )
                }
                .help("Sweep MIDI slot \(index + 1) from lower to upper range")
                .disabled(isSweeping || (isSoloActive && !isSoloed))
                Spacer()
                if showRemove {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "trash").imageScale(.medium)
                    }
                    .help("Remove slot \(index + 1)")
                }
            }
            // Tracked coordinate selector (custom inline dropdown)
            HStack(spacing: 8) {
                Text("Tracker:   ")
                TrackerSelector(
                    tracked: $params.tracked,
                    trackers: trackers,
                    trackerColors: trackerColors,
                    trackerColorNames: trackerColorNames,
                    onOpen: onTrackerOpen
                )
               
            }
            // MIDI channel
            Stepper("Midi CH: \(params.channel)", value: $params.channel, in: 1...16)
                .accessibilityLabel("MIDI Channel")
            
            // CC number
            Stepper("CC#: \(params.ccNumber)", value: $params.ccNumber, in: 0...127)
                .accessibilityLabel("MIDI CC Number")
            
            // Value range
            RangeSlider(
                range: Binding(
                    get: {
                        if let sweepUpper = sweepUpper {
                            return params.range.lowerBound...sweepUpper
                        } else {
                            return params.range
                        }
                    },
                    set: { newRange in
                        params.range = newRange
                    }
                ),
                bounds: 0...127
            )
        }
        .padding(12)
        .background(
            (highlight ? Color.white.opacity(0.55) : Color.black.opacity(bgOpacity))
                .animation(.easeInOut(duration: 0.15), value: highlight)
        )
        // Dim non-soloed rows when solo is active
        .opacity((isSoloActive && !isSoloed) ? 0.5 : 1.0)
        .cornerRadius(8)
    }

    private func startSweep() {
        // Prevent sweeping if another slot is soloed
        guard !(isSoloActive && !isSoloed) else { return }
        guard !isSweeping else { return }
        isSweeping = true
        let lower = params.range.lowerBound
        let upper = params.range.upperBound
        let steps = max(upper - lower, 1)
        let duration: Double = 1.0
        let interval = duration / Double(steps)
        sweepUpper = lower
        var current = lower
        sweepTimer?.invalidate()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            if current > upper {
                timer.invalidate()
                sweepTimer = nil
                sweepUpper = nil
                isSweeping = false
                return
            }
            sweepUpper = current
            MIDIOutput.send(channel: params.channel, ccNumber: params.ccNumber, value: current)
            current += 1
        }
    }
}

// Simple triangle shape
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// Inline dropdown selector that honors colors and uses the system scrollbar
private struct TrackerSelector: View {
    @Binding var tracked: String
    let trackers: [String]
    let trackerColors: [String: Color]
    let trackerColorNames: [String: String]
    var onOpen: () -> Void = {}
    @State private var isOpen: Bool = false
    private let maxDropdownHeight: CGFloat = 220
    
    private func comp(_ name: String) -> String {
        // Use the full name for lookup, but only display the last component for label
        let parts = name.split(separator: ".")
        return parts.count > 1 ? String(parts.last!) : name
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let selName = tracked
            let selColor = trackerColors[selName]
            // Prefer friendly display name when provided
            let selLabel: String = {
                if let friendly = trackerColorNames[selName], friendly.contains(".x") || friendly.contains(".y") {
                    return friendly
                } else if selName.contains(".x") || selName.contains(".y") {
                    return selName
                } else {
                    return trackerColorNames[selName] ?? selName
                }
            }()
            Button(action: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { isOpen.toggle() }
                if isOpen { onOpen() }
            }) {
                HStack(spacing: 10) {
                    if let c = selColor {
                        // Use a small circle swatch for all trackers (including Boids)
                        Circle()
                            .fill(c)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 0.5))
                    }
                    Text(selLabel)
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                }
            
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.1))
                .cornerRadius(6)
                .frame(maxWidth: .infinity, alignment: .leading)
               // .padding(.leading, 14)// Make button full width
            }
            if isOpen {
                ScrollView(showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(trackers, id: \.self) { name in
                            let c = trackerColors[name]
                            let label: String = {
                                if let friendly = trackerColorNames[name], friendly.contains(".x") || friendly.contains(".y") {
                                    return friendly
                                } else if name.contains(".x") || name.contains(".y") {
                                    return name
                                } else {
                                    return trackerColorNames[name] ?? name
                                }
                            }()
                            Button(action: {
                                tracked = name
                                withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) { isOpen = false }
                            }) {
                                HStack(spacing: 10) {
                                    if let c = c {
                                        Circle()
                                            .fill(c)
                                            .frame(width: 12, height: 12)
                                            .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 0.4))
                                    }
                                    Text(label)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                .padding(.leading, 8)
                                .padding(.trailing, 8)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.06))
                                .frame(maxWidth: .infinity, alignment: .leading) // Make each row full width
                            }
                            .buttonStyle(.plain)
                            Divider().background(Color.white.opacity(0.08))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading) // Make dropdown list full width
                }
                .frame(maxHeight: maxDropdownHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }
        }
    
    }
}

struct RangeSlider: View {
    @Binding var range: ClosedRange<Int>
    let bounds: ClosedRange<Int>
    private let trackHeight: CGFloat = 6
    private let handleDiameter: CGFloat = 22
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Range: \(range.lowerBound) - \(range.upperBound)")
            GeometryReader { geo in
                let width = geo.size.width
                let minValue = Double(bounds.lowerBound)
                let maxValue = Double(bounds.upperBound)
                let lower = Double(range.lowerBound)
                let upper = Double(range.upperBound)
                let lowerX = CGFloat((lower - minValue) / (maxValue - minValue)) * (width - handleDiameter) + handleDiameter/2
                let upperX = CGFloat((upper - minValue) / (maxValue - minValue)) * (width - handleDiameter) + handleDiameter/2
                ZStack {
                    // Full track (no horizontal padding)
                    RoundedRectangle(cornerRadius: trackHeight/2)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: trackHeight)
                        .frame(width: width)
                        .position(x: width/2, y: handleDiameter/2)
                    // Selected range track
                    RoundedRectangle(cornerRadius: trackHeight/2)
                        .fill(Color.accentColor)
                        .frame(width: abs(upperX - lowerX), height: trackHeight)
                        .position(x: (lowerX + upperX)/2, y: handleDiameter/2)
                    // Lower handle
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: handleDiameter, height: handleDiameter)
                        .position(x: lowerX, y: handleDiameter/2)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = min(max(value.location.x, handleDiameter/2), width - handleDiameter/2)
                                let percent = Double((x - handleDiameter/2) / (width - handleDiameter))
                                let newValue = Int(round(percent * (maxValue - minValue) + minValue))
                                if newValue <= range.upperBound && newValue >= bounds.lowerBound {
                                    range = newValue...range.upperBound
                                }
                            })
                    // Upper handle
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: handleDiameter, height: handleDiameter)
                        .position(x: upperX, y: handleDiameter/2)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = min(max(value.location.x, handleDiameter/2), width - handleDiameter/2)
                                let percent = Double((x - handleDiameter/2) / (width - handleDiameter))
                                let newValue = Int(round(percent * (maxValue - minValue) + minValue))
                                if newValue >= range.lowerBound && newValue <= bounds.upperBound {
                                    range = range.lowerBound...newValue
                                }
                            })
                }
                .frame(height: handleDiameter)
            }
            .frame(height: handleDiameter)
        }
    }
}

// MARK: - DataDocument for file export/import
struct DataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: data)
    }
}
