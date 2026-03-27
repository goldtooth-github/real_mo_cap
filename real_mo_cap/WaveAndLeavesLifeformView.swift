import SwiftUI
import SceneKit
import UIKit
import Combine
private var rootWasOffscreen = false
private var jointOffscreenStates: [Int: Bool] = [:]

// MARK: - MIDI CC Deduplication Cache
private final class MIDISendCache { var lastSentCCValues: [Int: Int] = [:] }

// Persistable settings for Waves & Leaves
private struct WavesSettings: Codable {
    var simulationSpeed: Float
    var waveAmplitude: Float
    var waveFrequency: Float
    var leafBuoyancy: Float
    var waveResolution: Int
    var secondWaveAmplitude: Float
    var secondWaveFrequency: Float
    var secondWaveDirection: Float
    var secondWavePhase: Float
    var secondWaveSpeed: Float
    var globalScale: Float
    var displayLFOOutputs: Bool
    var systemPosX: Float?
    var systemPosY: Float?
    var systemPosZ: Float?
    var elevation: Float?
}
// New: Preset includes settings + MIDI slots for Save/Load
private struct WavesPreset: Codable {
    var settings: WavesSettings
    var midiSlots: [MIDIParams]
}

// MARK: - SimHolder for persistent simulation
final class WaveAndLeavesSimHolder: ObservableObject {
    @Published var sim: WaveAndLeavesSimulationAsync? = nil
}

// MARK: - WaveAndLeavesLifeformView
struct WaveAndLeavesLifeformView: View {
    // MARK: - View State & Parameters
    var isActive: Bool = false
    var isPaused: Binding<Bool>
    var isDisplayLockPressed: Binding<Bool>

    // Simulation parameters
    private let waveScaleRange: ClosedRange<Float> = 0.55...2.0
    private let waveAmplitudeRange: ClosedRange<Float> = 0.1...0.6
    private let waveFrequencyRange: ClosedRange<Float> = 0.5...1.2
    private let leafBuoyancyRange: ClosedRange<Float> = 0.5...2.0
    private let simulationSpeedRange: ClosedRange<Float> = 0.1...1.2
    private let defaultWaveAmplitude: Float = 0.6
    private let defaultWaveFrequency: Float = 1.2
    private let defaultLeafBuoyancy: Float = 1.0
    private let defaultSimulationSpeed: Float = 1.0
    private let defaultWaveResolution: Int = 12
    private let waveResolutionRange: ClosedRange<Double> = 2...15
    @State private var waveAmplitude: Float = 0.6
    @State private var waveFrequency: Float = 1.0
    @State private var leafBuoyancy: Float = 1.0
    @State private var simulationSpeed: Float = 1.0
    @State private var waveResolution: Double = 12
    @State private var secondWaveAmplitude: Float = 0.4
    @State private var secondWaveFrequency: Float = 1.0
    @State private var secondWaveDirection: Float = 45.0
    @State private var secondWavePhase: Float = 0.3
    @State private var secondWaveSpeed: Float = 1.0
    @State private var showSecondWaveControls: Bool = true
    @StateObject private var simHolder = WaveAndLeavesSimHolder()
    @StateObject private var cameraState = CameraOrbitState()
    @State private var scnViewRef: SCNView? = nil
    @State private var skyNodeRef: SCNNode? = nil  // <-- ADD THIS LINE
    // MIDI/LFO state
    @State private var showMidiMenu: Bool = false
    @State private var midiSlots: [MIDIParams] = []
    private let midiSlotsKey = "MIDI_SLOTS_WAVELEAVES"
    @State private var midiFocusIndex: Int? = nil
    @State private var midiSendCache = MIDISendCache()
    @State private var lfoHistories: [RingHistory] = []
    @State private var displayLFOOutputs: Bool = false
    @State private var pinchGesture: UIPinchGestureRecognizer? = nil
    
    // Coalesce per-frame callback to avoid piling up when main is busy
    @State private var perFrameCallbackPending = false
    
    @EnvironmentObject var powerModeMonitor: PowerModeMonitor
    private var lfoRecordInterval: CFTimeInterval {
        powerModeMonitor.isLowPowerMode || reduceCPUOverhead ? 1.0 / 15.0 : 1.0 / 30.0
    }
    @State private var reduceCPUOverhead: Bool = false
    @State private var userReduceCPUOverhead: Bool = false
    
    private let lfoMaxSamples: Int = 50
    @State private var globalScale: Float = 0.8
    private let globalScaleRange: ClosedRange<Float> = 0.5...3.0
    // NEW: Solo state shared with MIDI menu
    @State private var midiSoloIndex: Int? = nil
    @State private var systemOffset: SIMD3<Float> = .zero
    // MARK: - View Config
    private let config = LifeformViewConfig(
        initialAzimuth: 0,
        initialElevation: 15,
        initialRadius: 15,
        minRadius: 8,
        maxRadius: 25,
        cameraControlMode: .nicks_control,
        ambientLightIntensity: 0.01,
        directionalLightIntensity: 0.95,
        directionalLightAngles: SCNVector3(x: 10, y: 20, z: 10),
        disableSceneLights: true,
        updateInterval: 0.016,
        title: "Light Buoy",
        controlPanelColor: Color.black.opacity(0.7),
        controlTextColor: .white,
        buttonBackgroundColor: Color.indigo.opacity(0.6),
        controlPanelBottomInset: 5
    )

    // MARK: - Permanent Debug Flags (if any)
    // (Add here if needed, as in MeshBird)

    // MARK: - Simulation Creation
    private func createWaveAndLeavesSimulation(scene: SCNScene) -> WaveAndLeavesSimulationAsync {
        let sim = WaveAndLeavesSimulationAsync(scene: scene, scnView: nil)
        sim.setWaveResolution(Int(waveResolution))
        sim.setSimulationSpeed(simulationSpeed)
        sim.setWaveAmplitude(waveAmplitude)
        sim.setWaveFrequency(waveFrequency)
        sim.setLeafBuoyancy(leafBuoyancy)
        sim.setSecondWaveAmplitude(secondWaveAmplitude)
        sim.setSecondWaveFrequency(secondWaveFrequency)
        sim.setSecondWaveDirectionDegrees(secondWaveDirection)
        sim.setSecondWavePhaseOffset(secondWavePhase)
        sim.setSecondWaveSpeedFactor(secondWaveSpeed)
        sim.setGlobalScale(globalScale)
        simHolder.sim = sim
        return sim
    }

    // MARK: - Controls UI
    private func buildControls(simBinding: Binding<WaveAndLeavesSimulationAsync?>, isPaused: Binding<Bool>) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("Speed").foregroundColor(config.controlTextColor)
                Slider(value: $simulationSpeed, in: simulationSpeedRange)
                    .onChange(of: simulationSpeed) { _, newVal in simHolder.sim?.setSimulationSpeed(newVal) }
                Text(String(format: "%.2f", simulationSpeed)).foregroundColor(config.controlTextColor).frame(width: 44)
            }
            HStack {
                Text("Wave Amplitude").foregroundColor(config.controlTextColor)
                Slider(value: $waveAmplitude, in: waveAmplitudeRange)
                    .onChange(of: waveAmplitude) { _, newVal in simHolder.sim?.setWaveAmplitude(newVal) }
                Text(String(format: "%.2f", waveAmplitude)).foregroundColor(config.controlTextColor).frame(width: 44)
            }
           
            // Swift
            HStack {
                Text("Elevation").foregroundColor(config.controlTextColor)
                Slider(value: $cameraState.elevation, in: 0.0...1.6)
                Text(String(format: "%.2f°", cameraState.elevation)).foregroundColor(config.controlTextColor).frame(width: 44)
            }
            /*
            HStack {
                Text("Wave Frequency").foregroundColor(config.controlTextColor)
                Slider(value: $waveFrequency, in: waveFrequencyRange)
                    .onChange(of: waveFrequency) { _, newVal in simHolder.sim?.setWaveFrequency(newVal) }
                Text(String(format: "%.2f", waveFrequency)).foregroundColor(config.controlTextColor).frame(width: 44)
            }*/
            Toggle("Display LFO outputs", isOn: $displayLFOOutputs)
                .toggleStyle(.switch)
                .foregroundColor(config.controlTextColor)
            HStack {
                Button(action: { showMidiMenu.toggle() }) {
                    HStack { Image(systemName: "gearshape"); Text("MIDI Settings + Tracking") }
                      
                        .foregroundColor(Color.blue)
                }
            }
        }
        .padding(.bottom, 100)
    }
    
    
    // MARK: - Helper Functions for LFO Overlay
    private func coordForTracker(_ tracker: String) -> String {
        // Return full tracker name for LFO overlay label
        return tracker
    }

    private func colorForTrackerHash(_ tracker: String) -> Color {
        // Simple hash to color mapping for demonstration
        let hash = abs(tracker.hashValue)
        let hue = Double((hash % 360)) / 360.0
        return Color(hue: hue, saturation: 0.7, brightness: 0.9)
    }

    // MARK: - Overlay View
    private var lfoOverlayView: some View {
        Group {
            if displayLFOOutputs, !midiSlots.isEmpty {
                let labels = midiSlots.map { $0.tracked } // Use full tracker name for label
                let colors = midiSlots.map { colorForTrackerHash($0.tracked) }
                let channels = midiSlots.map { $0.channel }
                let ccNumbers = midiSlots.map { $0.ccNumber }
                let notesBindings: [Binding<String>] = midiSlots.indices.map { i in
                    Binding<String>(
                        get: { midiSlots[i].coordinateName },
                        set: { midiSlots[i].coordinateName = $0 }
                    )
                }
                LFORingOverlayView(labels: labels, histories: lfoHistories, colors: colors, channels: channels, ccNumbers: ccNumbers, notes: notesBindings, topMargin: 44, onDoubleTap: { idx in
                    if midiSlots.indices.contains(idx) { midiFocusIndex = idx; showMidiMenu = true }
                }, compactThresholdFraction: 0.25)
                .padding(.horizontal, 8)
                .drawingGroup() // Hint to Metal: no alpha blending
            }
        }
    }

    // MARK: - Main View Body
    var body: some View {
        ModifiedSimulationView<WaveAndLeavesSimulationAsync>(
            config: config,
            customCameraState: cameraState,
            createSimulation: { scene in
                if let sim = simHolder.sim { return sim }
                return createWaveAndLeavesSimulation(scene: scene)
            },
            controlsBuilder: { binding, pausedBinding in AnyView(buildControls(simBinding: binding, isPaused: pausedBinding)) },
            onViewReady: { simBinding, scnView in
                simBinding.wrappedValue?.scnView = scnView
                scnViewRef = scnView
                if let scene = scnView.scene {
                    skyNodeRef = scene.rootNode.childNode(withName: "skynode", recursively: true)
                }
          
                    // Configure orthographic projection for Flower
                    if let cam = scnView.pointOfView?.camera {
                        cam.usesOrthographicProjection = true
                        // Map initial orthographic scale to current orbital radius so zoom feels consistent
                        cam.orthographicScale = Double(max(1, cameraState.radius))
                        cam.zNear = 0.1
                        cam.zFar = 2000
                    }
                simHolder.sim = simBinding.wrappedValue
                
                // Non-blocking, coalesced main-thread callback
                if let sim = simBinding.wrappedValue {
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
            systemScaleGetter: { globalScale },
            systemScaleSetter: { newVal in
                let clamped = min(max(newVal, waveScaleRange.lowerBound), waveScaleRange.upperBound)
                globalScale = clamped
                simHolder.sim?.setGlobalScale(clamped)
                // ADD THIS BLOCK - Scale skynode proportionally
                if let sky = skyNodeRef {
                    let skyScale = clamped * 10.0 // Adjust multiplier as needed
                    sky.scale = SCNVector3(skyScale, skyScale, skyScale)
                }
            },
            systemScaleRange: waveScaleRange,
            simulationDragHandler: { delta in
                // Prefer screen-space mapping at current root depth so elevation/rotation don’t skew movement
                if let sim = simHolder.sim, let v = sim.scnView ?? scnViewRef {
                    let root = SCNVector3(systemOffset.x, systemOffset.y, systemOffset.z)
                    let projRoot = v.projectPoint(root)
                    // Invert Y so dragging up moves up onscreen
                    let targetScreen = SCNVector3(
                        projRoot.x + Float(delta.width),
                        projRoot.y + Float(delta.height),
                        projRoot.z
                    )
                    let world0 = v.unprojectPoint(projRoot)
                    let world1 = v.unprojectPoint(targetScreen)
                    let move = SCNVector3(world1.x - world0.x, world1.y - world0.y, world1.z - world0.z)
                    sim.translate(dx: move.x, dy: move.y, dz: move.z)
                    systemOffset += SIMD3<Float>(move.x, move.y, move.z)
                    if let sky = skyNodeRef {
                        sky.position.x += move.x
                        sky.position.y += move.y
                        sky.position.z += move.z
                    }
                } else {
                    // Fallback to camera-plane mapping
                    let factor: Float = 0.02
                    let movementMultiplier: Float = 2.0
                    let dirs = cameraState.panDirectionVectors()
                    let right = dirs.right
                    let up = dirs.up

                    let dx = Float(-delta.width) * factor * movementMultiplier
                    let dy = Float(delta.height) * factor * movementMultiplier // inverted so drag up moves up
                    let worldMove = SCNVector3(
                        right.x * dx + up.x * dy,
                        right.y * dx + up.y * dy,
                        right.z * dx + up.z * dy
                    )

                    simHolder.sim?.translate(dx: worldMove.x, dy: worldMove.y, dz: worldMove.z)
                    systemOffset += SIMD3<Float>(worldMove.x, worldMove.y, worldMove.z)

                    if let sky = skyNodeRef {
                        sky.position.x += worldMove.x
                        sky.position.y += worldMove.y
                        sky.position.z += worldMove.z
                    }
                }
            },
            enableParallaxPan: true,
            driveWithSimulationManager: false,
            pauseHandler: { paused, sim in
                if paused { sim?.stopAsyncSimulation() } else { sim?.startAsyncSimulation() }
            },
            sceneOverlayBuilder: { AnyView(lfoOverlayView) },
            isDisplayLockPressed: isDisplayLockPressed,
            // Settings persistence hooks
            getSettingsData: { (try? JSONEncoder().encode(WavesPreset(settings: currentSettings(), midiSlots: midiSlots))) ?? Data() },
            applySettingsData: { data in
                if let p = try? JSONDecoder().decode(WavesPreset.self, from: data) {
                    applySettings(p.settings)
                    midiSlots = p.midiSlots
                    saveMIDISlots()
                    syncLFOHistoriesToSlots()
                    midiSendCache.lastSentCCValues = [:]
                } else if let s = try? JSONDecoder().decode(WavesSettings.self, from: data) {
                    applySettings(s)
                }
            }
        )
        .sheet(isPresented: $showMidiMenu) {midiMenuSheetView()}
        
        .onAppear {
            loadMIDISlots()
            syncLFOHistoriesToSlots()
          //  simHolder.sim?.startAsyncSimulation()
        }
        .onDisappear {
            simHolder.sim?.stopAsyncSimulation()
           // midiClock.upstream.connect().cancel()
        }
        .onChange(of: midiSlots) { _, _ in
            saveMIDISlots()
            midiSendCache.lastSentCCValues = midiSendCache.lastSentCCValues.filter { $0.key < midiSlots.count }
            syncLFOHistoriesToSlots()
        }
       //.onReceive(tickPublisher) { _ in
        //    if isActive && !isPaused.wrappedValue { midiTickLoop() }
       // }
    }

    // MARK: - Helper Functions
    private func syncLFOHistoriesToSlots() {
        if lfoHistories.count < midiSlots.count {
            for _ in 0..<(midiSlots.count - lfoHistories.count) { lfoHistories.append(RingHistory(capacity: lfoMaxSamples)) }
        } else if lfoHistories.count > midiSlots.count {
            lfoHistories.removeLast(lfoHistories.count - midiSlots.count)
        }
    }
    /// Load MIDI slots from UserDefaults
    private func loadMIDISlots() {
        if let data = UserDefaults.standard.data(forKey: midiSlotsKey),
           let loaded = try? JSONDecoder().decode([MIDIParams].self, from: data) { midiSlots = loaded }
        else { midiSlots = [MIDIParams(tracked: "Leaf.tip.x") ] }
    }
    /// Save MIDI slots to UserDefaults
    private func saveMIDISlots() {
        if let data = try? JSONEncoder().encode(midiSlots) { UserDefaults.standard.set(data, forKey: midiSlotsKey) }
    }
    /// Return all coordinate trackers for debris, buoy, and light (Leaf and Seaweed removed)
    private func makeWaveAndLeavesTrackers(_ sim: WaveAndLeavesSimulationAsync?) -> [String] {
        // Only include non-Leaf and non-Seaweed trackers
        var trackers = [
            "Buoy.base.x", "Buoy.base.y",
            "Buoy.light.x", "Buoy.light.y",
            "Buoy.angle", "Light.rotation",
            "Bottle.x", "Bottle.y"
        ]
        // If sim is present and has debris, add those dynamically
        if let sim = sim {
            for debris in sim.debris {
                let name: String
                switch debris.type {
                case .bottle: name = "Bottle"
                }
                if !trackers.contains("\(name).x") { trackers.append("\(name).x") }
                if !trackers.contains("\(name).y") { trackers.append("\(name).y") }
            }
        }
        return trackers
    }
    /// Return color mapping for trackers (Leaf and Seaweed removed)
    private func makeWaveAndLeavesTrackerColors(_ sim: WaveAndLeavesSimulationAsync?) -> [String: Color] {
        var map: [String: Color] = [
            "Buoy.base.x": .yellow, "Buoy.base.y": .yellow,
            "Buoy.light.x": .orange, "Buoy.light.y": .orange,
            "Buoy.angle": .purple, "Light.rotation": .indigo,
            "Bottle.x": .mint, "Bottle.y": .mint
        ]
        if let sim = sim {
            for debris in sim.debris {
                let name: String
                switch debris.type {
                case .bottle: name = "Bottle"
                }
                let color: Color = debris.type == .bottle ? .mint : .brown
                map["\(name).x"] = color
                map["\(name).y"] = color
            }
        }
        return map
    }
    /// Return color names for trackers (Leaf and Seaweed removed)
    private func makeWaveAndLeavesTrackerColorNames(_ sim: WaveAndLeavesSimulationAsync?) -> [String: String] {
        var map: [String: String] = [
            "Buoy.base.x": "Yellow", "Buoy.base.y": "Yellow",
            "Buoy.light.x": "Orange", "Buoy.light.y": "Orange",
            "Buoy.angle": "Purple", "Light.rotation": "Indigo",
            "Bottle.x": "Mint", "Bottle.y": "Mint"
        ]
        if let sim = sim {
            for debris in sim.debris {
                let name: String
                switch debris.type {
                case .bottle: name = "Bottle"
                }
                let colorName: String = debris.type == .bottle ? "Mint" : "Brown"
                map["\(name).x"] = colorName
                map["\(name).y"] = colorName
            }
        }
        return map
    }
    /// Resolve tracker value from simulation (screen-space or world position, or custom)
    private func resolveWaveAndLeavesTracker(_ tracker: String, in sim: WaveAndLeavesSimulationAsync, range: ClosedRange<Int>) -> Int? {
        // Buoy and light custom trackers
        switch tracker {
        case "Buoy.base.x":
            if let xy = sim.buoyBaseScreenXY127() { return scaleToRange(xy.x, range: range) }
            return nil
        case "Buoy.base.y":
            if let xy = sim.buoyBaseScreenXY127() { return scaleToRange(xy.y, range: range) }
            return nil
        case "Buoy.light.x":
            if let xy = sim.buoyLightScreenXY127() { return scaleToRange(xy.x, range: range) }
            return nil
        case "Buoy.light.y":
            if let xy = sim.buoyLightScreenXY127() { return scaleToRange(xy.y, range: range) }
            return nil
        case "Buoy.angle":
            if let angle = sim.buoyAngle() {
                let norm = max(0, min(127, Int(round(angle / 90.0 * 127))))
                return scaleToRange(norm, range: range)
            }
            return nil
        case "Light.rotation":
            if let rot = sim.lightRotation() {
                let norm = max(0, min(127, Int(round((rot.truncatingRemainder(dividingBy: 360)) / 360.0 * 127))))
                return scaleToRange(norm, range: range)
            }
            return nil
        default:
            break
        }
        let parts = tracker.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let joint = parts[0]
        let comp = parts[1]
        // Try screen-space projection for x/y first
        if comp == "x" || comp == "y" {
            if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
            if let proj = sim.projectedJointXY127(jointName: joint) {
                let rawVal = comp == "x" ? proj.x : proj.y
                return scaleToRange(rawVal, range: range)
            }
        }
        // Fallback to world position normalization
        guard let wp = sim.jointWorldPosition(joint) else { return nil }
        let vb = sim.visualBounds
        let raw: Float
        switch comp {
        case "x": raw = wp.x
        case "y": raw = wp.y
        case "z": raw = wp.z
        default: return nil
        }
        let cc = normalizeToCC(raw: raw, minVal: -vb, maxVal: vb)
        return scaleToRange(cc, range: range)
    }
    // MARK: - MIDI / LFO helper mapping functions
    /// Normalize raw value to MIDI CC (0-127)
    private func normalizeToCC(raw: Float, minVal: Float, maxVal: Float) -> Int {
        guard maxVal > minVal else { return 0 }
        let clamped = max(min(raw, maxVal), minVal)
        let t = (clamped - minVal) / (maxVal - minVal)
        return max(0, min(127, Int(round(t * 127))))
    }
    /// Scale MIDI CC to custom range
    private func scaleToRange(_ cc: Int, range: ClosedRange<Int>) -> Int {
        let t = Float(cc) / 127.0
        let minR = Float(range.lowerBound), maxR = Float(range.upperBound)
        let v = Int(round(minR + t * (maxR - minR)))
        return max(range.lowerBound, min(range.upperBound, v))
    }
    
    
 

    private func logRootOutOfScreenIfNeeded(sim: WaveAndLeavesSimulationAsync) {
        // Ensure we have a view to project with
        if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
        guard let scnView = sim.scnView else { return }
        guard let camera = scnView.pointOfView else { return }

        // Use buoy base as the "root" reference point for the simulation
        guard let xy = sim.buoyBaseScreenXY127() else {
            if !rootWasOffscreen {
                rootWasOffscreen = true
                print("[WaveAndLeaves] Buoy projection failed (treat as off-screen)")
            }
            return
        }

        let margin: Int = 1
        let minBound = margin
        let maxBound = 127 - margin
        
        let isOffscreen = xy.x <= minBound || xy.x >= maxBound || xy.y <= minBound || xy.y >= maxBound

        if isOffscreen && !rootWasOffscreen {
            rootWasOffscreen = true
            print("[WaveAndLeaves] Buoy went off-screen: (\(xy.x), \(xy.y))")
        } else if !isOffscreen && rootWasOffscreen {
            rootWasOffscreen = false
            print("[doubleWaveAndLeaves] Buoy back on-screen: (\(xy.x), \(xy.y))")
        }
        
        // Apply correction to keep buoy on screen using camera-relative directions
        if isOffscreen {
            
            // Get camera right and up vectors in world space
            let camTransform = camera.worldTransform
            let camRight = SCNVector3(camTransform.m11, camTransform.m12, camTransform.m13)
            let camUp = SCNVector3(camTransform.m21, camTransform.m22, camTransform.m23)
            
            // Calculate screen-space correction (in 0-127 units)
            var screenDx: Float = 0
            var screenDy: Float = 0
            
            if xy.x <= minBound {
                screenDx = Float(minBound - xy.x) // Positive = move right on screen
            } else if xy.x >= maxBound {
                screenDx = Float(maxBound - xy.x) // Negative = move left on screen
            }
            
            if xy.y <= minBound {
                screenDy = Float(minBound - xy.y) // Positive = move up on screen
            } else if xy.y >= maxBound {
                screenDy = Float(maxBound - xy.y) // Negative = move down on screen
            }
            
            // Scale screen units to world units (tune this factor as needed)
            let screenToWorld: Float = 0.5
            screenDx *= screenToWorld
            screenDy *= screenToWorld
            
            // Convert screen-space correction to world-space translation
            //let worldDx = camRight.x * screenDx + camUp.x * screenDy
            let worldDy = camRight.y * screenDx + camUp.y * screenDy
            let worldDz = camRight.z * screenDx + camUp.z * screenDy
           
            sim.translate(dx: 0, dy: worldDy, dz: worldDz)
            if let sky = skyNodeRef {
                      sky.position.x += 0
                      sky.position.y -= worldDy
                      sky.position.z -= worldDz
                  }
            systemOffset += SIMD3<Float>(0, worldDy, worldDz)
        }
    }
    // MARK: - MIDI Tick Loop
    @MainActor
    private func midiTickLoop() {
        autoreleasepool {
            guard let sim = simHolder.sim else { return }
            
            logRootOutOfScreenIfNeeded(sim: sim)

            if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
            if lfoHistories.count != midiSlots.count { syncLFOHistoriesToSlots() }
            let recordHistory = displayLFOOutputs
            for (index, slot) in midiSlots.enumerated() {
                // Only send for the soloed slot when solo is active
                if let s = midiSoloIndex, s != index { continue }
                guard index < lfoHistories.count else { continue }
                guard let ccVal = resolveWaveAndLeavesTracker(slot.tracked, in: sim, range: slot.range) else { continue }
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

    // MARK: - MIDI Menu Sheet
    private func midiMenuSheetView() -> some View {
        let trackers = makeWaveAndLeavesTrackers(simHolder.sim)
        let trackerColors = Dictionary(uniqueKeysWithValues: trackers.map { ($0, colorForTrackerHash($0)) })
        return MIDIMenuView(
            slots: $midiSlots,
            trackers: trackers,
            trackerColors: trackerColors,
            focusIndex: $midiFocusIndex,
            soloIndex: $midiSoloIndex,
            onSend: { _ in }
        )
        .environmentObject(LifeformModeStore())
    }
    
    // MARK: - Settings Persistence Helpers
    private func currentSettings() -> WavesSettings {
        WavesSettings(
            simulationSpeed: simulationSpeed,
            waveAmplitude: waveAmplitude,
            waveFrequency: waveFrequency,
            leafBuoyancy: leafBuoyancy,
            waveResolution: Int(waveResolution),
            secondWaveAmplitude: secondWaveAmplitude,
            secondWaveFrequency: secondWaveFrequency,
            secondWaveDirection: secondWaveDirection,
            secondWavePhase: secondWavePhase,
            secondWaveSpeed: secondWaveSpeed,
            globalScale: globalScale,
            displayLFOOutputs: displayLFOOutputs,
            systemPosX: systemOffset.x,
            systemPosY: systemOffset.y,
            systemPosZ: systemOffset.z,
            elevation: Float(cameraState.elevation)
        )
    }

    private func applySettings(_ settings: WavesSettings) {
        simulationSpeed = settings.simulationSpeed
        waveAmplitude = settings.waveAmplitude
        waveFrequency = settings.waveFrequency
        leafBuoyancy = settings.leafBuoyancy
        waveResolution = Double(settings.waveResolution)
        secondWaveAmplitude = settings.secondWaveAmplitude
        secondWaveFrequency = settings.secondWaveFrequency
        secondWaveDirection = settings.secondWaveDirection
        secondWavePhase = settings.secondWavePhase
        secondWaveSpeed = settings.secondWaveSpeed
        globalScale = settings.globalScale
        displayLFOOutputs = settings.displayLFOOutputs
        if let elev = settings.elevation { cameraState.elevation = Float(Double(elev)) }

        // Immediately apply to the running sim
        if let sim = simHolder.sim {
            sim.setSimulationSpeed(simulationSpeed)
            sim.setWaveAmplitude(waveAmplitude)
            sim.setWaveFrequency(waveFrequency)
            sim.setLeafBuoyancy(leafBuoyancy)
            sim.setWaveResolution(Int(waveResolution))
            sim.setSecondWaveAmplitude(secondWaveAmplitude)
            sim.setSecondWaveFrequency(secondWaveFrequency)
            sim.setSecondWaveDirectionDegrees(secondWaveDirection)
            sim.setSecondWavePhaseOffset(secondWavePhase)
            sim.setSecondWaveSpeedFactor(secondWaveSpeed)
            sim.setGlobalScale(globalScale)

            // Restore position if present
            let target = SIMD3<Float>(settings.systemPosX ?? 0, settings.systemPosY ?? 0, settings.systemPosZ ?? 0)
            let delta = target - systemOffset
            sim.translate(dx: delta.x, dy: delta.y, dz: delta.z)
            systemOffset = target
        } else {
            systemOffset = SIMD3<Float>(settings.systemPosX ?? 0, settings.systemPosY ?? 0, settings.systemPosZ ?? 0)
        }
        if let sky = skyNodeRef {
            let skyScale = globalScale * 10.0
            sky.scale = SCNVector3(skyScale, skyScale, skyScale)
        }
    }
}
