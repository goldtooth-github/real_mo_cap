import SwiftUI
import SceneKit
import UIKit
import Combine
import QuartzCore
// MARK: - SimHolder for persistent simulation
final class FlowerSimHolder: ObservableObject {
    @Published var sim: FlowerClusterSimulationAsync? = nil
}

// Persistable settings for Flower
private struct FlowerSettings: Codable {
    var sunSpeed: Float
    var openness: Float
    var flowerScale: Float
    var cameraElevation: Float
    var displayLFOOutputs: Bool
}
// New: Preset bundles settings + MIDI slots in Save/Load
private struct FlowerPreset: Codable {
    var settings: FlowerSettings
    var midiSlots: [MIDIParams]
}

struct FlowerLifeformView: View {
    // MARK: - View State & Parameters
    var isActive: Bool = false
    var isPaused: Binding<Bool> // now mandatory
    var isDisplayLockPressed: Binding<Bool>
    let petalCount = 6
    private let petalColors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple]
    @State private var sunSpeed: Float = 0.15
    @State private var openness: Float = 0.0
    @State private var flowerScale: Float = 1.0
    private let flowerScaleRange: ClosedRange<Float> = 0.75...2.5
    @StateObject private var cameraState = CameraOrbitState()
    @StateObject private var simHolder = FlowerSimHolder()
    // Remove SimulationManager; async sim owns updates
    // MIDI/LFO
    @State private var showMidiMenu: Bool = false
    @State private var midiSlots: [MIDIParams] = []
    private let midiSlotsKey = "MIDI_SLOTS_FLOWER"
    private final class MIDISendCache { var lastSentCCValues: [Int: Int] = [:] }
    @State private var midiSendCache = MIDISendCache()
    //@State private var tickPublisher = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    @State private var displayLFOOutputs: Bool = false
   // typealias RingHistory = [CGFloat]
    @State private var lfoHistories: [RingHistory] = []   // Holds reference types
    private let lfoMaxSamples: Int = 50
    @State private var midiFocusIndex: Int? = nil
    @State private var scnViewRef: SCNView? = nil
    // NEW: Solo state shared with MIDI menu
    @State private var midiSoloIndex: Int? = nil
    @State private var systemOffset: SIMD3<Float> = .zero
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
   
    // MARK: - View Config
    private let config = LifeformViewConfig(
        initialAzimuth: 0,
        initialElevation: 25,
        initialRadius: 18,
        minRadius: 3,
        maxRadius: 30,
        cameraControlMode: .nicks_control,
        ambientLightIntensity: 0.1,
        updateInterval: 0.016,
        title: "Heliotropic Flowers",
    
        controlPanelColor: Color.black.opacity(0.6),
        controlTextColor: .white,
        buttonBackgroundColor: Color.blue.opacity(0.6),
        controlPanelBottomInset: 5
    )

    // Snapshot/apply helpers
    private func currentSettings() -> FlowerSettings {
        FlowerSettings(
            sunSpeed: sunSpeed,
            openness: openness,
            flowerScale: flowerScale,
            cameraElevation: cameraState.elevation,
            displayLFOOutputs: displayLFOOutputs
        )
    }
    private func applySettings(_ s: FlowerSettings) {
        sunSpeed = s.sunSpeed; simHolder.sim?.setSunOrbitSpeed(s.sunSpeed)
        openness = s.openness; simHolder.sim?.setOpenness(s.openness)
        flowerScale = min(max(s.flowerScale, flowerScaleRange.lowerBound), flowerScaleRange.upperBound); simHolder.sim?.setGlobalScale(flowerScale)
        cameraState.elevation = s.cameraElevation
        displayLFOOutputs = s.displayLFOOutputs
    }

    // MARK: - Simulation Creation
    private func createFlowerSimulation(scene: SCNScene) -> FlowerClusterSimulationAsync {
        let sim = FlowerClusterSimulationAsync(scene: scene, scnView: nil, count: 5)
        sim.setSunOrbitSpeed(sunSpeed)
        sim.setOpenness(openness)
        sim.setGlobalScale(flowerScale)
        simHolder.sim = sim
        return sim
    }

    // MARK: - Controls UI
    private func buildControls(simBinding: Binding<FlowerClusterSimulationAsync?>, isPaused: Binding<Bool>) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text("Sun Speed").foregroundColor(config.controlTextColor)
                Slider(value: $sunSpeed, in: 0.05...0.5)
                    .onChange(of: sunSpeed) { _, v in simHolder.sim?.setSunOrbitSpeed(v) }
                Text(String(format: "%.2f", sunSpeed)).foregroundColor(config.controlTextColor).frame(width: 44)
            }
            HStack {
                Text("Elevation").foregroundColor(config.controlTextColor)
                Slider(value: $cameraState.elevation, in: 0.0...1.6)
                Text(String(format: "%.2f°", cameraState.elevation)).foregroundColor(config.controlTextColor).frame(width: 44)
            }
            Toggle("Display LFO outputs", isOn: $displayLFOOutputs)
                .toggleStyle(.switch)
                .foregroundColor(config.controlTextColor)
            HStack {
                Button(action: { showMidiMenu.toggle() }) {
                    HStack { Image(systemName: "gearshape"); Text("MIDI Settings + Tracking") }
                
                        .foregroundColor(Color.blue)
                }
            }
        }.padding(.bottom, 100)
    }

    // MARK: - Main View Body
    var body: some View {
        ModifiedSimulationView<FlowerClusterSimulationAsync>(
            config: config,
            customCameraState: cameraState,
            createSimulation: { scene in
                if let sim = simHolder.sim { return sim }
                return createFlowerSimulation(scene: scene)
            },
            controlsBuilder: { binding, pausedBinding in AnyView(buildControls(simBinding: binding, isPaused: pausedBinding)) },
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
                    
                    
                    // No manual start; ModifiedSimulationView will start when active & not paused
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
            systemScaleGetter: { flowerScale },
            systemScaleSetter: { newVal in
                let clamped = min(max(newVal, flowerScaleRange.lowerBound), flowerScaleRange.upperBound)
                flowerScale = clamped
                simHolder.sim?.setGlobalScale(clamped)
            },
            systemScaleRange: flowerScaleRange,
            simulationDragHandler: { delta in
                if let sim = simHolder.sim, let v = sim.scnView ?? scnViewRef {
                    let root = SCNVector3(systemOffset.x, systemOffset.y, systemOffset.z)
                    let projRoot = v.projectPoint(root)
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
                } else {
                    let factor: Float = 0.02
                    let movementMultiplier: Float = 2.0
                    let dirs = cameraState.panDirectionVectors()
                    let right = dirs.right
                    let up = dirs.up
                    let dx = Float(-delta.width) * factor * movementMultiplier
                    let dy = Float(delta.height) * factor * movementMultiplier
                    let worldMove = SCNVector3(
                        right.x * dx + up.x * dy,
                        right.y * dx + up.y * dy,
                        right.z * dx + up.z * dy
                    )
                    simHolder.sim?.translate(dx: worldMove.x, dy: worldMove.y, dz: worldMove.z)
                    systemOffset += SIMD3<Float>(worldMove.x, worldMove.y, worldMove.z)
                }
             },

            pauseHandler: { paused, sim in sim?.setPaused(paused) },
            sceneOverlayBuilder: {
                AnyView(
                    Group {
                        if displayLFOOutputs, !midiSlots.isEmpty {
                            // FIX: Use stable tracker color map instead of hash color
                            let labels = midiSlots.map { $0.tracked } // Changed: use full tracker name for label
                            let trackerColors = makeFlowerTrackerColors(simHolder.sim)
                            let colors = midiSlots.map { trackerColors[$0.tracked] ?? .gray }
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
                                compactThresholdFraction: 0.25
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
            getSettingsData: { (try? JSONEncoder().encode(FlowerPreset(settings: currentSettings(), midiSlots: midiSlots))) ?? Data() },
            applySettingsData: { data in
                if let p = try? JSONDecoder().decode(FlowerPreset.self, from: data) {
                    applySettings(p.settings)
                    midiSlots = p.midiSlots
                    saveMIDISlots(); syncLFOHistoriesToSlots(); midiSendCache.lastSentCCValues = [:]
                } else if let s = try? JSONDecoder().decode(FlowerSettings.self, from: data) {
                    applySettings(s)
                }
            }
        )
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showMidiMenu) {midiMenuSheetView()}
        .onAppear {
            loadMIDISlots(); syncLFOHistoriesToSlots()
        }
        .onChange(of: midiSlots) { _, _ in
            saveMIDISlots(); syncLFOHistoriesToSlots(); midiSendCache.lastSentCCValues = [:]
        }
        .onChange(of: isPaused.wrappedValue) { _, newVal in simHolder.sim?.setPaused(newVal) }
        .onDisappear {
            simHolder.sim?.stopAsyncSimulation(); simHolder.sim?.teardown(); simHolder.sim = nil
        }
      //  .onReceive(tickPublisher) { _ in
      //      if isActive && !isPaused.wrappedValue { midiTickLoop() }
      //  }
    }

    // MARK: - MIDI/LFO Helpers
    private func loadMIDISlots() {
        if let data = UserDefaults.standard.data(forKey: midiSlotsKey), let loaded = try? JSONDecoder().decode([MIDIParams].self, from: data) {
            midiSlots = loaded
        } else {
            midiSlots = [MIDIParams(tracked: "Petal-1")]
        }
    }
    private func saveMIDISlots() {
        if let data = try? JSONEncoder().encode(midiSlots) {
            UserDefaults.standard.set(data, forKey: midiSlotsKey)
        }
    }
    private func syncLFOHistoriesToSlots() {
        if lfoHistories.count < midiSlots.count {
            for _ in lfoHistories.count..<midiSlots.count {
                lfoHistories.append(RingHistory(capacity: lfoMaxSamples))
            }
        } else if lfoHistories.count > midiSlots.count {
            lfoHistories = Array(lfoHistories.prefix(midiSlots.count))
        }
    }

    // MARK: - Tracker Helpers (mirroring WaveAndLeaves)
    private func makeFlowerTrackers(_ sim: FlowerClusterSimulationAsync?) -> [String] {
        // Always include all possible trackers, regardless of sim state
        var trackers = [
            "Moon.x", "Moon.y",
            "Sun.x", "Sun.y"
        ]
        // Add per-flower head x/y trackers
        let count = sim?.flowerCount() ?? 5
        if count > 0 {
            for i in 0..<count {
                let base = "Flower-\(i+1)"
                trackers.append(contentsOf: ["\(base).x", "\(base).y"])
            }
        }
        // Petal openness trackers (normalized state)
        let petalCount = self.petalCount
        for i in 0..<petalCount {
            trackers.append("Petal-\(i+1)")
        }
        return trackers
    }

    private func makeFlowerTrackerColors(_ sim: FlowerClusterSimulationAsync?) -> [String: Color] {
        var map: [String: Color] = [
            "Moon.x": .pink, "Moon.y": .pink,
            "Sun.x": .yellow, "Sun.y": .yellow
        ]
        // Stable palette for flower heads
        let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .mint, .indigo, .teal]
        let count = sim?.flowerCount() ?? 5
        for i in 0..<max(0, count) {
            let c = palette[i % palette.count]
            let base = "Flower-\(i+1)"
            map["\(base).x"] = c
            map["\(base).y"] = c
        }
        // Petal trackers colors
        let petalCount = self.petalCount
        for i in 0..<petalCount {
            let color = palette[(i + 3) % palette.count]
            map["Petal-\(i+1)"] = color
        }
        return map
    }

    private func coordForTracker(_ tracker: String) -> String {
        // Now returns full tracker name for descriptive labeling
        return tracker
    }

    private func colorForTrackerHash(_ tracker: String) -> Color {
        let hash = abs(tracker.hashValue)
        let hue = Double((hash % 360)) / 360.0
        return Color(hue: hue, saturation: 0.7, brightness: 0.9)
    }

    private func resolveTracker(_ tracker: String, in sim: FlowerClusterSimulationAsync, range: ClosedRange<Int>) -> Int? {
        if tracker == "Moon.x" {
            if let xy = sim.projectedMoonXY127() { return scaleToRange(xy.x, range: range) }
            return nil
        }
        if tracker == "Moon.y" {
            if let xy = sim.projectedMoonXY127() { return scaleToRange(xy.y, range: range) }
            return nil
        }
        if tracker == "Sun.x" {
            if let xy = sim.projectedSunXY127() { return scaleToRange(xy.x, range: range) }
            return nil
        }
        if tracker == "Sun.y" {
            if let xy = sim.projectedSunXY127() { return scaleToRange(xy.y, range: range) }
            return nil
        }
        // Per-flower head trackers: "Flower-N.x" / "Flower-N.y"
        if tracker.hasPrefix("Flower-") {
            // Expect format Flower-<n>.<axis>
            let parts = tracker.split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].hasPrefix("Flower-") {
                let indexStr = parts[0].dropFirst("Flower-".count)
                if let n = Int(indexStr), n >= 1 {
                    let axis = parts[1]
                    if let xy = sim.projectedFlowerHeadXY127(flowerIndex: n - 1) {
                        return axis == "x" ? scaleToRange(xy.x, range: range) : (axis == "y" ? scaleToRange(xy.y, range: range) : nil)
                    }
                    return nil
                }
            }
        }
        if tracker.hasPrefix("Petal-") {
            if let idx = Int(tracker.dropFirst(6)), let state = sim.petalState(index: idx-1) {
                let cc = Int(round(state * 127))
                return scaleToRange(cc, range: range)
            }
        }
        return nil
    }
    private func scaleToRange(_ cc: Int, range: ClosedRange<Int>) -> Int {
        let t = Float(cc) / 127.0
        let minR = Float(range.lowerBound)
        let maxR = Float(range.upperBound)
        let v = Int(round(minR + t * (maxR - minR)))
        return max(range.lowerBound, min(range.upperBound, v))
    }
 
    
    // MARK: - MIDI Tick Loop
    @MainActor
    private func midiTickLoop() {
        autoreleasepool {
            guard let sim = simHolder.sim else { return }
            if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
            // Keep flowers on-screen (single gentle nudge per frame)
            logRootOutOfScreenIfNeeded(sim: sim)
            if lfoHistories.count != midiSlots.count { syncLFOHistoriesToSlots() }
            // 30 Hz history sampling
                    let now = CACurrentMediaTime()
                    let allowHistory = (now - lastLFORecordTime) >= lfoRecordInterval
                    if allowHistory { lastLFORecordTime = now }
        
                    let recordHistory = displayLFOOutputs && allowHistory
            for (index, slot) in midiSlots.enumerated() {
                // Only emit for the soloed slot when solo is active
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

    // MARK: - Screen clamping to keep flowers visible
    private func logRootOutOfScreenIfNeeded(sim: FlowerClusterSimulationAsync) {
        if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
        guard let scnView = sim.scnView, let camera = scnView.pointOfView else { return }
        let count = sim.flowerCount()
        var applied = false
        for i in 0..<count where !applied {
            guard let world = sim.flowerWorldPosition(index: i) else { continue }
            let projected = scnView.projectPoint(world)
            let w = max(scnView.bounds.width, 1)
            let h = max(scnView.bounds.height, 1)
            let screenX = CGFloat(projected.x)
            let screenY = CGFloat(projected.y)
            let margin: CGFloat = 12
            let minX = margin, maxX = w - margin, minY = margin, maxY = h - margin
            let isOff = (screenX < minX || screenX > maxX || screenY < minY || screenY > maxY)
            guard isOff else { continue }
            let clampedX = min(max(screenX, minX), maxX)
            let clampedY = min(max(screenY, minY), maxY)
            let target = SCNVector3(Float(clampedX), Float(clampedY), projected.z)
            let correctedWorld = scnView.unprojectPoint(target)
            var delta = correctedWorld - world
            if !delta.x.isFinite || !delta.y.isFinite || !delta.z.isFinite { continue }
            let camFwd = SCNVector3(camera.worldTransform.m31, camera.worldTransform.m32, camera.worldTransform.m33).normalized()
            let fProj = SCNVector3.dot(delta, camFwd)
            var deltaInPlane = delta - camFwd * fProj
            deltaInPlane.x = 0
            let maxStep: Float = 0.8
            let len = deltaInPlane.length()
            if len > maxStep { deltaInPlane = deltaInPlane.normalized() * maxStep }
            let k: Float = 0.25
            sim.adjustClusterPosition(dx: 0, dy: deltaInPlane.y * k, dz: deltaInPlane.z * k)
            applied = true
        }
    }

    // MARK: - MIDI Menu Sheet
    private func midiMenuSheetView() -> some View {
        let trackers = makeFlowerTrackers(simHolder.sim)
        let trackerColors = makeFlowerTrackerColors(simHolder.sim)
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
    
}
