import SwiftUI
import SceneKit
import Combine
import UniformTypeIdentifiers
import QuartzCore // for CACurrentMediaTime

private struct AMCASFSettings: Codable {
    var speed: Float
    var modelRotation: Float
    var modelScale: Float
    var gravityAmount: Float
    var displayLFOOutputs: Bool
    var reduceCPUOverhead: Bool
    var rootFixedX: Bool
    var rootFixedY: Bool
    var modelPosX: Float
    var modelPosY: Float
    var modelPosZ: Float
    
    // Allow decoding older presets that lack rootFixedX/Y
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speed = try c.decode(Float.self, forKey: .speed)
        modelRotation = try c.decode(Float.self, forKey: .modelRotation)
        modelScale = try c.decode(Float.self, forKey: .modelScale)
        gravityAmount = try c.decode(Float.self, forKey: .gravityAmount)
        displayLFOOutputs = try c.decode(Bool.self, forKey: .displayLFOOutputs)
        reduceCPUOverhead = try c.decode(Bool.self, forKey: .reduceCPUOverhead)
        rootFixedX = try c.decodeIfPresent(Bool.self, forKey: .rootFixedX) ?? true
        rootFixedY = try c.decodeIfPresent(Bool.self, forKey: .rootFixedY) ?? true
        modelPosX = try c.decode(Float.self, forKey: .modelPosX)
        modelPosY = try c.decode(Float.self, forKey: .modelPosY)
        modelPosZ = try c.decode(Float.self, forKey: .modelPosZ)
    }
    
    init(speed: Float, modelRotation: Float, modelScale: Float, gravityAmount: Float, displayLFOOutputs: Bool, reduceCPUOverhead: Bool, rootFixedX: Bool, rootFixedY: Bool, modelPosX: Float, modelPosY: Float, modelPosZ: Float) {
        self.speed = speed; self.modelRotation = modelRotation; self.modelScale = modelScale
        self.gravityAmount = gravityAmount; self.displayLFOOutputs = displayLFOOutputs
        self.reduceCPUOverhead = reduceCPUOverhead; self.rootFixedX = rootFixedX; self.rootFixedY = rootFixedY
        self.modelPosX = modelPosX; self.modelPosY = modelPosY; self.modelPosZ = modelPosZ
    }
}

private struct AMCASFPreset: Codable {
    var settings: AMCASFSettings
    var midiSlots: [MIDIParams]
}
// Track whether the root bone has gone offscreen
private var rootWasOffscreen = false
// Track whether the root bone was too close to camera (Z depth clipping)
private var rootWasTooCloseZ = false

final class AMCASFSimHolder: ObservableObject { @Published var sim: AMCASFSimulationAsync? = nil }

// MIDI CC Deduplication Cache
private final class MIDISendCache_AMCASFAsync { var lastSentCCValues: [Int: Int] = [:] }

struct AMCASFViewerLifeformViewAsync: View {
    var isActive: Bool = true
    var isPaused: Binding<Bool>
    var isDisplayLockPressed: Binding<Bool>
    var asfName: String = "09"
    var amcName: String = "09_03"
    var displayName: String? = nil   // optional human-readable name for the config title
    var loopStartFrame: Int? = nil   // nil = 0 (first frame)
    var loopEndFrame: Int? = nil     // nil = full clip length
    var loopCrossfadeFrames: Int = 30 // frames over which to crossfade at loop seam

    @StateObject private var holder = AMCASFSimHolder()
    @StateObject private var cameraState = CameraOrbitState()
    @State private var scnViewRef: SCNView? = nil

    @State private var speed: Float = 4.0
    @State private var looping: Bool = true
    @State private var showLoadError: Bool = false
    @State private var loadErrorMessage: String = ""
    @State private var scrubFrame: Int = 0
    @State private var play: Bool = true
    @State private var fileLoaded: Bool = false
    @State private var showInfo: Bool = false

    // New: model transform state
    @State private var modelRotation: Float = 45.0 // degrees yaw
    @State private var modelScale: Float = 1.0    // uniform scale
    @State private var modelElevation: Float = 0.0 // vertical offset in scene units
    @State private var cameraBaseY: Float? = nil
    // Gravity control amount (0..5 in 0.5 steps)
    @State private var gravityAmount: Float = 0.0
    // Root anchoring: X is permanently fixed, Y is permanently unfixed
    private let rootFixedX: Bool = true
    private let rootFixedY: Bool = false

    // Deduplication - remember last applied values to avoid redundant SceneKit updates
    @State private var lastAppliedModelRotation: Float? = nil
    @State private var lastAppliedCameraElevation: Float? = nil

    // MIDI / LFO state (mirroring MeshBird)
    @State private var showMidiMenu: Bool = false
    @State private var midiSlots: [MIDIParams] = []
    private var midiSlotsKey: String { "MIDI_SLOTS_AMCASF_ASYNC_\(asfName)_\(amcName)" }
    @State private var midiSendCache = MIDISendCache_AMCASFAsync()
    @State private var displayLFOOutputs: Bool = false
    @State private var lfoHistories: [RingHistory] = []
    @State private var midiFocusIndex: Int? = nil
    @State private var midiSoloIndex: Int? = nil
    @State private var lastLFORecordTime: CFTimeInterval = 0
    @EnvironmentObject var powerModeMonitor: PowerModeMonitor
    private var lfoRecordInterval: CFTimeInterval {
        powerModeMonitor.isLowPowerMode || reduceCPUOverhead ? 1.0 / 15.0 : 1.0 / 30.0
    }
    @State private var reduceCPUOverhead: Bool = false
    @State private var userReduceCPUOverhead: Bool = false
    @State private var perFrameCallbackPending: Bool = false

    private var lfoMaxSamples: Int {
        let base = 50
        let count = max(midiSlots.count, 1)
        return base - (base % count)
    }

    private var config: LifeformViewConfig {
        LifeformViewConfig(
        initialAzimuth: 0,
        initialElevation: 15,
        initialRadius: 30,
        minRadius: 5,
        maxRadius: 30,
        cameraControlMode: .nicks_control,
        ambientLightIntensity: 0.3,
        directionalLightIntensity: 0.9,
        directionalLightAngles: SCNVector3(x: -Float.pi/4, y: Float.pi/4, z: 0),
        updateInterval: 0.016,
        title: displayName ?? amcName,
        controlPanelColor: Color.black.opacity(0.6),
        controlTextColor: .white,
        buttonBackgroundColor: Color.blue.opacity(0.6),
        controlPanelBottomInset: 5
    )}

    private func createSimulation(scene: SCNScene) -> AMCASFSimulationAsync {
        if let existing = holder.sim { return existing }
        let sim = AMCASFSimulationAsync(scene: scene, scnView: nil)
        // Apply UI-default playback state: loop ON, default speed, but do NOT start playing yet.
        // Playback is deferred until the file is loaded and loop bounds are applied,
        // preventing jerky animation from frames advancing before setup is complete.
        sim.setSpeed(speed)
        sim.setLooping(true)
        sim.setPlaying(false)  // ← deferred until interpretLoadState
        sim.setRootedX(rootFixedX)
        sim.setRootedY(rootFixedY)
        // Hide the skeleton until loading + setup is complete (prevents flash of wrong position)
        sim.inner.rootNode.isHidden = true
        // Auto-load bundled ASF + AMC immediately
        sim.loadFiles(asfName: asfName, amcName: amcName)
        // Store sim reference BEFORE polling so pollUntilLoaded can access it
        holder.sim = sim
        // Poll until load completes so loop bounds are reliably applied
        pollUntilLoaded()
        return sim
    }

    /// Repeatedly checks load state until ready (or failed), then applies loop bounds.
    private func pollUntilLoaded(attempt: Int = 0) {
        guard let sim = holder.sim else { return }
        switch sim.loadState {
        case .ready:
            interpretLoadState()
        case .failed:
            interpretLoadState()
        case .loading, .idle:
            // Retry after a short delay, up to ~5 seconds
            if attempt < 50 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.pollUntilLoaded(attempt: attempt + 1)
                }
            }
        }
    }

    private func currentSettings() -> AMCASFSettings {
        let pos = holder.sim?.inner.rootNode.position ?? SCNVector3Zero
        return AMCASFSettings(
            speed: speed,
            modelRotation: modelRotation,
            modelScale: modelScale,
            gravityAmount: gravityAmount,
            displayLFOOutputs: displayLFOOutputs,
            reduceCPUOverhead: reduceCPUOverhead,
            rootFixedX: rootFixedX,
            rootFixedY: rootFixedY,
            modelPosX: pos.x,
            modelPosY: pos.y,
            modelPosZ: pos.z
        )
    }

    private func applySettings(_ s: AMCASFSettings) {
        speed = s.speed; holder.sim?.setSpeed(s.speed)
        modelRotation = s.modelRotation; applyModelRotation()
        modelScale = max(0.1, min(10.0, s.modelScale)); applyModelScale()
        gravityAmount = s.gravityAmount; holder.sim?.inner.setGravity(amount: s.gravityAmount)
        displayLFOOutputs = s.displayLFOOutputs
        reduceCPUOverhead = s.reduceCPUOverhead
        // Root X/Y are permanently fixed/unfixed
        holder.sim?.setRootedX(true)
        holder.sim?.setRootedY(false)
        if let node = holder.sim?.inner.rootNode {
            node.position = SCNVector3(s.modelPosX, s.modelPosY, s.modelPosZ)
        }
    }

    private func buildControls(simBinding: Binding<AMCASFSimulationAsync?>, isPaused: Binding<Bool>) -> some View {
        VStack(spacing: 10) {
            // Play / Loop toggles are intentionally removed; keep Reset hidden
            // Speed control
            HStack {
                Text("Speed").foregroundColor(config.controlTextColor)
                Slider(value: Binding(get: { Double(speed) }, set: { v in speed = Float(v); holder.sim?.setSpeed(speed) }), in: 0.0...8.0)
                Text(String(format: "%.2f", speed)).foregroundColor(config.controlTextColor).frame(width: 50)
            }
 
            // Move model transform controls above MIDI / LFO section
            HStack {
                Text("Model Rotation").foregroundColor(config.controlTextColor)
                // Rotation slider: only update modelRotation; actual application deduped in applyModelRotation
                Slider(value: Binding(get: { Double(modelRotation) }, set: { v in modelRotation = Float(v) }), in: -180.0...180.0)
                Text(String(format: "%.0f°", modelRotation)).foregroundColor(config.controlTextColor).frame(width: 56)
            }

            // MIDI / LFO controls
            Toggle("Display LFO outputs", isOn: $displayLFOOutputs)
                .toggleStyle(.switch)
                .foregroundColor(config.controlTextColor)
            HStack {
                Button(action: { showMidiMenu.toggle() }) {
                    HStack { Image(systemName: "gearshape"); Text("MIDI Settings + Tracking") }
                }
                .foregroundColor(Color.blue)
            }

            // Removed Reload Files, Show Info and Reset controls as requested
        }
        .padding(.bottom, 100)
    }

    private func reloadFiles() {
        showLoadError = false; loadErrorMessage = ""
        guard let sim = holder.sim else { return }
        sim.loadFiles(asfName: asfName, amcName: amcName) // Always loads from bundle
        pollUntilLoaded()
    }

    private func interpretLoadState() {
        guard let sim = holder.sim else { return }
        switch sim.loadState {
        case .ready:
            fileLoaded = true
            scrubFrame = sim.currentFrameIndex
            // Apply per-file loop bounds after clip is loaded
            sim.setLoopStartFrame(loopStartFrame)
            sim.setLoopEndFrame(loopEndFrame)
            sim.setLoopCrossfadeFrames(loopCrossfadeFrames)
            // Center the figure vertically: root at 65% up from the bottom
            let ortho = Float(scnViewRef?.pointOfView?.camera?.orthographicScale ?? Double(cameraState.radius))
            sim.centerRootVertically(screenFraction: 0.65, orthoScale: ortho)
            // Reset playback to the correct start frame
            sim.inner.reset()
            // NOW reveal the skeleton — it's at the correct position with correct bounds.
            sim.inner.rootNode.isHidden = false
            // Reset renderer timing so the first dt is clean (no stale accumulated time).
            sim.resetRendererTiming()
            sim.setPlaying(true)
        case .failed(let err):
            showLoadError = true
            loadErrorMessage = err.localizedDescription
            fileLoaded = false
        case .loading, .idle: break
        }
    }

    var body: some View {
        ModifiedSimulationView<AMCASFSimulationAsync>(
            config: config,
            customCameraState: cameraState,
            createSimulation: { scene in createSimulation(scene: scene) },
            controlsBuilder: { binding, pausedBinding in AnyView(buildControls(simBinding: binding, isPaused: pausedBinding)) },
            onViewReady: { _, scnView in
                scnViewRef = scnView
                scnView.backgroundColor = .black
                holder.sim?.scnView = scnView
                // capture camera base Y for elevation adjustments
                if cameraBaseY == nil, let pov = scnView.pointOfView { cameraBaseY = pov.position.y }
                // Apply initial transform to container
                applyModelScale()
                applyModelRotation()
                // Initialize gravity
                holder.sim?.inner.setGravity(amount: gravityAmount)
                holder.sim?.perFrameCallback = {
                    guard isActive && !isPaused.wrappedValue else { return }
                    if perFrameCallbackPending { return }
                    perFrameCallbackPending = true
                    DispatchQueue.main.async {
                        defer { perFrameCallbackPending = false }
                        if self.isActive && !self.isPaused.wrappedValue {
                            self.midiTickLoop()
                        }
                    }
                }
                holder.sim?.startAsyncSimulation()
                // Configure orthographic projection for Flower
                if let cam = scnView.pointOfView?.camera {
                    cam.usesOrthographicProjection = true
                    // Map initial orthographic scale to current orbital radius so zoom feels consistent
                    cam.orthographicScale = Double(max(1, cameraState.radius))
                    cam.zNear = 0.1
                    cam.zFar = 500
                
            }
            },
            isActive: isActive,
            systemScaleGetter: { modelScale },
            systemScaleSetter: { newVal in let clamped = max(0.1, min(10.0, newVal)); modelScale = clamped; applyModelScale() },
            systemScaleRange: 0.1...10.0,
            simulationDragHandler: { delta in
                let factor: Float = 0.05
                let mul: Float = 2.0
                let right = cameraState.panDirectionVectors().right
                let horiz = Float(-delta.width) * factor * mul
                             holder.sim?.inner.rootNode.position.x += right.x * horiz
                             holder.sim?.inner.rootNode.position.z += right.z * horiz
                             let vert = Float(-delta.height) * factor * mul
                             holder.sim?.inner.rootNode.position.y += vert
                
            },
            enableParallaxPan: false,
            driveWithSimulationManager: false,
            pauseHandler: { paused, sim in sim?.setPaused(paused) },
            sceneOverlayBuilder: {
                AnyView(
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading) {
                            if showLoadError {
                                Text("Load Error: \(loadErrorMessage)").foregroundColor(.red).padding(6).background(Color.black.opacity(0.5)).cornerRadius(6)
                            }
                            Spacer()
                        }.padding(8)
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
                            ).padding(.horizontal, 8)
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
                return (try? JSONEncoder().encode(AMCASFPreset(settings: currentSettings(), midiSlots: slots))) ?? Data()
            },
            applySettingsData: { data in
                let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                if let preset = try? JSONDecoder().decode(AMCASFPreset.self, from: data) {
                    applySettings(preset.settings)
                    if !preset.midiSlots.isEmpty {
                        midiSlots = preset.midiSlots
                        saveMIDISlots(); syncLFOHistoriesToSlots(); midiSendCache.lastSentCCValues = [:]
                    }
                } else if let settingsOnly = try? JSONDecoder().decode(AMCASFSettings.self, from: data) {
                    applySettings(settingsOnly)
                } else {
                }
            }
        )
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showMidiMenu) { midiMenuSheetView() }
        .onChange(of: midiSlots) { _, _ in
            saveMIDISlots(); syncLFOHistoriesToSlots(); midiSendCache.lastSentCCValues = [:]
        }
        .onAppear { loadMIDISlots(); syncLFOHistoriesToSlots() }
        .onDisappear { holder.sim?.stopAsyncSimulation(); holder.sim?.teardownAndDispose(); holder.sim = nil }
        // Keep transforms in sync when changed externally
      .onChange(of: modelRotation) { _, _ in applyModelRotation() }
        .onChange(of: modelScale) { _, _ in applyModelScale() }
        // Gravity change hook
        .onChange(of: gravityAmount) { _, newVal in holder.sim?.inner.setGravity(amount: newVal) }
    }

    // MARK: - Apply container transforms
    private func applyModelScale() {
        guard let node = holder.sim?.inner.rootNode else { return }
        let s = Float(modelScale)
        node.scale = SCNVector3(s, s, s)
    }
    private func applyModelRotation() {
        // small epsilon to avoid redundant SceneKit writes
        let eps: Float = 0.01 // degrees
        if let last = lastAppliedModelRotation, abs(last - modelRotation) <= eps { return }
        lastAppliedModelRotation = modelRotation
        guard let node = holder.sim?.inner.rootNode else { return }
        let rad = modelRotation * (.pi / 180)
        node.eulerAngles.y = rad
    }
    private func applyModelElevation() {
        // Elevation driven by cameraState.elevation; dedupe small changes
        let elev = Float(cameraState.elevation)
        let eps: Float = 0.001
        if let last = lastAppliedCameraElevation, abs(last - elev) <= eps { return }
        lastAppliedCameraElevation = elev
        guard let scn = scnViewRef, let pov = scn.pointOfView else { return }
        let base = cameraBaseY ?? pov.position.y
        pov.position.y = base + elev
    }

    // MARK: - MIDI / LFO Slot Management
    private func loadMIDISlots() {
        let clip = MIDISlotsClipboard.shared
        if clip.isGlobalEnabled, !clip.globalSlots.isEmpty { midiSlots = clip.globalSlots; return }
        if let data = UserDefaults.standard.data(forKey: midiSlotsKey),
           let loaded = try? JSONDecoder().decode([MIDIParams].self, from: data) {
            midiSlots = loaded
        } else {
            midiSlots = [MIDIParams(tracked: "frame.index")] // default track frame index
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
        for i in 0..<lfoHistories.count { if lfoHistories[i].capacity != samples { lfoHistories[i] = RingHistory(capacity: samples) } }
    }

    // MARK: - Tracker Helpers
    private func makeTrackers(_ sim: AMCASFSimulationAsync?) -> [String] {
        if let sim = sim { return sim.trackerNames() } else { return ["frame.index"] }
    }

    private func resolveTracker(_ tracker: String, in sim: AMCASFSimulationAsync, range: ClosedRange<Int>) -> Int? {
        if tracker == "frame.index" {
            let total = max(sim.totalFrames - 1, 1)
            let idx = min(max(sim.currentFrameIndex, 0), total)
            let norm = Float(idx) / Float(total)
            let cc = Int(round(norm * 127.0))
            return scaleToRange(cc, range: range)
        }
        let parts = tracker.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let bone = parts[0]; let comp = parts[1]
        guard comp == "x" || comp == "y" || comp == "z" else { return nil }
        if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
        if (comp == "x" || comp == "y") && sim.projectedJointXY127(jointName: bone) != nil {
            if let xy = sim.projectedJointXY127(jointName: bone) {
                let raw = (comp == "x") ? xy.x : xy.y
                return scaleToRange(raw, range: range)
            }
        }
        guard let wp = sim.jointWorldPosition(bone) else { return nil }
        let vb = sim.visualBounds
        let rawF: Float = (comp == "x") ? wp.x : (comp == "y") ? wp.y : wp.z
        let cc = normalizeToCC(raw: rawF, minVal: -vb, maxVal: vb)
        return scaleToRange(cc, range: range)
    }

    private func coordForTracker(_ tracker: String) -> String { tracker }

    private func colorForTrackerHash(_ tracker: String) -> Color {
        BoneColor.colorForTracker(tracker)
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

    // MARK: - Root clamping (AMCASF)

    private func logRootOutOfScreenIfNeeded(sim: AMCASFSimulationAsync) {
        if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
        guard let scnView = sim.scnView, let camera = scnView.pointOfView else { return }

        guard let rawXY = sim.rootBoneScreenXY127Raw(),
              let rootWorld = sim.jointWorldPosition(sim.inner.rootBoneName) else {
            if !rootWasOffscreen { rootWasOffscreen = true }
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

        if isOffscreen && !rootWasOffscreen { rootWasOffscreen = true }
        else if !isOffscreen && rootWasOffscreen { rootWasOffscreen = false }
        guard isOffscreen else { return }

        let clampedX = min(max(screenX, minX), maxX)
        let clampedY = min(max(screenY, minY), maxY)
        let projected = scnView.projectPoint(rootWorld)
        let targetScreen = SCNVector3(Float(clampedX), Float(clampedY), projected.z)
        let correctedWorld = scnView.unprojectPoint(targetScreen)
        var delta = correctedWorld - rootWorld

        let k: Float = 0.35
        if !delta.x.isFinite || !delta.y.isFinite || !delta.z.isFinite { return }

        // Remove any component along camera forward to keep motion parallel to the screen plane
        let camForward = SCNVector3(camera.worldTransform.m31, camera.worldTransform.m32, camera.worldTransform.m33).normalized()
        let forwardProj = SCNVector3.dot(delta, camForward)
        let deltaInPlane = delta - camForward * forwardProj

        // Apply clamp in camera up/right plane via rootBasePosition
        if var base = sim.inner.rootBasePosition as SIMD3<Float>? {
            base.z += deltaInPlane.z * k
            base.y += deltaInPlane.y * k
            base.x = 0
            sim.inner.rootBasePosition = base
        }
    }

    /// Prevents the root bone from getting too close to (or passing through) the camera's near clip plane.
    /// Checks the screen-space projected Z of the root bone; if it drops below a safe threshold,
    /// the figure is pushed back along the camera's forward axis via rootBasePosition.
    private func clampRootDepthIfNeeded(sim: AMCASFSimulationAsync) {
        if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
        guard let scnView = sim.scnView, let camera = scnView.pointOfView else { return }

        // Get projected Z (0 = near clip, 1 = far clip)
        guard let projZ = sim.rootBoneProjectedZ() else { return }

        // Safety margin: keep the root bone at least this far into the depth buffer.
        // 0.0 = exactly at near clip, 1.0 = at far clip. 0.02 gives comfortable headroom.
        let minSafeZ: Float = 0.02

        if projZ < minSafeZ {
            if !rootWasTooCloseZ {
                rootWasTooCloseZ = true
            }

            guard let rootWorld = sim.jointWorldPosition(sim.inner.rootBoneName) else { return }

            // Compute world-space position at the safe depth threshold
            let projected = scnView.projectPoint(rootWorld)
            // Build a target screen point with the same X/Y but at the safe Z depth
            let safeScreenPoint = SCNVector3(projected.x, projected.y, minSafeZ)
            let safeWorld = scnView.unprojectPoint(safeScreenPoint)

            // Delta from current world position to the safe position (pushes away from camera)
            let delta = safeWorld - rootWorld
            guard delta.x.isFinite && delta.y.isFinite && delta.z.isFinite else { return }

            // Apply correction via rootBasePosition along camera forward
            let k: Float = 0.5 // slightly aggressive to prevent clipping
            if var base = sim.inner.rootBasePosition as SIMD3<Float>? {
                base.x += delta.x * k
                base.y += delta.y * k
                base.z += delta.z * k
                sim.inner.rootBasePosition = base
            }
        } else {
            if rootWasTooCloseZ {
                rootWasTooCloseZ = false
            }
        }
    }

    // MARK: - MIDI Tick Loop
    @MainActor
    private func midiTickLoop() {
        autoreleasepool {
            guard let sim = holder.sim else { return }
            if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
            logRootOutOfScreenIfNeeded(sim: sim)
            clampRootDepthIfNeeded(sim: sim)
            if lfoHistories.count != midiSlots.count { syncLFOHistoriesToSlots() }

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
        let trackers = makeTrackers(holder.sim)
        let trackerColors = Dictionary(uniqueKeysWithValues: trackers.map { ($0, colorForTrackerHash($0)) })
        return MIDIMenuView(
            slots: $midiSlots,
            trackers: trackers,
            trackerColors: trackerColors,
            focusIndex: $midiFocusIndex,
            soloIndex: $midiSoloIndex,
            onSend: { _ in },
            onReloadLocal: { loadMIDISlots() }
        ).environmentObject(LifeformModeStore())
    }
}

private struct RingSparkline: View {
    @ObservedObject var history: RingHistory
    let stroke: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let n = max(history.count, 2)
            let step = w / CGFloat(max(n - 1, 1))
            ZStack(alignment: .center) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.5))
                    p.addLine(to: CGPoint(x: w, y: h * 0.5))
                }.stroke(Color.white.opacity(0.15), lineWidth: 1)
                Path { p in
                    if history.count == 0 {
                        p.move(to: CGPoint(x: 0, y: h * 0.5))
                        p.addLine(to: CGPoint(x: w, y: h * 0.5))
                    } else {
                        var didMove = false
                        history.forEachOrdered { i, v in
                            let clamped = min(max(v, 0), 1)
                            let x = CGFloat(i) * step
                            let y = (1 - clamped) * h
                            if !didMove { p.move(to: CGPoint(x: x, y: y)); didMove = true } else { p.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                }
                .stroke(stroke, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
