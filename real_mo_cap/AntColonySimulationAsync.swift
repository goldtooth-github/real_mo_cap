// File: AntColonySimulationAsync.swift
import SceneKit
import UIKit
import Foundation

// MARK: - AntColonySimulationAsync (renderer-driven)
final class AntColonySimulationAsync: NSObject, LifeformSimulation, SCNSceneRendererDelegate {
    // Inner synchronous core
    let inner: AntColonySimulation
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
    var ants: [AntColonySimulation.Ant] { inner.ants }
    var foodSources: [AntColonySimulation.FoodSource] { inner.foodSources }
    var nest: AntColonySimulation.Nest? { inner.nest }
    
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
    
    // Initial visual state seeding
    private var didSeedInitialState = false
    
    // Coalesce main-thread per-frame callback dispatch
    private var debugLogging = false
    private var midiCallbackPending = false  // ADD THIS LINE
    // Init
    init(antCount: Int = 15,
         foodSourceCount: Int = 5,
         scene: SCNScene,
         config: LifeformViewConfig,
         scnView: SCNView? = nil) {
        self.inner = AntColonySimulation(
            antCount: antCount,
            foodSourceCount: foodSourceCount,
            scene: scene,
            config: config,
            scnView: scnView
        )
        self.scnView = scnView
        super.init()
        attachRendererIfPossible()
        seedInitialVisualStateIfNeeded()
    }
    
    // LifeformSimulation
    func update(deltaTime: Float) { inner.update(deltaTime: deltaTime) }
    func reset() { inner.reset() }
    
    // Control API forwarders
    func setWorldScale(_ v: Float) { inner.setWorldScale(v) }
    func setWorldTilt(_ v: Float) { inner.setWorldTilt(v) }
    func setWorldYaw(_ v: Float) { inner.setWorldYaw(v) }
    func translate(dx: Float, dy: Float, dz: Float) { inner.translate(dx: dx, dy: dy, dz: dz) }
    
    @MainActor func projectedAntXY127(antIndex: Int) -> (x: Int, y: Int)? {
        inner.projectedAntXY127(antIndex: antIndex)
    }
    
    @MainActor func projectedFoodXY127(foodIndex: Int) -> (x: Int, y: Int)? {
        inner.projectedFoodXY127(foodIndex: foodIndex)
    }
    
    // Pause / Teardown
    @MainActor func setPaused(_ paused: Bool) {
        isPaused = paused
        inner.setSceneGraphPaused(paused)
        if let scene = sceneReference { scene.isPaused = paused }
        scnView?.isPlaying = !paused
        if paused {
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
        print("ant deiniti") }
    
    // Legacy async loop API
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
