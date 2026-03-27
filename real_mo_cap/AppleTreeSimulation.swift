import SceneKit
import UIKit
import Foundation

// MARK: - AppleTreeSimulation (synchronous core)
final class AppleTreeSimulation: LifeformSimulation {
    // MARK: - Public model data
    struct Branch {
        var position: SIMD3<Float>
        var length: Float
        var angle: Float
        var node: SCNNode?
        var leaves: [Leaf]
        var fruits: [Fruit]
    }
    struct Leaf {
        var position: SIMD3<Float>
        var node: SCNNode?
    }
    struct Fruit {
        var position: SIMD3<Float>
        var isEaten: Bool
        var node: SCNNode?
    }
    struct Ant {
        var position: SIMD3<Float>
        var carryingFruit: Bool
        var node: SCNNode?
        var path: [SIMD3<Float>]
        var targetFruitIndex: Int?
        var returningToNest: Bool
    }
    struct Nest {
        var position: SIMD3<Float>
        var node: SCNNode?
    }

    // Entities
    var branches: [Branch] = []
    var ants: [Ant] = []
    var nest: Nest?

    // Scene refs
    weak var sceneRef: SCNScene?
    weak var scnView: SCNView?
    let treeContainer = SCNNode()

    // Parameters & state
    var antCount: Int
    var branchCount: Int
    var fruitSpawnRate: Float
    private var time: Float = 0.0
    private var lastFruitSpawnTime: Float = 0.0
    private var fruitSpawnInterval: Float { max(0.5, 3.0 / max(0.1, fruitSpawnRate)) }
    private let config: LifeformViewConfig
    private(set) var isPaused: Bool = false
    private(set) var isLowPowerMode: Bool = false

    // MARK: - Init
    init(antCount: Int = 6, branchCount: Int = 4, fruitSpawnRate: Float = 1.0, scene: SCNScene, config: LifeformViewConfig, scnView: SCNView?) {
        self.antCount = antCount
        self.branchCount = branchCount
        self.fruitSpawnRate = fruitSpawnRate
        self.sceneRef = scene
        self.config = config
        self.scnView = scnView
        print("[AppleTreeSimulation] init - adding treeContainer to scene")
        scene.rootNode.addChildNode(treeContainer)
        setupLighting(scene: scene)
        setupTree()
        setupNest()
        setupAnts()
        for _ in 0..<3 { spawnFruit() }
        print("[AppleTreeSimulation] init complete - branches: \(branches.count), ants: \(ants.count), nest: \(nest != nil)")
    }

    // MARK: - LifeformSimulation
    func update(deltaTime: Float) {
        guard !isPaused else { return }
        step(deltaTime: deltaTime)
    }

    func reset() {
        removeAll()
        setupTree()
        setupNest()
        setupAnts()
        for _ in 0..<3 { spawnFruit() }
    }

    func teardown() {
        removeAll()
        treeContainer.removeFromParentNode()
        sceneRef = nil
        scnView = nil
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        treeContainer.isPaused = paused
        treeContainer.enumerateChildNodes { n, _ in n.isPaused = paused }
    }

    func setLowPowerMode(_ enabled: Bool) {
        isLowPowerMode = enabled
        if enabled {
            let keep = min(ants.count, max(1, antCount / 2))
            while ants.count > keep {
                if let a = ants.popLast(), let n = a.node { n.removeFromParentNode() }
            }
        } else {
            while ants.count < antCount { addAnt() }
        }
    }

    // MARK: - Core step
    private func step(deltaTime: Float) {
        time += deltaTime
        if time - lastFruitSpawnTime > fruitSpawnInterval {
            spawnFruit()
            lastFruitSpawnTime = time
        }

        for i in 0..<ants.count {
            guard let antNode = ants[i].node else { continue }
            if antNode.hasActions { continue }
            if ants[i].carryingFruit { continue }

            if let (bIdx, fIdx) = firstAvailableFruit() {
                branches[bIdx].fruits[fIdx].isEaten = true
                guard let fruitNode = branches[bIdx].fruits[fIdx].node, let nestNode = nest?.node else { continue }

                let moveToFruit = SCNAction.move(to: fruitNode.worldPosition, duration: 0.9)
                let pickUp = SCNAction.run { _ in
                    fruitNode.isHidden = true
                    self.ants[i].carryingFruit = true
                }
                let moveToNest = SCNAction.move(to: nestNode.worldPosition, duration: 0.9)
                let drop = SCNAction.run { _ in
                    self.ants[i].carryingFruit = false
                    fruitNode.removeFromParentNode()
                    self.branches[bIdx].fruits[fIdx].node = nil
                }
                let seq = SCNAction.sequence([moveToFruit, pickUp, moveToNest, drop])
                antNode.runAction(seq)
            } else {
                let dx = Float.random(in: -0.4...0.4)
                let dz = Float.random(in: -0.4...0.4)
                let target = SCNVector3(antNode.position.x + dx, antNode.position.y, antNode.position.z + dz)
                let a = SCNAction.move(to: target, duration: TimeInterval(Float.random(in: 1.0...2.5)))
                let back = SCNAction.move(to: antNode.position, duration: TimeInterval(Float.random(in: 1.0...2.5)))
                let seq = SCNAction.sequence([a, back])
                let rep = SCNAction.repeatForever(seq)
                antNode.runAction(rep, forKey: "wander")
            }
        }
    }

    private func firstAvailableFruit() -> (branchIndex: Int, fruitIndex: Int)? {
        for (bi, b) in branches.enumerated() {
            for (fi, f) in b.fruits.enumerated() {
                if !f.isEaten && f.node != nil { return (bi, fi) }
            }
        }
        return nil
    }

    private func spawnFruit() {
        guard !branches.isEmpty else { return }
        let bi = Int.random(in: 0..<branches.count)
        let b = branches[bi]
        let t = Float.random(in: 0.2...0.95)
        if let branchNode = b.node, let root = sceneRef?.rootNode {
            let local = SCNVector3(0, b.length * t, 0)
            let world = branchNode.convertPosition(local, to: root)
            let sphere = SCNSphere(radius: 0.12)
            sphere.firstMaterial?.diffuse.contents = UIColor.red
            let fruitNode = SCNNode(geometry: sphere)
            fruitNode.position = world
            root.addChildNode(fruitNode)
            let fruit = Fruit(position: SIMD3<Float>(fruitNode.worldPosition.x, fruitNode.worldPosition.y, fruitNode.worldPosition.z), isEaten: false, node: fruitNode)
            branches[bi].fruits.append(fruit)
            print("[AppleTreeSimulation] spawned fruit at branch \(bi)")
        }
    }

    private func setupLighting(scene: SCNScene) {
        let ambient = SCNLight(); ambient.type = .ambient; ambient.intensity = 400
        let ambientNode = SCNNode(); ambientNode.light = ambient; scene.rootNode.addChildNode(ambientNode)
        let directional = SCNLight(); directional.type = .directional; directional.intensity = 1000
        let dirNode = SCNNode(); dirNode.light = directional; dirNode.eulerAngles = SCNVector3(-Float.pi/4, Float.pi/4, 0)
        scene.rootNode.addChildNode(dirNode)
    }

    private func setupTree() {
        print("[AppleTreeSimulation] setupTree start")
        let trunk = SCNCylinder(radius: 0.18, height: 3.0)
        trunk.firstMaterial?.diffuse.contents = UIColor.brown
        let trunkNode = SCNNode(geometry: trunk)
        trunkNode.position = SCNVector3(0, 1.5, 0)
        trunkNode.eulerAngles = SCNVector3(0, 0, -0.25)
        treeContainer.addChildNode(trunkNode)
        print("[AppleTreeSimulation] trunk added")

        branches.removeAll()
        for i in 0..<branchCount {
            let length = Float.random(in: 1.0...2.2)
            let angle = Float.random(in: -0.6...0.6)
            let branchGeom = SCNCapsule(capRadius: 0.06, height: CGFloat(length))
            branchGeom.firstMaterial?.diffuse.contents = UIColor.brown
            let branchNode = SCNNode(geometry: branchGeom)
            let yPos: Float = Float(1.0 + Float(i) * 0.5)
            branchNode.position = SCNVector3(0, yPos, 0)
            branchNode.eulerAngles = SCNVector3(-Float.pi/2 + angle, 0, Float.random(in: -0.8...0.8))
            trunkNode.addChildNode(branchNode)

            var leaves: [Leaf] = []
            for _ in 0..<3 {
                let leafGeom = SCNSphere(radius: 0.08)
                leafGeom.firstMaterial?.diffuse.contents = UIColor.green
                let leafNode = SCNNode(geometry: leafGeom)
                let lx = Float.random(in: -0.25...0.25)
                let ly = Float.random(in: 0.1...length - 0.1)
                let lz = Float.random(in: -0.15...0.15)
                leafNode.position = SCNVector3(lx, ly, lz)
                branchNode.addChildNode(leafNode)
                leaves.append(Leaf(position: SIMD3<Float>(leafNode.worldPosition.x, leafNode.worldPosition.y, leafNode.worldPosition.z), node: leafNode))
            }

            let branch = Branch(position: SIMD3<Float>(branchNode.worldPosition.x, branchNode.worldPosition.y, branchNode.worldPosition.z), length: length, angle: angle, node: branchNode, leaves: leaves, fruits: [])
            branches.append(branch)
        }
        print("[AppleTreeSimulation] setupTree complete - created \(branches.count) branches")
    }

    private func setupNest() {
        let nestGeom = SCNSphere(radius: 0.25)
        nestGeom.firstMaterial?.diffuse.contents = UIColor.darkGray
        let nestNode = SCNNode(geometry: nestGeom)
        nestNode.position = SCNVector3(-0.8, 0.2, 0)
        treeContainer.addChildNode(nestNode)
        nest = Nest(position: SIMD3<Float>(nestNode.worldPosition.x, nestNode.worldPosition.y, nestNode.worldPosition.z), node: nestNode)
        print("[AppleTreeSimulation] nest created")
    }

    private func setupAnts() {
        ants.removeAll()
        for _ in 0..<antCount {
            addAnt()
        }
        print("[AppleTreeSimulation] created \(ants.count) ants")
    }

    private func addAnt() {
        guard let nestNode = nest?.node else { return }
        let antGeom = SCNSphere(radius: 0.06)
        antGeom.firstMaterial?.diffuse.contents = UIColor.black
        let antNode = SCNNode(geometry: antGeom)
        antNode.position = nestNode.position
        treeContainer.addChildNode(antNode)
        let ant = Ant(position: SIMD3<Float>(antNode.worldPosition.x, antNode.worldPosition.y, antNode.worldPosition.z), carryingFruit: false, node: antNode, path: [], targetFruitIndex: nil, returningToNest: false)
        ants.append(ant)
    }

    private func removeAll() {
        treeContainer.enumerateChildNodes { n, _ in n.removeFromParentNode() }
        branches.removeAll()
        ants.removeAll()
        nest = nil
    }
}