import SceneKit
import UIKit

// MARK: - BarleySimulation (synchronous core) mirrors JellyfishSimulation sequencing
final class BarleySimulation: LifeformSimulation {
    // MARK: - Public model data
    struct Stalk {
        var position: SIMD3<Float>
        var height: Float
        var phase: Float
        var color: UIColor
        var rootNode: SCNNode? = nil
        var segments: [SCNNode] = []
        var seedHead: SCNNode? = nil
        var lastBendAngles: [Float] = []
        var resistance: Float = 0.4
    }
    var stalks: [Stalk] = []
    
    // MARK: - Scene refs
    weak var sceneRef: SCNScene?
    weak var scnView: SCNView?
    private let fieldContainer = SCNNode()
    
    // MARK: - Parameters & state
    var userWindStrength: Float = 3.0 {
        didSet {
            // Removed gust injection on parameter change to avoid large transients
            // Gusts will be generated over time in step() based on nextGustTime
        }
    }
    private var baseWindDirection: SIMD3<Float> = SIMD3<Float>(1,0,0)
    private var baseWindStrength: Float = 0.8
    private var windFrequency: Float = 1.0
    private var windTurbulence: Float = 0.3
    private var time: Float = 0.0
    private var windGusts: [WindGust] = []
    private var nextGustTime: Float = 3.0
    
    var stalkCount: Int
    var stalkSpacing: Float
    var stalkColor: UIColor?
    private let config: LifeformViewConfig
    
    private(set) var fieldScale: Float = 1.0
    private(set) var fieldTilt: Float = 0.0
    private(set) var fieldYaw: Float = 0.0
    var fieldYOffset: Float = 50.0 * CameraOrbitState.sceneScale
    var seedHeadScale: Float = 2.5
    
    // Field bounds
    private var fieldMinX: Float = 0
    private var fieldMaxX: Float = 0
    private var fieldMinZ: Float = 0
    private var fieldMaxZ: Float = 0
    private var tallestSeedHeadHeight: Float = 0.0
    
    // Lighting
    private var directionalLightNode: SCNNode?
    
    // Flicker / misc unused debug retention removed
    
    // MARK: - Visual bounds fallback (for potential mapping similar to others)
    var visualBounds: Float { 30.0 }
    
    // MARK: - Gust data
    private struct WindGust { let direction: SIMD3<Float>; let strength: Float; let duration: Float; let startTime: Float; let areaMin: SIMD2<Float>; let areaMax: SIMD2<Float> }
    
    // MARK: - Init
    init(stalkCount: Int, stalkSpacing: Float, scene: SCNScene, stalkColor: UIColor?, config: LifeformViewConfig, scnView: SCNView?) {
        self.stalkCount = stalkCount
        self.stalkSpacing = stalkSpacing
        self.sceneRef = scene
        self.config = config
        self.scnView = scnView
        self.stalkColor = stalkColor
        scene.rootNode.addChildNode(fieldContainer)
        setupEarthWad()
        setupBarley(count: stalkCount, spacing: stalkSpacing, scene: scene)
        addDirectionalLight(to: scene)
        finalizeFieldPivot()
        applyFieldScale()
        applyFieldOrientation()
        generateWindGust(strength: 0.7 * userWindStrength, duration: 2.0)
        // Removed custom camera creation (use host SceneView camera)
        // setupOrthographicCamera(scene: scene)
    }
    
    // MARK: - LifeformSimulation
    func update(deltaTime: Float) { step(deltaTime: deltaTime) }
    func reset() {
        // Preserve transform so a reset doesn't move the field
        let preservedPosition = fieldContainer.position
        let preservedPivot = fieldContainer.pivot
        let preservedEuler = fieldContainer.eulerAngles
        let preservedScale = fieldContainer.scale
        
        removeAllStalks()
        if let scene = sceneRef {
            setupBarley(count: stalkCount, spacing: stalkSpacing, scene: scene)
        }
        finalizeFieldPivot()
        applyFieldScale()
        applyFieldOrientation()
        
        // Restore prior transform
        fieldContainer.pivot = preservedPivot
        fieldContainer.scale = preservedScale
        fieldContainer.eulerAngles = preservedEuler
        fieldContainer.position = preservedPosition
    }
    
    // MARK: - Public control API
    func setWindStrength(_ strength: Float) { userWindStrength = strength }
    func setFieldScale(_ scale: Float) {
        let clamped = max(0.05, scale)
        guard abs(clamped - fieldScale) > 0.0001 else { return }
        fieldScale = clamped
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0
        applyFieldScale()
        SCNTransaction.commit()
    }
    func setFieldTilt(_ angle: Float) { fieldTilt = angle; applyFieldOrientation() }
    func setFieldYaw(_ angle: Float) { fieldYaw = angle; applyFieldOrientation() }
    func translate(dx: Float, dy: Float, dz: Float) { if dx != 0 || dy != 0 || dz != 0 { fieldContainer.position.x += dx; fieldContainer.position.y += dy; fieldContainer.position.z += dz } }
    
    // MARK: - Pause support
    func setSceneGraphPaused(_ paused: Bool) { fieldContainer.isPaused = paused; fieldContainer.enumerateChildNodes { n,_ in n.isPaused = paused } }
    
    // MARK: - Teardown
    func teardown() {
        // Remove all actions from fieldContainer and its children
        fieldContainer.removeAllActions()
        fieldContainer.enumerateChildNodes { n, _ in n.removeAllActions() }
        // Remove all stalk nodes and clear stalks array
        removeAllStalks()
        stalks.removeAll()
        // Remove all child nodes from fieldContainer
        fieldContainer.enumerateChildNodes { n, _ in n.removeFromParentNode() }
        // Remove fieldContainer from scene
        fieldContainer.removeFromParentNode()
        // Remove and nil out directional light
        directionalLightNode?.removeFromParentNode(); directionalLightNode = nil
        // Remove and nil out camera (if any was created previously)
        cameraNode?.removeFromParentNode(); cameraNode = nil
        // Clear wind gusts
        windGusts.removeAll()
        // Clear scene and view references
        sceneRef = nil
        scnView = nil
    }
    
    // MARK: - Core simulation step
    private func step(deltaTime: Float) {
        time += deltaTime
        let windAngle = sin(time * 0.05) * Float.pi * 0.5
        baseWindDirection = SIMD3<Float>(cos(windAngle), 0, sin(windAngle))
        baseWindStrength = (0.3 + sin(time * 0.17) * 0.2) * userWindStrength
        windTurbulence = 0.1 + abs(sin(time * 0.23)) * 0.3 * userWindStrength
        if time > nextGustTime { generateWindGust(strength: 0.5 + Float.random(in: 0...1.0), duration: Float.random(in: 1.5...4.0)); let gustFreq = max(2.0, 8.0 - userWindStrength * 3.0); nextGustTime = time + Float.random(in: 1.0...gustFreq) }
        windGusts.removeAll { time > $0.startTime + $0.duration }
        for i in 0..<stalks.count { updateStalk(stalkIndex: i, deltaTime: deltaTime) }
    }
    
    // MARK: - Trackers
    func projectedSeedHeadXY127(stalkIndex: Int) -> (x: Int, y: Int)? {
        guard let scnView = scnView, stalkIndex >= 0, stalkIndex < stalks.count, let node = stalks[stalkIndex].seedHead else { return nil }
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
    func projectedSeedHeadXY127Raw(stalkIndex: Int) -> (x: Int, y: Int)? {
        guard let scnView = scnView,
              stalkIndex >= 0, stalkIndex < stalks.count,
              let node = stalks[stalkIndex].seedHead else { return nil }
        let worldPos = node.presentation.worldPosition
        let p = scnView.projectPoint(worldPos)
        let w = max(scnView.bounds.width, 1)
        let h = max(scnView.bounds.height, 1)
        let xView = CGFloat(p.x)
        let yView = h - CGFloat(p.y)
        let x127 = Int(round(xView / w * 127.0))
        let y127 = Int(round(yView / h * 127.0))
        return (x127, y127)
    }
    func seedHeadWorldPosition(stalkIndex: Int) -> SCNVector3? {
        guard stalkIndex >= 0, stalkIndex < stalks.count,
              let node = stalks[stalkIndex].seedHead else { return nil }
        return node.presentation.worldPosition
    }
    
    // MARK: - Private helpers
    private func applyFieldScale() { fieldContainer.scale = SCNVector3(fieldScale, fieldScale, fieldScale) }
    private func applyFieldOrientation() { fieldContainer.eulerAngles = SCNVector3(fieldTilt, fieldYaw, 0) }
    private func finalizeFieldPivot() { fieldContainer.pivot = SCNMatrix4MakeTranslation(0, tallestSeedHeadHeight, 0) }
    
    private func setupBarley(count: Int, spacing: Float, scene: SCNScene) {
        if fieldContainer.parent == nil { scene.rootNode.addChildNode(fieldContainer) }
        let gridSize = Int(ceil(sqrt(Double(count))))
        let actualCount = min(count, gridSize * gridSize)
        let totalFieldWidth = Float(max(gridSize - 1, 0)) * spacing
        let startX = -totalFieldWidth / 2
        let startZ = -totalFieldWidth / 2
        fieldMinX = Float.greatestFiniteMagnitude; fieldMaxX = -Float.greatestFiniteMagnitude
        fieldMinZ = Float.greatestFiniteMagnitude; fieldMaxZ = -Float.greatestFiniteMagnitude
        tallestSeedHeadHeight = 0
        stalks.removeAll(keepingCapacity: true)
        var current = 0
        outer: for i in 0..<gridSize {
            for j in 0..<gridSize {
                if current >= actualCount { break outer }
                let baseX = startX + Float(i) * spacing
                let baseZ = startZ + Float(j) * spacing
                let randomFactor = spacing * 0.8
                let xOffset = Float.random(in: -randomFactor...randomFactor)
                let zOffset = Float.random(in: -randomFactor...randomFactor)
                let height = Float.random(in: 30.0...100.0)
                let posX = baseX + xOffset
                let posZ = baseZ + zOffset
                let position = SIMD3<Float>(posX, 0, posZ)
                fieldMinX = min(fieldMinX, posX); fieldMaxX = max(fieldMaxX, posX)
                fieldMinZ = min(fieldMinZ, posZ); fieldMaxZ = max(fieldMaxZ, posZ)
                let phase = Float.random(in: 0...Float.pi*2)
                let resistance = Float.random(in: 0.3...1.2)
                let color: UIColor = stalkColor ?? {
                    let hue = CGFloat(Float.random(in: 0.10...0.15))
                    let saturation = CGFloat(Float.random(in: 0.6...0.8))
                    let brightness = CGFloat(Float.random(in: 0.8...0.95))
                    return UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1.0)
                }()
                var stalk = Stalk(position: position, height: height, phase: phase, color: color, resistance: resistance)
                let isLargeSeedHead = current < 5
                createStalk(stalk: &stalk, isLargeSeedHead: isLargeSeedHead)
                stalks.append(stalk)
                current += 1
            }
        }
        // Color-code first few heads
        let palette: [UIColor] = [.red, .orange, .yellow, .green, .blue]
        for i in 0..<min(palette.count, stalks.count) { stalks[i].seedHead?.geometry?.firstMaterial?.diffuse.contents = palette[i] }
        for s in stalks { if let seed = s.seedHead { tallestSeedHeadHeight = max(tallestSeedHeadHeight, seed.worldPosition.y) } }
        let centerX = (fieldMinX + fieldMaxX)/2
        let centerZ = (fieldMinZ + fieldMaxZ)/2
        fieldContainer.position = SCNVector3(-centerX * CameraOrbitState.sceneScale + config.initialFieldOffset.x,
                                             fieldYOffset + config.initialFieldOffset.y,
                                             -centerZ * CameraOrbitState.sceneScale + config.initialFieldOffset.z)
    }
    private func createStalk(stalk: inout Stalk, isLargeSeedHead: Bool) {
        let sceneScale = CameraOrbitState.sceneScale
        guard let scene = sceneRef else { return }
        let rootNode = SCNNode()
        rootNode.position = SCNVector3(stalk.position.x * sceneScale, 0, stalk.position.z * sceneScale)
        fieldContainer.addChildNode(rootNode)
        stalk.rootNode = rootNode
        let segmentCount = 8
        let segmentHeight = stalk.height / Float(segmentCount)
        var previous = rootNode
        var segments: [SCNNode] = [rootNode]
        var lastAngles: [Float] = [0]
        for i in 1..<segmentCount {
            let segmentNode = SCNNode()
            segmentNode.position = SCNVector3(0, segmentHeight * sceneScale, 0)
            let segmentWidth = (0.2 - (Float(i) * 0.02)) * sceneScale
            let visual = createSegmentVisual(width: segmentWidth, height: segmentHeight * sceneScale, color: stalk.color)
            segmentNode.addChildNode(visual)
            previous.addChildNode(segmentNode)
            segments.append(segmentNode)
            lastAngles.append(0)
            previous = segmentNode
        }
        let seedHeadNode = createSeedHead(color: stalk.color, scale: sceneScale, large: isLargeSeedHead)
        previous.addChildNode(seedHeadNode)
        stalk.seedHead = seedHeadNode
        stalk.segments = segments
        stalk.lastBendAngles = lastAngles
        // Update reference in array if needed later
        if let idx = stalks.firstIndex(where: { $0.rootNode === rootNode }) { stalks[idx] = stalk }
    }
    private func createSegmentVisual(width: Float, height: Float, color: UIColor) -> SCNNode {
        let cyl = SCNCylinder(radius: CGFloat(width), height: CGFloat(height))
        cyl.firstMaterial?.diffuse.contents = color
        cyl.firstMaterial?.lightingModel = .physicallyBased
        let node = SCNNode(geometry: cyl)
        node.position = SCNVector3(0, height/2, 0)
        node.castsShadow = true
        return node
    }
    private func createSeedHead(color: UIColor, scale: Float, large: Bool) -> SCNNode {
        let appliedScale = large ? seedHeadScale : 1.0
        let size: Float = 0.3 * scale * appliedScale
        let sphere = SCNSphere(radius: CGFloat(size))
        sphere.firstMaterial?.diffuse.contents = color
        let node = SCNNode(geometry: sphere)
        node.scale = SCNVector3(1,2,1)
        node.castsShadow = true
        return node
    }
    private func removeAllStalks() { stalks.forEach { $0.rootNode?.removeFromParentNode() }; stalks.removeAll() }
    
    // MARK: - Wind logic
    private func generateWindGust(strength: Float, duration: Float) {
        let hasField = fieldMinX < fieldMaxX && fieldMinZ < fieldMaxZ
        let angleVariation = Float.random(in: -Float.pi/3...Float.pi/3)
        let baseAngle = Float.random(in: 0...Float.pi*2)
        let dir = SIMD3<Float>(cos(baseAngle + angleVariation), 0, sin(baseAngle + angleVariation))
        let areaSize: Float
        let centerX: Float
        let centerZ: Float
        if hasField {
            let widthX = fieldMaxX - fieldMinX
            let widthZ = fieldMaxZ - fieldMinZ
            areaSize = max(widthX, widthZ) * Float.random(in: 0.8...1.2)
            centerX = Float.random(in: fieldMinX...fieldMaxX)
            centerZ = Float.random(in: fieldMinZ...fieldMaxZ)
        } else {
            areaSize = 10 * Float.random(in: 0.3...0.8)
            centerX = 0
            centerZ = 0
        }
        let min2 = SIMD2<Float>(centerX - areaSize/2, centerZ - areaSize/2)
        let max2 = SIMD2<Float>(centerX + areaSize/2, centerZ + areaSize/2)
        // Do not multiply by userWindStrength here; 'strength' is already scaled by overall wind
        let gust = WindGust(
            direction: dir,
            strength: strength * Float.random(in: 0.7...1.2),
            duration: duration * Float.random(in: 0.8...1.2),
            startTime: time,
            areaMin: min2,
            areaMax: max2
        )
        windGusts.append(gust)
    }
    private func updateStalk(stalkIndex: Int, deltaTime: Float) {
        guard stalkIndex < stalks.count else { return }
        var stalk = stalks[stalkIndex]
        let position = stalk.position
        var windEffect = sin(time * windFrequency + stalk.phase) * baseWindStrength
        let noise = sin(position.x * 0.05 + time * 0.1) * cos(position.z * 0.05 + time * 0.15) * 0.5 * userWindStrength
        windEffect += noise
        for g in windGusts {
            if position.x >= g.areaMin.x && position.x <= g.areaMax.x && position.z >= g.areaMin.y && position.z <= g.areaMax.y {
                let nx = (position.x - g.areaMin.x) / (g.areaMax.x - g.areaMin.x)
                let nz = (position.z - g.areaMin.y) / (g.areaMax.y - g.areaMin.y)
                let dist = sqrt(pow(nx - 0.5, 2) + pow(nz - 0.5, 2)) * 2
                let influence = max(0, 1 - dist)
                let tFactor = sin(min(Float.pi, (time - g.startTime) / g.duration * Float.pi))
                windEffect += g.strength * influence * tFactor
                windEffect += sin(time * 12 + stalk.phase * 3) * g.strength * 0.2 * influence * tFactor
            }
        }
        windEffect /= stalk.resistance
        let maxEffect: Float = 2.0 * userWindStrength
        windEffect = min(windEffect, maxEffect)
        let stalkWindDir = normalize(baseWindDirection + SIMD3<Float>(sin(stalk.phase + time * 0.3) * windTurbulence, 0, cos(stalk.phase + time * 0.27) * windTurbulence))
        for i in 1..<stalk.segments.count {
            let normalizedHeight = Float(i) / Float(stalk.segments.count)
            let bendCurve = sin(normalizedHeight * Float.pi)
            let bendFactor = bendCurve * 0.3 + (normalizedHeight * 0.4)
            let target = min(windEffect * 0.3 * bendFactor, (Float.pi/2) * bendFactor)
            let stiffnessFactor = max(0.4, abs(normalizedHeight - 0.5) * 1.5)
            let lerpFactor = min(1.0, deltaTime * (8.0 - stiffnessFactor * 6.0))
            let current = stalk.lastBendAngles[i] * (1 - lerpFactor) + target * lerpFactor
            stalk.lastBendAngles[i] = current
            let up = SIMD3<Float>(0,1,0)
            var axis = simd_cross(up, stalkWindDir)
            if simd_length(axis) > 0.0001 { axis = simd_normalize(axis) } else { axis = SIMD3<Float>(1,0,0) }
            stalk.segments[i].orientation = SCNQuaternion(x: 0, y: 0, z: 0, w: 1)
            let q = SCNQuaternion(axis.x * sin(current * 0.5), axis.y * sin(current * 0.5), axis.z * sin(current * 0.5), cos(current * 0.5))
            stalk.segments[i].orientation = q
        }
        stalks[stalkIndex] = stalk
    }
    private func normalize(_ v: SIMD3<Float>) -> SIMD3<Float> { let len = max(0.000001, sqrt(v.x*v.x + v.y*v.y + v.z*v.z)); return v / len }
    
    // MARK: - Earth / Light
    private func setupEarthWad() {
        let wadNode = SCNNode()
        let wadRadius: CGFloat = 1.7
        let wadHeight: CGFloat = 1.2
        let earthCylinder = SCNCylinder(radius: wadRadius, height: wadHeight)
        let earthMaterial = SCNMaterial()
        earthMaterial.diffuse.contents = UIColor(red: 0.45, green: 0.32, blue: 0.18, alpha: 1.0)
        earthMaterial.lightingModel = .physicallyBased
        earthCylinder.firstMaterial = earthMaterial
        let earthNode = SCNNode(geometry: earthCylinder)
        earthNode.position = SCNVector3(0, wadHeight/2, 0)
        earthNode.castsShadow = true
        wadNode.addChildNode(earthNode)
        let grassCylinder = SCNCylinder(radius: wadRadius, height: 0.18)
        let grassMat = SCNMaterial()
        grassMat.lightingModel = .physicallyBased
        grassMat.diffuse.contents = UIColor(red: 0.22, green: 0.55, blue: 0.22, alpha: 1.0)
        grassCylinder.firstMaterial = grassMat
        let grassNode = SCNNode(geometry: grassCylinder)
        grassNode.position = SCNVector3(0, wadHeight + 0.09, 0)
        grassNode.castsShadow = true
        wadNode.addChildNode(grassNode)
        fieldContainer.addChildNode(wadNode)
    }
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
        let node = SCNNode(); node.light = light
        node.position = SCNVector3(-20, 20, 20)
        node.look(at: SCNVector3(0,10,0))
        scene.rootNode.addChildNode(node)
        directionalLightNode = node
    }
    
    // Camera setup to match Jellyfish
    private func setupOrthographicCamera(scene: SCNScene) {
        // DISABLED: rely on outer ModifiedSimulationView / WireframeCubeSceneView camera
        /*
        scene.rootNode.childNodes.filter { $0.camera != nil }.forEach { $0.removeFromParentNode() }
        let camNode = SCNNode()
        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale = 20.0
        cam.zNear = 1.0
        cam.zFar = 100.0
        camNode.camera = cam
        let center = SCNVector3(0, fieldYOffset, 0)
        camNode.position = SCNVector3(center.x, center.y, 40)
        camNode.look(at: center)
        camNode.eulerAngles = SCNVector3Zero
        scene.rootNode.addChildNode(camNode)
        scnView?.pointOfView = camNode
        cameraNode = camNode
        */
    }
    // Camera update API
    private var cameraNode: SCNNode? = nil
    func updateCamera(elevation: Float, azimuth: Float, radius: Float) {
        // DISABLED: external camera controls handle view transform
        /*guard let camNode = cameraNode else { return }
        let center = SCNVector3(0, fieldYOffset, 0)
        let elevRad = elevation * .pi / 180.0
        let azimRad = azimuth * .pi / 180.0
        let x = center.x + radius * cos(elevRad) * sin(azimRad)
        let y = center.y + radius * sin(elevRad)
        let z = center.z + radius * cos(elevRad) * cos(azimRad)
        camNode.position = SCNVector3(x, y, z)
        camNode.look(at: center)*/
    }
    
    // Add low power mode support
    private var originalStalkCount: Int? = nil
    func setLowPowerMode(_ enabled: Bool) {
        // Preserve current transform to avoid visual jumps when rebuilding
        let preservedPosition = fieldContainer.position
        let preservedPivot = fieldContainer.pivot
        let preservedEuler = fieldContainer.eulerAngles
        let preservedScale = fieldContainer.scale
        
        if enabled {
            if originalStalkCount == nil { originalStalkCount = stalkCount }
            let newCount = max(1, stalkCount / 2)
            if stalkCount != newCount {
                stalkCount = newCount
                removeAllStalks()
                if let scene = sceneRef {
                    setupBarley(count: stalkCount, spacing: stalkSpacing, scene: scene)
                    // Keep prior pivot/transform so world position stays the same
                    fieldContainer.pivot = preservedPivot
                    applyFieldScale()
                    fieldContainer.scale = preservedScale
                    fieldContainer.eulerAngles = preservedEuler
                    fieldContainer.position = preservedPosition
                }
            }
        } else if let orig = originalStalkCount {
            if stalkCount != orig {
                stalkCount = orig
                removeAllStalks()
                if let scene = sceneRef {
                    setupBarley(count: stalkCount, spacing: stalkSpacing, scene: scene)
                    // Keep prior pivot/transform so world position stays the same
                    fieldContainer.pivot = preservedPivot
                    applyFieldScale()
                    fieldContainer.scale = preservedScale
                    fieldContainer.eulerAngles = preservedEuler
                    fieldContainer.position = preservedPosition
                }
            }
            originalStalkCount = nil
        }
    }
}
