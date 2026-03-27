import SceneKit
import UIKit

// MARK: - BoidsSimulationAsync (display-link / renderer driven)
final class BoidsSimulationAsync: NSObject, LifeformSimulation, SCNSceneRendererDelegate {
    // Inner synchronous core
    public let inner: BoidsSimulation
    var perFrameCallback: (() -> Void)?
    // Scene bridging
    public var sceneReference: SCNScene? {
        get { inner.sceneReference }
        set { inner.sceneReference = newValue }
    }
    weak var scnView: SCNView? {
        didSet {
            inner.scnView = scnView
            attachRendererIfPossible()
        }
    }
    var visualBounds: Float { inner.visualBounds }
    var fieldHalfSize: Float { inner.fieldHalfSize }
    
    // Timing and state
    private var lastTime: TimeInterval = 0
    private var isPaused: Bool = false
    private var dtClamp: Float = 1.0 / 30.0
    private var fixedTimeEnabled = false
    private var accumulator: Float = 0
    private let fixedStep: Float = 1.0 / 60.0
    private var externallyStopped: Bool = false
    private var requestedStart: Bool = false
    
    
    // NEW: coalesce main-thread per-frame callback dispatch
    private var midiCallbackPending = false
    
    // MARK: - Init
    init(scene: SCNScene, scnView: SCNView?) {
        self.inner = BoidsSimulation(scene: scene, scnView: scnView)
        self.scnView = scnView
        super.init()
        attachRendererIfPossible()
    }
    // MARK: - Start/Stop/Pause
    @MainActor func startAsyncSimulation() {
        requestedStart = true
        externallyStopped = false
        lastTime = 0
        attachRendererIfPossible()
        scnView?.isPlaying = true
    }
    @MainActor func stopAsyncSimulation() {
        externallyStopped = true
    }
    // MARK: - Pause
    @MainActor func setPaused(_ paused: Bool) {
        // debug("setPaused called: paused=", paused)
        isPaused = paused
        setSceneGraphPaused(paused)
        scnView?.isPlaying = !paused
    }
    // MARK: - Scene graph pause helper
    private func setSceneGraphPaused(_ paused: Bool) {
        inner.scnView?.scene?.isPaused = paused
    }
    // MARK: - Renderer Attach
    private func attachRendererIfPossible() {
        guard let v = scnView else { return }
        // debug("attachRendererIfPossible: delegate=", v.delegate as Any, " requestedStart=", requestedStart, " externallyStopped=", externallyStopped)
        if v.delegate !== self { v.delegate = self; /* debug("Delegate set to self") */ }
        if requestedStart && !externallyStopped { v.isPlaying = true; /* debug("isPlaying set to true") */ }
        if #available(iOS 13.0, *) { v.rendersContinuously = true }
    }
    // MARK: - SCNSceneRendererDelegate
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // debug("renderer:updateAtTime called: time=", time, " externallyStopped=", externallyStopped, " isPaused=", isPaused, " requestedStart=", requestedStart)
        if externallyStopped || isPaused {
            lastTime = time
            return
        }
        if !requestedStart {
            lastTime = time
            return
        }
        if lastTime == 0 {
            lastTime = time
            return
        }
        
        RenderCoordinator.shared.renderSemaphore.wait()
        defer { RenderCoordinator.shared.renderSemaphore.signal() }
        
        var dt = Float(time - lastTime)
        lastTime = time
        if dt > dtClamp { dt = dtClamp }
        if fixedTimeEnabled {
            accumulator += dt
            while accumulator >= fixedStep {
                inner.update(deltaTime: fixedStep)
                accumulator -= fixedStep
            }
        } else {
            inner.update(deltaTime: dt)
        }
        if let cb = perFrameCallback, !midiCallbackPending {
                    midiCallbackPending = true
                    DispatchQueue.main.async { [weak self] in
                        cb()
                        self?.midiCallbackPending = false
                    }
                }
    }
    // MARK: - Public Controls (forwarded)
    func setSpeedMultiplier(_ multiplier: Float) { inner.setSpeedMultiplier(multiplier) }
    func setWrappingEnabled(_ enabled: Bool) { inner.setWrappingEnabled(enabled) }
    func translate(dx: Float, dy: Float, dz: Float) { inner.translate(dx: dx, dy: dy, dz: dz) }
    func setGlobalScale(_ scale: Float) { inner.setGlobalScale(scale) }
    func reset() { inner.reset() }
    func setShowBoundsCircle(_ v: Bool) { inner.setShowBoundsCircle(v) }
    func setShowBoundsCube(_ v: Bool) { inner.setShowBoundsCube(v) }
    func setFishSize(_ size: Float) { inner.setFishSize(size) }
    // MARK: - API Forwarding for MIDI/Tracker
    @MainActor func projectedBoidXY127(index: Int) -> (x: Int, y: Int)? {
        return inner.projectedBoidXY127(index: index)
    }
    func boidVelocity(index: Int) -> SCNVector3? {
        return inner.boidVelocity(index: index)
    }
    func maxSpeedValue() -> Float {
        return inner.maxSpeedValue()
    }
    // MARK: - LifeformSimulation protocol
    func update(deltaTime: Float) { inner.update(deltaTime: deltaTime) }
    //func reset() { inner.reset() }
    // MARK: - Debug Helper
    private func debug(_ msg: String) {
        // Use ModifiedSimulationView's log instead for consistency
        // print("[BoidsSimulationAsync] " + msg)
    }
    func teardownAndDispose() {
        // Detach renderer delegate and release references
        scnView?.delegate = nil
        scnView = nil
        sceneReference = nil
        inner.teardownAndDispose()
    }
}
