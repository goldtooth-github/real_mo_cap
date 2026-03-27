// File: BarleySimulationAsync.swift
import SceneKit
import UIKit
import Foundation

// MARK: - BarleySimulationAsync (renderer-driven)
final class BarleySimulationAsync: NSObject, LifeformSimulation, SCNSceneRendererDelegate {
    // Inner synchronous core
    let inner: BarleySimulation
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
    var visualBounds: Float { inner.visualBounds }
    
    // Public model exposure
    var stalks: [BarleySimulation.Stalk] { inner.stalks }
    
    // Timing
    private var lastTime: TimeInterval = 0
    private var isPaused: Bool = false
    private let dtClamp: Float = 1.0 / 30.0         // Max delta (prevents jumps)
    private var fixedTimeEnabled = false
    private let fixedStep: Float = 1.0 / 60.0
    private var accumulator: Float = 0
    
    // Lifecycle flags (compatibility with existing callers)
    private var requestedStart: Bool = false
    private var externallyStopped: Bool = false
    
    // Initial visual state seeding
    private var didSeedInitialState = false
    
    // NEW: coalesce main-thread per-frame callback dispatch
       private var midiCallbackPending = false
    
    // Init
    init(stalkCount: Int = 40,
         stalkSpacing: Float = 2.0,
         scene: SCNScene,
         stalkColor: UIColor? = nil,
         config: LifeformViewConfig,
         scnView: SCNView? = nil) {
        self.inner = BarleySimulation(stalkCount: stalkCount,
                                      stalkSpacing: stalkSpacing,
                                      scene: scene,
                                      stalkColor: stalkColor,
                                      config: config,
                                      scnView: scnView)
        self.scnView = scnView
        super.init()
        attachRendererIfPossible()
        seedInitialVisualStateIfNeeded()
    }
    
    // LifeformSimulation
    func update(deltaTime: Float) { inner.update(deltaTime: deltaTime) }
    func reset() { inner.reset() }
    
    // Control API forwarders
    var userWindStrength: Float { get { inner.userWindStrength } set { inner.setWindStrength(newValue) } }
    func setWindStrength(_ v: Float) { inner.setWindStrength(v) }
    func setFieldScale(_ v: Float) { inner.setFieldScale(v) }
    func setFieldTilt(_ v: Float) { inner.setFieldTilt(v) }
    func setFieldYaw(_ v: Float) { inner.setFieldYaw(v) }
    func translate(dx: Float, dy: Float, dz: Float) { inner.translate(dx: dx, dy: dy, dz: dz) }
    @MainActor func projectedSeedHeadXY127(stalkIndex: Int) -> (x: Int, y: Int)? { inner.projectedSeedHeadXY127(stalkIndex: stalkIndex) }
    @MainActor func projectedSeedHeadXY127Raw(stalkIndex: Int) -> (x: Int, y: Int)? { inner.projectedSeedHeadXY127Raw(stalkIndex: stalkIndex) }
    @MainActor func seedHeadWorldPosition(stalkIndex: Int) -> SCNVector3? { inner.seedHeadWorldPosition(stalkIndex: stalkIndex) }
    
    ////-----here in the others the the stalkindex is mainactor but not here/
    
    // Camera update API
    func updateCamera(elevation: Float, azimuth: Float, radius: Float) {
        inner.updateCamera(elevation: elevation, azimuth: azimuth, radius: radius)
    }
    
    // Pause / Teardown
    @MainActor func setPaused(_ paused: Bool) {
        isPaused = paused
        inner.setSceneGraphPaused(paused)
        if let scene = sceneReference { scene.isPaused = paused }
        scnView?.isPlaying = !paused
        if paused {
            // Prevent large dt when resuming
            lastTime = 0
        }
    }
    func teardownAndDispose() {
        stopAsyncSimulation()
        inner.teardown()
        if let v = scnView { v.delegate = nil }
        scnView = nil
        sceneReference = nil
    }
    deinit { inner.teardown()
        print("barley deinit") }
    
    // Legacy async loop API (now stubs for compatibility)
    func startAsyncSimulation(updateInterval: TimeInterval = 0.016) {
        requestedStart = true
        externallyStopped = false
        attachRendererIfPossible()
    }
    func stopAsyncSimulation() {
        requestedStart = false
        externallyStopped = true
    }
    
    // Add low power mode support
    func setLowPowerMode(_ enabled: Bool) {
        inner.setLowPowerMode(enabled)
    }
    
    // Initial visual state seeding
    private func seedInitialVisualStateIfNeeded() {
        guard !didSeedInitialState else { return }
        inner.update(deltaTime: 0)
        for _ in 0..<3 {
            inner.update(deltaTime: 1.0 / 60.0)
        }
        didSeedInitialState = true
    }
    
    // Renderer attachment
    private func attachRendererIfPossible() {
        guard let v = scnView else { return }
        if v.delegate !== self {
            v.delegate = self
        }
        v.isPlaying = true
        if #available(iOS 13.0, *) {
            v.rendersContinuously = true
        }
        seedInitialVisualStateIfNeeded()
    }
    
    // SCNSceneRendererDelegate
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if externallyStopped || !requestedStart { return }
        if isPaused {
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
    
    // Optional: enable / disable fixed timestep externally
    func setFixedTime(enabled: Bool) {
        fixedTimeEnabled = enabled
        accumulator = 0
    }
}