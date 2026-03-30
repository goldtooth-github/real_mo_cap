// swift
import SwiftUI
import SceneKit
import UIKit
import Combine
import QuartzCore // if not already imported
private var rootWasOffscreen = false

// MARK: - MIDI CC Deduplication Cache
private final class MIDISendCache_MBAsync { var lastSentCCValues: [Int: Int] = [:] }

// Persistable settings for MeshBird
private struct MeshBirdSettings: Codable {
    var wingFlapSpeed: Float
    var birdRotation: Float
    var birdSize: Float
    var windIntensity: Float
    var displayLFOOutputs: Bool
    var birdPosX: Float
    var birdPosY: Float
    var birdPosZ: Float

    enum CodingKeys: String, CodingKey {
        case wingFlapSpeed, birdRotation, birdSize, windIntensity, displayLFOOutputs, birdPosX, birdPosY, birdPosZ
    }

    init(wingFlapSpeed: Float, birdRotation: Float, birdSize: Float, windIntensity: Float, displayLFOOutputs: Bool, birdPosX: Float, birdPosY: Float, birdPosZ: Float) {
        self.wingFlapSpeed = wingFlapSpeed
        self.birdRotation = birdRotation
        self.birdSize = birdSize
        self.windIntensity = windIntensity
        self.displayLFOOutputs = displayLFOOutputs
        self.birdPosX = birdPosX
        self.birdPosY = birdPosY
        self.birdPosZ = birdPosZ
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wingFlapSpeed = try c.decode(Float.self, forKey: .wingFlapSpeed)
        birdRotation = try c.decode(Float.self, forKey: .birdRotation)
        birdSize = try c.decode(Float.self, forKey: .birdSize)
        windIntensity = try c.decode(Float.self, forKey: .windIntensity)
        displayLFOOutputs = try c.decode(Bool.self, forKey: .displayLFOOutputs)
        birdPosX = try c.decodeIfPresent(Float.self, forKey: .birdPosX) ?? 0
        birdPosY = try c.decodeIfPresent(Float.self, forKey: .birdPosY) ?? 0
        birdPosZ = try c.decodeIfPresent(Float.self, forKey: .birdPosZ) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(wingFlapSpeed, forKey: .wingFlapSpeed)
        try c.encode(birdRotation, forKey: .birdRotation)
        try c.encode(birdSize, forKey: .birdSize)
        try c.encode(windIntensity, forKey: .windIntensity)
        try c.encode(displayLFOOutputs, forKey: .displayLFOOutputs)
        try c.encode(birdPosX, forKey: .birdPosX)
        try c.encode(birdPosY, forKey: .birdPosY)
        try c.encode(birdPosZ, forKey: .birdPosZ)
    }
}

// New: bundle settings + MIDI slots in presets
private struct MeshBirdPreset: Codable {
    var settings: MeshBirdSettings
    var midiSlots: [MIDIParams]
}

// MARK: - SimHolder for persistent simulation
final class MeshBirdSimHolder: ObservableObject {
    @Published var sim: MeshBirdSimulationAsync? = nil
}

// MARK: - MeshBirdLifeformViewAsync
struct MeshBirdLifeformViewAsync: View {
    // MARK: - View State & Parameters
    var isActive: Bool = false
    var isPaused: Binding<Bool>
    var isDisplayLockPressed: Binding<Bool>

    private let birdRotationRange: ClosedRange<Float> = -180.0...180.0
    private let birdSizeRange: ClosedRange<Float> = 2.0...10.0
    @State private var wingFlapSpeed: Float = 3.0
    @State private var birdRotation: Float = 0.0
    @State private var birdSize: Float = 5.0
    @State private var windIntensity: Float = 1.0
    @State private var birdOffset: SIMD3<Float> = .zero

    @StateObject private var simHolder = MeshBirdSimHolder()
    @State private var scnViewRef: SCNView? = nil
    @StateObject private var cameraState = CameraOrbitState()

    // MIDI/LFO state
    @State private var showMidiMenu: Bool = false
    @State private var midiSlots: [MIDIParams] = []
    private let midiSlotsKey = "MIDI_SLOTS_MESHBIRD_ASYNC"
    @State private var midiSendCache = MIDISendCache_MBAsync()
    @State private var displayLFOOutputs: Bool = false
    @State private var lfoHistories: [RingHistory] = []
    private var lfoMaxSamples: Int {
        let base = 50
        let count = max(midiSlots.count, 1)
        return base - (base % count)
    }

    // Throttle LFO history to ~30 Hz
    @State private var lastLFORecordTime: CFTimeInterval = 0
    @EnvironmentObject var powerModeMonitor: PowerModeMonitor
    private var lfoRecordInterval: CFTimeInterval {
        powerModeMonitor.isLowPowerMode || reduceCPUOverhead ? 1.0 / 15.0 : 1.0 / 30.0
    }
    @State private var reduceCPUOverhead: Bool = false
    @State private var userReduceCPUOverhead: Bool = false

    // Coalesce per‑frame callback to avoid piling up when main is busy
    @State private var perFrameCallbackPending = false

    @State private var midiFocusIndex: Int? = nil
    @State private var lastSentCCValues: [Int: Int] = [:]
    @State private var midiSoloIndex: Int? = nil

    private let config = LifeformViewConfig(
        initialAzimuth: 0,
        initialElevation: 20,
        initialRadius: 12,
        minRadius: 3,
        maxRadius: 12,
        cameraControlMode: .nicks_control,
        ambientLightIntensity: 0.4,
        directionalLightIntensity: 0.8,
        directionalLightAngles: SCNVector3(x: -Float.pi/4, y: Float.pi/4, z: 0),
        updateInterval: 0.016,
        title: "Mallard in Flight",
        controlPanelColor: Color.black.opacity(0.6),
        controlTextColor: .white,
        buttonBackgroundColor: Color.blue.opacity(0.6),
        controlPanelBottomInset: 5
    )

    private func applyPermanentDebugFlags() {
        DebugToggles.onlyUpdateWhenChanged = true
        DebugToggles.useUnitHeightScalingForSplines = true
        DebugToggles.cleanTeardown = true
        DebugToggles.disableImplicitAnimations = false
        DebugToggles.useAutoreleasePoolPerFrame = false
        DebugToggles.useLookAtConstraint = false
    }

    private func createMeshBirdSimulation(scene: SCNScene) -> MeshBirdSimulationAsync {
        applyPermanentDebugFlags()
        let sim = MeshBirdSimulationAsync(scene: scene, scnView: nil)
        sim.setWingFlapSpeed(wingFlapSpeed)
        sim.setBirdRotation(birdRotation)
        sim.setBirdSize(birdSize)
        sim.setWindIntensity(windIntensity)
        simHolder.sim = sim
        return sim
    }

    private func currentSettings() -> MeshBirdSettings {
        MeshBirdSettings(
            wingFlapSpeed: wingFlapSpeed,
            birdRotation: birdRotation,
            birdSize: birdSize,
            windIntensity: windIntensity,
            displayLFOOutputs: displayLFOOutputs,
            birdPosX: birdOffset.x,
            birdPosY: birdOffset.y,
            birdPosZ: birdOffset.z
        )
    }

    private func applySettings(_ s: MeshBirdSettings) {
        wingFlapSpeed = s.wingFlapSpeed; simHolder.sim?.setWingFlapSpeed(s.wingFlapSpeed)
        birdRotation = s.birdRotation; simHolder.sim?.setBirdRotation(s.birdRotation)
        birdSize = min(max(s.birdSize, birdSizeRange.lowerBound), birdSizeRange.upperBound); simHolder.sim?.setBirdSize(birdSize)
        windIntensity = s.windIntensity; simHolder.sim?.setWindIntensity(s.windIntensity)
        displayLFOOutputs = s.displayLFOOutputs
        let target = SIMD3<Float>(s.birdPosX, s.birdPosY, s.birdPosZ)
        let delta = target - birdOffset
        birdOffset = target
        simHolder.sim?.translate(dx: delta.x, dy: delta.y, dz: delta.z)
    }

    private func buildControls(simBinding: Binding<MeshBirdSimulationAsync?>, isPaused: Binding<Bool>) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Wing Speed").foregroundColor(config.controlTextColor)
                Slider(value: $wingFlapSpeed, in: 0.1...6.0)
                    .onChange(of: wingFlapSpeed) { _, v in simHolder.sim?.setWingFlapSpeed(v) }
                Text(String(format: "%.2f", wingFlapSpeed)).foregroundColor(config.controlTextColor).frame(width: 50)
            }
            HStack {
                Text("Bird Rotation").foregroundColor(config.controlTextColor)
                Slider(value: $birdRotation, in: birdRotationRange)
                    .onChange(of: birdRotation) { _, v in simHolder.sim?.setBirdRotation(v) }
                Text(String(format: "%.0f", birdRotation)).foregroundColor(config.controlTextColor).frame(width: 44)
            }
            HStack {
                Text("Wind Intensity").foregroundColor(config.controlTextColor)
                Slider(value: $windIntensity, in: 0...3)
                    .onChange(of: windIntensity) { _, v in simHolder.sim?.setWindIntensity(v) }
                Text(String(format: "%.2f", windIntensity)).foregroundColor(config.controlTextColor).frame(width: 44)
            }
            Toggle("Display LFO outputs", isOn: $displayLFOOutputs)
                .toggleStyle(.switch)
                .foregroundColor(config.controlTextColor)
            HStack {
                Button(action: { showMidiMenu.toggle() }) {
                    HStack { Image(systemName: "gearshape"); Text("MIDI Settings + Tracking") }
                }
                .foregroundColor(Color.blue)
            }
        }
        .padding(.bottom, 100)
    }

    var body: some View {
        ModifiedSimulationView<MeshBirdSimulationAsync>(
            config: config,
            customCameraState: cameraState,
            createSimulation: { scene in
                if let sim = simHolder.sim { return sim }
                return createMeshBirdSimulation(scene: scene)
            },
            controlsBuilder: { binding, pausedBinding in AnyView(buildControls(simBinding: binding, isPaused: pausedBinding)) },
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
                }
            },
            isActive: isActive,
            systemScaleGetter: { birdSize },
            systemScaleSetter: { newVal in
                let clamped = min(max(newVal, birdSizeRange.lowerBound), birdSizeRange.upperBound)
                birdSize = clamped
                simHolder.sim?.setBirdSize(clamped)
            },
            systemScaleRange: birdSizeRange,
            simulationDragHandler: { delta in
                let factor: Float = 0.02
                let movementMultiplier: Float = 2.0
                let right = cameraState.panDirectionVectors().right
                let horiz = Float(-delta.width) * factor * movementMultiplier
                let dz = right.z * horiz
                let dx = right.x * horiz
                simHolder.sim?.translate(dx: dx, dy: 0, dz: dz)
                birdOffset += SIMD3<Float>(dx, 0, dz)
                let vert = Float(-delta.height) * factor * movementMultiplier
                simHolder.sim?.translate(dx: 0, dy: vert, dz: 0)
                birdOffset += SIMD3<Float>(0, vert, 0)
            },
            enableParallaxPan: false,
            driveWithSimulationManager: false,
            pauseHandler: { paused, sim in
                sim?.setPaused(paused)
            },
            sceneOverlayBuilder: {
                AnyView(
                    ZStack(alignment: .topLeading) {
                        if displayLFOOutputs, !midiSlots.isEmpty {
                            let labels = midiSlots.map { coordForTracker($0.tracked) }
                            let colors = midiSlots.map { colorForTrackerHash($0.tracked) }
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
                                onDoubleTap: { i in midiFocusIndex = i; showMidiMenu = true },
                                compactThresholdFraction: 0.15
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
            getSettingsData: {
                let slots: [MIDIParams]
                if midiSlots.isEmpty,
                   let data = UserDefaults.standard.data(forKey: midiSlotsKey),
                   let decoded = try? JSONDecoder().decode([MIDIParams].self, from: data) {
                    slots = decoded
                } else {
                    slots = midiSlots
                }
                return (try? JSONEncoder().encode(MeshBirdPreset(settings: currentSettings(), midiSlots: slots))) ?? Data()
            },
            applySettingsData: { data in
                let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                if let preset = try? JSONDecoder().decode(MeshBirdPreset.self, from: data) {
                    print("[MeshBird] Loaded preset JSON (slots=\(preset.midiSlots.count)). Preview: \(preview)")
                    applySettings(preset.settings)
                    if preset.midiSlots.isEmpty {
                        print("[MeshBird] Preset has no MIDI slots; keeping existing slots (\(midiSlots.count))")
                    } else {
                        let migrated = preset.midiSlots.map { slot in
                            var s = slot
                            if s.tracked == "heartbeat.bpmInstant" { s.tracked = "heartbeat.bpm" }
                            return s
                        }
                        midiSlots = migrated
                        saveMIDISlots(); syncLFOHistoriesToSlots(); midiSendCache.lastSentCCValues = [:]
                    }
                } else if let s = try? JSONDecoder().decode(MeshBirdSettings.self, from: data) {
                    print("[MeshBird] Loaded settings-only JSON. Preview: \(preview)")
                    applySettings(s)
                } else {
                    print("[MeshBird] Failed to decode JSON for this view. Are you importing the right preset? Preview: \(preview)")
                }
            }
        )
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showMidiMenu) { midiMenuSheetView() }
        .onChange(of: midiSlots) { _, _ in
            saveMIDISlots(); syncLFOHistoriesToSlots(); midiSendCache.lastSentCCValues = [:]
        }
        .onAppear {
            loadMIDISlots(); syncLFOHistoriesToSlots()
        }
        .onDisappear { simHolder.sim?.stopAsyncSimulation(); simHolder.sim?.teardownAndDispose(); simHolder.sim = nil }
        .onChange(of: isPaused.wrappedValue) { _, newVal in simHolder.sim?.setPaused(newVal) }
        .onChange(of: birdRotation) { _, newVal in simHolder.sim?.setBirdRotation(newVal) }
        .onChange(of: birdSize) { _, newVal in simHolder.sim?.setBirdSize(newVal) }
        .onChange(of: windIntensity) { _, newVal in simHolder.sim?.setWindIntensity(newVal) }
    }

    // MARK: - MIDI/LFO Slot Management
    private func loadMIDISlots() {
        let clip = MIDISlotsClipboard.shared
        if clip.isGlobalEnabled, !clip.globalSlots.isEmpty { midiSlots = clip.globalSlots; return }
        if let data = UserDefaults.standard.data(forKey: midiSlotsKey),
           let loaded = try? JSONDecoder().decode([MIDIParams].self, from: data) {
            midiSlots = loaded.map { slot in
                var s = slot
                if s.tracked == "heartbeat.bpmInstant" { s.tracked = "heartbeat.bpm" }
                return s
            }
            if loaded.contains(where: { $0.tracked == "heartbeat.bpmInstant" }) { saveMIDISlots() }
        } else {
            midiSlots = [MIDIParams(tracked: "head.x")]
        }
    }

    private func saveMIDISlots() {
        guard !MIDISlotsClipboard.shared.isGlobalEnabled else { return }
        if let data = try? JSONEncoder().encode(midiSlots) { UserDefaults.standard.set(data, forKey: midiSlotsKey) }
    }

    private func syncLFOHistoriesToSlots() {
        let samples = lfoMaxSamples
        if lfoHistories.count < midiSlots.count {
            for _ in 0..<(midiSlots.count - lfoHistories.count) { lfoHistories.append(RingHistory(capacity: samples)) }
        } else if lfoHistories.count > midiSlots.count {
            lfoHistories.removeLast(lfoHistories.count - midiSlots.count)
        }
        for i in 0..<lfoHistories.count {
            if lfoHistories[i].capacity != samples {
                lfoHistories[i] = RingHistory(capacity: samples)
            }
        }
    }

    // MARK: - Tracker Helpers
    private func makeTrackers(_ sim: MeshBirdSimulationAsync?) -> [String] {
        let joints = ["body","lowerBack","head","neck","tail","tailTip",
                      "leftWingTip","rightWingTip","beakTip",
                      "underneck1","underneck2","bodyUnder1","bodyUnder2"]
        var names: [String] = []
        for j in joints { names.append(contentsOf: ["\(j).x", "\(j).y"]) }
        names.append("heartbeat.bpm")
        names.append("heartbeat.pulse")
        return names
    }

    private func resolveTracker(_ tracker: String, in sim: MeshBirdSimulationAsync, range: ClosedRange<Int>) -> Int? {
        if tracker == "heartbeat.pulse" {
            return sim.heartbeatLatched ? range.upperBound : range.lowerBound
        }
        if tracker == "heartbeat.bpm" {
            let bpm: Float = sim.heartbeatBPM
            let minBPM: Float = 120.0
            let maxBPM: Float = 320.0
            let clamped = max(minBPM, min(maxBPM, bpm))
            let norm = (clamped - minBPM) / (maxBPM - minBPM)
            let cc = Int(round(norm * 127.0))
            return scaleToRange(cc, range: range)
        }
        let parts = tracker.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let joint = parts[0]; let comp = parts[1]
        guard comp == "x" || comp == "y" || comp == "z" else { return nil }
        if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
        if comp == "x" || comp == "y" {
            if let xy = sim.projectedJointXY127(jointName: joint) {
                let raw = (comp == "x") ? xy.x : xy.y
                return scaleToRange(raw, range: range)
            }
        }
        guard let wp = sim.jointWorldPosition(joint) else { return nil }
        let vb = sim.visualBounds
        let rawF: Float = (comp == "x") ? wp.x : (comp == "y") ? wp.y : wp.z
        let cc = normalizeToCC(raw: rawF, minVal: -vb, maxVal: vb)
        return scaleToRange(cc, range: range)
    }

    private func coordForTracker(_ tracker: String) -> String { tracker }

    private func colorForTrackerHash(_ tracker: String) -> Color {
        let hash = abs(tracker.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.7, brightness: 0.9)
    }

    private func normalizeToCC(raw: Float, minVal: Float, maxVal: Float) -> Int {
        let range = maxVal - minVal
        guard range > 0 else { return 0 }
        let wrappedRaw = raw - minVal
        let modRaw = wrappedRaw.truncatingRemainder(dividingBy: range)
        let norm = (modRaw < 0 ? modRaw + range : modRaw) / range
        return Int(round(norm * 127))
    }

    private func scaleToRange(_ value: Int, range: ClosedRange<Int>) -> Int {
        let minV = range.lowerBound
        let maxV = range.upperBound
        let norm = CGFloat(value) / 127.0
        return Int(round(norm * CGFloat(maxV - minV) + CGFloat(minV)))
    }

    // MARK: - Screen Bounds Constraint
    private func logRootOutOfScreenIfNeeded(sim: MeshBirdSimulationAsync) {
        // Ensure we have a view to project with
        if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
        guard let scnView = sim.scnView, let camera = scnView.pointOfView else { return }

        // Project the bird body; use raw values so we can measure how far it drifted
        guard let rawXY = sim.birdBodyScreenXY127Raw(),
              let bodyWorld = sim.jointWorldPosition("body") else {
            if !rootWasOffscreen {
                rootWasOffscreen = true
                print("[MeshBird] Bird body projection failed (treat as off-screen)")
            }
            return
        }

        let margin: Int = 2 // give a small guard band near the edges
        let w = max(scnView.bounds.width, 1)
        let h = max(scnView.bounds.height, 1)
        let minX = CGFloat(margin) / 127.0 * w
        let maxX = w - minX
        let minY = CGFloat(margin) / 127.0 * h
        let maxY = h - minY

        // Convert the 0-127 space (flipped Y) back into SceneKit screen coordinates (origin bottom-left)
        let screenX = CGFloat(rawXY.x) / 127.0 * w
        let screenY = (1.0 - CGFloat(rawXY.y) / 127.0) * h
        let needsClampX = screenX < minX || screenX > maxX
        let needsClampY = screenY < minY || screenY > maxY
        let isOffscreen = needsClampX || needsClampY

        if isOffscreen && !rootWasOffscreen {
            rootWasOffscreen = true
            print("[MeshBird] Bird went off-screen: raw=(\(rawXY.x), \(rawXY.y))")
        } else if !isOffscreen && rootWasOffscreen {
            rootWasOffscreen = false
            print("[MeshBird] Bird back on-screen: raw=(\(rawXY.x), \(rawXY.y))")
        }
        guard isOffscreen else { return }

        // Clamp to the visible pixel rectangle and unproject back into world space at the current depth
        let clampedX = min(max(screenX, minX), maxX)
        let clampedY = min(max(screenY, minY), maxY)
        let projected = scnView.projectPoint(bodyWorld)
        let targetScreen = SCNVector3(Float(clampedX), Float(clampedY), projected.z)
        let correctedWorld = scnView.unprojectPoint(targetScreen)
        var delta = correctedWorld - bodyWorld

        // Soften the correction to avoid overshoot; also guard bad values
        let k: Float = 0.35
        delta.x *= k; delta.y *= k; delta.z *= k
        if !delta.x.isFinite || !delta.y.isFinite || !delta.z.isFinite { return }

        // Use camera up/right to avoid degenerate camera matrices
        var camRight = SCNVector3(camera.worldTransform.m11, camera.worldTransform.m12, camera.worldTransform.m13)
        var camUp = SCNVector3(camera.worldTransform.m21, camera.worldTransform.m22, camera.worldTransform.m23)
        if camRight.length() < 1e-4 || camUp.length() < 1e-4 { return }
        camRight = camRight.normalized(); camUp = camUp.normalized()

        // Remove any component along camera forward to keep motion parallel to the screen plane
        let camForward = SCNVector3(camera.worldTransform.m31, camera.worldTransform.m32, camera.worldTransform.m33).normalized()
        let forwardProj = SCNVector3.dot(delta, camForward)
        let deltaInPlane = delta - camForward * forwardProj

        sim.translate(dx: 0, dy: deltaInPlane.y, dz: deltaInPlane.z)
        birdOffset += SIMD3<Float>(0, deltaInPlane.y, deltaInPlane.z)
    }

    // MARK: - MIDI Tick Loop
    @MainActor
    private func midiTickLoop() {
        autoreleasepool {
            guard let sim = simHolder.sim else { return }
            
            logRootOutOfScreenIfNeeded(sim: sim)
            
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
                guard let ccVal = resolveTracker(slot.tracked, in: sim, range: slot.range) else { continue }

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

    private func midiMenuSheetView() -> some View {
        let trackers = makeTrackers(simHolder.sim)
        let trackerColors = Dictionary(uniqueKeysWithValues: trackers.map { ($0, colorForTrackerHash($0)) })
        return MIDIMenuView(
            slots: $midiSlots,
            trackers: trackers,
            trackerColors: trackerColors,
            focusIndex: $midiFocusIndex,
            soloIndex: $midiSoloIndex,
            onSend: { _ in },
            onReloadLocal: { loadMIDISlots() }
        )
        .environmentObject(LifeformModeStore())
    }
}
//
