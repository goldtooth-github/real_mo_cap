import SceneKit
import UIKit

// MARK: - SimplePlantLadybirdsSimulationAsync
// Thin async wrapper around SimplePlantLadybirdsSimulation.
// Responsibilities:
//  - Own inner synchronous simulation instance
//  - Attach as SCNSceneRendererDelegate to drive per-frame updates
//  - Provide start/stop/pause lifecycle used by ModifiedSimulationView
//  - Forward all public control / tracker API to inner
// Mirrors architecture of MeshBirdSimulationAsync / BarleySimulationAsync / JellyfishSimulationAsync.
final class SimplePlantLadybirdsSimulationAsync: NSObject, LifeformSimulation, SCNSceneRendererDelegate {
    // Public config mirror
    typealias Config = SimplePlantLadybirdsSimulation.Config

    // Core
    let inner: SimplePlantLadybirdsSimulation
    var perFrameCallback: (() -> Void)?
    // Timing
    private var lastTime: TimeInterval = 0
    private var isPaused: Bool = false
    private var dtClamp: Float = 1.0 / 30.0
    private var fixedTimeEnabled = false
    private var accumulator: Float = 0
    private let fixedStep: Float = 1.0 / 60.0
    // Scene bridging
    var sceneReference: SCNScene? {
        get { inner.sceneReference }
        set { inner.sceneReference = newValue }
    }
    weak var scnView: SCNView? {
        didSet {
            inner.scnView = scnView
            attachRendererIfPossible()
        }
    }

    // Timing / lifecycle flags
   // private var lastTime: TimeInterval = 0
    private var requestedStart = false
    private var externallyStopped = false
   // private var isPaused = false
    // NEW: coalesce main-thread per-frame callback dispatch
    private var midiCallbackPending = false
     
    

    // Init
    init(scene: SCNScene, scnView: SCNView?, config: Config, globalConfig: LifeformViewConfig?) {
        self.inner = SimplePlantLadybirdsSimulation(scene: scene, scnView: scnView, config: config, globalConfig: globalConfig)
        self.scnView = scnView
        super.init()
        attachRendererIfPossible()
    }

    // Renderer attach helper
    private func attachRendererIfPossible() {
        guard let v = scnView else { return }
        if v.delegate !== self { v.delegate = self }
        if requestedStart && !externallyStopped { v.isPlaying = true }
        if #available(iOS 13.0, *) { v.rendersContinuously = true }
    }

    // MARK: - LifeformSimulation
    func update(deltaTime: Float) { inner.update(deltaTime: deltaTime) }
    func reset() { inner.reset() }

    // MARK: - Public control passthrough
    func setScaleMultiplier(_ v: Float) { inner.setScaleMultiplier(v) }
    func setSpeedMultiplier(_ v: Float) { inner.setSpeedMultiplier(v) }
    func currentScaleMultiplier() -> Float { inner.currentScaleMultiplier() }
    func currentSpeedMultiplier() -> Float { inner.currentSpeedMultiplier() }
    func translate(dx: Float, dy: Float, dz: Float) { inner.translate(dx: dx, dy: dy, dz: dz) }
    func setGlobalScale(_ s: Float) { inner.setGlobalScale(s) }
    func currentGlobalScale() -> Float { inner.currentGlobalScale() }
    func setRotationAngle(_ angleDegrees: Float) { inner.setRotationAngle(angleDegrees) }

    // Trackers
    func segmentCount(caterpillar index: Int) -> Int { inner.segmentCount(caterpillar: index) }
    @MainActor func projectedFirstCaterpillarSegmentXY127(segment: Int) -> (x: Int, y: Int)? { inner.projectedFirstCaterpillarSegmentXY127(segment: segment) }

    // MARK: - Pause
    @MainActor func setPaused(_ paused: Bool) {
        isPaused = paused
        scnView?.isPlaying = !paused && requestedStart && !externallyStopped
        if paused { lastTime = 0 }
    }

    // MARK: - Async lifecycle (used by ModifiedSimulationView)
    @MainActor func startAsyncSimulation() {
        requestedStart = true
        externallyStopped = false
        lastTime = 0
        attachRendererIfPossible()
        scnView?.isPlaying = true
    }

    @MainActor func stopAsyncSimulation() {
        externallyStopped = true
        scnView?.isPlaying = false
    }

    // MARK: - Low Power Mode
    func setLowPowerMode(_ enabled: Bool) {
        inner.setLowPowerMode(enabled)
    }

    // MARK: - SCNSceneRendererDelegate
    private var uiUpdateFrameCounter = 0
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if externallyStopped || isPaused { lastTime = time; return }
        if !requestedStart { lastTime = time; return }
        if lastTime == 0 { lastTime = time; return }
        
        // Acquire semaphore to limit concurrent render updates
        RenderCoordinator.shared.renderSemaphore.wait()
        defer { RenderCoordinator.shared.renderSemaphore.signal() }
        
        var dt = Float(time - lastTime)
        lastTime = time
        if dt > dtClamp { dt = dtClamp }
        if fixedTimeEnabled {
            accumulator += dt
            while accumulator >= fixedStep {
                update(deltaTime: fixedStep)
                accumulator -= fixedStep
            }
        } else {
            update(deltaTime: dt)
        }
        if let cb = perFrameCallback, !midiCallbackPending {
            midiCallbackPending = true
            DispatchQueue.main.async { [weak self] in
                cb()
                self?.midiCallbackPending = false
            }
        }
    }
 
    // MARK: - Teardown
    func teardownAndDispose() {
        scnView?.delegate = nil
        scnView = nil
        inner.scnView = nil
    }

    deinit { teardownAndDispose() }
}
