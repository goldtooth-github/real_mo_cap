import SceneKit
import Foundation
import UIKit

final class JellyfishSimulationAsync: NSObject, LifeformSimulation, SCNSceneRendererDelegate {

    // MARK: - Core
    let inner: JellyfishSimulation
    var perFrameCallback: (() -> Void)?
    // Scene indirection
    var sceneReference: SCNScene? {
        get { inner.sceneRef }
        set { inner.sceneRef = newValue }
    }
    weak var scnView: SCNView? {
        didSet {
            inner.scnView = scnView
            scheduleRealign()
            attachRendererIfPossible()
        }
    }
    var visualBounds: Float { inner.visualBounds }

    // MARK: - Public mode toggles passthrough
    var isWorkbenchMode: Bool {
        get { inner.isWorkbenchMode }
        set { inner.isWorkbenchMode = newValue }
    }

    // MARK: - Timing
    private var lastTime: TimeInterval = 0
    private var requestedStart = false
    private var externallyStopped = false
    private var isPaused = false

    // Clamp control
    private var dtClampEnabled: Bool = true
    private var dtClamp: Float = 1.0 / 30.0
    // Fixed step (optional)
    private var fixedTimeEnabled = false
    private let fixedStep: Float = 1.0 / 60.0
    private var accumulator: Float = 0

    // Legacy speed compensation (scales motion to feel like unclamped spikes)
    private var legacySpeedCompensationEnabled = true

    // Resume flag to preserve phase continuity
    private var skipFirstFrameAfterResume = false

    // Debug
    private var debugLogging = false
    // NEW: coalesce main-thread per-frame callback dispatch
    private var midiCallbackPending = false
    // MARK: - Init
    init(scene: SCNScene, scnView: SCNView?, isWorkbenchMode: Bool = false) {
        self.inner = JellyfishSimulation(scene: scene, scnView: scnView)
        self.scnView = scnView
       // self.isWorkbenchMode = isWorkbenchMode
        super.init()
        attachRendererIfPossible()
        seedInitialStateIfNeeded()
    }

    // MARK: - LifeformSimulation
    func update(deltaTime: Float) { inner.update(deltaTime: deltaTime) }
    func reset() {
        inner.reset()
        lastTime = 0
        seedInitialStateIfNeeded()
    }

    // MARK: - Public control forwards
    func setPulseSpeed(_ v: Float) { inner.setPulseSpeed(v) }
    func setRotation(_ v: Float) { inner.setRotation(v) }
    func setJellySize(_ v: Float) { inner.setJellySize(v) }
    func getJellySize() -> Float { inner.getJellySize() }
    func translate(dx: Float, dy: Float, dz: Float) { inner.translate(dx: dx, dy: dy, dz: dz) }
    func setLowPowerMode(_ isLowPower: Bool) { inner.setLowPowerMode(isLowPower) }
    func setWaterCurrentStrength(_ v: Float) { inner.setWaterCurrentStrength(v) }

    func trackerNames() -> [String] { inner.trackerNames() }
    @MainActor func jellyWorldPosition(index: Int, nodeType: String) -> SCNVector3? { inner.jellyWorldPosition(index: index, nodeType: nodeType) }
    @MainActor func  projectedJellyXY127(index: Int, nodeType: String = "inner") -> (x: Int, y: Int)? {
        inner.projectedJellyXY127(index: index, nodeType: nodeType)
    }

    // MARK: - Start / Stop (legacy API compatibility)
    func startAsyncSimulation(updateInterval: TimeInterval = 0.016) {
        // updateInterval ignored now (renderer driven)
        requestedStart = true
        externallyStopped = false
        seedInitialStateIfNeeded()
        attachRendererIfPossible()
    }

    func stopAsyncSimulation() {
        requestedStart = false
        externallyStopped = true
    }

    func teardownAndDispose() {
        stopAsyncSimulation()
        scnView?.delegate = nil
        scnView = nil
        sceneReference = nil
        inner.teardownAndDispose()
    }

    // MARK: - Pause
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        inner.setSceneGraphPaused(paused)
        sceneReference?.isPaused = paused
        scnView?.isPlaying = !paused
        if paused {
            skipFirstFrameAfterResume = true   // preserve phase continuity
        }
    }

    // MARK: - Configuration
    func setClamp(enabled: Bool, maxStep: Float? = nil) {
        dtClampEnabled = enabled
        if let m = maxStep { dtClamp = m }
    }
    func setLegacySpeedCompensation(_ enabled: Bool) {
        legacySpeedCompensationEnabled = enabled
    }
    func setFixedTime(enabled: Bool) {
        fixedTimeEnabled = enabled
        accumulator = 0
    }
    func setDebugLogging(_ enabled: Bool) { debugLogging = enabled }

    // MARK: - Renderer hookup
    private func attachRendererIfPossible() {
        guard let v = scnView else { return }
        if v.delegate !== self { v.delegate = self }
        v.isPlaying = true
        if #available(iOS 13.0, *) {
            v.rendersContinuously = true
        }
    }

    // MARK: - Initial seeding / warm-up
    private var didSeed = false
    private func seedInitialStateIfNeeded() {
        guard !didSeed else { return }
        // Deterministic initial placement
        inner.update(deltaTime: 0)
        // Optional warm-up micro steps (settle procedural motion)
        for _ in 0..<3 {
            inner.update(deltaTime: 1.0 / 60.0)
        }
        didSeed = true
    }

    // MARK: - Realignment (camera / framing parity with old version)
    private func scheduleRealign() {
        guard let view = scnView else { return }
        for i in 0...2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40 * i)) { [weak self, weak view] in
                guard let self, let v = view, v.bounds.size != .zero else { return }
                self.inner.realignAfterViewAttached()
            }
        }
    }

    // MARK: - SCNSceneRendererDelegate
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if externallyStopped || !requestedStart { return }
        if isPaused { return }

        if lastTime == 0 {
            lastTime = time
            return   // skip first (matches old first non-zero dt behavior)
        }

        RenderCoordinator.shared.renderSemaphore.wait()
        defer { RenderCoordinator.shared.renderSemaphore.signal() }
        
        
        var rawDt = Float(time - lastTime)
        lastTime = time

        var dt = rawDt
        if dtClampEnabled && dt > dtClamp {
            if legacySpeedCompensationEnabled {
                // Preserve perceived speed by scaling later
            }
            dt = min(dt, dtClamp)
        }

        var effectiveDt = dt
        if legacySpeedCompensationEnabled && dt < rawDt && dt > 0 {
            // Scale to emulate old larger step energy
            let ratio = rawDt / dt
            effectiveDt *= ratio
        }

        if skipFirstFrameAfterResume {
            skipFirstFrameAfterResume = false
            return
        }

        if fixedTimeEnabled {
            accumulator += effectiveDt
            while accumulator >= fixedStep {
                stepSimulation(fixedStep)
                accumulator -= fixedStep
            }
        } else {
            stepSimulation(effectiveDt)

        }
        if let cb = perFrameCallback, !midiCallbackPending {
                 midiCallbackPending = true
                 DispatchQueue.main.async { [weak self] in
                     cb()
                     self?.midiCallbackPending = false
                 }
             }
    }

    // MARK: - Step
    private func stepSimulation(_ dt: Float) {
        if debugLogging {
            print("[Jellyfish] frame dt=\(dt)")
        }
        update(deltaTime: dt)
    }
}
