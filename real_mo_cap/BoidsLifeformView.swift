// MARK: - Imports
import SwiftUI
import SceneKit
import UIKit
import QuartzCore


// MARK: - MIDI CC Deduplication Cache
private final class MIDISendCache_MBAsync { var lastSentCCValues: [Int: Int] = [:] }

// Persistable settings for Boids
private struct BoidsSettings: Codable {
    var boidSpeed: Float
    var boidSize: Float
    var sceneScale: Float
    var wrappingEnabled: Bool
    var displayLFOOutputs: Bool
    var flockPosX: Float
    var flockPosY: Float
    var flockPosZ: Float

    enum CodingKeys: String, CodingKey { case boidSpeed, boidSize, sceneScale, wrappingEnabled, displayLFOOutputs, flockPosX, flockPosY, flockPosZ }

    init(boidSpeed: Float, boidSize: Float, sceneScale: Float, wrappingEnabled: Bool, displayLFOOutputs: Bool, flockPosX: Float, flockPosY: Float, flockPosZ: Float) {
        self.boidSpeed = boidSpeed
        self.boidSize = boidSize
        self.sceneScale = sceneScale
        self.wrappingEnabled = wrappingEnabled
        self.displayLFOOutputs = displayLFOOutputs
        self.flockPosX = flockPosX
        self.flockPosY = flockPosY
        self.flockPosZ = flockPosZ
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boidSpeed = try c.decode(Float.self, forKey: .boidSpeed)
        boidSize = try c.decode(Float.self, forKey: .boidSize)
        sceneScale = try c.decode(Float.self, forKey: .sceneScale)
        wrappingEnabled = try c.decode(Bool.self, forKey: .wrappingEnabled)
        displayLFOOutputs = try c.decode(Bool.self, forKey: .displayLFOOutputs)
        flockPosX = try c.decodeIfPresent(Float.self, forKey: .flockPosX) ?? 0
        flockPosY = try c.decodeIfPresent(Float.self, forKey: .flockPosY) ?? 0
        flockPosZ = try c.decodeIfPresent(Float.self, forKey: .flockPosZ) ?? 0
    }
}
// New wrapper to include MIDI slots in saved files
private struct BoidsPreset: Codable {
    var settings: BoidsSettings
    var midiSlots: [MIDIParams]
}

// MARK: - SimHolder for persistent simulation
final class BoidsSimHolder: ObservableObject {
    @Published var sim: BoidsSimulationAsync? = nil
}

// MARK: - BoidsFlockView
struct BoidsFlockView: View {
    // MARK: - View State & Parameters
    var isActive: Bool = false
    var isPaused: Binding<Bool>
    var isDisplayLockPressed: Binding<Bool>   // <-- add this

    // MIDI tick publisher (downsampled)
   // private let tickPublisher = GlobalTickRouter.shared.$ccTick
    @State private var tickPublisher = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    // Simulation parameters
    private let boidSizeRange: ClosedRange<Float> = 0.05...0.6
    @State private var boidSpeed: Float = 0.5
    @State private var boidSize: Float = 0.3
    @State private var sceneScale: Float = 1.0
    
    @State private var wrappingEnabled: Bool = false
    @State private var showBoundaryCube: Bool = false
    // Simulation/camera state
    @StateObject private var simHolder = BoidsSimHolder()
    @State private var scnViewRef: SCNView? = nil
    @StateObject private var cameraState = CameraOrbitState()
    // MIDI/LFO state
    @State private var showMidiMenu: Bool = false
    @State private var midiSlots: [MIDIParams] = []
    private let midiSlotsKey = "MIDI_SLOTS_BOIDS"
    @State private var midiSendCache = MIDISendCache_MBAsync()
    @State private var displayLFOOutputs: Bool = false
    @State private var lfoHistories: [RingHistory] = []
    private let lfoMaxSamples: Int = 50
    @State private var midiFocusIndex: Int? = nil
    @State private var lastSentCCValues: [Int: Int] = [:]
    // NEW: Solo state shared with MIDI menu
    @State private var midiSoloIndex: Int? = nil
    @State private var flockOffset: SIMD3<Float> = .zero

    // Throttle LFO history to ~30 Hz
    @State private var lastLFORecordTime: CFTimeInterval = 0
    @EnvironmentObject var powerModeMonitor: PowerModeMonitor
    private var lfoRecordInterval: CFTimeInterval {
        powerModeMonitor.isLowPowerMode || reduceCPUOverhead ? 1.0 / 15.0 : 1.0 / 30.0
    }
    @State private var reduceCPUOverhead: Bool = false
    @State private var userReduceCPUOverhead: Bool = false
    
    
  //  private let lfoRecordInterval: CFTimeInterval = 1.0 / 30.0
    
       // Coalesce per‑frame callback to avoid piling up when main is busy
    @State private var perFrameCallbackPending = false
    
    // Snapshot current settings
    private func currentSettings() -> BoidsSettings {
        BoidsSettings(
            boidSpeed: boidSpeed,
            boidSize: boidSize,
            sceneScale: sceneScale,
            wrappingEnabled: wrappingEnabled,
            displayLFOOutputs: displayLFOOutputs,
            flockPosX: flockOffset.x,
            flockPosY: flockOffset.y,
            flockPosZ: flockOffset.z
        )
    }
    // Apply settings and update simulation
    private func applySettings(_ s: BoidsSettings) {
        boidSpeed = s.boidSpeed; simHolder.sim?.setSpeedMultiplier(s.boidSpeed)
        boidSize = min(max(s.boidSize, boidSizeRange.lowerBound), boidSizeRange.upperBound); simHolder.sim?.setFishSize(boidSize)
        sceneScale = s.sceneScale; simHolder.sim?.setGlobalScale(s.sceneScale)
        wrappingEnabled = s.wrappingEnabled; simHolder.sim?.setWrappingEnabled(s.wrappingEnabled)
        displayLFOOutputs = s.displayLFOOutputs
        let target = SIMD3<Float>(s.flockPosX, s.flockPosY, s.flockPosZ)
        if let sim = simHolder.sim {
            let delta = target - flockOffset
            sim.translate(dx: delta.x, dy: delta.y, dz: delta.z)
            flockOffset = target
        } else {
            flockOffset = target
        }
    }

    // MARK: - View Config
    private let config = LifeformViewConfig(
        initialAzimuth: 0,
        initialElevation: 0,
        initialRadius: 18,
        minRadius: 6,
        maxRadius: 30,
        cameraControlMode: .nicks_control,
        ambientLightIntensity: 0.0,
        directionalLightIntensity: 0.9,
        directionalLightAngles: SCNVector3(x: -Float.pi/4, y: Float.pi/4, z: 0),
        updateInterval: 0.016,
        title: "Fish Flocking",
        controlPanelColor: Color.black.opacity(0.7),
        controlTextColor: .white,
        buttonBackgroundColor: Color.blue.opacity(0.7),
        controlPanelBottomInset: 5
    )

    // MARK: - Permanent Debug Flags (set each appear)
    private func applyPermanentDebugFlags() {
        DebugToggles.onlyUpdateWhenChanged = true
        DebugToggles.useUnitHeightScalingForSplines = true
        DebugToggles.cleanTeardown = true
        DebugToggles.disableImplicitAnimations = false
        DebugToggles.useAutoreleasePoolPerFrame = false
        DebugToggles.useLookAtConstraint = false
    }

    // MARK: - Simulation Creation
    private func createBoidsSimulation(scene: SCNScene) -> BoidsSimulationAsync {
        applyPermanentDebugFlags()
        if let sim = simHolder.sim { return sim }
        let sim = BoidsSimulationAsync(scene: scene, scnView: nil)
        sim.setSpeedMultiplier(boidSpeed)
        sim.setFishSize(boidSize)
        sim.setGlobalScale(sceneScale)
        sim.setWrappingEnabled(wrappingEnabled)
       // sim.setShowBoundsCube(showBoundaryCube)
        simHolder.sim = sim
        return sim
    }

    // MARK: - Controls UI
    private func buildControls(simBinding: Binding<BoidsSimulationAsync?>, isPaused: Binding<Bool>) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Speed:").foregroundColor(config.controlTextColor)
                Slider(value: $boidSpeed, in: 0.05...1.50, step: 0.01)
                    .onChange(of: boidSpeed) { _, v in simHolder.sim?.setSpeedMultiplier(v) }
                Text(String(format: "%.2f", boidSpeed))
                    .foregroundColor(config.controlTextColor)
                    .frame(width: 44)
            }
            HStack {
                Text("Boid Size:").foregroundColor(config.controlTextColor)
                Slider(value: $boidSize, in: boidSizeRange, step: 0.01)
                    .disabled(simHolder.sim == nil)
                    .onChange(of: boidSize) { _, v in
                        guard let sim = simHolder.sim else { return }
                        sim.setFishSize(v)
                    }
                Text(String(format: "%.2f", boidSize))
                    .foregroundColor(config.controlTextColor)
                    .frame(width: 50)
            }
            Toggle("Wrap Edges", isOn: $wrappingEnabled)
                .toggleStyle(.switch)
                .foregroundColor(config.controlTextColor)
                .onChange(of: wrappingEnabled) { _, val in simHolder.sim?.setWrappingEnabled(val) }
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
        ModifiedSimulationView<BoidsSimulationAsync>(
            config: config,
            customCameraState: cameraState,
            createSimulation:
            { scene in
                if let sim = simHolder.sim { return sim }
                return createBoidsSimulation(scene: scene)
            },
            controlsBuilder: { simBinding, pausedBinding in AnyView(buildControls(simBinding: simBinding, isPaused: pausedBinding)) },
            onViewReady: { _, scnView in
                if let sim = simHolder.sim {
                    sim.scnView = scnView
                    scnViewRef = scnView
                    scnView.backgroundColor = .black
                    scnView.isOpaque = true
                    sim.sceneReference?.background.contents = UIColor.black
                    
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
                    
                    
                    // No manual start; ModifiedSimulationView will start when active & not paused
                }
            },
            isActive: isActive,
            systemScaleGetter: { sceneScale },
            systemScaleSetter: { newVal in
                let clamped = min(max(newVal, 0.5), 2.0)
                if abs(clamped - sceneScale) > 0.0001 {
                    sceneScale = clamped
                    simHolder.sim?.setGlobalScale(clamped)
                }
            },
            systemScaleRange: 0.5...2.0,
            simulationDragHandler: { delta in
                let factor: Float = 0.02
                let movementMultiplier: Float = 2.0
                let dirs = cameraState.panDirectionVectors()
                let right = dirs.right
                let horiz = Float(-delta.width) * factor * movementMultiplier
                simHolder.sim?.translate(dx: right.x * horiz, dy: 0, dz: right.z * horiz)
                flockOffset += SIMD3<Float>(right.x * horiz, 0, right.z * horiz)
                let vert = -Float(delta.height) * factor * movementMultiplier // NOTE sign
                simHolder.sim?.translate(dx: 0, dy: vert, dz: 0)
                flockOffset += SIMD3<Float>(0, vert, 0)
            },

            enableParallaxPan: false,
            driveWithSimulationManager: false,
            pauseHandler: { paused, sim in
            sim?.setPaused(paused)
            },
           // externalPaused: isPaused
            sceneOverlayBuilder: {
                AnyView(
                    Group {
                        if displayLFOOutputs, !midiSlots.isEmpty {
                            let labels = midiSlots.map { $0.tracked } // Use full tracker name for LFO overlay
                            // Use per-boid fixed palette so overlay colors match boid colors
                            let colors = midiSlots.map { boidColorForTracker($0.tracked) }
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
                            .drawingGroup() // Hint to Metal: no alpha blending
                        }
                    }
                )
            },
            panelAutoHideEnabled: true,
            externalPaused: isPaused,
            isDisplayLockPressed: isDisplayLockPressed,
            // Settings persistence hooks
            getSettingsData: {
                (try? JSONEncoder().encode(BoidsPreset(settings: currentSettings(), midiSlots: midiSlots))) ?? Data()
            },
            applySettingsData: { data in
                if let preset = try? JSONDecoder().decode(BoidsPreset.self, from: data) {
                    applySettings(preset.settings)
                    midiSlots = preset.midiSlots
                    saveMIDISlots()
                    syncLFOHistoriesToSlots()
                    midiSendCache.lastSentCCValues = [:]
                } else if let s = try? JSONDecoder().decode(BoidsSettings.self, from: data) {
                    // Legacy: settings only
                    applySettings(s)
                }
            }
        )
        .sheet(isPresented: $showMidiMenu) { 
            midiMenuSheetView()
        }
        .onChange(of: midiSlots) { _, _ in
            saveMIDISlots(); syncLFOHistoriesToSlots(); midiSendCache.lastSentCCValues = [:]
        }
        .onAppear {
            loadMIDISlots(); syncLFOHistoriesToSlots()
        }
        .onDisappear {
            simHolder.sim?.stopAsyncSimulation();
            simHolder.sim?.teardownAndDispose(); simHolder.sim = nil }
        .onChange(of: isPaused.wrappedValue) { _, newVal in simHolder.sim?.setPaused(newVal) }
       // .onReceive(tickPublisher) { _ in
        //    if isActive && !isPaused.wrappedValue { midiTickLoop() }
       // }
    }
    // MARK: - MIDI/LFO Slot Management
    private func loadMIDISlots() {
        let clip = MIDISlotsClipboard.shared
        if clip.isGlobalEnabled, !clip.globalSlots.isEmpty { midiSlots = clip.globalSlots; return }
        if let data = UserDefaults.standard.data(forKey: midiSlotsKey),
           let loaded = try? JSONDecoder().decode([MIDIParams].self, from: data) {
            midiSlots = loaded
        } else {
            midiSlots = [MIDIParams(tracked: "head.x")]
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
    
    // MARK: - MIDI Menu Sheet
    private func midiMenuSheetView() -> some View {
        let trackers = makeBoidsTrackers(simHolder.sim)
        // Use the fixed per-boid palette for dropdown swatches
        let trackerColors = makeBoidsTrackerColors(simHolder.sim)
        return MIDIMenuView(
            slots: $midiSlots,
            trackers: trackers,
            trackerColors: trackerColors,
            focusIndex: $midiFocusIndex,
            soloIndex: $midiSoloIndex,
            onSend: { _ in },
            onReloadLocal: { loadMIDISlots() }
        )
    }
    
    // Constrain simulation root (scene center) to screen bounds
    private func logRootOutOfScreenIfNeeded(sim: BoidsSimulationAsync) {
        if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
        guard let scnView = sim.scnView, let camera = scnView.pointOfView else { return }

        let rootWorld = sim.inner.rootWorldPosition
        let projected = scnView.projectPoint(rootWorld)
        let w = max(scnView.bounds.width, 1)
        let h = max(scnView.bounds.height, 1)
        let screenX = CGFloat(projected.x)
        let screenY = CGFloat(projected.y)
        let margin: CGFloat = 4 // pixels of guard band
        let minX = margin
        let maxX = w - margin
        let minY = margin
        let maxY = h - margin
        let isOffscreen = (screenX < minX || screenX > maxX || screenY < minY || screenY > maxY)
        guard isOffscreen else { return }

        let clampedX = min(max(screenX, minX), maxX)
        let clampedY = min(max(screenY, minY), maxY)
        let targetScreen = SCNVector3(Float(clampedX), Float(clampedY), projected.z)
        let correctedWorld = scnView.unprojectPoint(targetScreen)
        var delta = correctedWorld - rootWorld
        if !delta.x.isFinite || !delta.y.isFinite || !delta.z.isFinite { return }

        // Keep motion in camera plane to avoid depth pops
        let camForward = SCNVector3(camera.worldTransform.m31, camera.worldTransform.m32, camera.worldTransform.m33).normalized()
        let forwardProj = SCNVector3.dot(delta, camForward)
        let deltaInPlane = delta - camForward * forwardProj

        let k: Float = 0.35
        sim.translate(dx: deltaInPlane.x * k, dy: deltaInPlane.y * k, dz: deltaInPlane.z * k)
        flockOffset += SIMD3<Float>(deltaInPlane.x * k, deltaInPlane.y * k, deltaInPlane.z * k)
    }

    
    // MARK: - MIDI Tick Loop (mirrors MeshBird)
    private func midiTickLoop() {
        autoreleasepool {
            guard let sim = simHolder.sim else { return }
            if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
            logRootOutOfScreenIfNeeded(sim: sim)
            if lfoHistories.count != midiSlots.count { syncLFOHistoriesToSlots() }
            
                        // 30 Hz history sampling
                        let now = CACurrentMediaTime()
                        let allowHistory = (now - lastLFORecordTime) >= lfoRecordInterval
                        if allowHistory { lastLFORecordTime = now }
                        let recordHistory = displayLFOOutputs && allowHistory
            
            for (index, slot) in midiSlots.enumerated() {
                // If a slot is soloed, only allow that one to emit MIDI
                if let s = midiSoloIndex, s != index { continue }
                guard index < lfoHistories.count else { continue }
                guard let ccVal = resolveBoidsTracker(slot.tracked, in: sim, range: slot.range) else { continue }
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
    
    
    
    // MARK: - Tracker Helpers
    private func makeBoidsTrackers(_ sim: BoidsSimulationAsync?) -> [String] {
        // Only track X, Y, and speed for the first 5 boids (Red, Orange, Yellow, Green, Blue)
        var names: [String] = []
        for n in 1...5 {
            names.append("Boid-\(n).x")
            names.append("Boid-\(n).y")
            names.append("Boid-\(n).speed")
        }
        return names
    }
    private func trackerLabel(_ tracker: String) -> String {
        if tracker.hasSuffix(".x") { return "X" }
        if tracker.hasSuffix(".y") { return "Y" }
        if tracker.hasSuffix(".speed") { return "Speed" }
        return tracker
    }
    // Fixed palette for first five boids, matching their visual colors
    private func boidColorForTracker(_ tracker: String) -> Color {
        let palette: [Color] = [.red, .orange, .yellow, .green, .blue]
        guard let base = tracker.split(separator: ".").first,
              base.hasPrefix("Boid-"),
              let idx = Int(base.replacingOccurrences(of: "Boid-", with: "")),
              idx >= 1, idx <= palette.count
        else { return defaultColorForTracker(tracker) }
        return palette[idx - 1]
    }
    private func defaultColorForTracker(_ tracker: String) -> Color {
        let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .gray]
        let hash = abs(tracker.hashValue)
        return palette[hash % palette.count]
    }
    private func makeBoidsTrackerColors(_ sim: BoidsSimulationAsync?) -> [String: Color] {
        let palette: [Color] = [.red, .orange, .yellow, .green, .blue]
        var map: [String: Color] = [:]
        for i in 0..<5 {
            let n = i + 1
            let c = palette[i]
            for s in ["x","y","speed"] { map["Boid-\(n).\(s)"] = c }
        }
        return map
    }
    private func makeBoidsTrackerColorNames(_ sim: BoidsSimulationAsync?) -> [String: String] {
        var map: [String: String] = [:]
        for i in 0..<5 { let n = i + 1; for s in ["x","y","speed"] { map["Boid-\(n).\(s)"] = "Boid \(n)" } }
        return map
    }
    private func resolveBoidsTracker(_ tracker: String, in sim: BoidsSimulationAsync, range: ClosedRange<Int>) -> Int? {
        let parts = tracker.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let idPart = parts[0]
        let comp = parts[1]
        guard idPart.hasPrefix("Boid-") else { return nil }
        guard let idx = Int(idPart.replacingOccurrences(of: "Boid-", with: "")), idx >= 1 else { return nil }
        let index = idx - 1
        if comp == "x" || comp == "y" {
            if let proj = sim.projectedBoidXY127(index: index) {
                let rawProj = comp == "x" ? proj.x : proj.y
                return scaleToRange(rawProj, range: range)
            }
        }
        if comp == "speed" {
            guard let v = sim.boidVelocity(index: index) else { return nil }
            let speed = v.length()
            let maxAbs = max(0.05, sim.maxSpeedValue())
            let cc = normalizeToCC(raw: speed, minVal: 0, maxVal: maxAbs)
            return scaleToRange(cc, range: range)
        }
        return nil
    }
    private func scaleToRange(_ value: Int, range: ClosedRange<Int>) -> Int {
        let minV = range.lowerBound
        let maxV = range.upperBound
        let norm = CGFloat(value) / 127.0
        return Int(round(norm * CGFloat(maxV - minV) + CGFloat(minV)))
    }
    private func normalizeToCC(raw: Float, minVal: Float, maxVal: Float) -> Int {
        let range = maxVal - minVal
        guard range > 0 else { return 0 }
        let wrappedRaw = raw - minVal
        let modRaw = wrappedRaw.truncatingRemainder(dividingBy: range)
        let norm = (modRaw < 0 ? modRaw + range : modRaw) / range
        return Int(round(norm * 127))
    }
    // ...other helpers unchanged...
}
