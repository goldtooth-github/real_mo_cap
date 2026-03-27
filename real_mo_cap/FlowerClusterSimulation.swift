import SceneKit
import SwiftUI

/// Cluster simulation that instantiates multiple FlowerSimulation instances sharing one environment.
class FlowerClusterSimulation: LifeformSimulation {
    // Wad radius should match FlowerSimulation's ground wad (buildGround uses 7.0)
    private static let groundWadRadius: Float = 7.0
    private static let edgeMargin: Float = 0.15
    private var flowers: [FlowerSimulation] = []
    private let primary: FlowerSimulation
    private let count: Int
    
    private let scene: SCNScene
    private var randomSeedPositions: [SCNVector3] = []
    // Store collision radii for spacing
    private var flowerCollisionData: [(position: SCNVector3, radius: Float)] = []
    private let separationCoefficient: Float
    private let wadRadiusInstance: Float
    // Store original (unscaled) positions for scaling
    private var originalPositions: [SCNVector3] = []
    private var currentScale: Float = 1.0
    
    // Add a root node for the cluster
    private var clusterRootNode = SCNNode()
    
    /// - Parameters:
    ///   - radius: Maximum area radius for flower centers (should be <= ground wad radius).
    ///   - separationCoefficient: Multiplier applied to sum of two flowers' collision radii to enforce minimum center distance.
    init(scene: SCNScene, scnView: SCNView?, count: Int = 5, radius: Float = groundWadRadius, separationCoefficient: Float = 0.6, randomizePrimary: Bool = false) {
        self.scene = scene
        self.count = max(1, count)
        self.separationCoefficient = max(0, separationCoefficient)
        // Clamp radius to ground wad radius
        self.wadRadiusInstance = min(radius, Self.groundWadRadius)
        // Primary builds & updates environment
        let primaryConfig = randomizePrimary ? FlowerConfig.random() : FlowerConfig()
        primary = FlowerSimulation(scene: scene, scnView: scnView, buildEnvironment: true, updateEnvironment: true, position: .zero, config: primaryConfig)
        flowers.append(primary)
        let primaryRadius = collisionRadius(for: primaryConfig)
        flowerCollisionData.append((.zero, primaryRadius))
        originalPositions.append(.zero) // Primary always at origin
        clusterRootNode.addChildNode(primary.rootNode)
        if count > 1 { spawnAdditionalFlowers(total: count - 1, scnView: scnView) }
        scene.rootNode.addChildNode(clusterRootNode)
    }
    
    /// Compute a collision radius (approx flower horizontal extent) for spacing.
    private func collisionRadius(for config: FlowerConfig) -> Float { (config.headRadius + config.petalLength) * 1.0 }
    
    /// Attempt to spawn additional flowers with separation constraint.
    private func spawnAdditionalFlowers(total: Int, scnView: SCNView?) {
        var spawned = 0
        let maxAttemptsPerFlower = 400
        while spawned < total {
            let config = FlowerConfig.random()
            let collR = collisionRadius(for: config)
            // Ensure candidate center stays inside wad radius accounting for own radius and margin
            let allowableCenterRadius = max(0.01, wadRadiusInstance - collR - Self.edgeMargin)
            var placed = false
            for _ in 0..<maxAttemptsPerFlower {
                let angle = Float.random(in: 0..<(2 * .pi))
                // sqrt for uniform density across disk
                let radial = sqrt(Float.random(in: 0...1)) * allowableCenterRadius
                let x = cos(angle) * radial
                let z = sin(angle) * radial
                let candidate = SCNVector3(x, 0, z)
                // Ensure candidate is within wad bounds and separated from others
                if isSeparated(candidate: candidate, radius: collR) {
                    randomSeedPositions.append(candidate)
                    let f = FlowerSimulation(scene: scene, scnView: scnView, buildEnvironment: false, updateEnvironment: false, position: candidate, config: config)
                    flowers.append(f)
                    flowerCollisionData.append((candidate, collR))
                    originalPositions.append(candidate) // Store unscaled position
                    clusterRootNode.addChildNode(f.rootNode)
                    placed = true
                    break
                }
            }
            if !placed { break } // Cannot place more respecting spacing
            spawned += 1
        }
    }
    
    /// Validate candidate maintains required separation from all existing flowers.
    private func isSeparated(candidate: SCNVector3, radius: Float) -> Bool {
        for existing in flowerCollisionData {
            let dx = candidate.x - existing.position.x
            let dz = candidate.z - existing.position.z
            let distSq = dx*dx + dz*dz
            let minDist = separationCoefficient * (radius + existing.radius)
            if distSq < minDist * minDist { return false }
        }
        return true
    }
    
    // MARK: - LifeformSimulation
    func update(deltaTime: Float) { for f in flowers { f.update(deltaTime: deltaTime) } }
    func reset() { for f in flowers { f.reset() } }
    
    // MARK: - Control pass-through (propagate to all where sensible)
    func setSunOrbitSpeed(_ v: Float) { primary.setSunOrbitSpeed(v) }
    func setRainIntensity(_ v: Float) { flowers.forEach { $0.setRainIntensity(v) } }
    func setOpenness(_ v: Float) { flowers.forEach { $0.setOpenness(v) } }
    func setGlobalScale(_ s: Float) {
        clusterRootNode.scale = SCNVector3(s, s, s)
        // Removed per-flower scaling to avoid double-scaling
    }
    func translate(dx: Float, dy: Float, dz: Float) {
        clusterRootNode.position.x += dx
        clusterRootNode.position.y += dy
        clusterRootNode.position.z += dz
    }
    
    // MARK: - SCNView handling
    var scnView: SCNView? {
        get { primary.scnView }
        set { if let v = newValue { flowers.forEach { $0.scnView = v } } }
    }
    func setSCNView(_ v: SCNView) { flowers.forEach { $0.scnView = v } }
    
    // MIDI helpers (delegate to primary for now)
    func trackerNames() -> [String] { primary.trackerNames() }
    func petalState(index: Int) -> Float? { primary.petalState(index: index) }
    
    /// Returns an array of (x, y, opennessRadius) for all flowers in the cluster.
    func allFlowersLFOOutput() -> [(x: Int, y: Int, opennessRadius: Float)] {
        return flowers.compactMap { $0.flowerLFOOutput() }
    }

    /// Returns tracker names for all flowers in the cluster for MIDI/LFO output.
    func allFlowerTrackerNames() -> [String] {
        var names: [String] = []
        for (i, _) in flowers.enumerated() {
            names.append(contentsOf: ["Flower-\(i+1).x", "Flower-\(i+1).y", "Flower-\(i+1).radius"])
        }
        return names
    }

    /// Returns a dictionary mapping tracker names to their values for MIDI/LFO output.
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
}
