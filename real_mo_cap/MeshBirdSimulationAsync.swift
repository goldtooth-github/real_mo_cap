import SceneKit
import UIKit
import Foundation

// MARK: - MeshBirdSimulationAsync (display-link / renderer driven)
final class MeshBirdSimulationAsync: NSObject, LifeformSimulation, SCNSceneRendererDelegate {
    // Inner synchronous core
    public let inner: MeshBirdSimulation
    var perFrameCallback: (() -> Void)?

    // Bridged refs
    public var sceneReference: SCNScene? {
        get { inner.sceneRef }
        set { inner.sceneRef = newValue }
    }
    weak var scnView: SCNView? {
        didSet {
            inner.scnView = scnView
            attachRendererIfPossible()
        }
    }
    var visualBounds: Float { inner.visualBounds }

    // Timing
    private var lastTime: TimeInterval = 0
    private var isPaused: Bool = false
    private var dtClamp: Float = 1.0 / 30.0
    private var fixedTimeEnabled = false
    private var accumulator: Float = 0
    private let fixedStep: Float = 1.0 / 60.0

    // Lifecycle flags
    private var externallyStopped: Bool = false
    private var requestedStart: Bool = false

    // Debounce for heavy reset triggers
    private var pendingReset = false
    private var resetDispatchWork: DispatchWorkItem?

    // NEW: coalesce main-thread per-frame callback dispatch
    private var midiCallbackPending = false

    // Init
    init(scene: SCNScene, scnView: SCNView?) {
        self.inner = MeshBirdSimulation(scene: scene, scnView: scnView)
        self.scnView = scnView
        super.init()
        attachRendererIfPossible()
    }

    // MARK: - LifeformSimulation passthrough
    func update(deltaTime: Float) { inner.update(deltaTime: deltaTime) }
    func reset() { inner.reset() }

    // MARK: - Public control API
    func setWingFlapSpeed(_ v: Float) { inner.setWingFlapSpeed(v) }
    func setBirdRotation(_ v: Float) { inner.setBirdRotation(v) }
    func setBirdSize(_ v: Float) { inner.setBirdSize(v) }
    func setWindIntensity(_ v: Float) { inner.setWindIntensity(v) }
    func translate(dx: Float, dy: Float, dz: Float) { inner.translate(dx: dx, dy: dy, dz: dz) }

    // MARK: - Trackers
    func trackerNames() -> [String] { inner.trackerNames() }
    @MainActor func jointWorldPosition(_ name: String) -> SCNVector3? { inner.jointWorldPosition(name) }
    @MainActor func projectedJointXY127(jointName: String) -> (x: Int, y: Int)? { inner.projectedJointXY127(jointName: jointName) }
    @MainActor func projectedJointXY127Raw(jointName: String) -> (x: Int, y: Int)? { inner.projectedJointXY127Raw(jointName: jointName) }
    @MainActor func birdBodyScreenXY127() -> (x: Int, y: Int)? { inner.birdBodyScreenXY127() }
    @MainActor func birdBodyScreenXY127Raw() -> (x: Int, y: Int)? { inner.birdBodyScreenXY127Raw() }

    // MARK: - Pause
    @MainActor func setPaused(_ paused: Bool) {
        isPaused = paused
        inner.setSceneGraphPaused(paused)
        scnView?.isPlaying = !paused
    }

    // MARK: - Start/Stop
    @MainActor func startAsyncSimulation() {
        requestedStart = true
        externallyStopped = false
        lastTime = 0
        attachRendererIfPossible()
        scnView?.isPlaying = true
    }
    @MainActor func stopAsyncSimulation() { externallyStopped = true }

    // MARK: - Renderer Attach
    private func attachRendererIfPossible() {
        guard let v = scnView else { return }
        if v.delegate !== self { v.delegate = self }
        if requestedStart && !externallyStopped { v.isPlaying = true }
        if #available(iOS 13.0, *) { v.rendersContinuously = true }
    }

    // MARK: - Debounced heavy reset
    func scheduleResetDebounced(after delay: TimeInterval = 0.05) {
        resetDispatchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingReset = false
            self?.reset()
        }
        pendingReset = true
        resetDispatchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - SCNSceneRendererDelegate
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

    // MARK: - Cleanup
    func cleanup() {
        print("[MeshBirdSimulationAsync] cleanup called")
        scnView?.delegate = nil
        scnView = nil
        sceneReference = nil
    }
    deinit { print("[MeshBirdSimulationAsync] deinit called") }
    func teardownAndDispose() {
        scnView?.delegate = nil
        scnView = nil
        sceneReference = nil
        inner.teardownAndDispose()
    }

    // Heartbeat exposure
    var heartbeat: Bool { inner.heartbeat }
    var heartbeatLatched: Bool { inner.heartbeatLatchedPublic }
    var heartbeatBPM: Float { inner.heartbeatBPM }
    var heartbeatBPMInstant: Float { inner.heartbeatBPMInstant }
}
