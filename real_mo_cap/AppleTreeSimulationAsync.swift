import SceneKit
import UIKit
import Foundation

// MARK: - AppleTreeSimulationAsync (renderer-driven)
final class AppleTreeSimulationAsync: NSObject, LifeformSimulation, SCNSceneRendererDelegate {
    // Inner synchronous core
    let inner: AppleTreeSimulation
    var perFrameCallback: (() -> Void)?

    // Scene bridging
    var sceneReference: SCNScene? {
        get { inner.sceneRef }
        set { inner.sceneRef = newValue }
    }
    weak var scnView: SCNView? {
        didSet {
            inner.scnView = scnView
            attachRendererIfPossible()
        }
    }
    // Add visualBounds if needed

    // Timing
    private var lastTime: TimeInterval = 0
    private var isPaused: Bool = false
    private let dtClamp: Float = 1.0 / 30.0
    private var fixedTimeEnabled = false
    private let fixedStep: Float = 1.0 / 60.0
    private var accumulator: Float = 0

    // Lifecycle flags
    private var requestedStart: Bool = false
    private var externallyStopped: Bool = false

    // Init
    init(antCount: Int = 10,
         branchCount: Int = 5,
         fruitSpawnRate: Float = 1.0,
         scene: SCNScene,
         config: LifeformViewConfig,
         scnView: SCNView? = nil) {
        self.inner = AppleTreeSimulation(antCount: antCount,
                                         branchCount: branchCount,
                                         fruitSpawnRate: fruitSpawnRate,
                                         scene: scene,
                                         config: config,
                                         scnView: scnView)
        self.scnView = scnView
        super.init()
        attachRendererIfPossible()
    }

    // LifeformSimulation
    func update(deltaTime: Float) { inner.update(deltaTime: deltaTime) }
    func reset() { inner.reset() }

    // Pause / Teardown
    @MainActor func setPaused(_ paused: Bool) {
        isPaused = paused
        inner.treeContainer.isPaused = paused
        if let scene = sceneReference { scene.isPaused = paused }
        scnView?.isPlaying = !paused
        if paused { lastTime = 0 }
    }
    func teardownAndDispose() {
        stopAsyncSimulation()
        inner.teardown()
        if let v = scnView { v.delegate = nil }
        scnView = nil
        sceneReference = nil
    }

    // Async loop
    func startAsyncSimulation(updateInterval: TimeInterval = 0.016) {
        requestedStart = true
        externallyStopped = false
        attachRendererIfPossible()
        print("[AppleTreeSimulationAsync] startAsyncSimulation requested")
    }
    func stopAsyncSimulation() {
        requestedStart = false
        externallyStopped = true
        print("[AppleTreeSimulationAsync] stopAsyncSimulation requested")
    }

    // Renderer attachment
    private func attachRendererIfPossible() {
        guard let v = scnView else { return }
        if v.delegate !== self { v.delegate = self }
        v.isPlaying = true
        if #available(iOS 13.0, *) { v.rendersContinuously = true }
    }

    // SCNSceneRendererDelegate
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // Debug: indicate renderer called at least once
        if lastTime == 0 { print("[AppleTreeSimulationAsync] renderer first update") }
        if externallyStopped || !requestedStart { return }
        if isPaused { lastTime = time; return }
        if lastTime == 0 { lastTime = time; return }
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
        if let cb = perFrameCallback {
            DispatchQueue.main.async { cb() }
        }
    }
    // Optional: enable / disable fixed timestep externally
    func setFixedTime(enabled: Bool) {
        fixedTimeEnabled = enabled
        accumulator = 0
    }
}