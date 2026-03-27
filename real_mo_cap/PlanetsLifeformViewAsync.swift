import SwiftUI
import SceneKit
import UIKit
import Combine
import QuartzCore// MARK: - MIDI CC Deduplication Cache
private final class MIDISendCacheAsync { var lastSentCCValues: [Int: Int] = [:] }

// Persistable settings for Planets
private struct PlanetsSettings: Codable {
    var systemScale: Float
    var simulationSpeed: Float
    var systemTiltDegreesX: Double
    var displayLFOOutputs: Bool
}
// New: bundle settings + MIDI slots for Save/Load
private struct PlanetsPreset: Codable {
    var settings: PlanetsSettings
    var midiSlots: [MIDIParams]
}

// MARK: - SimHolder for persistent simulation
final class PlanetSimHolder: ObservableObject {
    @Published var sim: PlanetsSimulationAsync? = nil
}

// MARK: - PlanetsLifeformViewAsync
struct PlanetsLifeformViewAsync: View {
    // MARK: - View State & Parameters
    var isActive: Bool = false
    var isPaused: Binding<Bool> // now mandatory
    var isDisplayLockPressed: Binding<Bool>
   // @StateObject private var customCameraState = PannedCameraState(panX: 0, panY: 0)
    @StateObject private var cameraState = CameraOrbitState()
    @State private var simRef: PlanetsSimulationAsync? = nil
    @State private var scnViewRef: SCNView? = nil
    @StateObject private var simHolder = PlanetSimHolder()
    @State private var systemScale: Float = 2.0 // Set to max for full scale
    @State private var simulationSpeed: Float = 3.5 // bumped for visible motion
    @State private var systemTiltDegreesX: Double = 90.0 // Set to 90 degrees for full tilt
    @State private var showMidiMenu: Bool = false
    @State private var midiSlots: [MIDIParams] = []
    private let midiSlotsKey = "MIDI_SLOTS_PLANETS_ASYNC"
    @State private var midiFocusIndex: Int? = nil
    @State private var displayLFOOutputs: Bool = false
    @State private var lfoHistories: [RingHistory] = []
    private let lfoMaxSamples: Int = 50
    @State private var midiSendCache = MIDISendCacheAsync()
    //@State private var tickPublisher = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    // Prewarm guards
    @State private var didPrewarmMIDI = false
    @State private var didPrewarmProjection = false
    // NEW: Solo state shared with MIDI menu
    @State private var midiSoloIndex: Int? = nil

    // Throttle LFO history to ~20 Hz
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
        initialAzimuth: 90, // align camera along +Z looking toward origin
        initialElevation: 0,
        initialRadius: 10,
        minRadius: 8,
        maxRadius: 25,
        cameraControlMode: .nicks_control, // enable drag + pinch like Jellyfish
        ambientLightIntensity: 0.3,
        directionalLightIntensity: 0.5,
        directionalLightAngles: SCNVector3(x: -Float.pi/4, y: Float.pi/4, z: 0),
        disableSceneLights: true,
        updateInterval: 0.016,
        title: "Planets",
        controlPanelColor: Color.black.opacity(0.7),
        controlTextColor: .white,
        buttonBackgroundColor: Color.indigo.opacity(0.6),
        controlPanelBottomInset: 5
    )
    
    // Snapshot/apply helpers
    private func currentSettings() -> PlanetsSettings {
        PlanetsSettings(
            systemScale: systemScale,
            simulationSpeed: simulationSpeed,
            systemTiltDegreesX: systemTiltDegreesX,
            displayLFOOutputs: displayLFOOutputs
        )
    }
    private func applySettings(_ s: PlanetsSettings) {
        systemScale = s.systemScale; simHolder.sim?.setSystemScale(s.systemScale)
        simulationSpeed = s.simulationSpeed; simHolder.sim?.setSimulationSpeed(s.simulationSpeed)
        systemTiltDegreesX = s.systemTiltDegreesX; simHolder.sim?.setSystemTiltX(angle: Float(systemTiltDegreesX * .pi / 180.0))
        displayLFOOutputs = s.displayLFOOutputs
    }

    // MARK: - Simulation Creation
    private func createSimulation(scene: SCNScene) -> PlanetsSimulationAsync {
        let sim = PlanetsSimulationAsync(scene: scene, scnView: nil)
        sim.setSystemScale(systemScale)
        sim.setSimulationSpeed(simulationSpeed)
        // Apply initial tilt so Y changes are visible by default (side-on->over angle)
        let tiltRadians = Float(systemTiltDegreesX * .pi / 180.0)
        sim.setSystemTiltX(angle: tiltRadians)
        simRef = sim
        simHolder.sim = sim
        return sim
    }
    
    // MARK: - Controls UI
    private func buildControls(simBinding: Binding<PlanetsSimulationAsync?>, isPaused: Binding<Bool>) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("Tilt:").foregroundColor(config.controlTextColor)
                Slider(value: Binding(
                    get: { systemTiltDegreesX },
                    set: { newVal in
                        systemTiltDegreesX = newVal
                        let radians = Float(newVal * .pi / 180.0)
                        simBinding.wrappedValue?.setSystemTiltX(angle: radians)
                    }
                ), in: 0...90)
                Text(String(format: "%3.0f°", systemTiltDegreesX))
                    .foregroundColor(config.controlTextColor)
                    .frame(width: 50)
            }
            HStack {
                Text("Speed:").foregroundColor(config.controlTextColor)
                Slider(value: Binding(
                    get: { Double(simulationSpeed) },
                    set: { newVal in
                        simulationSpeed = Float(newVal)
                        simBinding.wrappedValue?.setSimulationSpeed(simulationSpeed)
                    }
                ), in: 0.1...10.0)
                Text(String(format: "%.2f", simulationSpeed))
                    .foregroundColor(config.controlTextColor)
                    .frame(width: 44)
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
        }
        .padding(.bottom, 100)
    }
    
    // MARK: - Main View Body
    var body: some View {
        ModifiedSimulationView<PlanetsSimulationAsync>(
            config: config,
            customCameraState: cameraState,
            createSimulation: { scene in
                if let s = simHolder.sim { return s }
                let sim = createSimulation(scene: scene)
                simHolder.sim = sim
                return sim
            },
            
            controlsBuilder: { binding, pausedBinding in AnyView(buildControls(simBinding: binding, isPaused: pausedBinding)) },
            onViewReady: { _, scnView in
                if let sim = simHolder.sim {
                    sim.scnView = scnView
                    scnViewRef = scnView
                    scnView.backgroundColor = .black
                    scnView.isOpaque = true
                    // Performance optimizations
                    scnView.preferredFramesPerSecond = 60
                    scnView.antialiasingMode = .multisampling2X // Reduce from default 4X if applicable
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
                    
                    // Prewarm projection math once view + sim are wired up to avoid first-touch hitch.
                    if !didPrewarmProjection {
                        didPrewarmProjection = true
                        DispatchQueue.main.async {
                            let firstTracker = makeTrackers(sim).first
                            if let t = firstTracker, let dot = t.firstIndex(of: ".") {
                                let name = String(t[..<dot])
                                _ = sim.projectedPlanetXY127(name: name)
                            } else {
                                _ = sim.projectedPlanetXY127(name: "Sun")
                            }
                        }
                    }
                }
            },
            isActive: isActive,
            systemScaleGetter: { systemScale },
            systemScaleSetter: { newVal in
                let clamped = min(max(newVal, 0.5), 2.0)
                systemScale = clamped
                simHolder.sim?.setSystemScale(clamped)
              //  print("[Planets] Pinch -> systemScale=\(clamped)")
            },
            systemScaleRange: 0.5...2.0,
            simulationDragHandler: { delta in
                let factor: Float = 0.02
                let movementMultiplier: Float = 2.0
                let horiz = Float(delta.width) * factor * movementMultiplier
                let vert = Float(-delta.height) * factor * movementMultiplier
             //   print("[Planets] Drag -> dx=\(horiz), dy=\(vert)")
                simHolder.sim?.translateSystemXY(dx: horiz, dy: vert)
            },
            enableParallaxPan: false,
            driveWithSimulationManager: false,
            pauseHandler: { paused, sim in
                sim?.setPaused(paused)
            },
            sceneOverlayBuilder: {
                AnyView(
                    ZStack {
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
                                onDoubleTap: { i in midiFocusIndex = i; showMidiMenu = true }
                            )
                            .padding(.horizontal, 8)
                            .drawingGroup() // Hint to Metal: no alpha blending
                        }
                        //FrameRateOverlay()
                    }
                )
            },
            panelAutoHideEnabled: true,
            externalPaused: isPaused,
            isDisplayLockPressed: isDisplayLockPressed,
            // Settings persistence hooks
            getSettingsData: { (try? JSONEncoder().encode(PlanetsPreset(settings: currentSettings(), midiSlots: midiSlots))) ?? Data() },
            applySettingsData: { data in if let p = try? JSONDecoder().decode(PlanetsPreset.self, from: data) {
                applySettings(p.settings)
                midiSlots = p.midiSlots
                saveMIDISlots(); syncLFOHistoriesToSlots(); midiSendCache.lastSentCCValues = [:]
            } else if let s = try? JSONDecoder().decode(PlanetsSettings.self, from: data) {
                applySettings(s)
            } }
        )
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showMidiMenu) { midiMenuSheetView() }
        .onAppear {
            loadMIDISlots(); syncLFOHistoriesToSlots()
            // Centralized prewarm so CoreMIDI/haptics init doesn't coincide with first control use.
            if !didPrewarmMIDI {
                didPrewarmMIDI = true
                PrewarmCenter.shared.run()
            }
        }
        .onChange(of: midiSlots) { _, _ in
            saveMIDISlots()
            syncLFOHistoriesToSlots()
            midiSendCache.lastSentCCValues = [:]
        }
        .onChange(of: isPaused.wrappedValue) { _, newVal in
            simHolder.sim?.setPaused(newVal)
        }
        .onChange(of: isActive) { _, _ in }
        .onDisappear { simHolder.sim?.teardownAndDispose(); simHolder.sim = nil }
       // .onReceive(tickPublisher) { _ in
        //    if isActive && !isPaused.wrappedValue {
                // Only run MIDI tick; simulation is updated by the renderer
        //        midiTickLoop()
        //    }
       // }
    }
    
    // MARK: - MIDI helpers
    
    func loadMIDISlots() {
        if let data = UserDefaults.standard.data(forKey: midiSlotsKey),
           let loaded = try? JSONDecoder().decode([MIDIParams].self, from: data) {
            midiSlots = loaded
        } else {
            // Ensure overlay can appear on first toggle by seeding a default tracker
            let first = makePlanetsTrackers(simHolder.sim).first ?? "Sun.x"
            midiSlots = [MIDIParams(tracked: first)]
        }
    }
    func saveMIDISlots() {
        if let data = try? JSONEncoder().encode(midiSlots) { UserDefaults.standard.set(data, forKey: midiSlotsKey) }
    }
    func syncLFOHistoriesToSlots() {
        if lfoHistories.count < midiSlots.count {
            for _ in 0..<(midiSlots.count - lfoHistories.count) { lfoHistories.append(RingHistory(capacity: lfoMaxSamples)) }
        } else if lfoHistories.count > midiSlots.count {
            lfoHistories.removeLast(lfoHistories.count - midiSlots.count)
        }
    }
    func defaultPlanetNames() -> [String] { ["Sun","Earth","Mars","Mercury","Comet"] }
    func makePlanetsTrackers(_ sim: PlanetsSimulationAsync?) -> [String] {
        if let sim = sim {
            let names = sim.planetNames()
            if !names.isEmpty { return names.flatMap { ["\($0).x", "\($0).y"] } }
        }
        return defaultPlanetNames().flatMap { ["\($0).x", "\($0).y"] }
    }
    func makePlanetsTrackerColors(_ sim: PlanetsSimulationAsync?) -> [String: Color] {
        var map: [String: Color] = [:]
        if let sim = sim {
            let names = sim.planetNames()
            if !names.isEmpty {
                for name in names {
                    let c = Color(sim.planetColor(name: name) ?? .white)
                    map["\(name).x"] = c; map["\(name).y"] = c
                }
                return map
            }
        }
        // Fallback palette
        let fallback: [(String, Color)] = [("Sun", .yellow),("Earth", .blue),("Mars", .red),("Mercury", .gray),("Comet", .cyan)]
        for (n,c) in fallback { map["\(n).x"] = c; map["\(n).y"] = c }
        return map
    }
    func makePlanetsTrackerColorNames(_ sim: PlanetsSimulationAsync?) -> [String: String] {
        var map: [String: String] = [:]
        if let sim = sim {
            let names = sim.planetNames()
            if !names.isEmpty {
                for name in names { map["\(name).x"] = name; map["\(name).y"] = name }
                return map
            }
        }
        for name in defaultPlanetNames() { map["\(name).x"] = name; map["\(name).y"] = name }
        return map
    }
    func resolvePlanetTracker(_ tracker: String, in sim: PlanetsSimulationAsync, range: ClosedRange<Int>) -> Int? {
        guard let dot = tracker.firstIndex(of: ".") else { return nil }
        let planetName = String(tracker[..<dot])
        let component = String(tracker[tracker.index(after: dot)...])
        if let proj = sim.projectedPlanetXY127(name: planetName) {
            let raw = component == "x" ? proj.x : proj.y
            return scaleToRange(raw, range: range)
        }
        // Fallback to world->CC using visualBounds
        guard let wp = sim.planetWorldPosition(name: planetName) else { return nil }
        let vb = sim.visualBounds
        let rawF: Float = (component == "x") ? wp.x : wp.y
        let cc = normalizeToCC(raw: rawF, minVal: -vb, maxVal: vb)
        return scaleToRange(cc, range: range)
    }
    func normalizeToCC(raw: Float, minVal: Float, maxVal: Float) -> Int {
        let range = maxVal - minVal
        guard range > 0 else { return 0 }
        let wrappedRaw = raw - minVal
        let modRaw = wrappedRaw.truncatingRemainder(dividingBy: range)
        let norm = (modRaw < 0 ? modRaw + range : modRaw) / range
        return Int(round(norm * 127))
    }
    func scaleToRange(_ value: Int, range: ClosedRange<Int>) -> Int {
        let minV = range.lowerBound
        let maxV = range.upperBound
        let norm = CGFloat(value) / 127.0
        return Int(round(norm * CGFloat(maxV - minV) + CGFloat(minV)))
    }
    func coordForTracker(_ tracker: String) -> String {
        // Expect format "Planet.axis" (e.g., "Earth.x"). If it matches, return "Planet x".
        if let dot = tracker.firstIndex(of: ".") {
            let name = String(tracker[..<dot])
            let axis = String(tracker[tracker.index(after: dot)...]).lowercased()
            return "\(name) \(axis)"
        }
        return tracker
    }
    func colorForTracker(_ tracker: String, in sim: PlanetsSimulationAsync?) -> Color? {
        guard let sim = sim, let dot = tracker.firstIndex(of: ".") else { return nil }
        let planetName = String(tracker[..<dot])
        return Color(sim.planetColor(name: planetName) ?? .white)
    }
    func readableColorName(from uiColor: UIColor) -> String {
        let palette: [(String, UIColor)] = [("Yellow", .yellow),("Orange", .orange),("Red", .red),("Purple", .purple),("Blue", .blue),("Cyan", .cyan),("Green", .green),("Brown", .brown),("Gray", .gray)]
        func rgba(_ c: UIColor) -> (CGFloat,CGFloat,CGFloat,CGFloat) {
            var r: CGFloat = 0,g: CGFloat = 0,b: CGFloat = 0,a: CGFloat = 0
            if c.getRed(&r, green: &g, blue: &b, alpha: &a) { return (r,g,b,a) }
            let cg = c.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)
            if let cg = cg, let comps = cg.components, comps.count >= 3 {
                let r = comps[0], g = comps[1], b = comps[2]; let a = comps.count >= 4 ? comps[3] : 1
                return (r,g,b,a)
            }
            return (0,0,0,1)
        }
        let (r1,g1,b1,_) = rgba(uiColor)
        var best: (String, CGFloat) = ("", .greatestFiniteMagnitude)
        for (name, col) in palette {
            let (r2,g2,b2,_) = rgba(col)
            let d = (r1-r2)*(r1-r2)+(g1-g2)*(g1-g2)+(b1-b2)*(b1-b2)
            if d < best.1 { best = (name, d) }
        }
        return best.0.isEmpty ? "Color" : best.0
    }
    // Ensure currently selected MIDI slots reference valid trackers
    func sanitizeSlots(_ sim: PlanetsSimulationAsync?) {
        guard let sim = sim else { return }
        let allowed = Set(makeTrackers(sim))
        guard let first = allowed.first else { return }
        var changed = false
        for i in midiSlots.indices {
            if !allowed.contains(midiSlots[i].tracked) {
                midiSlots[i].tracked = first
                changed = true
            }
        }
        if midiSlots.isEmpty { midiSlots = [MIDIParams(tracked: first)]; changed = true }
        if changed { saveMIDISlots() }
    }
    
    // MARK: - Tracker Helpers (mirroring MeshBird)
    private func makeTrackers(_ sim: PlanetsSimulationAsync?) -> [String] {
        let names: [String]
        if let sim = sim, !sim.planetNames().isEmpty {
            names = sim.planetNames()
        } else {
            names = ["Sun","Earth","Mars","Mercury","Comet"]
        }
        var trackers: [String] = []
        for n in names { trackers.append(contentsOf: ["\(n).x", "\(n).y"]) }
        return trackers
    }
    private func colorForTrackerHash(_ tracker: String) -> Color {
        let hash = abs(tracker.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.7, brightness: 0.9)
    }
    
    // MARK: - Background
 
        func addSpaceBackground(to scene: SCNScene) {
            let backgroundSphere = SCNSphere(radius: 20)
            if let mat = backgroundSphere.firstMaterial {
                mat.isDoubleSided = true
                mat.diffuse.contents = UIImage(named: "sta")
                mat.lightingModel = .constant
                mat.writesToDepthBuffer = false // do not occlude foreground
            }
            let starsNode = SCNNode(geometry: backgroundSphere)
            starsNode.renderingOrder = -1 // render behind everything
            starsNode.position = SCNVector3(0, 0, 0)
            scene.rootNode.addChildNode(starsNode)
        }
    // MARK: - MIDI Tick Loop
    @MainActor
    private func midiTickLoop() {
        autoreleasepool {
            guard let sim = simHolder.sim else { return }
            if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
            // Keep system on-screen with a gentle single nudge
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
                guard let ccVal = resolvePlanetTracker(slot.tracked, in: sim, range: slot.range) else { continue }
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

    // MARK: - Screen clamping to keep planets visible
    private func logRootOutOfScreenIfNeeded(sim: PlanetsSimulationAsync) {
        if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
        guard let scnView = sim.scnView, let camera = scnView.pointOfView else { return }
        // Use the sun as the anchor (center of the system)
        guard let world = sim.planetWorldPosition(name: "Sun") else { return }
        let projected = scnView.projectPoint(world)
        let w = max(scnView.bounds.width, 1)
        let h = max(scnView.bounds.height, 1)
        let screenX = CGFloat(projected.x)
        let screenY = CGFloat(projected.y)
        let margin: CGFloat = 12
        let minX = margin, maxX = w - margin, minY = margin, maxY = h - margin
        let isOff = (screenX < minX || screenX > maxX || screenY < minY || screenY > maxY)
        guard isOff else { return }
        // Clamp into the safe band
        let clampedX = min(max(screenX, minX), maxX)
        let clampedY = min(max(screenY, minY), maxY)
        let target = SCNVector3(Float(clampedX), Float(clampedY), projected.z)
        let correctedWorld = scnView.unprojectPoint(target)
        var delta = correctedWorld - world
        if !delta.x.isFinite || !delta.y.isFinite || !delta.z.isFinite { return }
        // Keep movement in camera plane, drop forward component
        let camFwd = SCNVector3(camera.worldTransform.m31, camera.worldTransform.m32, camera.worldTransform.m33).normalized()
        let fProj = SCNVector3.dot(delta, camFwd)
        var deltaInPlane = delta - camFwd * fProj
        deltaInPlane.z = 0
        let maxStep: Float = 0.8
        let len = deltaInPlane.length()
        if len > maxStep { deltaInPlane = deltaInPlane.normalized() * maxStep }
        let k: Float = 0.25
        sim.translateSystemXY(dx: deltaInPlane.x * k, dy: deltaInPlane.y * k)
    }

    // MARK: - MIDI Menu Sheet
    private func midiMenuSheetView() -> some View {
        let trackers = makeTrackers(simHolder.sim)
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

}
