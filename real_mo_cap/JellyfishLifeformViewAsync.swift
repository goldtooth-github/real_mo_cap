import SwiftUI
import SceneKit
import UIKit
import Combine
import QuartzCore // if not already imported
 
// MARK: - MIDI CC Deduplication Cache
private final class MIDISendCache { var lastSentCCValues: [Int: Int] = [:] }

// Helper settings model for save/load
private struct JellyfishSettings: Codable {
    var pulseSpeed: Float
    var jellySize: Float
    var rotation: Float
    var displayLFOOutputs: Bool
    var reduceCPUOverhead: Bool
    var waterCurrent: Float?
    var jellyPosX: Float?
    var jellyPosY: Float?
    var jellyPosZ: Float?

    enum CodingKeys: String, CodingKey { case pulseSpeed, jellySize, rotation, displayLFOOutputs, reduceCPUOverhead, waterCurrent, jellyPosX, jellyPosY, jellyPosZ }
}
 // New: Preset that bundles settings + MIDI slots for export/import
private struct JellyfishPreset: Codable {
    var settings: JellyfishSettings
    var midiSlots: [MIDIParams]
}

// MARK: - SimHolder (non-observable to avoid publish during view updates)
final class SimHolder { var sim: JellyfishSimulationAsync? }

// MARK: - JellyfishLifeformViewAsync
struct JellyfishLifeformViewAsync: View {
    // MARK: - View State & Parameters
    var isActive: Bool = false
    var isPaused: Binding<Bool>
    var uiDetached: Bool = false
    var isDisplayLockPressed: Binding<Bool>
 
    //@EnvironmentObject var focuspocus
    
    // MIDI tick publisher (downsampled)
    //  private let tickPublisher = GlobalTickRouter.shared.$ccTick
   // @State private var tickPublisher = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    // Simulation parameters
    @State private var pulseSpeed: Float = 1.0
    @State private var jellySize: Float = 1.3 // Increased from 1.7
    @State private var rotation: Float = 0.0
    @State private var waterCurrent: Float = 0.25
    // @State private var overlayFlushTrigger = UUID()
   // @State private var lastFlushTime: CFTimeInterval = 0
    private let pulseSpeedRange: ClosedRange<Float> = 0.1...3.0
    private let sizeRange: ClosedRange<Float> = 0.4...2.5 // Increased upper bound from 2.0
    private let rotationRange: ClosedRange<Float> = 0.0...360.0
    private let waterCurrentRange: ClosedRange<Float> = 0.0...2.5
    private let minJellySize: Float = 0.4
    private let maxJellySize: Float = 2.5 // Increased from 2.0
    // Simulation/camera state
    // Throttle LFO history to ~30 Hz
       @State private var lastLFORecordTime: CFTimeInterval = 0
    @EnvironmentObject var powerModeMonitor: PowerModeMonitor
    private var lfoRecordInterval: CFTimeInterval {
        powerModeMonitor.isLowPowerMode || reduceCPUOverhead ? 1.0 / 15.0 : 1.0 / 30.0
    }
    @State private var reduceCPUOverhead: Bool = false
    @State private var userReduceCPUOverhead: Bool = false
    // User's preferred value
       // Coalesce per‑frame callback to avoid piling up when main is busy
        @State private var perFrameCallbackPending = false
    // Debounce state for slider changes
    @State private var lastAppliedPulseSpeed: Float = 1.0
    @State private var lastAppliedRotation: Float = 0.0
    @State private var lastAppliedWaterCurrent: Float = 0.25
    private let epsilon: Float = 0.01 // Minimum change threshold
    
    
    @State private var simRef: JellyfishSimulationAsync?
    @State private var simHolder = SimHolder()
    @State private var scnViewRef: SCNView? = nil
    @StateObject private var cameraState = CameraOrbitState()
    // MIDI/LFO state
    @State private var showMidiMenu: Bool = false
    @State private var midiSlots: [MIDIParams] = []
    private let midiSlotsKey = "MIDI_SLOTS_JELLYFISH_ASYNC"
    @State private var midiSendCache = MIDISendCache()
    @State private var displayLFOOutputs: Bool = false
    @State private var lfoHistories: [RingHistory] = []   // Holds reference types
   private let lfoMaxSamples: Int = 50
   // private var lfoMaxSamples: Int { powerModeMonitor.isLowPowerMode || reduceCPUOverhead ? 10 : 50}
    @State private var midiFocusIndex: Int? = nil
 
    @State private var showBoundsBox: Bool = false // Debug: show visual bounds
    //@State private var lastSentCCValues: [Int: Int] = [:]
    // NEW: Solo state shared with MIDI menu
    @State private var midiSoloIndex: Int? = nil
    @State private var jellyOffset: SIMD3<Float> = .zero
    
    // MARK: - View Config
    private let config = LifeformViewConfig(
        initialAzimuth: 0,
        initialElevation: 0,
        initialRadius: 30,
        minRadius: 1,
        maxRadius: 40,
        cameraControlMode: .nicks_control,
        ambientLightIntensity: 0.45,
        directionalLightIntensity: 0.7,
        directionalLightAngles: SCNVector3(x: -Float.pi/4, y: Float.pi/5, z: 0),
        updateInterval: 0.016,
        title: "Jellyfish",
        controlPanelColor: Color.black.opacity(0.55),
        controlTextColor: .white,
        buttonBackgroundColor: Color.purple.opacity(0.55),
        controlPanelBottomInset: 5
    )
    
    // MARK: - Simulation Creation
    private func createJellyfishSimulation(scene: SCNScene) -> JellyfishSimulationAsync {
        let sim = JellyfishSimulationAsync(scene: scene, scnView: nil)
        sim.setPulseSpeed(pulseSpeed)
        sim.setJellySize(jellySize)
        sim.setRotation(rotation)
        sim.setWaterCurrentStrength(waterCurrent)
        return sim
    }
    
    // Construct current settings snapshot
    private func currentSettings() -> JellyfishSettings {
        JellyfishSettings(
            pulseSpeed: pulseSpeed,
            jellySize: jellySize,
            rotation: rotation,
            displayLFOOutputs: displayLFOOutputs,
            reduceCPUOverhead: reduceCPUOverhead,
            waterCurrent: waterCurrent,
            jellyPosX: jellyOffset.x,
            jellyPosY: jellyOffset.y,
            jellyPosZ: jellyOffset.z
        )
    }
    
    // Apply settings to UI and simulation
    private func applySettings(_ s: JellyfishSettings) {
        pulseSpeed = s.pulseSpeed; simHolder.sim?.setPulseSpeed(s.pulseSpeed)
        jellySize = min(max(s.jellySize, minJellySize), maxJellySize); simHolder.sim?.setJellySize(jellySize)
        rotation = s.rotation; simHolder.sim?.setRotation(s.rotation)
        let wc = s.waterCurrent ?? waterCurrent
        waterCurrent = wc; simHolder.sim?.setWaterCurrentStrength(wc)
        displayLFOOutputs = s.displayLFOOutputs
        // Respect Low Power Mode override behavior
        if powerModeMonitor.isLowPowerMode {
            userReduceCPUOverhead = s.reduceCPUOverhead
            reduceCPUOverhead = true
            simHolder.sim?.setLowPowerMode(true)
        } else {
            reduceCPUOverhead = s.reduceCPUOverhead
            userReduceCPUOverhead = s.reduceCPUOverhead
            simHolder.sim?.setLowPowerMode(s.reduceCPUOverhead)
        }
        // Apply saved position
        let target = SIMD3<Float>(s.jellyPosX ?? 0, s.jellyPosY ?? 0, s.jellyPosZ ?? 0)
        if let sim = simHolder.sim {
            let delta = target - jellyOffset
            sim.translate(dx: delta.x, dy: delta.y, dz: delta.z)
            jellyOffset = target
        } else {
            jellyOffset = target
        }
    }
    
    // MARK: - Controls UI
    private func buildControls(simBinding: Binding<JellyfishSimulationAsync?>, isPaused: Binding<Bool>) -> some View {
        if uiDetached {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(spacing: 10) {
                // Pulse Speed
                HStack {
                    Text("Pulse").foregroundColor(config.controlTextColor)
                    Slider(value: Binding(
                        get: { Double(pulseSpeed) },
                        set: { v in pulseSpeed = Float(v) }
                    ), in: Double(pulseSpeedRange.lowerBound)...Double(pulseSpeedRange.upperBound))
                    Text(String(format: "%.0f°", pulseSpeed)).foregroundColor(config.controlTextColor).frame(width: 48)
                }
                // Water Current (global turbulence)
                HStack {
                    Text("Water Current").foregroundColor(config.controlTextColor)
                    Slider(value: Binding(
                        get: { Double(waterCurrent) },
                        set: { v in waterCurrent = Float(v) }
                    ), in: Double(waterCurrentRange.lowerBound)...Double(waterCurrentRange.upperBound))
                    Text(String(format: "%.2f", waterCurrent)).foregroundColor(config.controlTextColor).frame(width: 48)
                }
                // LFO overlay toggle
                Toggle("Display LFO outputs", isOn: $displayLFOOutputs)
                    .toggleStyle(.switch)
                    .foregroundColor(config.controlTextColor)
                Toggle("Reduce CPU Overhead", isOn: $reduceCPUOverhead)
                    .toggleStyle(.switch)
                    .foregroundColor(config.controlTextColor)
                    .disabled(powerModeMonitor.isLowPowerMode)
                // Always reserve space to avoid layout shift
                Text("(Device in Low Power Mode)")
                    .font(.caption)
                    .foregroundColor(.yellow)
                    .opacity(powerModeMonitor.isLowPowerMode ? 1 : 0)
                    .padding(.top, -10)
                // MIDI settings + Reset
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
        )
    }
    
    // MARK: - Friendly label for tracker names
    private func friendlyTrackerLabel(_ tracker: String) -> String {
        let parts = tracker.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return tracker }
        let base = parts[0]
        let comp = parts[1]
        if base.hasPrefix("j"), let underIdx = base.firstIndex(of: "_") {
            let idxPart = String(base[base.startIndex..<underIdx]) // e.g. j0
            let typePart = String(base[base.index(after: underIdx)...]) // e.g. inner
            if idxPart.hasPrefix("j"), let idx = Int(idxPart.dropFirst()) {
                let t = typePart.lowercased()
                let displayIdx = idx + 1 // 1-based for UI
                return t == "inner" ? "Jellyfish \(displayIdx).\(comp)" : "Jellyfish \(displayIdx) \(t).\(comp)"
            }
        }
        return tracker
    }
    
    // MARK: - Main View Body
    var body: some View {
        ModifiedSimulationView<JellyfishSimulationAsync>(
            config: config,
            customCameraState: cameraState,
            createSimulation: { scene in
                if let s = simHolder.sim { return s }
                let sim = createJellyfishSimulation(scene: scene)
                simHolder.sim = sim
                return sim
            },
            controlsBuilder: { binding, pausedBinding in
                AnyView(buildControls(simBinding: binding, isPaused: pausedBinding))
            },
            onViewReady: { simBinding, scnView in
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
            systemScaleGetter: { jellySize },
            systemScaleSetter: { newScale in
                let clamped = min(max(newScale, minJellySize), maxJellySize)
                jellySize = clamped
                simHolder.sim?.setJellySize(clamped)
            },
            systemScaleRange: sizeRange,
            simulationDragHandler: { delta in
                let factor: Float = 0.02
                let movementMultiplier: Float = 2.0
                let horiz = Float(delta.width) * factor * movementMultiplier
                let vert = Float(-delta.height) * factor * movementMultiplier
                simHolder.sim?.translate(dx: horiz, dy: vert, dz: 0)
                jellyOffset += SIMD3<Float>(horiz, vert, 0)
            },
            enableParallaxPan: false,
            driveWithSimulationManager: false,
            pauseHandler: { paused, sim in
                sim?.setPaused(paused)
            },
            sceneOverlayBuilder: {
                AnyView(
                    Group {
                        if displayLFOOutputs, !midiSlots.isEmpty, !uiDetached {
                            let labels = midiSlots.map { slot in
                                friendlyTrackerLabel(slot.tracked)
                            }
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
                           // .equatable()
                         //   .id(displayLFOOutputs ? overlayFlushTrigger : UUID()) // Reset every 5s when visible
                        }
                    }
                )
            },
            panelAutoHideEnabled: true,
            externalPaused: isPaused,
            isDisplayLockPressed: isDisplayLockPressed,
            // Settings serialization hooks
            getSettingsData: {
                let slots: [MIDIParams]
                if midiSlots.isEmpty,
                let data = UserDefaults.standard.data(forKey: midiSlotsKey),
                let decoded = try? JSONDecoder().decode([MIDIParams].self, from: data) {
                    slots = decoded
                } else {
                    slots = midiSlots
                }
                print("[Jellyfish] Exporting preset JSON (slots=\(slots.count))")
                return (try? JSONEncoder().encode(JellyfishPreset(settings: currentSettings(), midiSlots: slots))) ?? Data()
            },
            applySettingsData: { data in
                let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                if let preset = try? JSONDecoder().decode(JellyfishPreset.self, from: data) {
                    print("[Jellyfish] Loaded preset JSON (slots=\(preset.midiSlots.count)). Preview: \(preview)")
                    applySettings(preset.settings)
                    // Migrate any legacy 'heartbeat.bpmInstant' trackers
                    let migrated = preset.midiSlots.map { slot in
                        var s = slot
                        if s.tracked == "heartbeat.bpmInstant" { s.tracked = "heartbeat.bpm" }
                        return s
                    }
                    midiSlots = migrated
                    saveMIDISlots()
                    syncLFOHistoriesToSlots()
                    midiSendCache.lastSentCCValues = [:]
                } else if let decoded = try? JSONDecoder().decode(JellyfishSettings.self, from: data) {
                    print("[Jellyfish] Loaded settings-only JSON. Preview: \(preview)")
                    applySettings(decoded)
                } else {
                    print("[Jellyfish] Failed to decode JSON for this view. Are you importing the right preset? Preview: \(preview)")
                }
            }
        )
        .preferredColorScheme(.dark)
        // MIDI Settings sheet
        .sheet(isPresented: $showMidiMenu) { midiMenuSheetView() }
        // Lifecycle + MIDI/LFO updates
        .onChange(of: midiSlots) { _, _ in
            saveMIDISlots()
            syncLFOHistoriesToSlots()
            midiSendCache.lastSentCCValues = [:]
        }
        .onChange(of: pulseSpeed) { _, _ in
            debouncedApplyPulseSpeed()         }
        .onChange(of: waterCurrent) { _, _ in
            debouncedApplyWaterCurrent()         }
        
        
        
        .onChange(of: powerModeMonitor.isLowPowerMode) { _, isLow in
            if isLow {
                // Entering low power mode: force reduceCPUOverhead ON
                userReduceCPUOverhead = reduceCPUOverhead // Save user preference
                reduceCPUOverhead = true
                simHolder.sim?.setLowPowerMode(true)
            } else {
                // Exiting low power mode: restore user preference
                reduceCPUOverhead = userReduceCPUOverhead
                simHolder.sim?.setLowPowerMode(userReduceCPUOverhead)
            }
        }
        .onChange(of: reduceCPUOverhead) { _, v in
            // Only update simulation if not in low power mode
            if !powerModeMonitor.isLowPowerMode {
                userReduceCPUOverhead = v
                simHolder.sim?.setLowPowerMode(v)
            }
        }
        .onChange(of: isPaused.wrappedValue) { _, newVal in
            simHolder.sim?.setPaused(newVal)
        }
        .onAppear {
            loadMIDISlots()
            syncLFOHistoriesToSlots()
            // On appear, sync toggle to power mode
            if powerModeMonitor.isLowPowerMode {
                userReduceCPUOverhead = reduceCPUOverhead
                reduceCPUOverhead = true
                simHolder.sim?.setLowPowerMode(true)
            } else {
                simHolder.sim?.setLowPowerMode(reduceCPUOverhead)
            }
        }
        .onDisappear {
            simHolder.sim?.stopAsyncSimulation(); simHolder.sim?.teardownAndDispose(); simHolder.sim = nil
        }
       // .onReceive(tickPublisher) { _ in
       //     if isActive && !isPaused.wrappedValue { midiTickLoop() }
       // }
    }

    // MARK: - MIDI Tick Loop
    @MainActor
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
            // Flush Metal texture cache every 5 seconds
           //      if now - lastFlushTime > 5.0 {
             //        overlayFlushTrigger = UUID()
             //        lastFlushTime = now
             //    }
            for (index, slot) in midiSlots.enumerated() {
                // Respect solo: when set, only the soloed slot emits
                if let s = midiSoloIndex, s != index { continue }
                guard index < lfoHistories.count else { continue }
                guard let ccVal = resolveJellyTracker(slot.tracked, in: sim, range: slot.range) else { continue }
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

    // MARK: - Individual Jellyfish Screen Clamping
    private func logRootOutOfScreenIfNeeded(sim: JellyfishSimulationAsync) {
        if sim.scnView == nil, let fallback = scnViewRef { sim.scnView = fallback }
        guard let scnView = sim.scnView, let camera = scnView.pointOfView else { return }
        
        let jellyCount = sim.inner.jellyfishCount_exposed
        for i in 0..<jellyCount {
            guard let jellyWorld = sim.jellyWorldPosition(index: i, nodeType: "inner") else { continue }
            
            let projected = scnView.projectPoint(jellyWorld)
            let w = max(scnView.bounds.width, 1)
            let h = max(scnView.bounds.height, 1)
            let screenX = CGFloat(projected.x)
            let screenY = CGFloat(projected.y)
            let margin: CGFloat = 8 // pixels
            let minX = margin
            let maxX = w - margin
            let minY = margin
            let maxY = h - margin
            let isOffscreen = (screenX < minX || screenX > maxX || screenY < minY || screenY > maxY)
            guard isOffscreen else { continue }
            
            let clampedX = min(max(screenX, minX), maxX)
            let clampedY = min(max(screenY, minY), maxY)
            let targetScreen = SCNVector3(Float(clampedX), Float(clampedY), projected.z)
            let correctedWorld = scnView.unprojectPoint(targetScreen)
            var delta = correctedWorld - jellyWorld
            if !delta.x.isFinite || !delta.y.isFinite || !delta.z.isFinite { continue }
            
            // Keep motion in camera plane to avoid depth pops
            let camForward = SCNVector3(camera.worldTransform.m31, camera.worldTransform.m32, camera.worldTransform.m33).normalized()
            let forwardProj = SCNVector3.dot(delta, camForward)
            let deltaInPlane = delta - camForward * forwardProj
            
            // Gentler correction factor
            let k: Float = 0.35
            let correctionDelta = SCNVector3(deltaInPlane.x * k, deltaInPlane.y * (k*2), deltaInPlane.z * k)
            
            // Apply position correction
            sim.inner.adjustJellyfishPosition(index: i, dx: correctionDelta.x, dy: correctionDelta.y, dz: correctionDelta.z)
            
            // Also nudge velocity away from the edge to help jellyfish turn
          
        }
    }

    private func debouncedApplyPulseSpeed() {
        guard abs(pulseSpeed - lastAppliedPulseSpeed) > epsilon else { return }
        simHolder.sim?.setPulseSpeed(pulseSpeed)
        lastAppliedPulseSpeed = pulseSpeed
    }

    private func debouncedApplyWaterCurrent() {
        guard abs(waterCurrent - lastAppliedWaterCurrent) > epsilon else { return }
        simHolder.sim?.setWaterCurrentStrength(waterCurrent)
        lastAppliedWaterCurrent = waterCurrent
    }
    
    private func debouncedApplyRotation() {
        guard abs(rotation - lastAppliedRotation) > epsilon else { return }
        simHolder.sim?.setRotation(rotation)
        lastAppliedRotation = rotation
    }
    
    
    // Resolve a Jellyfish tracker name (e.g., "j0_inner.x") into a CC in 0..127, scaled to slot.range
    private func resolveJellyTracker(_ tracker: String, in sim: JellyfishSimulationAsync, range: ClosedRange<Int>) -> Int? {
        let parts = tracker.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let base = parts[0]
        let comp = parts[1].lowercased()
        guard comp == "x" || comp == "y" || comp == "z" else { return nil }
        // base format: "j<index>_<type>" e.g. j0_inner, j1_outer, etc.
        let baseParts = base.split(separator: "_", maxSplits: 1).map(String.init)
        guard baseParts.count == 2 else { return nil }
        let idxPart = baseParts[0] // e.g. j0
        let typePart = baseParts[1] // e.g. inner
        guard idxPart.hasPrefix("j"), let idx = Int(idxPart.dropFirst()) else { return nil }
        if comp == "x" || comp == "y" {
            if let xy = sim.projectedJellyXY127(index: idx, nodeType: typePart) {
                let raw = (comp == "x") ? xy.x : xy.y
                return scaleToRange(raw, range: range)
            }
            return nil
        }
        // Z-world mapping (optional): map world Z to CC via visual bounds
        if let wp = sim.jellyWorldPosition(index: idx, nodeType: typePart) {
            let vb = sim.visualBounds
            let rawF: Float = wp.z
            let cc = normalizeToCC(raw: rawF, minVal: -vb, maxVal: vb)
            return scaleToRange(cc, range: range)
        }
        return nil
    }
    private func loadMIDISlots() {
        let clip = MIDISlotsClipboard.shared
        if clip.isGlobalEnabled, !clip.globalSlots.isEmpty { midiSlots = clip.globalSlots; return }
        if let data = UserDefaults.standard.data(forKey: midiSlotsKey),
           let loaded = try? JSONDecoder().decode([MIDIParams].self, from: data) {
            // Migrate any legacy 'heartbeat.bpmInstant' trackers to 'heartbeat.bpm'
            midiSlots = loaded.map { slot in
                var s = slot
                if s.tracked == "heartbeat.bpmInstant" { s.tracked = "heartbeat.bpm" }
                return s
            }
            // Persist migration if any changed
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
        if lfoHistories.count < midiSlots.count {
            for _ in 0..<(midiSlots.count - lfoHistories.count) { lfoHistories.append(RingHistory(capacity: lfoMaxSamples)) }
        } else if lfoHistories.count > midiSlots.count {
            lfoHistories.removeLast(lfoHistories.count - midiSlots.count)
        }
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
        let norm = CGFloat(max(0, min(127, value))) / 127.0
        return Int(round(norm * CGFloat(maxV - minV) + CGFloat(minV)))
    }

    // MARK: - Tracker Helpers
    private func makeTrackers(_ sim: JellyfishSimulationAsync?) -> [String] {
        let sim = sim ?? simHolder.sim
        guard let sim = sim else { return ["j0_inner.x", "j0_inner.y"] }
        var names: [String] = []
        // Generate for all tracker bases: j{idx}_{type}
        for base in sim.trackerNames() {
            let comps = base.split(separator: "_", maxSplits: 1).map(String.init)
            guard comps.count == 2 else { continue }
            // Append both axes for each base
            names.append("\(base).x")
            names.append("\(base).y")
        }
        return names
    }
    private func colorForTrackerHash(_ s: String) -> Color {
        Color(hue: Double(abs(s.hashValue % 255)) / 255.0, saturation: 0.8, brightness: 0.9)
    }

    // MARK: - MIDI Menu Sheet
    @ViewBuilder private func midiMenuSheetView() -> some View {
        let trackers = makeTrackers(simHolder.sim)
        let trackerColors = Dictionary(uniqueKeysWithValues: trackers.map { ($0, colorForTrackerHash($0)) })
        let trackerColorNames = Dictionary(uniqueKeysWithValues: trackers.map { ($0, friendlyTrackerLabel($0)) })
        MIDIMenuView(
            slots: $midiSlots,
            trackers: trackers,
            trackerColors: trackerColors,
            trackerColorNames: trackerColorNames,
            focusIndex: $midiFocusIndex,
            soloIndex: $midiSoloIndex,
            onSend: { _ in },
            onReloadLocal: { loadMIDISlots() }
        )
    }
}

struct JellyfishLifeformViewAsync_Previews: PreviewProvider {
    static var previews: some View {
        JellyfishLifeformViewAsync(isPaused: .constant(false), isDisplayLockPressed: .constant(false))
            .environmentObject(PowerModeMonitor())
            //.environmentObject(Focuspocus())
    }
}
