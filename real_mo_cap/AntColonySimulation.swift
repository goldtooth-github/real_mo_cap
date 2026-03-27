import SceneKit
import UIKit

// MARK: - AntColonySimulation (synchronous core)
final class AntColonySimulation: LifeformSimulation {
    // MARK: - Public model data
    enum AntState {
        case seekingFood
        case carryingFood
        case returningToNest
    }
    
    struct Ant {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var state: AntState
        var targetFoodIndex: Int?
        var color: UIColor
        var node: SCNNode?
        var speed: Float
        var carryingFoodVisual: SCNNode? = nil
        // Wandering
        var wanderDirection: SIMD3<Float> = SIMD3<Float>(1, 0, 0)
        var lastWanderUpdateTime: Float = 0
        var pheromoneIgnoreUntil: Float = 0  // Time until the ant ignores pheromones
    }
    
    struct FoodSource {
        var position: SIMD3<Float>
        var size: Float
        var node: SCNNode?
        var color: UIColor
    }
    
    struct Nest {
        var position: SIMD3<Float>
        var node: SCNNode?
    }
    
    struct PheromoneTrail {
        var position: SIMD3<Float>
        var foodIndex: Int
        var strength: Float
        var createdTime: Float
        var node: SCNNode?
        var directionToFood: SIMD3<Float>
    }
    
    var pheromoneTrails: [PheromoneTrail] = []
    private let pheromoneDecayRate: Float = 0.01     // per second
    private let pheromoneLifetime: Float = 4.0     // seconds
    private let pheromoneDropInterval: Float = 0.2  // seconds
    private var lastPheromoneDropTime: [Int: Float] = [:]  // antIndex → time
    var ants: [Ant] = []
    var foodSources: [FoodSource] = []
    var nest: Nest?
    
    // MARK: - Scene refs
    weak var sceneRef: SCNScene?
    weak var scnView: SCNView?
    private let worldContainer = SCNNode()
    
    // MARK: - Parameters & state
    let antCount: Int
    let foodSourceCount: Int
    let worldRadius: Float = 30.0
    private var time: Float = 0.0
    private let config: LifeformViewConfig
    
    private(set) var worldScale: Float = 1.0
    private(set) var worldTilt: Float = 0.0
    private(set) var worldYaw: Float = 0.0
    var worldYOffset: Float = 0.0
    
    // Lighting
    private var directionalLightNode: SCNNode?
    
    // MARK: - Visual bounds
    var visualBounds: Float { worldRadius * 2 }
    
    // MARK: - Init
    init(antCount: Int = 15,
         foodSourceCount: Int = 5,
         scene: SCNScene,
         config: LifeformViewConfig,
         scnView: SCNView?) {
        self.antCount = antCount
        self.foodSourceCount = foodSourceCount
        self.sceneRef = scene
        self.config = config
        self.scnView = scnView
        scene.rootNode.addChildNode(worldContainer)
        setupGround()
        setupNest()
        setupFoodSources()
        setupAnts()
        addDirectionalLight(to: scene)
        finalizeWorldPivot()
        applyWorldScale()
        applyWorldOrientation()
    }
    
    // MARK: - LifeformSimulation
    func update(deltaTime: Float) { step(deltaTime: deltaTime) }
    func reset() {
        let preservedPosition = worldContainer.position
        let preservedPivot = worldContainer.pivot
        let preservedEuler = worldContainer.eulerAngles
        let preservedScale = worldContainer.scale
        
        removeAllEntities()
        if let scene = sceneRef {
            setupNest()
            setupFoodSources()
            setupAnts()
        }
        finalizeWorldPivot()
        applyWorldScale()
        applyWorldOrientation()
        
        worldContainer.pivot = preservedPivot
        worldContainer.scale = preservedScale
        worldContainer.eulerAngles = preservedEuler
        worldContainer.position = preservedPosition
    }
    
    // MARK: - Public control API
    func setWorldScale(_ scale: Float) {
        let clamped = max(0.05, scale)
        guard abs(clamped - worldScale) > 0.0001 else { return }
        worldScale = clamped
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0
        applyWorldScale()
        SCNTransaction.commit()
    }
    func setWorldTilt(_ angle: Float) { worldTilt = angle; applyWorldOrientation() }
    func setWorldYaw(_ angle: Float) { worldYaw = angle; applyWorldOrientation() }
    func translate(dx: Float, dy: Float, dz: Float) {
        if dx != 0 || dy != 0 || dz != 0 {
            worldContainer.position.x += dx
            worldContainer.position.y += dy
            worldContainer.position.z += dz
        }
    }
    
    // MARK: - Pause support
    func setSceneGraphPaused(_ paused: Bool) {
        worldContainer.isPaused = paused
        worldContainer.enumerateChildNodes { n, _ in n.isPaused = paused }
    }
    
    // MARK: - Teardown
    func teardown() {
        worldContainer.removeAllActions()
        worldContainer.enumerateChildNodes { n, _ in n.removeAllActions() }
        removeAllEntities()
        ants.removeAll()
        foodSources.removeAll()
        nest = nil
        worldContainer.enumerateChildNodes { n, _ in n.removeFromParentNode() }
        worldContainer.removeFromParentNode()
        directionalLightNode?.removeFromParentNode()
        directionalLightNode = nil
        sceneRef = nil
        scnView = nil
    }
    
    // MARK: - Core simulation step
    private func step(deltaTime: Float) {
        time += deltaTime
        
        
        for i in (0..<pheromoneTrails.count).reversed() {
            pheromoneTrails[i].strength -= pheromoneDecayRate * deltaTime
            let age = time - pheromoneTrails[i].createdTime

            if let node = pheromoneTrails[i].node {
                node.opacity = CGFloat(max(0, pheromoneTrails[i].strength))
            }

            if pheromoneTrails[i].strength <= 0 || age > pheromoneLifetime {
                pheromoneTrails[i].node?.removeFromParentNode()
                pheromoneTrails.remove(at: i)
            }
        }
        
        // Update each ant
        for i in 0..<ants.count {
            updateAnt(antIndex: i, deltaTime: deltaTime)
        }
        
        // Remove depleted food sources and spawn new ones
        var indicesToRemove: [Int] = []
        for i in 0..<foodSources.count {
            if foodSources[i].size <= 0 {
                indicesToRemove.append(i)
            }
        }
        
        // Remove in reverse order to avoid index shifts
        for i in indicesToRemove.reversed() {
            foodSources[i].node?.removeFromParentNode()
            foodSources.remove(at: i)
        }
        
        // Spawn new food sources to maintain count
        while foodSources.count < foodSourceCount {
            spawnNewFoodSource()
        }
        
        // Update visual representations
        updateVisuals()
    }
    
    // MARK: - Ant behavior
    // MARK: - Ant behavior
    private func updateAnt(antIndex: Int, deltaTime: Float) {
        guard antIndex < ants.count else { return }
        var ant = ants[antIndex]

        switch ant.state {

        case .seekingFood:
            // Only follow pheromones if not in ignore period and no food target
            if ant.targetFoodIndex == nil, time > ant.pheromoneIgnoreUntil, let pheromone = findNearestPheromone(to: ant.position, maxDistance: 2.0) {
                let target = ant.position + pheromone.directionToFood * 3.0
                moveTowardsWithAvoidance(&ant, target: target, deltaTime: deltaTime, antIndex: antIndex)
                ants[antIndex] = ant
                return
            }
            // If we have a food target, go directly to it (ignore pheromones)
            if let foodIndex = ant.targetFoodIndex ?? findNearestFoodSource(to: ant.position, maxDistance: 3.0) {
                ant.targetFoodIndex = foodIndex
                let targetPos = foodSources[foodIndex].position
                moveTowardsWithAvoidance(&ant, target: targetPos, deltaTime: deltaTime, antIndex: antIndex)
                let dist = distance(ant.position, targetPos)
                if dist < 1.0 {
                    takeFoodBite(antIndex: antIndex, foodIndex: foodIndex)
                    ant = ants[antIndex]
                }
                ants[antIndex] = ant
                return
            }
            // Otherwise, wander randomly
            wanderRandomly(&ant, deltaTime: deltaTime)
            ants[antIndex] = ant
            return

        case .carryingFood, .returningToNest:
            // Go to nest
            if let nestPos = nest?.position {
                moveTowardsWithAvoidance(&ant, target: nestPos, deltaTime: deltaTime, antIndex: antIndex)
                // Drop pheromone while carrying, to mark path back to food
                if ant.state == .carryingFood {
                    dropPheromone(from: antIndex)
                }
                let dist = distance(ant.position, nestPos)
                if dist < 2.0 {
                    // Reached nest: drop food
                    ant.state = .seekingFood
                    ant.targetFoodIndex = nil
                    // Remove crumb visual if present
                    if let crumb = ant.carryingFoodVisual {
                        crumb.removeFromParentNode()
                        ant.carryingFoodVisual = nil
                    }
                               }
                           }
                       }

                       ants[antIndex] = ant
                   }
    
    private func moveTowards(_ ant: inout Ant, target: SIMD3<Float>, deltaTime: Float) {
        let direction = normalize(target - ant.position)
        ant.velocity = direction * ant.speed
        ant.position += ant.velocity * deltaTime
        
        // Clamp to world bounds
        let maxDist = worldRadius * 0.9
        if simd_length(ant.position) > maxDist {
            ant.position = normalize(ant.position) * maxDist
        }
    }
    
    
    private func moveTowardsWithAvoidance(
        _ ant: inout Ant,
        target: SIMD3<Float>,
        deltaTime: Float,
        antIndex: Int
    ) {
        // Desired movement towards target
        var desired = target - ant.position
        if simd_length(desired) > 0.0001 {
            desired = normalize(desired)
        }

        // Simple separation from other ants
        var separation = SIMD3<Float>(0, 0, 0)
        let avoidanceRadius: Float = 5.0

        for (i, other) in ants.enumerated() {
            if i == antIndex { continue }
            let offset = ant.position - other.position
            let d = simd_length(offset)
            if d > 0 && d < avoidanceRadius {
                let push = (avoidanceRadius - d) / avoidanceRadius
                separation += normalize(offset) * push
            }
        }

        let steering = normalize(desired + separation)
        ant.velocity = steering * ant.speed
        ant.position += ant.velocity * deltaTime

        // Clamp to world bounds
        let maxDist = worldRadius * 0.9
        if simd_length(ant.position) > maxDist {
            ant.position = normalize(ant.position) * maxDist
        }
    }
    
    private func wanderRandomly(_ ant: inout Ant, deltaTime: Float) {
        let wanderUpdateInterval: Float = 0.7
        if time - ant.lastWanderUpdateTime > wanderUpdateInterval {
            let randomAngle = Float.random(in: 0...(Float.pi * 2))
            let newDir = SIMD3<Float>(cos(randomAngle), 0, sin(randomAngle))
            let distFromCenter = simd_length(ant.position)
            let maxDist = worldRadius * 0.9
            var bias = SIMD3<Float>(0, 0, 0)
            if distFromCenter > maxDist * 0.85 {
                bias = normalize(-ant.position) // direction to center
            }
            let blend: Float = distFromCenter > maxDist * 0.85 ? 0.5 : 0.3
            let centerBlend: Float = distFromCenter > maxDist * 0.85 ? 0.2 : 0.0
            let wanderComponent = ant.wanderDirection * (1.0 - blend - centerBlend)
            let randomComponent = newDir * blend
            let centerComponent = bias * centerBlend
            let combined = wanderComponent + randomComponent + centerComponent
            ant.wanderDirection = normalize(combined)
            ant.lastWanderUpdateTime = time
        }
        ant.velocity = ant.wanderDirection * ant.speed * 0.9
        ant.position += ant.velocity * deltaTime
        // Clamp to world bounds
        let maxDist = worldRadius * 0.9
        if simd_length(ant.position) > maxDist {
            ant.position = normalize(ant.position) * maxDist
        }
    }
    
    private func findNearestFoodSource(to position: SIMD3<Float>, maxDistance: Float) -> Int? {
        var nearestIndex: Int?
        var nearestDist: Float = maxDistance
        for (i, food) in foodSources.enumerated() {
            if food.size > 0 {
                let dist = distance(position, food.position)
                if dist < nearestDist {
                    nearestDist = dist
                    nearestIndex = i
                }
            }
        }
        return nearestIndex
    }
    
    private func takeFoodBite(antIndex: Int, foodIndex: Int) {
        guard foodIndex < foodSources.count else { return }
        guard antIndex < ants.count else { return }

        // Reduce food size
        foodSources[foodIndex].size -= 0.5

        // Ant now carries food and remembers which source
        ants[antIndex].state = .carryingFood
        ants[antIndex].targetFoodIndex = foodIndex

        // Visual crumb above the ant
        if let antNode = ants[antIndex].node {
            let crumb = SCNSphere(radius: 0.15)
            let mat = SCNMaterial()
            mat.diffuse.contents = foodSources[foodIndex].color
            mat.lightingModel = .physicallyBased
            crumb.firstMaterial = mat

            let crumbNode = SCNNode(geometry: crumb)
            crumbNode.position = SCNVector3(0, 0.4, 0)  // just above the body
            antNode.addChildNode(crumbNode)
            ants[antIndex].carryingFoodVisual = crumbNode
        }
    }
    
    private func spawnNewFoodSource() {
        let angle = Float.random(in: 0...(2 * .pi))
        let radius = Float.random(in: 10...worldRadius * 0.8)
        let position = SIMD3<Float>(
            cos(angle) * radius,
            0,
            sin(angle) * radius
        )

        let size = Float.random(in: 5...10)
        let hue = CGFloat.random(in: 0.1...0.3)
        let color = UIColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1.0)

        var food = FoodSource(position: position, size: size, node: nil, color: color)
        food.node = createFoodNode(food: food)
        foodSources.append(food)
    }

    private func dropPheromone(from antIndex: Int) {
        let now = time
        let last = lastPheromoneDropTime[antIndex] ?? -1e6
        if now - last < pheromoneDropInterval { return }
        lastPheromoneDropTime[antIndex] = now

        guard antIndex < ants.count else { return }
        guard let foodIndex = ants[antIndex].targetFoodIndex else { return }
        let pos = ants[antIndex].position

        // Visual node
        let sphere = SCNSphere(radius: 0.1)
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.black.withAlphaComponent(0.8)
        mat.emission.contents = UIColor.black
        mat.lightingModel = .constant
        sphere.firstMaterial = mat

        let node = SCNNode(geometry: sphere)
        node.position = SCNVector3(pos.x, 0.1, pos.z)
        worldContainer.addChildNode(node)

        let direction = normalize(foodSources[foodIndex].position - pos)
        let trail = PheromoneTrail(
            position: pos,
            foodIndex: foodIndex,
            strength: 1.0,
            createdTime: now,
            node: node,
            directionToFood: direction
        )
        pheromoneTrails.append(trail)
    }

    private func findNearestPheromone(to position: SIMD3<Float>, maxDistance: Float) -> PheromoneTrail? {
        var bestTrail: PheromoneTrail?
        var bestDist = maxDistance
        for p in pheromoneTrails {
            let d = distance(position, p.position)
            if d < bestDist {
                bestDist = d
                bestTrail = p
            }
        }
        return bestTrail
    }    // MARK: - Trackers
    func projectedAntXY127(antIndex: Int) -> (x: Int, y: Int)? {
        guard let scnView = scnView,
              antIndex >= 0,
              antIndex < ants.count,
              let node = ants[antIndex].node else { return nil }
        
        let worldPos = node.presentation.worldPosition
        let p = scnView.projectPoint(worldPos)
        let w = max(scnView.bounds.width, 1)
        let h = max(scnView.bounds.height, 1)
        let xView = CGFloat(p.x)
        let yView = h - CGFloat(p.y)
        let x127 = Int(round(min(max(xView, 0), w) / w * 127))
        let y127 = Int(round(min(max(yView, 0), h) / h * 127))
        return (x127, y127)
    }
    
    func projectedFoodXY127(foodIndex: Int) -> (x: Int, y: Int)? {
        guard let scnView = scnView,
              foodIndex >= 0,
              foodIndex < foodSources.count,
              let node = foodSources[foodIndex].node else { return nil }
        
        let worldPos = node.presentation.worldPosition
        let p = scnView.projectPoint(worldPos)
        let w = max(scnView.bounds.width, 1)
        let h = max(scnView.bounds.height, 1)
        let xView = CGFloat(p.x)
        let yView = h - CGFloat(p.y)
        let x127 = Int(round(min(max(xView, 0), w) / w * 127))
        let y127 = Int(round(min(max(yView, 0), h) / h * 127))
        return (x127, y127)
    }
    
    // MARK: - Private helpers
    private func applyWorldScale() {
        worldContainer.scale = SCNVector3(worldScale, worldScale, worldScale)
    }
    
    private func applyWorldOrientation() {
        worldContainer.eulerAngles = SCNVector3(worldTilt, worldYaw, 0)
    }
    
    private func finalizeWorldPivot() {
        worldContainer.pivot = SCNMatrix4MakeTranslation(0, 0, 0)
    }
    
    private func setupGround() {
        let groundRadius: CGFloat = CGFloat(worldRadius)
        let groundPlane = SCNCylinder(radius: groundRadius, height: 0.5)
        let groundMaterial = SCNMaterial()
        groundMaterial.diffuse.contents = UIColor(red: 0.85, green: 0.75, blue: 0.65, alpha: 1.0)
        groundMaterial.lightingModel = .physicallyBased
        groundPlane.firstMaterial = groundMaterial
        
        let groundNode = SCNNode(geometry: groundPlane)
        groundNode.position = SCNVector3(0, -0.25, 0)
        groundNode.castsShadow = true
        worldContainer.addChildNode(groundNode)
    }
    
    private func setupNest() {
        let nestPos = SIMD3<Float>(0, 0, 0)
        let nestNode = createNestNode()
        nest = Nest(position: nestPos, node: nestNode)
    }
    
    private func createNestNode() -> SCNNode {
        let nestSize: CGFloat = 4.0
        let cone = SCNCone(topRadius: 0, bottomRadius: nestSize, height: nestSize * 0.5)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 1.0)
        material.lightingModel = .physicallyBased
        cone.firstMaterial = material
        
        let node = SCNNode(geometry: cone)
        node.position = SCNVector3(0, 1, 0)
        node.castsShadow = true
        worldContainer.addChildNode(node)
        return node
    }
    
    private func setupFoodSources() {
        for _ in 0..<foodSourceCount {
            spawnNewFoodSource()
        }
    }
    
    private func createFoodNode(food: FoodSource) -> SCNNode {
        let sphere = SCNSphere(radius: CGFloat(food.size * 0.2))
        let material = SCNMaterial()
        material.diffuse.contents = food.color
        material.lightingModel = .physicallyBased
        sphere.firstMaterial = material
        
        let node = SCNNode(geometry: sphere)
        node.position = SCNVector3(food.position.x, 0.5, food.position.z)
        node.castsShadow = true
        worldContainer.addChildNode(node)
        return node
    }
    
    private func setupAnts() {
        let antColors: [UIColor] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .magenta]
        
        for i in 0..<antCount {
            let angle = Float.random(in: 0...(Float.pi * 2))
            let radius = Float.random(in: 2...8)
            let position = SIMD3<Float>(
                cos(angle) * radius,
                0,
                sin(angle) * radius
            )
            
            let color = antColors[i % antColors.count]
            var ant = Ant(
                position: position,
                velocity: SIMD3<Float>(0, 0, 0),
                state: .seekingFood,
                targetFoodIndex: nil,
                color: color,
                node: nil,
                speed: Float.random(in: 4...6)
            )
            
            ant.node = createAntNode(ant: ant)
            ants.append(ant)
        }
    }
    
    private func createAntNode(ant: Ant) -> SCNNode {
        let bodySize: CGFloat = 0.5
        
        // Body
        let body = SCNSphere(radius: bodySize)
        let bodyMaterial = SCNMaterial()
        bodyMaterial.diffuse.contents = ant.color
        bodyMaterial.lightingModel = .physicallyBased
        body.firstMaterial = bodyMaterial
        
        let node = SCNNode(geometry: body)
        node.position = SCNVector3(ant.position.x, 0.5, ant.position.z)
        node.castsShadow = true
        worldContainer.addChildNode(node)
        return node
    }
    
    private func updateVisuals() {
        // Update ant positions
        for i in 0..<ants.count {
            if let node = ants[i].node {
                node.position = SCNVector3(ants[i].position.x, 0.5, ants[i].position.z)
                
                // Rotate ant to face movement direction
                if simd_length(ants[i].velocity) > 0.1 {
                    let angle = atan2(ants[i].velocity.z, ants[i].velocity.x)
                    node.eulerAngles.y = angle
                }
            }
        }
        
        // Update food source sizes
        for i in 0..<foodSources.count {
            if let node = foodSources[i].node, let sphere = node.geometry as? SCNSphere {
                sphere.radius = CGFloat(max(0.1, foodSources[i].size * 0.2))
            }
        }
    }
    
    private func removeAllEntities() {
        ants.forEach { $0.node?.removeFromParentNode() }
        ants.removeAll()
        foodSources.forEach { $0.node?.removeFromParentNode() }
        foodSources.removeAll()
        nest?.node?.removeFromParentNode()
        nest = nil
    }
    
    // MARK: - Lighting
    private func addDirectionalLight(to scene: SCNScene) {
        let light = SCNLight()
        light.type = .directional
        light.color = UIColor.white
        light.intensity = 1200
        light.castsShadow = true
        light.shadowMode = .deferred
        light.shadowColor = UIColor(white: 0, alpha: 0.5)
        light.shadowRadius = 8
        light.shadowSampleCount = 16
        
        let node = SCNNode()
        node.light = light
        node.position = SCNVector3(-20, 20, 20)
        node.look(at: SCNVector3(0, 5, 0))
        scene.rootNode.addChildNode(node)
        directionalLightNode = node
    }
    
    // MARK: - Utility
    private func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let len = max(0.000001, sqrt(v.x*v.x + v.y*v.y + v.z*v.z))
        return v / len
    }
    
    private func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        return simd_length(a - b)
    }
    
    // Add low power mode support
    private var originalAntCount: Int? = nil
    func setLowPowerMode(_ enabled: Bool) {
        let preservedPosition = worldContainer.position
        let preservedPivot = worldContainer.pivot
        let preservedEuler = worldContainer.eulerAngles
        let preservedScale = worldContainer.scale
        
        if enabled {
            if originalAntCount == nil {
                originalAntCount = ants.count
            }
            let newCount = max(5, ants.count / 2)
            if ants.count > newCount {
                // Remove excess ants
                for i in (newCount..<ants.count).reversed() {
                    ants[i].node?.removeFromParentNode()
                    ants.remove(at: i)
                }
            }
        } else if let orig = originalAntCount {
            let currentCount = ants.count
            if currentCount < orig {
                // Add ants back
                for _ in currentCount..<orig {
                    let angle = Float.random(in: 0...(Float.pi * 2))
                    let radius = Float.random(in: 2...8)
                    let position = SIMD3<Float>(
                        cos(angle) * radius,
                        0,
                        sin(angle) * radius
                    )
                    let antColors: [UIColor] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .magenta]
                    let color = antColors[ants.count % antColors.count]
                    var ant = Ant(
                        position: position,
                        velocity: SIMD3<Float>(0, 0, 0),
                        state: .seekingFood,
                        targetFoodIndex: nil,
                        color: color,
                        node: nil,
                        speed: Float.random(in: 4...6)
                    )
                    ant.node = createAntNode(ant: ant)
                    ants.append(ant)
                }
            }
            originalAntCount = nil
        }
        
        worldContainer.pivot = preservedPivot
        worldContainer.scale = preservedScale
        worldContainer.eulerAngles = preservedEuler
        worldContainer.position = preservedPosition
    }
}
