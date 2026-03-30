import SwiftUI
import SceneKit
import UIKit
import Combine
import QuartzCore

// MARK: - MIDI CC Deduplication Cache
private final class MIDISendCache_AntColony { var lastSentCCValues: [Int: Int] = [:] }

// Persistable settings for Ant Colony
private struct AntColonySettings: Codable {
    var worldScale: Float
    var worldYawDegrees: Double
    var reducedAntsForLowPower: Bool
    var displayLFOOutputs: Bool
}

// Preset bundles settings + MIDI slots for export/import
private struct AntColonyPreset: Codable {
    var settings: AntColonySettings
    var midiSlots: [MIDIParams]
}

// MARK: - SimHolder for persistent simulation
final class AntColonySimHolder: ObservableObject {
    @Published var sim: AntColonySimulationAsync? = nil
}

// MARK: - AntColonyLifeformView
struct AntColonyLifeformView: View {
    // MARK: - View State & Parameters
    var isActive: Bool = false
    var isPaused: Binding<Bool>
    var isDisplayLockPressed: Binding<Bool>
    
    @StateObject private var cameraState = CameraOrbitState()
    @StateObject private var simHolder = AntColonySimHolder()
    @State private var scnViewRef: SCNView? = nil
    
    // Simulation parameters
    @State private var worldScale: Float = 1.3
    @State private var worldYawDegrees: Double = 0.0
    
    // MIDI/LFO state
    private let midiSlotsKey = "MIDI_SLOTS_ANTCOLONY"
    @State private var showMidiMenu: Bool = false
    @State private var midiSlots: [MIDIParams] = []
    @State private var midiFocusIndex: Int? = nil
    @State private var displayLFOOutputs: Bool = false
    @State private var lfoHistories: [RingHistory] = []
    private let lfoMaxSamples: Int = 50
    @State private var midiSendCache = MIDISendCache_AntColony()
    @State private var midiSoloIndex: Int? = nil
    
    @EnvironmentObject var powerModeMonitor: PowerModeMonitor
    @State private var userAntCount: Int = 5
    @State private var reducedAntsForLowPower: Bool = false
    @State private var userReducedAnts: Bool = false
    
    // Throttle LFO history to ~30 Hz
    @State private var lastLFORecordTime: CFTimeInterval = 0
    private let lfoRecordInterval: CFTimeInterval = 1.0 / 30.0
    
    // Coalesce per‑frame callback
    @State private var perFrameCallbackPending = false
    
    // MARK: - View Config
    private let config = LifeformViewConfig(
        initialAzimuth: 0,
        initialElevation: 30,
        initialRadius: 60,
        minRadius: 20,
        maxRadius: 100,
        cameraControlMode: .nicks_control,
        ambientLightIntensity: 0.5,
        directionalLightIntensity: 0.8,
        directionalLightAngles: SCNVector3(x: -Float.pi/3, y: Float.pi/4, z: 0),
        updateInterval: 0.016,
        title: "Ant Colony",
        controlPanelColor: Color.black.opacity(0.6),
        controlTextColor: .white,
        buttonBackgroundColor: Color.blue.opacity(0.6),
        controlPanelBottomInset: 5
    )
    
    // Snapshot current settings
    private func currentSettings() -> AntColonySettings {
        AntColonySettings(
            worldScale: worldScale,
            worldYawDegrees: worldYawDegrees,
            reducedAntsForLowPower: reducedAntsForLowPower,
            displayLFOOutputs: displayLFOOutputs
        )
    }
    
    // Apply settings and update sim
    private func applySettings(_ s: AntColonySettings) {
        worldScale = s.worldScale
        simHolder.sim?.setWorldScale(s.worldScale)
        worldYawDegrees = s.worldYawDegrees
        simHolder.sim?.setWorldYaw(Float(s.worldYawDegrees * .pi / 180.0))
        
        if powerModeMonitor.isLowPowerMode {
            userReducedAnts = s.reducedAntsForLowPower
            reducedAntsForLowPower = true
            userAntCount = 8
            simHolder.sim?.setLowPowerMode(true)
        } else {
            reducedAntsForLowPower = s.reducedAntsForLowPower
            userReducedAnts = s.reducedAntsForLowPower
            userAntCount = reducedAntsForLowPower ? 8 : 15
            simHolder.sim?.setLowPowerMode(reducedAntsForLowPower)
        }
        displayLFOOutputs = s.displayLFOOutputs
    }
    
    // MARK: - Controls UI
    private func buildControls(simBinding: Binding<AntColonySimulationAsync?>, isPaused: Binding<Bool>) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Rotation").foregroundColor(config.controlTextColor)
                Slider(value: $worldYawDegrees, in: 0...360, step: 1)
                    .onChange(of: worldYawDegrees) { _, deg in
                        simHolder.sim?.setWorldYaw(Float(deg * .pi / 180.0))
                    }
                Text(String(format: "%3.0f°", worldYawDegrees))
                    .foregroundColor(config.controlTextColor)
                    .frame(width: 50)
            }
            
            Toggle("Display LFO outputs", isOn: $displayLFOOutputs)
                .toggleStyle(.switch)
                .foregroundColor(config.controlTextColor)
            
            Toggle("Reduced Ants (Low Power Mode)", isOn: $reducedAntsForLowPower)
                .toggleStyle(.switch)
                .foregroundColor(config.controlTextColor)
                .disabled(powerModeMonitor.isLowPowerMode)
            
            lowPowerIndicator()
            
            HStack {
                Button(action: { showMidiMenu.toggle() }) {
                    HStack {
                        Image(systemName: "waveform")
                        Text("MIDI Settings + Tracking")
                    }
                }
                .foregroundColor(Color.blue)
            }
        }
        .padding(.bottom, 100)
    }
    
    // MARK: - Simulation Creation
    private func createAntColonySimulation(scene: SCNScene) -> AntColonySimulationAsync {
        let sim = AntColonySimulationAsync(
            antCount: userAntCount,
            foodSourceCount: 5,
            scene: scene,
            config: config,
            scnView: nil
        )
        sim.setWorldScale(worldScale)
        sim.setWorldYaw(Float(worldYawDegrees * .pi / 180.0))
        simHolder.sim = sim
        return sim
    }
    
    // MARK: - Body
    var body: some View {
        ModifiedSimulationView<AntColonySimulationAsync>(
            config: config,
            customCameraState: cameraState,
            createSimulation: { scene in
                if let sim = simHolder.sim { return sim }
                return createAntColonySimulation(scene: scene)
            },
            controlsBuilder: { binding, paused in
                AnyView(buildControls(simBinding: binding, isPaused: paused))
            },
            onViewReady: { _, scnView in
                if let sim = simHolder.sim {
                    sim.scnView = scnView
                    scnViewRef = scnView
                    scnView.backgroundColor = .black
                    scnView.isOpaque = true
                    
                    // Non‑blocking, coalesced main‑thread callback
                    sim.perFrameCallback = {
                        guard self.isActive && !self.isPaused.wrappedValue else { return }
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
                
                // Configure orthographic projection
                if let cam = scnView.pointOfView?.camera {
                    cam.usesOrthographicProjection = true
                    cam.orthographicScale = Double(max(1, cameraState.radius))
                    cam.zNear = 0.1
                    cam.zFar = 2000
                }
            },
            isActive: isActive,
            systemScaleGetter: { worldScale },
            systemScaleSetter: { newVal in
                worldScale = newVal
                simHolder.sim?.setWorldScale(newVal)
            },
            systemScaleRange: 0.3...2.5,
            simulationDragHandler: { delta in
                let factor: Float = 0.02
                let movementMultiplier: Float = 2.0
                let right = cameraState.panDirectionVectors().right
                let horiz = Float(-delta.width) * factor * movementMultiplier
                simHolder.sim?.translate(dx: right.x * horiz, dy: 0, dz: right.z * horiz)
                let vert = Float(-delta.height) * factor * movementMultiplier
                simHolder.sim?.translate(dx: 0, dy: vert, dz: 0)
            },
            enableParallaxPan: false,
            driveWithSimulationManager: false,
            pauseHandler: { paused, sim in sim?.setPaused(paused) },
            sceneOverlayBuilder: {
                return AnyView(Group {
                    if displayLFOOutputs, !midiSlots.isEmpty {
                        let labels = midiSlots.map { coordForTracker($0.tracked) }
                        let colors = midiSlots.map { colorForTracker($0.tracked) }
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
                            onDoubleTap: { idx in
                                midiFocusIndex = idx
                                showMidiMenu = true
                            }
                        )
                        .padding(.horizontal, 8)
                        .drawingGroup() // Hint to Metal: no alpha blending
                    }
                })
            },
            panelAutoHideEnabled: true,
            externalPaused: isPaused,
            isDisplayLockPressed: isDisplayLockPressed,
            // Settings persistence hooks
            getSettingsData: {
                (try? JSONEncoder().encode(AntColonyPreset(
                    settings: currentSettings(),
                    midiSlots: midiSlots
                ))) ?? Data()
            },
            applySettingsData: { data in
                if let p = try? JSONDecoder().decode(AntColonyPreset.self, from: data) {
                    applySettings(p.settings)
                    midiSlots = p.midiSlots
                    saveMIDISlots()
                    syncLFOHistoriesToSlots()
                    midiSendCache.lastSentCCValues = [:]
                } else if let s = try? JSONDecoder().decode(AntColonySettings.self, from: data) {
                    applySettings(s)
                }
            }
        )
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showMidiMenu) { midiMenuSheetView() }
        // MIDI slots change
        .onChange(of: midiSlots) { _, _ in
            saveMIDISlots()
            syncLFOHistoriesToSlots()
            midiSendCache.lastSentCCValues = [:]
        }
        // Lifecycle
        .onAppear {
            loadMIDISlots()
            syncLFOHistoriesToSlots()
            
            // Start the simulation
            simHolder.sim?.startAsyncSimulation()
            
            if powerModeMonitor.isLowPowerMode {
                userReducedAnts = reducedAntsForLowPower
                reducedAntsForLowPower = true
                userAntCount = 8
                simHolder.sim?.setLowPowerMode(true)
            } else {
                reducedAntsForLowPower = userReducedAnts
                userAntCount = reducedAntsForLowPower ? 8 : 15
                simHolder.sim?.setLowPowerMode(reducedAntsForLowPower)
            }
        }
        .onChange(of: powerModeMonitor.isLowPowerMode) { _, isLow in
            if isLow {
                userReducedAnts = reducedAntsForLowPower
                reducedAntsForLowPower = true
                userAntCount = 8
                simHolder.sim?.setLowPowerMode(true)
            } else {
                reducedAntsForLowPower = userReducedAnts
                userAntCount = reducedAntsForLowPower ? 8 : 15
                simHolder.sim?.setLowPowerMode(reducedAntsForLowPower)
            }
        }
        .onChange(of: reducedAntsForLowPower) { _, v in
            if !powerModeMonitor.isLowPowerMode {
                userReducedAnts = v
                userAntCount = v ? 8 : 15
                simHolder.sim?.setLowPowerMode(v)
            }
        }
        .onDisappear {
            simHolder.sim?.stopAsyncSimulation()
            simHolder.sim?.teardownAndDispose()
            simHolder.sim = nil
        }
        // Pause binding propagate
        .onChange(of: isPaused.wrappedValue) { _, newVal in
            simHolder.sim?.setPaused(newVal)
        }
        // Param changes
        .onChange(of: worldScale) { _, v in simHolder.sim?.setWorldScale(v) }
        .onChange(of: worldYawDegrees) { _, deg in
            simHolder.sim?.setWorldYaw(Float(deg * .pi / 180.0))
        }
    }
    
    // MARK: - MIDI/LFO Slot Management
    private func loadMIDISlots() {
        let clip = MIDISlotsClipboard.shared
        if clip.isGlobalEnabled, !clip.globalSlots.isEmpty { midiSlots = clip.globalSlots; return }
        if let data = UserDefaults.standard.data(forKey: midiSlotsKey),
           let loaded = try? JSONDecoder().decode([MIDIParams].self, from: data) {
            midiSlots = loaded
        } else {
            midiSlots = [MIDIParams(tracked: "Ant 1.x")]
        }
    }
    
    private func saveMIDISlots() {
        guard !MIDISlotsClipboard.shared.isGlobalEnabled else { return }
        if let data = try? JSONEncoder().encode(midiSlots) {
            UserDefaults.standard.set(data, forKey: midiSlotsKey)
        }
    }
    
    private func syncLFOHistoriesToSlots() {
        if lfoHistories.count < midiSlots.count {
            for _ in 0..<(midiSlots.count - lfoHistories.count) {
                lfoHistories.append(RingHistory(capacity: lfoMaxSamples))
            }
        } else if lfoHistories.count > midiSlots.count {
            lfoHistories.removeLast(lfoHistories.count - midiSlots.count)
        }
    }
    
    // MARK: - Tracker Helpers
    private func makeAntColonyTrackers(_ sim: AntColonySimulationAsync?) -> [String] {
        guard let sim = sim else { return ["Ant 1.x", "Ant 1.y"] }
        let limit = min(sim.ants.count, 8)
        var names: [String] = []
        for i in 0..<limit {
            let n = i + 1
            names.append("Ant \(n).x")
            names.append("Ant \(n).y")
        }
        // Add food sources
        for i in 0..<min(sim.foodSources.count, 5) {
            let n = i + 1
            names.append("Food \(n).x")
            names.append("Food \(n).y")
        }
        return names
    }
    
    private func colorForTracker(_ tracker: String) -> Color {
        guard let sim = simHolder.sim else { return .gray }
        let base = tracker.split(separator: ".", maxSplits: 1).first.map(String.init) ?? tracker
        
        if base.hasPrefix("Ant ") {
            let idxStr = base.replacingOccurrences(of: "Ant ", with: "")
            if let n = Int(idxStr) {
                let idx = n - 1
                if idx >= 0 && idx < sim.ants.count {
                    return Color(sim.ants[idx].color)
                }
            }
        } else if base.hasPrefix("Food ") {
            let idxStr = base.replacingOccurrences(of: "Food ", with: "")
            if let n = Int(idxStr) {
                let idx = n - 1
                if idx >= 0 && idx < sim.foodSources.count {
                    return Color(sim.foodSources[idx].color)
                }
            }
        }
        
        return .gray
    }
    
    private func coordForTracker(_ tracker: String) -> String { tracker }
    
    private func scaleToRange(_ cc: Int, range: ClosedRange<Int>) -> Int {
        let t = max(0, min(127, cc))
        let minR = range.lowerBound
        let maxR = range.upperBound
        if maxR == minR { return minR }
        return Int(round(Float(minR) + Float(t) / 127.0 * Float(maxR - minR)))
    }
    
    private func resolveAntColonyTracker(_ tracker: String, in sim: AntColonySimulationAsync, range: ClosedRange<Int>) -> Int? {
        let parts = tracker.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let base = parts[0]
        let axis = parts[1]
        
        if base.hasPrefix("Ant ") {
            let idxStr = base.replacingOccurrences(of: "Ant ", with: "")
            guard let n = Int(idxStr), n >= 1 else { return nil }
            let index = n - 1
            if let xy = sim.projectedAntXY127(antIndex: index) {
                let raw = (axis == "x") ? xy.x : (axis == "y" ? xy.y : nil)
                if let r = raw { return scaleToRange(r, range: range) }
            }
        } else if base.hasPrefix("Food ") {
            let idxStr = base.replacingOccurrences(of: "Food ", with: "")
            guard let n = Int(idxStr), n >= 1 else { return nil }
            let index = n - 1
            if let xy = sim.projectedFoodXY127(foodIndex: index) {
                let raw = (axis == "x") ? xy.x : (axis == "y" ? xy.y : nil)
                if let r = raw { return scaleToRange(r, range: range) }
            }
        }
        
        return nil
    }
    
    private func lowPowerIndicator() -> some View {
        Text("(Device in Low Power Mode)")
            .font(.caption)
            .foregroundColor(.yellow)
            .opacity(powerModeMonitor.isLowPowerMode ? 1 : 0)
            .padding(.top, -10)
    }
    
    // MIDI Settings sheet view
    @ViewBuilder private func midiMenuSheetView() -> some View {
        let trackers = makeAntColonyTrackers(simHolder.sim)
        let trackerColors = Dictionary(uniqueKeysWithValues: trackers.map { ($0, colorForTracker($0)) })
        MIDIMenuView(
            slots: $midiSlots,
            trackers: trackers,
            trackerColors: trackerColors,
            focusIndex: $midiFocusIndex,
            soloIndex: $midiSoloIndex,
            onSend: { slots in
                guard let sim = simHolder.sim else { return }
                for (idx, slot) in slots.enumerated() {
                    if let s = midiSoloIndex, s != idx { continue }
                    if let val = resolveAntColonyTracker(slot.tracked, in: sim, range: slot.range) {
                        MIDIOutput.send(channel: slot.channel, ccNumber: slot.ccNumber, value: val)
                    }
                }
            },
            onReloadLocal: { loadMIDISlots() }
        )
        .environmentObject(LifeformModeStore())
    }
    
    // MIDI Tick Loop
    private func midiTickLoop() {
        autoreleasepool {
            guard let sim = simHolder.sim else { return }
            if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
            if lfoHistories.count != midiSlots.count { syncLFOHistoriesToSlots() }
            
            // 30 Hz history sampling
            let now = CACurrentMediaTime()
            let allowHistory = (now - lastLFORecordTime) >= lfoRecordInterval
            if allowHistory { lastLFORecordTime = now }
            
            let recordHistory = displayLFOOutputs && allowHistory
            
            for (index, slot) in midiSlots.enumerated() {
                if let s = midiSoloIndex, s != index { continue }
                guard index < lfoHistories.count else { continue }
                guard let ccVal = resolveAntColonyTracker(slot.tracked, in: sim, range: slot.range) else { continue }
                
                if midiSendCache.lastSentCCValues[index] != ccVal {
                    MIDIOutput.send(channel: slot.channel, ccNumber: slot.ccNumber, value: ccVal)
                    midiSendCache.lastSentCCValues[index] = ccVal
                }
                
                if recordHistory {
                    let norm = CGFloat(max(0, min(127, ccVal))) / 127.0
                    lfoHistories[index].append(norm)
                }
            }
        }
    }
}
