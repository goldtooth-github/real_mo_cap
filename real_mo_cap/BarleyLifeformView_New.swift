import SwiftUI
import SceneKit
import UIKit
import Combine
import QuartzCore // if not already imported
private var barleyRootWasOffscreen = false

// MARK: - MIDI CC Deduplication Cache
private final class MIDISendCache_MBAsync { var lastSentCCValues: [Int: Int] = [:] }

// Persistable settings for Barley
private struct BarleySettings: Codable {
    var fieldScale: Float
    var windStrength: Float
    var fieldYawDegrees: Double
    var reduceStalksForLowPower: Bool
    var displayLFOOutputs: Bool
}
// New: Preset bundles settings + MIDI slots for export/import
private struct BarleyPreset: Codable {
    var settings: BarleySettings
    var midiSlots: [MIDIParams]
}

// MARK: - SimHolder for persistent simulation
final class BarleySimHolder: ObservableObject { @Published var sim: BarleySimulationAsync? = nil }

// MARK: - BarleyLifeformViewAsync (formerly _New) aligned with Jellyfish/MeshBird structure
struct BarleyLifeformView_New: View {
    // MARK: - View State & Parameters
    var isActive: Bool = false
    var isPaused: Binding<Bool> // now mandatory like other views
   // private let tickPublisher = GlobalTickRouter.shared.$ccTick
    var isDisplayLockPressed: Binding<Bool>
    //@State private var tickPublisher = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    @StateObject private var cameraState = CameraOrbitState()
    @StateObject private var simHolder = BarleySimHolder()
    @State private var scnViewRef: SCNView? = nil
    // Simulation parameters
    @State private var fieldScale: Float = 1.3
    @State private var windStrength: Float = 1.0
    @State private var fieldYawDegrees: Double = 0.0
    @State private var stalkColor: Color = .green
    // MIDI/LFO state
    private let midiSlotsKey = "MIDI_SLOTS_BARLEY"
    @State private var showMidiMenu: Bool = false
    @State private var midiSlots: [MIDIParams] = []
    @State private var midiFocusIndex: Int? = nil
    @State private var displayLFOOutputs: Bool = false
    @State private var lfoHistories: [RingHistory] = []
   
    @State private var midiSendCache = MIDISendCache_MBAsync()
    // NEW: Solo state shared with MIDI menu
    @State private var midiSoloIndex: Int? = nil

 
    @State private var userStalkCount: Int = 40
    @State private var reduceStalksForLowPower: Bool = false
    @State private var userReduceStalks: Bool = false
     // Throttle LFO history to ~30 Hz
    @State private var lastLFORecordTime: CFTimeInterval = 0
    
    private var lfoMaxSamples: Int {
        powerModeMonitor.isLowPowerMode || reduceCPUOverhead ? 25 : 50
    }
    
    @EnvironmentObject var powerModeMonitor: PowerModeMonitor
    private var lfoRecordInterval: CFTimeInterval {
        powerModeMonitor.isLowPowerMode || reduceCPUOverhead ? 1.0 / 15.0 : 1.0 / 30.0
    }
    @State private var reduceCPUOverhead: Bool = false
    @State private var userReduceCPUOverhead: Bool = false
    
    // Coalesce per‑frame callback to avoid piling up when main is busy
    @State private var perFrameCallbackPending = false
    
    // MARK: - View Config
    private let config = LifeformViewConfig(
        initialAzimuth: 0,
        initialElevation: 20,
        initialRadius: 7,
        minRadius: 3,
        maxRadius: 25,
        cameraControlMode: .nicks_control,
        ambientLightIntensity: 0.5,
        directionalLightIntensity: 0.8,
        directionalLightAngles: SCNVector3(x: -Float.pi/3, y: Float.pi/4, z: 0),
        updateInterval: 0.016,
        title: "Barley in Wind",
        controlPanelColor: Color.black.opacity(0.6),
        controlTextColor: .white,
        buttonBackgroundColor: Color.blue.opacity(0.6),
        controlPanelBottomInset: 5
    )

    // Snapshot current settings
    private func currentSettings() -> BarleySettings {
        BarleySettings(
            fieldScale: fieldScale,
            windStrength: windStrength,
            fieldYawDegrees: fieldYawDegrees,
            reduceStalksForLowPower: reduceStalksForLowPower,
            displayLFOOutputs: displayLFOOutputs
        )
    }
    // Apply settings and update sim
    private func applySettings(_ s: BarleySettings) {
        fieldScale = s.fieldScale; simHolder.sim?.setFieldScale(s.fieldScale)
        windStrength = s.windStrength; simHolder.sim?.setWindStrength(s.windStrength)
        fieldYawDegrees = s.fieldYawDegrees; simHolder.sim?.setFieldYaw(Float(s.fieldYawDegrees * .pi / 180.0))
        if powerModeMonitor.isLowPowerMode {
            userReduceStalks = s.reduceStalksForLowPower
            reduceStalksForLowPower = true
            userStalkCount = 20
            simHolder.sim?.setLowPowerMode(true)
        } else {
            reduceStalksForLowPower = s.reduceStalksForLowPower
            userReduceStalks = s.reduceStalksForLowPower
            userStalkCount = reduceStalksForLowPower ? 20 : 40
            simHolder.sim?.setLowPowerMode(reduceStalksForLowPower)
        }
        displayLFOOutputs = s.displayLFOOutputs
    }

    // MARK: - Controls UI
    private func buildControls(simBinding: Binding<BarleySimulationAsync?>, isPaused: Binding<Bool>) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Wind").foregroundColor(config.controlTextColor)
                Slider(value: $windStrength, in: 0...2)
                    .onChange(of: windStrength) { _, v in simHolder.sim?.setWindStrength(v) }
                Text(String(format: "%.2f", windStrength)).foregroundColor(config.controlTextColor).frame(width: 44)
            }
            HStack {
                Text("Rotation").foregroundColor(config.controlTextColor)
                Slider(value: $fieldYawDegrees, in: 0...360, step: 1)
                    .onChange(of: fieldYawDegrees) { _, deg in simHolder.sim?.setFieldYaw(Float(deg * .pi / 180.0)) }
                Text(String(format: "%3.0f°", fieldYawDegrees)).foregroundColor(config.controlTextColor).frame(width: 50)
            }
            Toggle("Display LFO outputs", isOn: $displayLFOOutputs)
                .toggleStyle(.switch)
                .foregroundColor(config.controlTextColor)
            Toggle("Reduce Stalks (Low Power Mode)", isOn: $reduceStalksForLowPower)
                .toggleStyle(.switch)
                .foregroundColor(config.controlTextColor)
                .disabled(powerModeMonitor.isLowPowerMode)
            lowPowerIndicator()
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

    // MARK: - Simulation Creation
    private func createBarleySimulation(scene: SCNScene) -> BarleySimulationAsync {
        let uiColor = UIColor(stalkColor)
        let sim = BarleySimulationAsync(stalkCount: userStalkCount, stalkSpacing: 2.0, scene: scene, stalkColor: uiColor, config: config, scnView: nil)
        sim.userWindStrength = windStrength
        sim.setFieldScale(fieldScale)
        sim.setFieldYaw(Float(fieldYawDegrees * .pi / 180.0))
        simHolder.sim = sim
        return sim
    }

    // MARK: - Body
    var body: some View {
        ModifiedSimulationView<BarleySimulationAsync>(
            config: config,
            customCameraState: cameraState,
            createSimulation: { scene in
                if let sim = simHolder.sim { return sim }
                return createBarleySimulation(scene: scene)
            },
            controlsBuilder: { binding, paused in AnyView(buildControls(simBinding: binding, isPaused: paused)) },
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
            
                    // Configure orthographic projection for Flower
                    if let cam = scnView.pointOfView?.camera {
                        cam.usesOrthographicProjection = true
                        // Map initial orthographic scale to current orbital radius so zoom feels consistent
                        cam.orthographicScale = Double(max(1, cameraState.radius))
                        cam.zNear = 0.1
                        cam.zFar = 2000
                    
                }
            },
            isActive: isActive,
            systemScaleGetter: { fieldScale },
            systemScaleSetter: { newVal in fieldScale = newVal; simHolder.sim?.setFieldScale(newVal) },
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
                            onDoubleTap: { idx in midiFocusIndex = idx; showMidiMenu = true }
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
            getSettingsData: { (try? JSONEncoder().encode(BarleyPreset(settings: currentSettings(), midiSlots: midiSlots))) ?? Data() },
            applySettingsData: { data in
                if let p = try? JSONDecoder().decode(BarleyPreset.self, from: data) {
                    applySettings(p.settings)
                    midiSlots = p.midiSlots
                    saveMIDISlots(); syncLFOHistoriesToSlots(); midiSendCache.lastSentCCValues = [:]
                } else if let s = try? JSONDecoder().decode(BarleySettings.self, from: data) {
                    applySettings(s)
                }
            }
        )
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showMidiMenu) { midiMenuSheetView() }
        // MIDI slots change
        .onChange(of: midiSlots) { _, _ in
            saveMIDISlots(); syncLFOHistoriesToSlots(); midiSendCache.lastSentCCValues = [:]
        }
        // Lifecycle
        .onAppear {
            loadMIDISlots()
            syncLFOHistoriesToSlots()
            // Sync stalk count to power mode
            if powerModeMonitor.isLowPowerMode {
                userReduceStalks = reduceStalksForLowPower
                reduceStalksForLowPower = true
                userStalkCount = 20
                simHolder.sim?.setLowPowerMode(true)
            } else {
                reduceStalksForLowPower = userReduceStalks
                userStalkCount = reduceStalksForLowPower ? 20 : 40
                simHolder.sim?.setLowPowerMode(reduceStalksForLowPower)
            }
        }
        .onChange(of: powerModeMonitor.isLowPowerMode) { isLow in
            if isLow {
                userReduceStalks = reduceStalksForLowPower
                reduceStalksForLowPower = true
                userStalkCount = 20
                simHolder.sim?.setLowPowerMode(true)
            } else {
                reduceStalksForLowPower = userReduceStalks
                userStalkCount = reduceStalksForLowPower ? 20 : 40
                simHolder.sim?.setLowPowerMode(reduceStalksForLowPower)
            }
            syncLFOHistoriesToSlots()
        }
        .onChange(of: reduceStalksForLowPower) { v in
            if !powerModeMonitor.isLowPowerMode {
                userReduceStalks = v
                userStalkCount = v ? 20 : 40
                simHolder.sim?.setLowPowerMode(v)
            }
            
        }
        .onDisappear { simHolder.sim?.stopAsyncSimulation(); simHolder.sim?.teardownAndDispose(); simHolder.sim = nil }
        // Pause binding propagate
        .onChange(of: isPaused.wrappedValue) { _, newVal in simHolder.sim?.setPaused(newVal) }
        // Remove manual active change logic
        // Param changes
        .onChange(of: fieldScale) { _, v in simHolder.sim?.setFieldScale(v) }
        .onChange(of: windStrength) { _, v in simHolder.sim?.setWindStrength(v) }
        .onChange(of: fieldYawDegrees) { _, deg in simHolder.sim?.setFieldYaw(Float(deg * .pi / 180.0)) }
        .onChange(of: stalkColor) { _, newColor in if let sim = simHolder.sim { sim.inner.stalkColor = UIColor(newColor); sim.reset() } }
        // MIDI tick loop
       // .onReceive(tickPublisher) { _ in if isActive && !isPaused.wrappedValue { midiTickLoop() } }
    }

    // MARK: - MIDI/LFO Slot Management
    private func loadMIDISlots() {
        let clip = MIDISlotsClipboard.shared
        if clip.isGlobalEnabled, !clip.globalSlots.isEmpty { midiSlots = clip.globalSlots; return }
        if let data = UserDefaults.standard.data(forKey: midiSlotsKey),
           let loaded = try? JSONDecoder().decode([MIDIParams].self, from: data) { midiSlots = loaded }
        else { midiSlots = [MIDIParams(tracked: "Stalk Head 1.x")] }
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
    private func makeBarleyTrackers(_ sim: BarleySimulationAsync?) -> [String] {
        guard let sim = sim else { return ["Stalk Head 1.x", "Stalk Head 1.y"] }
        let limit = min(sim.stalks.count, 5)
        var names: [String] = []
        for i in 0..<limit {
            let n = i + 1
            names.append("Stalk Head \(n).x")
            names.append("Stalk Head \(n).y")
        }
        return names
    }
    // Simplified: derive color directly from tracker name and current simulation state
    private func colorForTracker(_ tracker: String) -> Color {
        guard let sim = simHolder.sim else { return .gray }
        let base = tracker.split(separator: ".", maxSplits: 1).first.map(String.init) ?? tracker
        if base.hasPrefix("Stalk Head ") {
            let idxStr = base.replacingOccurrences(of: "Stalk Head ", with: "")
            if let n = Int(idxStr) {
                let idx = n - 1
                if idx >= 0 && idx < sim.stalks.count {
                    // Prefer the seed head's actual material color (palette-applied), fallback to stalk color
                    if let head = sim.stalks[idx].seedHead,
                       let mat = head.geometry?.firstMaterial,
                       let ui = mat.diffuse.contents as? UIColor {
                        return Color(ui)
                    }
                    return Color(sim.stalks[idx].color)
                }
            }
        }
        return .gray
    }
    // Display label passthrough (unified name already in tracker)
    private func coordForTracker(_ tracker: String) -> String { tracker }
    // Scale a 0-127 CC to an arbitrary integer range
    private func scaleToRange(_ cc: Int, range: ClosedRange<Int>) -> Int {
        let t = max(0, min(127, cc))
        let minR = range.lowerBound
        let maxR = range.upperBound
        if maxR == minR { return minR }
        return Int(round(Float(minR) + Float(t) / 127.0 * Float(maxR - minR)))
    }
    // Resolve a tracker like "Stalk Head 1.x" to a scaled value using BarleySimulationAsync
    private func resolveBarleyTracker(_ tracker: String, in sim: BarleySimulationAsync, range: ClosedRange<Int>) -> Int? {
        // Expect format: "Stalk Head N.x" or ".y"
        let parts = tracker.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let base = parts[0]
        let axis = parts[1]
        guard base.hasPrefix("Stalk Head ") else { return nil }
        let idxStr = base.replacingOccurrences(of: "Stalk Head ", with: "")
        guard let n = Int(idxStr), n >= 1 else { return nil }
        let index = n - 1
        if let xy = sim.projectedSeedHeadXY127(stalkIndex: index) {
            let raw = (axis == "x") ? xy.x : (axis == "y" ? xy.y : nil)
            if let r = raw { return scaleToRange(r, range: range) }
        }
        return nil
    }
    
    private func logRootOutOfScreenIfNeeded(sim: BarleySimulationAsync) {
        if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
        guard let scnView = sim.scnView, let camera = scnView.pointOfView else { return }
        let anchorIndex = 0
        guard let rawXY = sim.projectedSeedHeadXY127Raw(stalkIndex: anchorIndex),
              let headWorld = sim.seedHeadWorldPosition(stalkIndex: anchorIndex) else {
            if !barleyRootWasOffscreen {
                barleyRootWasOffscreen = true
                print("[Barley] Seed head projection failed (treat as off-screen)")
            }
            return
        }

        let margin: Int = 2
        let w = max(scnView.bounds.width, 1)
        let h = max(scnView.bounds.height, 1)
        let minX = CGFloat(margin) / 127.0 * w
        let maxX = w - minX
        let minY = CGFloat(margin) / 127.0 * h
        let maxY = h - minY

        let screenX = CGFloat(rawXY.x) / 127.0 * w
        let screenY = (1.0 - CGFloat(rawXY.y) / 127.0) * h
        let isOffscreen = (screenX < minX || screenX > maxX || screenY < minY || screenY > maxY)

        if isOffscreen && !barleyRootWasOffscreen {
            barleyRootWasOffscreen = true
            print("[Barley] Seed head went off-screen: raw=(\(rawXY.x), \(rawXY.y))")
        } else if !isOffscreen && barleyRootWasOffscreen {
            barleyRootWasOffscreen = false
            print("[Barley] Seed head back on-screen: raw=(\(rawXY.x), \(rawXY.y))")
        }
        guard isOffscreen else { return }

        let clampedX = min(max(screenX, minX), maxX)
        let clampedY = min(max(screenY, minY), maxY)
        let projected = scnView.projectPoint(headWorld)
        let targetScreen = SCNVector3(Float(clampedX), Float(clampedY), projected.z)
        let correctedWorld = scnView.unprojectPoint(targetScreen)
        var delta = correctedWorld - headWorld

        let k: Float = 0.35
        delta.x *= k; delta.y *= k; delta.z *= k
        if !delta.x.isFinite || !delta.y.isFinite || !delta.z.isFinite { return }

        let camForward = SCNVector3(camera.worldTransform.m31, camera.worldTransform.m32, camera.worldTransform.m33).normalized()
        let forwardProj = SCNVector3.dot(delta, camForward)
        let deltaInPlane = delta - camForward * forwardProj

        sim.translate(dx: 0, dy: deltaInPlane.y, dz: deltaInPlane.z)
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
        let trackers = makeBarleyTrackers(simHolder.sim)
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
                    if let val = resolveBarleyTracker(slot.tracked, in: sim, range: slot.range) {
                        MIDIOutput.send(slot: slot, value: val)
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
            logRootOutOfScreenIfNeeded(sim: sim)
            if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
            if lfoHistories.count != midiSlots.count { syncLFOHistoriesToSlots() }
         //   let recordHistory = displayLFOOutputs
            // 30 Hz history sampling
                      let now = CACurrentMediaTime()
                       let allowHistory = (now - lastLFORecordTime) >= lfoRecordInterval
                      if allowHistory { lastLFORecordTime = now }
           
                      let recordHistory = displayLFOOutputs && allowHistory
            
            for (index, slot) in midiSlots.enumerated() {
                if let s = midiSoloIndex, s != index { continue }
                guard index < lfoHistories.count else { continue }
                guard let ccVal = resolveBarleyTracker(slot.tracked, in: sim, range: slot.range) else { continue }
                if midiSendCache.lastSentCCValues[index] != ccVal {
                    MIDIOutput.send(slot: slot, value: ccVal)
                    midiSendCache.lastSentCCValues[index] = ccVal
                }
                if recordHistory {
                    let norm = CGFloat(max(0, min(127, slot.applyInversion(ccVal)))) / 127.0
                    lfoHistories[index].append(norm)
                }
            }
        }
    }
}
