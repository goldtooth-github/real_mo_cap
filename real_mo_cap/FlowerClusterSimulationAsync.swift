import SceneKit
import UIKit

/// Async cluster simulation that instantiates multiple FlowerSimulation instances sharing one environment and runs via SCNSceneRendererDelegate (renderer-driven like Boids/Wave).
final class FlowerClusterSimulationAsync: NSObject, LifeformSimulation, SCNSceneRendererDelegate {
    // MARK: - Ground constraints (must match FlowerSimulation.buildGround wad radius)
    private static let groundWadRadius: Float = 7.0
    private static let edgeMargin: Float = 0.15 // keep a small margin away from edge
    
    // MARK: - Scene / view
    private let scene: SCNScene
    weak var scnView: SCNView? {
        didSet {
            if let v = scnView { flowers.forEach { $0.scnView = v } }
            attachRendererIfPossible()
        }
    }
    var visualBounds: Float { 30.0 }
    
    // MARK: - Cluster state
    private var flowers: [FlowerSimulation] = []
    private let primary: FlowerSimulation
    private let primaryConfig: FlowerConfig // stored for collision radius
    private let count: Int
    private var clusterRootNode = SCNNode()
    private var originalPositions: [SCNVector3] = []
    private let wadRadiusInstance: Float
    private let separationCoefficient: Float
    
    // MARK: - Renderer-driven timing state (mirrors BoidsSimulationAsync style)
    private var lastTime: TimeInterval = 0
    private var requestedStart: Bool = false
    private var externallyStopped: Bool = false
    private var isPaused: Bool = false
    private var dtClamp: Float = 1.0 / 30.0
    private var fixedTimeEnabled: Bool = false
    private let fixedStep: Float = 1.0 / 60.0
    private var accumulator: Float = 0
    
    // MARK: - Per-frame callback coalescing
    var perFrameCallback: (() -> Void)?
    private var midiCallbackPending = false
    
    // MARK: - Init
    init(scene: SCNScene, scnView: SCNView?, count: Int = 5, radius: Float = FlowerClusterSimulationAsync.groundWadRadius, separationCoefficient: Float = 0.6, randomizePrimary: Bool = false) {
        self.scene = scene
        self.count = max(1, count)
        self.wadRadiusInstance = min(radius, Self.groundWadRadius)
        self.separationCoefficient = max(0, separationCoefficient)
        let primaryConfig = randomizePrimary ? FlowerConfig.random() : FlowerConfig()
        self.primaryConfig = primaryConfig
        let p = FlowerSimulation(scene: scene, scnView: scnView, buildEnvironment: true, updateEnvironment: true, position: .zero, config: primaryConfig)
        self.primary = p
        self.flowers.append(p)
        self.originalPositions.append(.zero)
        self.scnView = scnView
        clusterRootNode.addChildNode(p.rootNode)
       
        scene.rootNode.addChildNode(clusterRootNode)
        super.init()
        if count > 1 { spawnAdditionalFlowers(total: count - 1, scnView: scnView) }
        attachRendererIfPossible()
    }
    
    // MARK: - Start / Stop / Pause (renderer-driven)
    @MainActor func startAsyncSimulation() {
        requestedStart = true
        externallyStopped = false
        lastTime = 0
        attachRendererIfPossible()
        scnView?.isPlaying = true
    }
    @MainActor func startAsyncSimulation(updateInterval: TimeInterval) { // backward compatibility signature
        startAsyncSimulation() // interval ignored; renderer controls timing
    }
    @MainActor func stopAsyncSimulation() { externallyStopped = true }
    @MainActor func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        scnView?.isPlaying = !paused
        primary.scnView?.scene?.isPaused = paused
    }
    
    // MARK: - Renderer delegate attach
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
                update(deltaTime: fixedStep)
                accumulator -= fixedStep
            }
        } else {
            update(deltaTime: dt)
        }
        if let cb = perFrameCallback, !midiCallbackPending {
            midiCallbackPending = true
            DispatchQueue.main.async { [weak self] in
                cb(); self?.midiCallbackPending = false
            }
        }
    }
    
    // MARK: - Setup helpers
    private func collisionRadius(for config: FlowerConfig) -> Float { (config.headRadius + config.petalLength) * 1.0 }
    private func isSeparated(candidate: SCNVector3, radius: Float, existing: [(pos: SCNVector3, rad: Float)]) -> Bool {
        for e in existing {
            let dx = candidate.x - e.pos.x
            let dz = candidate.z - e.pos.z
            let distSq = dx*dx + dz*dz
            let minDist = separationCoefficient * (radius + e.rad)
            if distSq < minDist * minDist { return false }
        }
        return true
    }
    private func spawnAdditionalFlowers(total: Int, scnView: SCNView?) {
        var spawned = 0
        var placedMeta: [(pos: SCNVector3, rad: Float)] = [(pos: .zero, rad: collisionRadius(for: primaryConfig))]
        while spawned < total {
            let cfg = FlowerConfig.random()
            let collR = collisionRadius(for: cfg)
            let allowableCenterRadius = max(0.01, wadRadiusInstance - collR - Self.edgeMargin)
            var placed = false
            for _ in 0..<400 {
                let angle = Float.random(in: 0..<(2 * .pi))
                let radial = sqrt(Float.random(in: 0...1)) * allowableCenterRadius
                let x = cos(angle) * radial
                let z = sin(angle) * radial
                let candidate = SCNVector3(x, 0, z)
                if isSeparated(candidate: candidate, radius: collR, existing: placedMeta) {
                    let f = FlowerSimulation(scene: scene, scnView: scnView, buildEnvironment: false, updateEnvironment: false, position: candidate, config: cfg)
                    flowers.append(f)
                    clusterRootNode.addChildNode(f.rootNode)
                    originalPositions.append(candidate)
                    placedMeta.append((pos: candidate, rad: collR))
                    placed = true
                    break
                }
            }
            if !placed { break }
            spawned += 1
        }
    }
    
    // MARK: - LifeformSimulation
    func update(deltaTime dt: Float) { flowers.forEach { $0.update(deltaTime: dt) } }
    func reset() {
        if flowers.count > 1 { for i in 1..<flowers.count { flowers[i].rootNode.removeFromParentNode() } }
        flowers = [primary]
        originalPositions = [.zero]
        primary.reset()
        let newCluster = SCNNode()
        scene.rootNode.addChildNode(newCluster)
        clusterRootNode.removeFromParentNode()
        clusterRootNode = newCluster
        if primary.rootNode.parent != nil { primary.rootNode.removeFromParentNode() }
        clusterRootNode.addChildNode(primary.rootNode)
        if count > 1 { spawnAdditionalFlowers(total: count - 1, scnView: scnView) }
    }
    
    // MARK: - Public controls
    func setSunOrbitSpeed(_ v: Float) { primary.setSunOrbitSpeed(v) }
    func setRainIntensity(_ v: Float) { flowers.forEach { $0.setRainIntensity(v) } }
    func setOpenness(_ v: Float) { flowers.forEach { $0.setOpenness(v) } }
    func setGlobalScale(_ s: Float) { clusterRootNode.scale = SCNVector3(s, s, s) }
    func translate(dx: Float, dy: Float, dz: Float) { clusterRootNode.position += SCNVector3(dx, dy, dz) }
    
    // MARK: - Trackers / MIDI
    func trackerNames() -> [String] { primary.trackerNames() }
    func petalState(index: Int) -> Float? { primary.petalState(index: index) }
    func flowerCount() -> Int { flowers.count }
    func projectedFlowerHeadXY127(flowerIndex: Int) -> (x: Int, y: Int)? {
        guard flowerIndex >= 0 && flowerIndex < flowers.count else { return nil }
        return flowers[flowerIndex].projectedFlowerHeadXY127()
    }
    func allFlowersLFOOutput() -> [(x: Int, y: Int, opennessRadius: Float)] { flowers.compactMap { $0.flowerLFOOutput() } }
    func allFlowerTrackerNames() -> [String] { (0..<flowers.count).flatMap { ["Flower-\($0+1).x", "Flower-\($0+1).y", "Flower-\($0+1).radius"] } }
    func allFlowerLFOTrackerValues() -> [String: Float] {
        var result: [String: Float] = [:]
        for (i, flower) in flowers.enumerated() {
            if let (x, y, radius) = flower.flowerLFOOutput() {
                result["Flower-\(i+1).x"] = Float(x)
                result["Flower-\(i+1).y"] = Float(y)
                result["Flower-\(i+1).radius"] = radius
            }
        }
        return result
    }
    // Screen-space projection wrappers for primary flower / sun / moon
    func projectedFlowerHeadXY127() -> (x: Int, y: Int)? { primary.projectedFlowerHeadXY127() }
    func projectedSunXY127() -> (x: Int, y: Int)? { primary.projectedSunXY127() }
    func projectedMoonXY127() -> (x: Int, y: Int)? { primary.projectedMoonXY127() }
    
    // MARK: - Teardown
    @MainActor func teardown() {
        stopAsyncSimulation()
        clusterRootNode.removeFromParentNode()
        scnView?.delegate = nil
        scnView = nil
        flowers.removeAll()
        originalPositions.removeAll()
    }
    
    // MARK: - Debug helper
    private func debug(_ items: Any...) { /* print("[FlowerClusterSimulationAsync]", items) */ }
    
    // MARK: - Exposed for screen clamping
    // World position of a flower head (for screen clamping)
    func flowerWorldPosition(index: Int) -> SCNVector3? {
        guard index >= 0 && index < flowers.count else { return nil }
        return flowers[index].flowerHeadWorldPosition()
    }
    
    /// Adjust cluster root position by delta (used for screen clamping)
    func adjustClusterPosition(dx: Float, dy: Float, dz: Float) {
        clusterRootNode.position.x += dx
        clusterRootNode.position.y += dy
        clusterRootNode.position.z += dz
    }
}