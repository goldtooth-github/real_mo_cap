import SceneKit
import UIKit

// Renderer-driven async simulation for Planets with coalesced UI updates
final class PlanetsSimulationAsync: NSObject, LifeformSimulation, SCNSceneRendererDelegate {
    private let inner: PlanetsSimulation
    var perFrameCallback: (() -> Void)?
    private var midiCallbackPending = false
    weak var scnView: SCNView? {
        didSet { inner.scnView = scnView; inner.realignAfterViewAttached(); attachRendererIfPossible() }
    }
    var visualBounds: Float { 80.0 }
    private var lastTime: TimeInterval = 0
    private var paused: Bool = false
    private var requestedStart: Bool = true
    // Pending UI-driven values (coalesced per frame)
    private let lock = NSLock()
    private var pendTiltX: Float?
    private var pendScale: Float?
    private var pendRotationZ: Float?
    private var pendSpeed: Float?
    private var pendSpinMultiplier: Float?
    private var pendTranslateXY: SIMD2<Float> = .zero
    private var pendTranslateXZ: SIMD2<Float> = .zero
    // Init
    init(scene: SCNScene, scnView: SCNView?, isWorkbenchMode: Bool = false) {
        self.inner = PlanetsSimulation(scene: scene, scnView: scnView)
        self.scnView = scnView
        super.init()
        inner.realignAfterViewAttached()
        attachRendererIfPossible()
    }
    // Renderer hookup
    private func attachRendererIfPossible() {
        guard let v = scnView else { return }
        if v.delegate !== self { v.delegate = self }
        v.isPlaying = true
        if #available(iOS 13.0, *) { v.rendersContinuously = true }
    }
    // Lifecycle
    func startAsyncSimulation(updateInterval: TimeInterval = 0.0) { requestedStart = true; attachRendererIfPossible() }
    func stopAsyncSimulation() { requestedStart = false }
    func teardownAndDispose() { stopAsyncSimulation(); scnView?.delegate = nil; scnView = nil }
    // LifeformSimulation
    func update(deltaTime: Float) { inner.update(deltaTime: deltaTime) }
    func reset() { inner.reset() }
    // Public control API (coalesced)
    func setSimulationSpeed(_ speed: Float) { lock.lock(); pendSpeed = speed; lock.unlock() }
    func setSystemScale(_ scale: Float) { lock.lock(); pendScale = scale; lock.unlock() }
    func setSystemRotation(angle: Float) { lock.lock(); pendRotationZ = angle; lock.unlock() }
    func setSystemTiltX(angle: Float) { lock.lock(); pendTiltX = angle; lock.unlock() }
    func setSpinGlobalMultiplier(_ m: Float) { lock.lock(); pendSpinMultiplier = m; lock.unlock() }
    func translateSystem(dx: Float, dz: Float) { lock.lock(); pendTranslateXZ += SIMD2<Float>(dx, dz); lock.unlock() }
    func translateSystemXY(dx: Float, dy: Float) { lock.lock(); pendTranslateXY += SIMD2<Float>(dx, dy); lock.unlock() }
    func translate(dx: Float, dy: Float, dz: Float) { translateSystemXY(dx: dx, dy: dy); translateSystem(dx: dx, dz: dz) }
    func planetNames() -> [String] { inner.planets.map { $0.name } }
    func planetColor(name: String) -> UIColor? { inner.planets.first(where: { $0.name == name })?.color }
    @MainActor func planetWorldPosition(name: String) -> SCNVector3? {
        guard let node = inner.planets.first(where: { $0.name == name })?.node else { return nil }
        return node.presentation.convertPosition(SCNVector3Zero, to: nil)
    }
    @MainActor func projectedPlanetXY127(name: String) -> (x: Int, y: Int)? {
        guard let v = scnView, let pos = planetWorldPosition(name: name) else { return nil }
        let proj = v.projectPoint(pos)
        let w = max(v.bounds.width, 1)
        let h = max(v.bounds.height, 1)
        let xView = CGFloat(proj.x)
        let yView = h - CGFloat(proj.y)
        let x127 = Int(round(min(max(xView, 0), w) / w * 127))
        let y127 = Int(round(min(max(yView, 0), h) / h * 127))
        return (x127, y127)
    }
    @MainActor func setPaused(_ p: Bool) { paused = p; scnView?.isPlaying = !p }
    // Drain pending UI updates once per frame
    @MainActor private func drainPending() {
        lock.lock()
        let tilt = pendTiltX; pendTiltX = nil
        let scale = pendScale; pendScale = nil
        let rotZ = pendRotationZ; pendRotationZ = nil
        let speed = pendSpeed; pendSpeed = nil
        let spinMul = pendSpinMultiplier; pendSpinMultiplier = nil
        let tXY = pendTranslateXY; pendTranslateXY = .zero
        let tXZ = pendTranslateXZ; pendTranslateXZ = .zero
        lock.unlock()
        if let v = speed { inner.setSimulationSpeed(v) }
        if let s = scale { inner.setSystemScale(s) }
        if let r = rotZ { inner.setSystemRotation(angle: r) }
        if let a = tilt { inner.setSystemTiltX(angle: a) }
        if let m = spinMul { inner.setSpinGlobalMultiplier(m) }
        if tXY != .zero { inner.translateSystemXY(dx: tXY.x, dy: tXY.y) }
        if tXZ != .zero { inner.translateSystem(dx: tXZ.x, dz: tXZ.y) }
    }
    // SCNSceneRendererDelegate
    @MainActor  func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if paused || !requestedStart { return }
        if lastTime == 0 { lastTime = time; return }
        drainPending()
        
        RenderCoordinator.shared.renderSemaphore.wait()
        defer { RenderCoordinator.shared.renderSemaphore.signal() }
        
        var dt = Float(time - lastTime)
        lastTime = time
        // Clamp dt to avoid large spikes while dragging UI
        let maxStep: Float = 1.0 / 60.0
        if dt > maxStep { dt = maxStep }
        if dt > 0 { inner.update(deltaTime: dt) }
        if let cb = perFrameCallback, !midiCallbackPending {
                   midiCallbackPending = true
                   DispatchQueue.main.async { [weak self] in
                       cb()
                      self?.midiCallbackPending = false
                  }
              }
        
        
    }
}
