import SwiftUI
import SceneKit
import UIKit
import Combine
import QuartzCore

// MARK: - MIDI CC Deduplication Cache
private final class MIDISendCache_MBAsync { var lastSentCCValues: [Int: Int] = [:] }

// Persistable settings for Simple Plant Ladybirds
private struct SimplePlantSettings: Codable {
    var rotationAngle: Float
    var speedMultiplier: Float
    var sceneScale: Float
    var displayLFOOutputs: Bool
}
// New: bundle settings + MIDI slots
private struct SimplePlantPreset: Codable {
    var settings: SimplePlantSettings
    var midiSlots: [MIDIParams]
}

// MARK: - SimHolder for persistent simulation
final class SimplePlantLadybirdsSimHolder: ObservableObject { @Published var sim: SimplePlantLadybirdsSimulationAsync? }

// MARK: - SimplePlantLadybirdsLifeformView
struct SimplePlantLadybirdsLifeformView: View {
    // MARK: - View State & Parameters
    var isActive: Bool = false
    var isPaused: Binding<Bool> // now mandatory
    @StateObject private var cameraState = CameraOrbitState()
    @StateObject private var simHolder = SimplePlantLadybirdsSimHolder()
    var isDisplayLockPressed: Binding<Bool>
    @State private var scnViewRef: SCNView? = nil
    @State private var pinchGesture: UIPinchGestureRecognizer? = nil
    @State private var rotationAngle: Float = 0.0
    @State private var speedMultiplier: Float = 1.0
    @State private var sceneScale: Float = 2.0
    private let sceneScaleRange: ClosedRange<Float> = 0.4...6.0
    // MIDI/LFO state
    @State private var midiSlots: [MIDIParams] = []
    @State private var showMidiMenu: Bool = false
    @State private var displayLFOOutputs: Bool = false
    @State private var lfoHistories: [RingHistory] = []
    private let lfoMaxSamples: Int = 50
    @State private var midiSendCache = MIDISendCache_MBAsync()
    @State private var midiFocusIndex: Int? = nil
    private let midiSlotsKey = "MIDI_SLOTS_SIMPLE_PLANT_LADYBIRDS"
    private let segmentPalette: [Color] = [.red,.orange,.yellow,.green,.blue,.indigo,.purple]
    // Use a local timer to align with MeshBird/Jellyfish
    //@State private var tickPublisher = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    // NEW: Solo state shared with MIDI menu
    @State private var midiSoloIndex: Int? = nil
    // Throttle LFO history to ~20 Hz for reduced overhead
        @State private var lastLFORecordTime: CFTimeInterval = 0
        private let lfoRecordInterval: CFTimeInterval = 1.0 / 20.0
    
        // Coalesce per‑frame callback to avoid piling up when main is busy
        @State private var perFrameCallbackPending = false
    
    @StateObject private var powerModeMonitor = PowerModeMonitor()

    // MARK: - View Config
    private let config = LifeformViewConfig(
        initialAzimuth: 0,
        initialElevation: 0,
        initialRadius: 16,
        minRadius: 6,
        maxRadius: 30,
        cameraControlMode: .nicks_control,
        ambientLightIntensity: 0.5,
        directionalLightIntensity: 0.7, // Reduced from 0.9 for performance
        directionalLightAngles: SCNVector3(x: -Float.pi/5, y: Float.pi/4, z: 0),
        updateInterval: 0.016,
        title: "Stripping a Plant",
        controlPanelColor: Color.black.opacity(0.7),
        controlTextColor: .white,
        buttonBackgroundColor: Color.red.opacity(0.55),
        initialFieldOffset: SCNVector3(0, -8, 0)
       
    )

    // Snapshot/apply
    private func currentSettings() -> SimplePlantSettings {
        SimplePlantSettings(
            rotationAngle: rotationAngle,
            speedMultiplier: speedMultiplier,
            sceneScale: sceneScale,
            displayLFOOutputs: displayLFOOutputs
        )
    }
    private func applySettings(_ s: SimplePlantSettings) {
        rotationAngle = s.rotationAngle; simHolder.sim?.setRotationAngle(s.rotationAngle)
        speedMultiplier = s.speedMultiplier; simHolder.sim?.setSpeedMultiplier(s.speedMultiplier)
        sceneScale = min(max(s.sceneScale, sceneScaleRange.lowerBound), sceneScaleRange.upperBound); simHolder.sim?.setGlobalScale(sceneScale)
        displayLFOOutputs = s.displayLFOOutputs
    }

    // MARK: - Simulation Creation
    private func createSimplePlantLadybirdsSimulation(scene: SCNScene) -> SimplePlantLadybirdsSimulationAsync {
        let sim = SimplePlantLadybirdsSimulationAsync(scene: scene, scnView: nil, config: SimplePlantLadybirdsSimulation.Config(), globalConfig: config)
        sim.setRotationAngle(rotationAngle)
        sim.setSpeedMultiplier(speedMultiplier)
        sim.setGlobalScale(sceneScale)
        simHolder.sim = sim
        return sim
    }

    // MARK: - Controls UI
    private func buildControls(simBinding: Binding<SimplePlantLadybirdsSimulationAsync?>, isPaused: Binding<Bool>) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Rotation").foregroundColor(config.controlTextColor)
                Slider(value: Binding(get: { Double(rotationAngle) }, set: { v in rotationAngle = Float(v); simHolder.sim?.setRotationAngle(rotationAngle) }), in: 0...360, step: 1)
                Text("\(Int(rotationAngle))°").foregroundColor(config.controlTextColor).frame(width: 44)
            }
            HStack {
                Text("Speed").foregroundColor(config.controlTextColor)
                Slider(value: Binding(get: { Double(speedMultiplier) }, set: { v in speedMultiplier = Float(v); simHolder.sim?.setSpeedMultiplier(speedMultiplier) }), in: 0.1...6.0, step: 0.01)
                Text(String(format: "%.2f", speedMultiplier)).foregroundColor(config.controlTextColor).frame(width: 44)
            }
            Toggle("Display LFO outputs", isOn: $displayLFOOutputs)
                .toggleStyle(.switch)
                .foregroundColor(config.controlTextColor)
            HStack {
                Button(action: { showMidiMenu.toggle() }) {
                    HStack { Image(systemName: "gearshape"); Text("MIDI Settings + Tracking") }
                }
                // .padding(.horizontal, 14)
                // .padding(.vertical, 20)
               //  .cornerRadius(8)
                 .foregroundColor(Color.blue)
             }
         }
         .padding(.bottom, 100)
    }

    // MARK: - Main View Body
    var body: some View {
        ModifiedSimulationView<SimplePlantLadybirdsSimulationAsync>(
            config: config,
            customCameraState: cameraState,
            createSimulation: { scene in
                if let sim = simHolder.sim { return sim }
                return createSimplePlantLadybirdsSimulation(scene: scene)
            },
            controlsBuilder: { binding, pausedBinding in AnyView(buildControls(simBinding: binding, isPaused: pausedBinding)) },
            onViewReady: {  _, scnView in
                if let sim = simHolder.sim {
                    sim.scnView = scnView
                    scnViewRef = scnView
                    scnView.backgroundColor = .black
                    scnView.isOpaque = true
                    sim.sceneReference?.background.contents = UIColor.black

                    // --- UI/LFO update throttling with coalescing ---
                    sim.perFrameCallback = {
                        guard self.isActive && !self.isPaused.wrappedValue else { return }
                        // Coalesce: skip if already pending to avoid queue buildup
                        if self.perFrameCallbackPending { return }
                        self.perFrameCallbackPending = true
                        DispatchQueue.main.async {
                            defer { self.perFrameCallbackPending = false }
                            if self.isActive && !self.isPaused.wrappedValue {
                                self.midiTickLoop()
                            }
                        }
                    }
                }
            },
            isActive: isActive,
            systemScaleGetter: { sceneScale },
            systemScaleSetter: { newVal in
                let clamped = min(max(newVal, sceneScaleRange.lowerBound), sceneScaleRange.upperBound)
                if abs(clamped - sceneScale) > 0.0001 { sceneScale = clamped; simHolder.sim?.setGlobalScale(clamped) }
            },
            systemScaleRange: sceneScaleRange,
            simulationDragHandler: { delta in
                let factor: Float = 0.02
                let movementMultiplier: Float = 2.0
                let dirs = cameraState.panDirectionVectors()
                let right = dirs.right
                let horiz = Float(-delta.width) * factor * movementMultiplier
                simHolder.sim?.translate(dx: right.x * horiz, dy: 0, dz: right.z * horiz)
                let vert = -Float(delta.height) * factor * movementMultiplier
                simHolder.sim?.translate(dx: 0, dy: vert, dz: 0)
            },
            enableParallaxPan: true,
            driveWithSimulationManager: false,
            pauseHandler: { paused, sim in
                sim?.setPaused(paused)
            },
            sceneOverlayBuilder: {
                AnyView(
                    Group {
                        if displayLFOOutputs {
                            if midiSlots.isEmpty {
                                Text("No MIDI slots loaded. Check MIDI settings.")
                                    .foregroundColor(.red)
                                    .padding(.top, 8)
                                    .padding(.horizontal, 8)
                            } else {
                                // Use the same full tracker names as the MIDI dropdown labels
                                let labels = midiSlots.map { coordForTracker($0.tracked) }
                                let colors = midiSlots.map { $0.channel == 1 ? .green : colorForTracker($0.tracked) }
                                let channels = midiSlots.map { $0.channel }
                                let ccNumbers = midiSlots.map { $0.ccNumber }
                                let notesBindings: [Binding<String>] = midiSlots.indices.map { i in
                                    Binding<String>(
                                        get: { midiSlots[i].coordinateName },
                                        set: { midiSlots[i].coordinateName = $0 }
                                    )
                                }
                                LFORingOverlayView(
                                    labels: labels,
                                    histories: lfoHistories,
                                    colors: colors,
                                    channels: channels,
                                    ccNumbers: ccNumbers,
                                    notes: notesBindings,
                                    topMargin: 44,
                                    onDoubleTap: { i in midiFocusIndex = i; showMidiMenu = true }
                                )
                                .padding(.horizontal, 8)
                            }
                        }
                    }
                )
            },
            panelAutoHideEnabled: true,
            externalPaused: isPaused,
            isDisplayLockPressed: isDisplayLockPressed,
            // Settings persistence hooks
            getSettingsData: { (try? JSONEncoder().encode(SimplePlantPreset(settings: currentSettings(), midiSlots: midiSlots))) ?? Data() },
            applySettingsData: { data in if let p = try? JSONDecoder().decode(SimplePlantPreset.self, from: data) {
                applySettings(p.settings)
                midiSlots = p.midiSlots
                saveMIDISlots(); syncLFOHistoriesToSlots(); midiSendCache.lastSentCCValues = [:]
            } else if let s = try? JSONDecoder().decode(SimplePlantSettings.self, from: data) { applySettings(s) } }

        )
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showMidiMenu) { midiMenuSheetView() }
        .onAppear {
            loadMIDISlots()
            syncLFOHistoriesToSlots()
            // Wire up low power mode to simulation
            powerModeMonitor.setLowPowerModeHandler { enabled in
                simHolder.sim?.setLowPowerMode(enabled)
            }
        }
        .onDisappear {
            simHolder.sim?.stopAsyncSimulation()
            simHolder.sim?.teardownAndDispose()
            simHolder.sim = nil
        }
        .onChange(of: midiSlots) { _, _ in
            saveMIDISlots()
            midiSendCache.lastSentCCValues = [:]
            syncLFOHistoriesToSlots()
        }
        .onChange(of: isPaused.wrappedValue) { _, newVal in
            simHolder.sim?.setPaused(newVal)
        }
 
        
       // .onReceive(tickPublisher) { _ in
        //    if isActive && !isPaused.wrappedValue { midiTickLoop() }
        //}
    }

    // MARK: - MIDI/LFO Slot Management
    private func loadMIDISlots() {
        let clip = MIDISlotsClipboard.shared
        if clip.isGlobalEnabled, !clip.globalSlots.isEmpty { midiSlots = clip.globalSlots; return }
        if let data = UserDefaults.standard.data(forKey: midiSlotsKey), let loaded = try? JSONDecoder().decode([MIDIParams].self, from: data) {
            midiSlots = loaded
        } else {
            midiSlots = [MIDIParams(tracked: "Ladybird-1.x")]
        }
    }
    private func saveMIDISlots() {
        guard !MIDISlotsClipboard.shared.isGlobalEnabled else { return }
        if let data = try? JSONEncoder().encode(midiSlots) { UserDefaults.standard.set(data, forKey: midiSlotsKey) }
    }
    private func syncLFOHistoriesToSlots() {
        if lfoHistories.count < midiSlots.count {
            for _ in 0..<(midiSlots.count - lfoHistories.count) { lfoHistories.append(RingHistory(capacity: lfoMaxSamples)) }
        } else if lfoHistories.count > midiSlots.count {
            lfoHistories.removeLast(lfoHistories.count - midiSlots.count)
        }
    }

    // MARK: - Tracker Helpers
    private func makeLadybirdTrackers(_ sim: SimplePlantLadybirdsSimulationAsync?) -> [String] {
        guard let sim = sim else { return ["Ladybird-1.x", "Ladybird-1.y"] }
        let count = sim.segmentCount(caterpillar: 0)
        var list: [String] = []
        for i in 0..<count { let n = i+1; list.append(contentsOf: ["Ladybird-\(n).x", "Ladybird-\(n).y"]) }
        return list
    }
    private func makeLadybirdTrackerColors(_ sim: SimplePlantLadybirdsSimulationAsync?) -> [String: Color] {
        guard let sim = sim else { return [:] }
        let count = sim.segmentCount(caterpillar: 0)
        var map: [String: Color] = [:]
        for i in 0..<count { let n = i+1; let c = segmentPalette[i % segmentPalette.count]; map["Ladybird-\(n).x"] = c; map["Ladybird-\(n).y"] = c }
        return map
    }
    private func makeLadybirdTrackerColorNames(_ sim: SimplePlantLadybirdsSimulationAsync?) -> [String: String] {
        guard let sim = sim else { return [:] }
        let count = sim.segmentCount(caterpillar: 0)
        var map: [String: String] = [:]
        for i in 0..<count { let n = i+1; map["Ladybird-\(n).x"] = "Ladybird \(n)"; map["Ladybird-\(n).y"] = "Ladybird \(n)" }
        return map
    }
    private func resolveLadybirdTracker(_ tracker: String, in sim: SimplePlantLadybirdsSimulationAsync, range: ClosedRange<Int>) -> Int? {
        let parts = tracker.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        guard parts[0].hasPrefix("Ladybird-"), let idx = Int(parts[0].replacingOccurrences(of: "Ladybird-", with: "")), idx >= 1 else { return nil }
        let segment = idx - 1
        if let proj = sim.projectedFirstCaterpillarSegmentXY127(segment: segment) {
            let raw = parts[1] == "x" ? proj.x : proj.y
            return scaleToRange(raw, range: range)
        }
        return nil
    }
    private func scaleToRange(_ cc: Int, range: ClosedRange<Int>) -> Int { let t = Float(cc)/127.0; let minR = Float(range.lowerBound); let maxR = Float(range.upperBound); let v = Int(round(minR + t * (maxR - minR))); return max(range.lowerBound, min(range.upperBound, v)) }
    private func coordForTracker(_ tracker: String) -> String { if let dot = tracker.firstIndex(of: ".") { return String(tracker[tracker.index(after: dot)...]) }; return tracker }
    private func colorForTracker(_ tracker: String) -> Color { if let idxStr = tracker.split(separator: ".").first?.replacingOccurrences(of: "Ladybird-", with: ""), let idx = Int(idxStr), idx>=1, idx<=segmentPalette.count { return segmentPalette[idx-1] } else { return .white } }

    // MARK: - MIDI Menu Sheet
    private func midiMenuSheetView() -> some View {
        let trackers = makeLadybirdTrackers(simHolder.sim)
        let trackerColors = makeLadybirdTrackerColors(simHolder.sim)
        let trackerColorNames = makeLadybirdTrackerColorNames(simHolder.sim)
        return MIDIMenuView(
            slots: $midiSlots,
            trackers: trackers,
            trackerColors: trackerColors,
            trackerColorNames: trackerColorNames,
            focusIndex: $midiFocusIndex,
            soloIndex: $midiSoloIndex,
            onSend: { slots in
                guard let sim = simHolder.sim else { return }
                // If solo is active, only send for the soloed slot index
                for (idx, slot) in slots.enumerated() {
                    if let s = midiSoloIndex, s != idx { continue }
                    guard let val = resolveLadybirdTracker(slot.tracked, in: sim, range: slot.range) else { continue }
                    MIDIOutput.send(channel: slot.channel, ccNumber: slot.ccNumber, value: val)
                }
            },
            onReloadLocal: { loadMIDISlots() }
        )
        .environmentObject(LifeformModeStore())
    }

    // MARK: - MIDI Tick Loop
    @MainActor
    private func midiTickLoop() {
        autoreleasepool {
            guard let sim = simHolder.sim else { return }
            if sim.scnView == nil, let v = scnViewRef { sim.scnView = v }
            if lfoHistories.count != midiSlots.count { syncLFOHistoriesToSlots() }
            
            // Throttle LFO history updates to reduce overhead
            let now = CACurrentMediaTime()
            let allowHistory = (now - lastLFORecordTime) >= lfoRecordInterval
            if allowHistory { lastLFORecordTime = now }
            
            let recordHistory = displayLFOOutputs && allowHistory
            
            for (i, slot) in midiSlots.enumerated() {
                // Only emit for the soloed slot when solo is active
                if let s = midiSoloIndex, s != i { continue }
                guard i < lfoHistories.count else { continue }
                guard let val = resolveLadybirdTracker(slot.tracked, in: sim, range: slot.range) else { continue }
                if midiSendCache.lastSentCCValues[i] != val {
                    MIDIOutput.send(channel: slot.channel, ccNumber: slot.ccNumber, value: val)
                    midiSendCache.lastSentCCValues[i] = val
                }
                if recordHistory {
                    let norm = CGFloat(max(0, min(127, val))) / 127.0
                    lfoHistories[i].append(norm)
                }
            }
        }
    }
}
