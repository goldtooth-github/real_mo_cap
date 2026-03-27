import SceneKit
import UIKit
import simd

// MARK: - Backward compatibility typealiases (old async-specific names)
typealias FloatingDebrisAsync = FloatingDebris
typealias LighthouseBuoyParametersAsync = LighthouseBuoyParameters

// MARK: - WaveAndLeavesSimulationAsync (renderer-driven wrapper)
final class WaveAndLeavesSimulationAsync: NSObject, LifeformSimulation, SCNSceneRendererDelegate {
    // Inner synchronous simulation
    public let inner: WaveAndLeavesSimulation
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
    // Optional per-frame callback (coalesced on main queue)
    var perFrameCallback: (() -> Void)?
    private var midiCallbackPending = false
    // Timing state (mirrors BoidsSimulationAsync)
    private var lastTime: TimeInterval = 0
    private var isPaused: Bool = false
    private var jointPositions: [String: SCNVector3] = [:]
    private var jointNodes: [String: SCNNode] = [:]
    private var dtClamp: Float = 1.0 / 30.0
    private var fixedTimeEnabled: Bool = false
    private let fixedStep: Float = 1.0 / 60.0
    private var accumulator: Float = 0
    private var externallyStopped: Bool = false
    private var requestedStart: Bool = false
    // MARK: - Exposed convenience
    var simulationRootNode: SCNNode { inner.simulationRootNode }
    var visualBounds: Float { inner.visualBounds }
    var debris: [FloatingDebris] { inner.debris }
    // MARK: - Init
    init(scene: SCNScene, scnView: SCNView?, buoyParams: LighthouseBuoyParameters? = nil, buoyAnchorXZ: SIMD2<Float>? = nil, addBuoy: Bool = true) {
        self.inner = WaveAndLeavesSimulation(scene: scene, scnView: scnView, buoyParams: buoyParams, buoyAnchorXZ: buoyAnchorXZ, addBuoy: addBuoy)
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
    // Backward compatibility signature (interval ignored because renderer drives timing)
    @MainActor func startAsyncSimulation(updateInterval: TimeInterval) { startAsyncSimulation() }
    @MainActor func stopAsyncSimulation() { externallyStopped = true }
    @MainActor func setPaused(_ paused: Bool) {
        isPaused = paused
        setSceneGraphPaused(paused)
        scnView?.isPlaying = !paused
    }
    private func setSceneGraphPaused(_ paused: Bool) { inner.scnView?.scene?.isPaused = paused }
    // MARK: - Renderer attach
    private func attachRendererIfPossible() {
        guard let v = scnView else { return }
        if v.delegate !== self { v.delegate = self }
        if requestedStart && !externallyStopped { v.isPlaying = true }
        if #available(iOS 13.0, *) { v.rendersContinuously = true }
    }
    // MARK: - SCNSceneRendererDelegate
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if externallyStopped || isPaused { lastTime = time; return }
        if !requestedStart { lastTime = time; return }
        if lastTime == 0 { lastTime = time; return }
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
                cb(); self?.midiCallbackPending = false
            }
        }
    }
    // MARK: - LifeformSimulation
    func update(deltaTime: Float) { inner.update(deltaTime: deltaTime) }
    func reset() { inner.reset() }
    // MARK: - Forwarded API (Wave controls)
    func setSimulationSpeed(_ speed: Float) { inner.setSimulationSpeed(speed) }
    func setSpeedMultiplier(_ multiplier: Float) { inner.setSimulationSpeed(multiplier) } // compatibility alias
    func setWaveAmplitude(_ amp: Float) { inner.setWaveAmplitude(amp) }
    func setWaveFrequency(_ freq: Float) { inner.setWaveFrequency(freq) }
    func setLeafBuoyancy(_ buoy: Float) { inner.setLeafBuoyancy(buoy) }
    func setGlobalScale(_ scale: Float) { inner.setGlobalScale(scale) }
    func setWaveResolution(_ res: Int) { inner.setWaveResolution(res) }
    // Second wave
    func setSecondWaveAmplitude(_ amp: Float) { inner.setSecondWaveAmplitude(amp) }
    func setSecondWaveFrequency(_ freq: Float) { inner.setSecondWaveFrequency(freq) }
    func setSecondWaveDirectionDegrees(_ deg: Float) { inner.setSecondWaveDirectionDegrees(deg) }
    func setSecondWavePhaseOffset(_ phase: Float) { inner.setSecondWavePhaseOffset(phase) }
    func setSecondWaveSpeedFactor(_ factor: Float) { inner.setSecondWaveSpeedFactor(factor) }
    // Third wave
    func setThirdWaveAmplitude(_ amp: Float) { inner.setThirdWaveAmplitude(amp) }
    func setThirdWaveFrequency(_ freq: Float) { inner.setThirdWaveFrequency(freq) }
    func setThirdWaveDirectionDegrees(_ deg: Float) { inner.setThirdWaveDirectionDegrees(deg) }
    func setThirdWavePhaseOffset(_ phase: Float) { inner.setThirdWavePhaseOffset(phase) }
    func setThirdWaveSpeedFactor(_ factor: Float) { inner.setThirdWaveSpeedFactor(factor) }
    // Primary wave
    func setPrimaryWaveDirectionDegrees(_ deg: Float) { inner.setPrimaryWaveDirectionDegrees(deg) }
    func setPrimaryWavePhaseOffset(_ phase: Float) { inner.setPrimaryWavePhaseOffset(phase) }
    func setPrimaryWaveSpeedFactor(_ factor: Float) { inner.setPrimaryWaveSpeedFactor(factor) }
    func setPrimaryAmpMod(depth: Float? = nil, spatialFreq: Float? = nil, phase: Float? = nil) { inner.setPrimaryAmpMod(depth: depth, spatialFreq: spatialFreq, phase: phase) }
    func setPrimaryFreqMod(depth: Float? = nil, spatialFreq: Float? = nil, phase: Float? = nil) { inner.setPrimaryFreqMod(depth: depth, spatialFreq: spatialFreq, phase: phase) }
    // Wind & Foam
    func setWindGust(enabled: Bool? = nil, frequency: Float? = nil, secondaryFrequency: Float? = nil, secondaryMix: Float? = nil, amplitude: Float? = nil, speedFactor: Float? = nil, phase: Float? = nil) {
        inner.setWindGust(enabled: enabled, frequency: frequency, secondaryFrequency: secondaryFrequency, secondaryMix: secondaryMix, amplitude: amplitude, speedFactor: speedFactor, phase: phase)
    }
    func setFoam(enabled: Bool? = nil, slopeThreshold: Float? = nil, slopeRange: Float? = nil, heightThreshold: Float? = nil, intensity: Float? = nil) {
        inner.setFoam(enabled: enabled, slopeThreshold: slopeThreshold, slopeRange: slopeRange, heightThreshold: heightThreshold, intensity: intensity)
    }
    // Translation
    func translate(dx: Float, dy: Float, dz: Float) { inner.translate(dx: dx, dy: dy, dz: dz) }
    // Tracking & projection helpers
    @MainActor func projectedJointXY127(jointName: String) -> (x: Int, y: Int)? { inner.projectedJointXY127(jointName: jointName) }
    func buoyBaseWorldPosition() -> SCNVector3? { inner.buoyBaseWorldPosition() }
    func buoyLightWorldPosition() -> SCNVector3? { inner.buoyLightWorldPosition() }
    func buoyBaseScreenXY127() -> (x: Int, y: Int)? { inner.buoyBaseScreenXY127() }
 
    func buoyLightScreenXY127() -> (x: Int, y: Int)? { inner.buoyLightScreenXY127() }
    func buoyAngle() -> Float? { inner.buoyAngle() }
    func lightRotation() -> Float? { inner.lightRotation() }
    // Buoy controls
    func addLighthouseBuoy(anchorXZ: SIMD2<Float>? = nil, params: LighthouseBuoyParametersAsync = .default) { inner.addLighthouseBuoy(anchorXZ: anchorXZ, params: params) }
    func removeLighthouseBuoy() { inner.removeLighthouseBuoy() }
    func updateLighthouseBuoyParameters(_ mutate: (inout LighthouseBuoyParameters) -> Void) { inner.updateLighthouseBuoyParameters(mutate) }
    func updateLighthouseBuoyParametersAsync(_ mutate: (inout LighthouseBuoyParametersAsync) -> Void) { inner.updateLighthouseBuoyParameters { mutate(&($0)) } }
    // Night mode
    func setNight(_ night: Bool) { inner.setNight(night) }
    // MARK: - Teardown
    func teardownAndDispose() {
        scnView?.delegate = nil
        scnView = nil
        sceneReference = nil
    }
    @MainActor func jointWorldPosition(_ name: String) -> SCNVector3? {
        if let node = jointNodes[name] { return node.worldPosition }
        if let pos = jointPositions[name] {
            let world = pos.applyingMatrix(simulationRootNode.worldTransform)
            return world
        }
        return nil
    }
    // MARK: - Debug
    private func debug(_ items: Any...) { /* print("[WaveAndLeavesSimulationAsync]", items) */ }
}
