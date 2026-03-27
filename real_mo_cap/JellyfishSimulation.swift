import SceneKit
import UIKit

class JellyfishSimulation: LifeformSimulation {
    private struct Jellyfish {
        let outerHood: SCNNode
        let innerHood: SCNNode
        let frillNodes: [SCNNode]
        var frillPhases: [Float]
        // Precomputed frill chains to avoid per-frame traversal
        let frillChains: [[SCNNode]]
        let tentacleStems: [SCNNode]
        let tentacleSegments: [[TentacleSegment]] // Changed from tentacleNodes
        let tentacleConnectors: [[SCNNode]] // Connectors between balls
        var basePosition: SCNVector3 // <-- changed from let to var
        // --- Add velocity for Boids movement ---
        var velocity: SCNVector3 // NEW: velocity for boids movement
        // --- Luminescent dots ---
        var dotNodes: [SCNNode]
        var dotPhases: [Float]
        // Shared dot material for all dots (single intensity update per frame)
        let dotSharedMaterial: SCNMaterial
        // Animation state
        var pulsePhase: Float
        var pulseSpeed: Float
        var swayPhase: Float
        var swaySpeed: Float
        var driftPhase: Float
        var driftSpeed: Float
        var prevOuterBreath: Float // Track previous breath value for movement
        // REMOVED: let glowLightNode: SCNNode
        // Precomputed constants to avoid per-frame geometry queries
        let tentacleBaseRadius: Float
        let tentacleAttachY: Float
        // Collision radius for pairwise separation (pre-scale, in local units)
        let collisionRadius: Float
        // Per-jelly forward motion speed (so #2 can differ deterministically)
        var moveSpeed: Float
        // --- NEW: phase offset for frill sharing ---
        var frillPhaseOffset: Float
        var dotFlickerPhase: Int // NEW: tracks which dots are flickering
    }
    private var jellyfishList: [Jellyfish] = []
    weak var sceneRef: SCNScene?
    private let jellyfishCount = 5
    private let rootNode = SCNNode()
    
    // Expose scnView for view integration
    weak var scnView: SCNView?
    
    // Provide visual bounds similar to other sims (for world->CC fallback)
    var visualBounds: Float {
        if let scene = sceneRef,
           let cameraState = (scene as? NSObject)?.value(forKey: "cameraState") as? CameraOrbitState {
            return cameraState.visualBounds
        }
        return 30.0
    }
    // Parameters for animation and control
    private var pulseSpeed: Float = 1.0
    private var swaySpeed: Float = 0.6
    private var verticalDriftSpeed: Float = 0.25
    private var jellySize: Float = 2.0
    private var rotation: Float = 0.0
    private var bellCurve: CGFloat = 0.9 // Controls how round the bell top is
    private var bellHeight: CGFloat = 1.2 // Default bell height multiplier
    private var frillAmplitude: CGFloat = 0.12 // Amplitude of rim frill
    private var frillFrequency: CGFloat = 6.0 // Frequency of rim frill
    private var outerHoodYBreathAmount: Float = 0.22 // amplitude for Y-only breathing on outer hood
    private var outerHoodYBreathPhaseOffset: Float = .pi // phase offset (radians) for outer hood Y breathing
    private var innerHoodYScale: CGFloat = 0.55 // Controls Y scale of inner hood
    private var outerHoodYOffset: Float = 0.38 // Offset for outer hood Y position
    private var tentacleOriginRatio: Float = 0.3 // Ratio of bell radius for tentacle origin (0=center, 1=rim)
    private var frillLength: CGFloat = 0.86 // Default frill length
    
    // Boundary parameters (cube)
    // Remove hardcoded boundaries
   // private var boundaryMin = SCNVector3(-1, -1.0, -1)
    //private var boundaryMax = SCNVector3(0.5, 0.5, 0.5)
    
    // --- Scale logic ---
    private var scale: Float = 1.0 // Initial scale value
    private let minScale: Float = 0.4
    private let maxScale: Float = 3.5
    
    // --- Variation controls ---
    // How much the 2nd jellyfish's size can vary relative to the 1st (e.g. 0.25 -> ±25%)
    private var sizeVariationFactor: Float = 0.7
    // How much the 2nd jellyfish's forward speed can vary relative to the 1st
    private var moveSpeedVariationFactor: Float = 0.85
    
    // Debug: throttle console logs
    // Debug: throttle console logs
    private var frameCount: Int = 0
    private var waterCurrentStrength: Float = 0.0
    private var waterCurrentPhase: Float = 0.0
    private var waterCurrentPhaseFast: Float = 0.0

    // --- Parameters for boundary steering ---
    private let boundaryMarginFactor: Float = 0.12 // 12% of field size
    private let boundarySteeringStrength: Float = 0.8 // steering force multiplier
    private let maxVelocity: Float = 1.2 // max speed for jellyfish
    
    // --- Simplified boundary ---
    private var boundaryWidth: Float = 20.0
    private var boundaryHeight: Float = 20.0
    private var boundaryDepth: Float = 20.0
    private var lastViewSize: CGSize = .zero // Track last view size
    private let staticZPosition: Float = 0 // Static Z position for all jellyfish
    private var pendingViewSizeCheck: Bool = false // Prevent repeated scheduling while a size check is pending
    private var didBuild: Bool = false // Tracks whether heavy geometry has been built

    private func handleViewSizeChange(size: CGSize) {
        guard size != .zero, size != lastViewSize else { return }
        lastViewSize = size
        _ = getBoundaryMinMax()
    }

    func setWaterCurrentStrength(_ value: Float) {
        // Clamp or scale as desired (example: 0...2)
        waterCurrentStrength = max(0, min(2.0, value))
    }

    // Helper to get min/max boundary coordinates
    private func getBoundaryMinMax() -> (min: SCNVector3, max: SCNVector3) {
        let min = SCNVector3(-boundaryWidth/2, -boundaryHeight/2, -boundaryDepth/2)
        let max = SCNVector3(boundaryWidth/2, boundaryHeight/2, boundaryDepth/2)
        return (min, max)
    }

    func setBoundaryScale(width: Float, height: Float, depth: Float) {
        boundaryWidth = width
        boundaryHeight = height
        boundaryDepth = depth
       // updateBoundaryNode()
    }

   
    init(scene: SCNScene, scnView: SCNView?, deferBuild: Bool = false) {
        self.sceneRef = scene
        self.scnView = scnView
        scene.rootNode.addChildNode(rootNode)
        setupCameraIfNeeded()
        alignSceneWithScreenSpace() // basic alignment; jellyfish may be added later if deferred
        rootNode.scale = SCNVector3(scale, scale, scale)
        if !deferBuild { buildAll() }
    }

    private func buildAll() {
        guard !didBuild else { return }
        buildJellyfish()
        addSimpleDirectionalLight()
        enforceSeparation(iterations: 1)
        didBuild = true
    }

    public func ensureBuilt() { buildAll() }
    
    private func setupCameraIfNeeded() {
        guard let view = scnView else { return }
        if view.pointOfView == nil {
            let camNode = SCNNode()
            let cam = SCNCamera()
            cam.usesOrthographicProjection = true
            camNode.camera = cam
            camNode.position = SCNVector3(0, 0, 10)
            view.scene?.rootNode.addChildNode(camNode)
            view.pointOfView = camNode
        }
    }
    //private func ensureBoundaryCorners() {
    //    if boundaryCorners.count != 8, let calc = calculateWorldBoundaries() {
    //        setBoundaryDimensions(min: calc.min, max: calc.max)
     //   }
   // }
    // Align scenespace with screenspace so that the visible area matches the screen size exactly
    private func alignSceneWithScreenSpace() {
        setupCameraIfNeeded()
        guard let scnView = scnView, let cameraNode = scnView.pointOfView, let camera = cameraNode.camera else { return }
        camera.usesOrthographicProjection = true
        // Use a fixed orthographic scale for content size
        camera.orthographicScale = 20.0
        let bounds = getBoundaryMinMax()
        let center = SCNVector3(
            (bounds.min.x + bounds.max.x) * 0.5,
            (bounds.min.y + bounds.max.y) * 0.5,
            (bounds.min.z + bounds.max.z) * 0.5
        )
        rootNode.position = center
        cameraNode.position = SCNVector3(center.x, center.y, 10)
        cameraNode.look(at: center)
        cameraNode.eulerAngles = SCNVector3Zero
       // rootNode.scale = SCNVector3(1, 1, 1)
        // No boundaryCorners logic
       // updateBoundaryNode()
    }
    
    public func realignAfterViewAttached() { alignSceneWithScreenSpace() }
    
    func reset() {
        // Remove all child nodes and actions from rootNode and its children
        rootNode.removeAllActions()
        rootNode.enumerateChildNodes { node, _ in
            node.removeAllActions()
            node.removeFromParentNode()
        }
        // Remove all jellyfish nodes and clear arrays
        jellyfishList.forEach { jelly in
            jelly.outerHood.removeAllActions()
            jelly.outerHood.removeFromParentNode()
            jelly.innerHood.removeAllActions()
            jelly.innerHood.removeFromParentNode()
            jelly.frillNodes.forEach { $0.removeAllActions(); $0.removeFromParentNode() }
            jelly.tentacleSegments.flatMap { $0 }.forEach { $0.node.removeAllActions(); $0.node.removeFromParentNode() }
            jelly.tentacleConnectors.flatMap { $0 }.forEach { $0.removeAllActions(); $0.removeFromParentNode() }
            jelly.dotNodes.forEach { $0.removeAllActions(); $0.removeFromParentNode() }
        }
        jellyfishList.removeAll(keepingCapacity: false)
        buildJellyfish()
        enforceSeparation(iterations: 2)
    }
    
    private func buildJellyfish() {
        guard sceneRef != nil else { return }
        jellyfishList.removeAll(keepingCapacity: true)
        // Build first jellyfish normally
        let config0 = randomConfig(index: 0)
        var j0 = buildSingleJellyfish(config: config0)
        j0.moveSpeed = 0.18
        j0.frillPhaseOffset = 0.0 // No offset for jellyfish 1
        jellyfishList.append(j0)
        // If only one jellyfish is requested, stop here
        guard jellyfishCount > 1 else { return }
        // Build second jellyfish with controlled differences
        var config1 = randomConfig(index: 1)
        // Enforce size difference relative to j0 using ±sizeVariationFactor
        let ratio0: CGFloat = max(0.3, min(2.0, config1.innerRadius / max(0.0001, config1.outerRadius)))
        var sizeScale: Float = 1.0
        // Try a few times to avoid being too similar to 1.0
        for _ in 0..<3 {
            let minScale = max(0.1, 1.0 - sizeVariationFactor)
            let maxScale = 1.0 + sizeVariationFactor
            let s = Float.random(in: minScale...maxScale)
            if abs(s - 1.0) > 0.06 { sizeScale = s; break }
            sizeScale = s
        }
        let newOuter: CGFloat = config0.outerRadius * CGFloat(sizeScale)
        let newInner: CGFloat = max(0.05, newOuter * ratio0)
        config1 = JellyfishConfig(
            position: config1.position,
            outerRadius: newOuter,
            innerRadius: newInner,
            hoodColor: config1.hoodColor,
            innerColor: config1.innerColor,
            hoodAlpha: config1.hoodAlpha,
            innerAlpha: config1.innerAlpha,
            frillColor: config1.frillColor,
            frillAlpha: config1.frillAlpha,
            frillCount: 0, // No frills for 2nd jellyfish
            tentacleCount: 0, // No tentacles for 2nd jellyfish
            tentacleLength: config1.tentacleLength,
            tentacleColor: config1.tentacleColor,
            tentacleAlpha: config1.tentacleAlpha
        )
        var j1 = buildSingleJellyfish(config: config1)
        // Share frill phases with jellyfish 1, but offset
        j1.frillPhases = j0.frillPhases
        j1.frillPhaseOffset = Float.pi / 2 // Offset for jellyfish 2
        // Force a clearly different breathing phase for #2
        let phaseOffset = Float.random(in: 0.7 * Float.pi ... 1.3 * Float.pi)
        j1.pulsePhase = fmodf(j0.pulsePhase + phaseOffset, Float.pi * 2)
        // Keep prevOuterBreath consistent with the new phase to avoid a jump
        j1.prevOuterBreath = sinf(j1.pulsePhase + outerHoodYBreathPhaseOffset)
        // Give #2 a different forward motion speed
        var msScale: Float = 1.0
        for _ in 0..<3 {
            let minS = max(0.1, 1.0 - moveSpeedVariationFactor)
            let maxS = 1.0 + moveSpeedVariationFactor
            let s = Float.random(in: minS...maxS)
            if abs(s - 1.0) > 0.06 { msScale = s; break }
            msScale = s
        }
        j1.moveSpeed = j0.moveSpeed * msScale
        jellyfishList.append(j1)
        // Build any remaining jellyfish (if count > 2) with custom rules
        if jellyfishCount > 2 {
            for i in 2..<jellyfishCount {
                var config = randomConfig(index: i)
                // 3rd jellyfish: use only inner hood, hide outer hood, but keep dots
                if i == 2 {
                    config = JellyfishConfig(
                        position: config.position,
                        outerRadius: config.innerRadius, // swap: use inner radius for outer hood
                        innerRadius: config.innerRadius, // keep inner hood
                        hoodColor: config.innerColor,    // swap: use inner color for outer hood
                        innerColor: config.innerColor,
                        hoodAlpha: config.innerAlpha,    // swap: use inner alpha for outer hood
                        innerAlpha: config.innerAlpha,
                        frillColor: config.frillColor,
                        frillAlpha: config.frillAlpha,
                        frillCount: config.frillCount,
                        tentacleCount: config.tentacleCount,
                        tentacleLength: config.tentacleLength,
                        tentacleColor: config.tentacleColor,
                        tentacleAlpha: config.tentacleAlpha
                    )
                }
                // 4th jellyfish: no tentacles
                if i == 3 {
                    config = JellyfishConfig(
                        position: config.position,
                        outerRadius: config.outerRadius,
                        innerRadius: config.innerRadius,
                        hoodColor: config.hoodColor,
                        innerColor: config.innerColor,
                        hoodAlpha: config.hoodAlpha,
                        innerAlpha: config.innerAlpha,
                        frillColor: config.frillColor,
                        frillAlpha: config.frillAlpha,
                        frillCount: config.frillCount,
                        tentacleCount: 0, // No tentacles
                        tentacleLength: 0,
                        tentacleColor: config.tentacleColor,
                        tentacleAlpha: config.tentacleAlpha
                    )
                }
                var j = buildSingleJellyfish(config: config)
                j.moveSpeed = 0.18 * Float.random(in: 1.0 - moveSpeedVariationFactor ... 1.0 + moveSpeedVariationFactor)
                jellyfishList.append(j)
            }
        }
    }
    
    private struct JellyfishConfig {
        let position: SCNVector3
        let outerRadius: CGFloat
        let innerRadius: CGFloat
        let hoodColor: UIColor
        let innerColor: UIColor
        let hoodAlpha: CGFloat
        let innerAlpha: CGFloat
        let frillColor: UIColor
        let frillAlpha: CGFloat
        let frillCount: Int
        let tentacleCount: Int
        let tentacleLength: Int
        let tentacleColor: UIColor
        let tentacleAlpha: CGFloat
    }
    
    // Helper to get the center of the boundary
    private func getBoundaryCenter() -> SCNVector3 {
        let bounds = getBoundaryMinMax()
        return SCNVector3(
            (bounds.min.x + bounds.max.x) * 0.5,
            (bounds.min.y + bounds.max.y) * 0.5,
            (bounds.min.z + bounds.max.z) * 0.5
        )
    }
    
    private func randomConfig(index: Int) -> JellyfishConfig {
        let outerRadius = CGFloat.random(in: 0.7...1.2)
        let innerRadius = outerRadius * CGFloat.random(in: 0.55...0.85)
        // Jellyfish should start at the center of the boundary in world space
        let position = getBoundaryCenter()
        // --- Outer hood base color ---
        let hoodRed = CGFloat.random(in: 0.8...1.0)
        let hoodGreen = CGFloat.random(in: 0.7...1.0)
        let hoodBlue = CGFloat.random(in: 0.8...1.0)
        let hoodColor = UIColor(red: hoodRed, green: hoodGreen, blue: hoodBlue, alpha: 0.8)
        // --- Inner hood color: offset red or blue channel ---
        let colorVariance = CGFloat.random(in: -0.08...0.08)
        let varyRed = Bool.random()
        let innerRed = min(max(hoodRed + (varyRed ? colorVariance : 0), 0), 1)
        let innerBlue = min(max(hoodBlue + (varyRed ? 0 : colorVariance), 0), 1)
        let innerGreen = hoodGreen // keep green similar
        let innerColor = UIColor(red: innerRed, green: innerGreen, blue: innerBlue, alpha: 0.4)
        let hoodAlpha = self.hoodAlpha
        // Use class properties for alpha values
        let innerAlpha = self.innerAlpha
        let frillAlpha = self.frillAlpha
        let frillCount = self.frillCount // Use property instead of hardcoded value
        let tentacleCount = 1 // 5 + 2 more tentacles
        let tentacleLength = 3
        let frillColor = UIColor(
            red: CGFloat.random(in: 0.2...1.0),
            green: CGFloat.random(in: 0.2...1.0),
            blue: CGFloat.random(in: 0.2...1.0),
            alpha: 1.0
        )
        let tentacleColor = UIColor(
            red: CGFloat.random(in: 0.2...1.0),
            green: CGFloat.random(in: 0.2...1.0),
            blue: CGFloat.random(in: 0.2...1.0),
            alpha: 1.0
        )
        let tentacleAlpha = self.tentacleAlpha
        return JellyfishConfig(
            position: position,
            outerRadius: outerRadius,
            innerRadius: innerRadius,
            hoodColor: hoodColor,
            innerColor: innerColor,
            hoodAlpha: hoodAlpha,
            innerAlpha: innerAlpha,
            frillColor: frillColor,
            frillAlpha: frillAlpha,
            frillCount: frillCount,
            tentacleCount: tentacleCount,
            tentacleLength: tentacleLength,
            tentacleColor: tentacleColor,
            tentacleAlpha: tentacleAlpha
        )
    }
    
    // Bell mesh generator
    private func bellMesh(radius: CGFloat, height: CGFloat, rimSegments: Int, curve: CGFloat = 0.6, verticalSegments: Int = 8, flare: CGFloat = 0.18, rimOverride: [SCNVector3]? = nil) -> SCNGeometry {
        var positions: [SCNVector3] = []
        let hemisphereSegments = verticalSegments / 2
        let flareSegments = verticalSegments - hemisphereSegments
        // Hemisphere (top half of sphere)
        for v in 0...hemisphereSegments {
            let phi = (.pi / 2) * CGFloat(v) / CGFloat(hemisphereSegments) // 0 to pi/2
            let y = height * cos(phi)
            let r = radius * sin(phi)
            for i in 0..<rimSegments {
                let angle = CGFloat(i) / CGFloat(rimSegments) * .pi * 2
                let x = r * cos(angle)
                let z = r * sin(angle)
                positions.append(SCNVector3(x, y, z))
            }
        }
        // Flare (from equator to rim)
        let equatorY = height * cos(.pi/2)
        let equatorR = radius * sin(.pi/2)
        for v in 1...flareSegments {
            let t = CGFloat(v) / CGFloat(flareSegments)
            let r = equatorR * (1 + flare * t)
            for i in 0..<rimSegments {
                let angle = CGFloat(i) / CGFloat(rimSegments) * .pi * 2
                // Frilly rim: sine wave offset on y
                let frill = frillAmplitude * sin(frillFrequency * angle)
                let y = equatorY - height * 0.18 * t + frill
                let x = r * cos(angle)
                let z = r * sin(angle)
                positions.append(SCNVector3(x, y, z))
            }
        }
        // If provided, override the rim ring (last ring before apex) with external positions
        if let rim = rimOverride, rim.count == rimSegments {
            let rimStart = (hemisphereSegments + flareSegments) * rimSegments
            for i in 0..<rimSegments { positions[rimStart + i] = rim[i] }
        }
        // Add apex point (center top)
        positions.append(SCNVector3(0, height, 0))
        let apexIndex = Int(positions.count - 1)
        // Build triangle indices
        var indices: [Int32] = []
        // Connect apex to first ring
        for i in 0..<rimSegments {
            let next = (i + 1) % rimSegments
            indices.append(Int32(apexIndex))
            indices.append(Int32(i))
            indices.append(Int32(next))
        }
        // Connect vertical rings
        let totalSegments = hemisphereSegments + flareSegments
        for v in 0..<totalSegments {
            let ringStart = v * rimSegments
            let nextRingStart = (v + 1) * rimSegments
            for i in 0..<rimSegments {
                let next = (i + 1) % rimSegments
                // First triangle
                indices.append(Int32(ringStart + i))
                indices.append(Int32(nextRingStart + i))
                indices.append(Int32(nextRingStart + next))
                // Second triangle
                indices.append(Int32(ringStart + i))
                indices.append(Int32(nextRingStart + next))
                indices.append(Int32(ringStart + next))
            }
        }
        let vertexSource = SCNGeometrySource(vertices: positions)
        // Normals: point outwards from bell center for smooth shading
        let bellCenter = SCNVector3(0, height * 0.5, 0)
        var normals: [SCNVector3] = []
        for v in positions {
            let n = (v - bellCenter).normalized()
            normals.append(n)
        }
        let normalSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
    }
    
    private struct TentacleSegment {
        let node: SCNNode
        let angle: Float
        let segmentIndex: Int
    }
    
    private func buildSingleJellyfish(config: JellyfishConfig) -> Jellyfish {
        // Outer hood (bell mesh)
        let rimSegments = 16 // Lowered from 32 for performance
        let outerGeom = bellMesh(radius: config.outerRadius, height: config.outerRadius * bellHeight, rimSegments: rimSegments, curve: bellCurve)
        let outerMat = SCNMaterial()
        // Texture setup
        outerMat.diffuse.contents = config.hoodColor.withAlphaComponent(config.hoodAlpha)
        // Make it shiny
        //outerMat.specular.contents = UIColor.white
       // outerMat.shininess = 100.0
        // Make it grainy (simulate with roughness)
        // Optionally, add a subtle metallic effect
       // outerMat.metalness.contents = 0.75
        outerMat.isDoubleSided = false
        outerMat.transparency = config.hoodAlpha
        outerMat.blendMode = .alpha
        outerGeom.firstMaterial = outerMat
        let outerNode = SCNNode(geometry: outerGeom)
        outerNode.castsShadow = false // Disable shadow casting for performance
        // Offset outer hood Y position
        outerNode.position = SCNVector3(config.position.x, config.position.y + outerHoodYOffset, config.position.z)
        rootNode.addChildNode(outerNode)
        // Compute outer rim positions so inner rim can match exactly
        let outBellRad = config.outerRadius
        let outBellHt = config.outerRadius * bellHeight
        let outFlare: CGFloat = 0.18
        var outerRimPositions: [SCNVector3] = []
        for i in 0..<rimSegments {
            let angle = CGFloat(i) / CGFloat(rimSegments) * .pi * 2
            let t: CGFloat = 1.0 // rim
            let r = outBellRad * (1 + outFlare * t)
            let frill = frillAmplitude * sin(frillFrequency * angle)
            let y = outBellHt * cos(.pi/2) - outBellHt * 0.18 * t + frill
            let x = r * cos(angle)
            let z = r * sin(angle)
            outerRimPositions.append(SCNVector3(x, y, z))
        }
        // Inner hood (smaller bell mesh), but force rim to match the outer hood rim positions
        let innerGeom = bellMesh(radius: config.innerRadius, height: config.innerRadius * (bellHeight * 0.92), rimSegments: rimSegments, curve: bellCurve, rimOverride: outerRimPositions)
        let innerMat = SCNMaterial()
        innerMat.diffuse.contents = config.innerColor.withAlphaComponent(config.innerAlpha)
        innerMat.isDoubleSided = false
        innerMat.transparency = config.innerAlpha
        innerMat.blendMode = .alpha // Changed from .add to .alpha
        innerMat.emission.contents = config.innerColor.withAlphaComponent(config.innerAlpha)
        innerMat.emission.intensity = 0.5 // Added emission for inner hood
        innerGeom.firstMaterial = innerMat
        let innerNode = SCNNode(geometry: innerGeom)
        innerNode.castsShadow = false // Disable shadow casting for performance
        innerNode.position = config.position // leave inner hood at original position
        rootNode.addChildNode(innerNode)
        // --- Place omni light between inner and outer hoods ---
      //  let outerPos = outerNode.position
       //  let innerPos = innerNode.position
        // Calculate midpoint between inner and outer hoods
      //  let midPos = SCNVector3(
      //      (outerPos.x + innerPos.x) * 0.5,
      //      (outerPos.y + innerPos.y) * 0.5,
      //      (outerPos.z + innerPos.z) * 0.5
      //  )
       /* let glowLightNode = SCNNode()
        let glowLight = SCNLight()
        glowLight.type = .omni
        glowLight.color = config.innerColor.withAlphaComponent(0.7)
        glowLight.intensity = 0.0 // low intensity for subtle glow
        glowLight.attenuationStartDistance = 0.0
        glowLight.attenuationEndDistance = 2.2 * config.outerRadius * bellHeight
        glowLightNode.light = glowLight
        glowLightNode.position = midPos
        rootNode.addChildNode(glowLightNode)*/
        // Extract rim positions from both hoods
        func extractRimPositions(from geometry: SCNGeometry, rimSegments: Int) -> [SCNVector3] {
            guard let vertexSource = geometry.sources(for: .vertex).first else { return [] }
            let vectorCount = vertexSource.vectorCount
            let stride = vertexSource.dataStride
            let offset = vertexSource.dataOffset
            let bytesPerVector = vertexSource.bytesPerComponent * 3
            let data = vertexSource.data
            // The rim ring is the last ring before the apex
            let rimStart = vectorCount - rimSegments - 1 // -1 for apex
            var positions: [SCNVector3] = []
            for i in 0..<rimSegments {
                let idx = rimStart + i
                let byteRange = (offset + idx * stride)..<(offset + idx * stride + bytesPerVector)
                let subdata = data.subdata(in: byteRange)
                let floats = subdata.withUnsafeBytes { ptr -> [Float] in
                    let buffer = ptr.bindMemory(to: Float.self)
                    return [buffer[0], buffer[1], buffer[2]]
                }
                positions.append(SCNVector3(floats[0], floats[1], floats[2]))
            }
            return positions
        }
        let innerRimPositions = extractRimPositions(from: innerGeom, rimSegments: rimSegments)
        let outerRimPositionsForTrim = extractRimPositions(from: outerGeom, rimSegments: rimSegments)
        // Tentacles simplified: single spheres attached to the outer hood with no animation
        var tentacleSegments: [[TentacleSegment]] = []
        var tentacleConnectors: [[SCNNode]] = []
        let tentacleStems: [SCNNode] = []
        let tentacleBaseRadius = Float(config.outerRadius) * tentacleOriginRatio
        let localAttachY = -Float(config.outerRadius) * 0.12 // relative to outer hood
        let tentacleSegmentSpacing: Float = 0.32 // vertical spacing between segments
        for i in 0..<config.tentacleCount {
            let angle = (Float(i) / Float(max(1, config.tentacleCount))) * Float.pi * 2
            let localX = tentacleBaseRadius * sin(angle)
            let localZ = tentacleBaseRadius * cos(angle)
            var tentacleChain: [TentacleSegment] = []
            var connectorChain: [SCNNode] = []
            var prevNode: SCNNode? = nil
            // Central tentacle: matches frill color and alphax
            if i == config.tentacleCount / 2 {
                let centralColor = config.frillColor
                let centralAlpha: CGFloat = min(1.0, config.frillAlpha * 1.5) // much brighter
                let threadRadius: CGFloat = 0.022 // thin
                let segCount = 8 // longer chain
                let threadLength: CGFloat = 1.8 // total length
                let segLen: CGFloat = threadLength / CGFloat(segCount)
                let segYStart = localAttachY
                let tentacleRoot = SCNNode()
                outerNode.addChildNode(tentacleRoot)
                tentacleRoot.position = SCNVector3(localX, segYStart, localZ)
                var parentNode: SCNNode = tentacleRoot
                for s in 0..<segCount {
                    let segGeom = SCNCylinder(radius: threadRadius, height: segLen)
                    let segMat = SCNMaterial()
                    segMat.diffuse.contents = centralColor // Opaque
                    segMat.isDoubleSided = false
                    segMat.transparency = 1.0 // Opaque
                    segMat.blendMode = .alpha
                    segMat.emission.contents = centralColor
                    segMat.emission.intensity = 1.2 // much brighter emission
                    segGeom.firstMaterial = segMat
                    let segNode = SCNNode(geometry: segGeom)
                    segNode.pivot = SCNMatrix4MakeTranslation(0, Float(segLen/2.0), 0)
                    parentNode.addChildNode(segNode)
                    if s > 0 { segNode.position = SCNVector3(0, -Float(segLen), 0) }
                    parentNode = segNode
                    tentacleChain.append(TentacleSegment(node: segNode, angle: angle, segmentIndex: s))
                }
                tentacleSegments.append(tentacleChain)
                tentacleConnectors.append(connectorChain)
                continue
            }
            // Other tentacles: shade brighter than frill color
            let frillRGBA = config.frillColor.cgColor.components ?? [1,1,1,1]
            let brighten: CGFloat = 1.0 // match frill color exactly
            let tentacleColor = UIColor(
                red: min(max(frillRGBA[0] * brighten, 0), 1),
                green: min(max(frillRGBA[1] * brighten, 0), 1),
                blue: min(max(frillRGBA[2] * brighten, 0), 1),
                alpha: 1.0
            )
            let tentacleAlpha: CGFloat = min(1.0, config.frillAlpha * 1.5) // much brighter
            for seg in 0..<config.tentacleLength {
                let sphereGeom = SCNSphere(radius: 0.12)
                let beadMat = SCNMaterial()
                beadMat.diffuse.contents = tentacleColor // Opaque
                beadMat.isDoubleSided = false
                beadMat.transparency = 1.0 // Opaque
                beadMat.blendMode = .alpha
                beadMat.emission.contents = tentacleColor
                beadMat.emission.intensity = 0.3 // much brighter emission
                sphereGeom.firstMaterial = beadMat
                let sphereNode = SCNNode(geometry: sphereGeom)
                sphereNode.castsShadow = false // Disable shadow casting for tentacle segment
                let segY = localAttachY - Float(seg) * tentacleSegmentSpacing
                sphereNode.position = SCNVector3(localX, segY, localZ)
                // Optionally, add a tiny omni light for real emission (commented for performance)
                /*
                let glowLight = SCNLight()
                glowLight.type = .omni
                glowLight.color = tentacleColor.withAlphaComponent(0.18)
                glowLight.intensity = 8 // very low
                glowLight.attenuationStartDistance = 0.0
                glowLight.attenuationEndDistance = 0.22
                let glowNode = SCNNode()
                glowNode.light = glowLight
                sphereNode.addChildNode(glowNode)
                */
                outerNode.addChildNode(sphereNode)
                tentacleChain.append(TentacleSegment(node: sphereNode, angle: angle, segmentIndex: seg))
                // Add connector cylinder between previous and current segment
                if let prev = prevNode {
                    let cylGeom = SCNCylinder(radius: 0.045, height: 0.1)
                    // Use outer hood material for tentacle connectors
                    let cylMat = SCNMaterial()
                    cylMat.diffuse.contents = tentacleColor // Opaque
                    cylMat.isDoubleSided = false
                    cylMat.transparency = 1.0 // Opaque
                    cylMat.blendMode = .alpha
                    cylGeom.firstMaterial = cylMat
                    let cylNode = SCNNode(geometry: cylGeom)
                    cylNode.castsShadow = false // Disable shadow casting for tentacle connector
                    outerNode.addChildNode(cylNode)
                    connectorChain.append(cylNode)
                }
                prevNode = sphereNode
            }
            tentacleSegments.append(tentacleChain)
            tentacleConnectors.append(connectorChain)
        }
        // Frill ring
        var frillNodes: [SCNNode] = []
        var frillPhases: [Float] = []
        var frillChains: [[SCNNode]] = []
        // Create a single shared frill material for all frills
        let sharedFrillMat = SCNMaterial()
        sharedFrillMat.diffuse.contents = config.frillColor.withAlphaComponent(config.frillAlpha)
        sharedFrillMat.isDoubleSided = false
        sharedFrillMat.transparency = config.frillAlpha
        sharedFrillMat.blendMode = .add
        sharedFrillMat.emission.contents = config.frillColor.withAlphaComponent(min(config.frillAlpha * 0.55, 1.0))
        //let rimSegments = 32
        let bellRad = config.outerRadius
        let bellHt = config.outerRadius * bellHeight
        let flare: CGFloat = 0.18
        let frillRad = bellRad * (1 + flare)
        let equatorY = bellHt * cos(.pi/2)
        let rimY = equatorY - bellHt * 0.18 + frillAmplitude // y at rim
        for i in 0..<config.frillCount {
            let angle = CGFloat(i) / CGFloat(config.frillCount) * .pi * 2
            let x = frillRad * cos(angle)
            let z = frillRad * sin(angle)
            let threadRadius: CGFloat = 0.02 // slightly thinner thread
            let threadLength: CGFloat = frillLength * (0.92 + CGFloat.random(in: -0.06...0.06))
            // Use shared material for all frills
            let frillMat = sharedFrillMat
            // Root anchor at rim (no geometry)
            let frillRoot = SCNNode()
            frillRoot.castsShadow = false // Disable shadow casting for frill root
            outerNode.addChildNode(frillRoot)
            frillRoot.position = SCNVector3(x, CGFloat(rimY), z)
            // Build a segmented chain so the tip can sway more (drag at the end)
            let segCount = 10
            let segLen: CGFloat = threadLength / CGFloat(segCount)
            var parentNode: SCNNode = frillRoot
            var chain: [SCNNode] = []
            for s in 0..<segCount {
                let segGeom = SCNCylinder(radius: threadRadius, height: segLen)
                segGeom.firstMaterial = frillMat
                let segNode = SCNNode(geometry: segGeom)
                segNode.castsShadow = false // Disable shadow casting for frill segment
                // anchor at top so each segment extends downward
                segNode.pivot = SCNMatrix4MakeTranslation(0, Float(segLen/2.0), 0)
                parentNode.addChildNode(segNode)
                if s > 0 { segNode.position = SCNVector3(0, -Float(segLen), 0) }
                parentNode = segNode
                chain.append(segNode)
            }
            // Removed tip light from frill tip for performance
            frillNodes.append(frillRoot)
            frillPhases.append(Float.random(in: 0...Float.pi*2))
            frillChains.append(chain)
        }
        // --- Luminescent dots on hood top ---
        let dotCount = self.dotCount // Use the current property value
        var dotNodes: [SCNNode] = []
        var dotPhases: [Float] = []
        let bellHeightVal = Float(config.outerRadius * bellHeight)
        let bellRadiusVal = Float(config.outerRadius)
        let bellCenterVec = SCNVector3(0, bellHeightVal * 0.5, 0)
        // Create a copy of innerMat for dots, but with emission enabled
        let dotMatFromInner = SCNMaterial()
        dotMatFromInner.diffuse.contents = innerMat.diffuse.contents
        dotMatFromInner.isDoubleSided = innerMat.isDoubleSided
        dotMatFromInner.transparency = innerMat.transparency
        dotMatFromInner.blendMode = innerMat.blendMode
        dotMatFromInner.lightingModel = .physicallyBased
        dotMatFromInner.emission.contents = config.innerColor.withAlphaComponent(0.8)
        dotMatFromInner.emission.intensity = 1.5
        // Disperse dots using stratified bands for phi
        let bandCount = 5
        let dotsPerBand = dotCount / bandCount
        let dotMaterial: SCNMaterial = dotMatFromInner
        for band in 0..<bandCount {
            let phiMin = Float(band) * (Float.pi/2) / Float(bandCount)
            let phiMax = Float(band+1) * (Float.pi/2) / Float(bandCount)
            for _ in 0..<dotsPerBand {
                let phi = Float.random(in: phiMin...phiMax) // wider range, covers more of hood
                let theta = Float.random(in: 0...Float.pi*2)
                let r = bellRadiusVal * sin(phi)
                let y = bellHeightVal * cos(phi)
                let x = r * cos(theta)
                let z = r * sin(theta)
                let dotGeom = SCNSphere(radius: 0.05)
                dotGeom.firstMaterial = dotMaterial
                let dotNode = SCNNode(geometry: dotGeom)
                dotNode.castsShadow = false // Disable shadow casting for dot
                let rawPos = SCNVector3(x, y, z)
                let outward = (rawPos - bellCenterVec).normalized()
                let outwardOffset = 0.06 * Float(config.outerRadius)
                dotNode.position = rawPos + outward * outwardOffset
                dotNode.renderingOrder = 100
                outerNode.addChildNode(dotNode)
                dotNodes.append(dotNode)
                dotPhases.append(Float.random(in: 0...Float.pi*2))
            }
        }
        let pulsePhase = Float.random(in: 0...Float.pi*2)
        let pulseSpeed = self.pulseSpeed // Use simulation's pulseSpeed, not random
        let swayPhase = Float.random(in: 0...Float.pi*2)
        let swaySpeed = Float.random(in: 0.3...0.7)
        let driftPhase = Float.random(in: 0...Float.pi*2)
        let driftSpeed = Float.random(in: 0.1...0.3)
        let prevOuterBreath: Float = sinf(pulsePhase + outerHoodYBreathPhaseOffset) // initial breath
        // --- Initialize velocity for boids movement ---
        // Give each jellyfish a random direction and speed for velocity
        let angle = Float.random(in: 0...(2 * Float.pi))
        let speed = Float.random(in: 0.08...0.35)
        let velocity = SCNVector3(
            cos(angle) * speed,
            sin(angle) * speed,
            0 // keep Z static for now
        )
        return Jellyfish(
            outerHood: outerNode,
            innerHood: innerNode,
            frillNodes: frillNodes,
            frillPhases: frillPhases,
            frillChains: frillChains,
            tentacleStems: tentacleStems,
            tentacleSegments: tentacleSegments,
            tentacleConnectors: tentacleConnectors,
            basePosition: config.position,
            velocity: velocity, // NEW
            dotNodes: dotNodes,
            dotPhases: dotPhases,
            dotSharedMaterial: dotMatFromInner,
            pulsePhase: pulsePhase,
            pulseSpeed: pulseSpeed,
            swayPhase: swayPhase,
            swaySpeed: swaySpeed,
            driftPhase: driftPhase,
            driftSpeed: driftSpeed,
            prevOuterBreath: prevOuterBreath,
          //  glowLightNode: glowLightNode,
            tentacleBaseRadius: Float(config.outerRadius) * tentacleOriginRatio,
            tentacleAttachY: -Float(config.outerRadius) * 0.12,
            collisionRadius: Float(config.outerRadius),
            moveSpeed: 0.18, // default; may be overridden for #2
            frillPhaseOffset: 0.0, // default value, will be set in buildJellyfish
            dotFlickerPhase: 0 // NEW: initialize flicker phase
        )
    }
    
    // Helper to calculate world boundaries from SCNView and camera
    private func calculateWorldBoundaries() -> (min: SCNVector3, max: SCNVector3)? {
        guard let view = scnView, let cameraNode = view.pointOfView, let camera = cameraNode.camera else { return nil }
        // Only support orthographic for now
        guard camera.usesOrthographicProjection else { return nil }
        let scale = Float(camera.orthographicScale)
       
        let minX = -scale
        let maxX = scale
        let minY = -scale
        let maxY = scale
        // Force a small symmetric Z range around 0 so geometry is safely in front of camera (camera looks along -Z from positive Z)
        let minZ: Float = -scale
        let maxZ: Float = scale
        return (SCNVector3(minX, minY, minZ), SCNVector3(maxX, maxY, maxZ))
    }
    
    public var isWorkbenchMode: Bool = false

    // MARK: - Jellyfish simulation update
    func update(deltaTime: Float) {
        setupCameraIfNeeded()
        // Detect SCNView size change (especially from zero after layout) without blocking the calling thread.
        if let view = scnView {
            if Thread.isMainThread {
                handleViewSizeChange(size: view.bounds.size)
            } else {
                if !pendingViewSizeCheck { // throttle scheduling
                    pendingViewSizeCheck = true
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, let v = self.scnView else { self?.pendingViewSizeCheck = false; return }
                        self.handleViewSizeChange(size: v.bounds.size)
                        self.pendingViewSizeCheck = false
                    }
                }
            }
        }
        // Apply rotation from slider to root node (yaw)
        rootNode.eulerAngles.y = rotation * (.pi / 180)
        frameCount &+= 1
        let boundaries = getBoundaryMinMax() // <-- direct assignment, not conditional binding
        let minX = boundaries.min.x
        let maxX = boundaries.max.x
        let minY = boundaries.min.y
        let maxY = boundaries.max.y
        let minZ = boundaries.min.z
        let maxZ = boundaries.max.z
        let marginX = (maxX - minX) * boundaryMarginFactor
        let marginY = (maxY - minY) * boundaryMarginFactor
        let marginZ = (maxZ - minZ) * boundaryMarginFactor
        for i in 0..<jellyfishList.count {
            var jelly = jellyfishList[i];
            // --- Animate pulse, sway, frill, tentacle as before ---
            // Animate pulse (scale and bell height)
            jelly.pulsePhase += jelly.pulseSpeed * deltaTime
            let breath = sinf(jelly.pulsePhase)
            let pulse = 1.0 + 0.18 * breath
            let bellPulse = 1.2 + 0.18 * breath
            // Outer hood: Y-only breathing with phase offset (default π = 180°), keep X/Z at 1.0
            let outerBreath = sinf(jelly.pulsePhase + outerHoodYBreathPhaseOffset)
            jelly.outerHood.scale = SCNVector3(1.0, 1.0 + outerHoodYBreathAmount * outerBreath, 1.0)
            // Inner hood: preserve fuller pulse look, but allow custom Y scale
            jelly.innerHood.scale = SCNVector3(pulse, bellPulse * Float(innerHoodYScale), pulse)
            // Animate sway (rotation)
            jelly.swayPhase += jelly.swaySpeed * deltaTime
            let sway = 0.18 * sinf(jelly.swayPhase)
            // Subtle pitch and roll modulation (very slight)
            let tiltPitch: Float = 0.06 * sinf(jelly.swayPhase * 0.8 + jelly.pulsePhase * 0.6)
            let tiltRoll: Float = 0.04 * cosf(jelly.swayPhase * 1.1 - jelly.pulsePhase * 0.4)
            jelly.outerHood.eulerAngles = SCNVector3(tiltPitch, sway, tiltRoll)
            jelly.innerHood.eulerAngles = SCNVector3(tiltPitch, sway, tiltRoll)
            // Animate drift (vertical movement)
            jelly.driftPhase += jelly.driftSpeed * deltaTime
            let drift = 0.8 * sinf(jelly.driftPhase) // Increased for more vertical exploration
            // --- Bell inhale/exhale vertical movement (inverted) ---
            let bellBreath = sinf(jelly.pulsePhase) // -1 (inhale) to +1 (exhale)
            let bellRise = -0.45 * bellBreath // More pronounced vertical rise
            // --- Movement based on breathing ---
            let breathDelta = outerBreath - jelly.prevOuterBreath
            let moveSpeed: Float = jelly.moveSpeed
            var moveVec = SCNVector3Zero
            if breathDelta < 0 {
                let yaw = jelly.outerHood.eulerAngles.y
                let pitch = jelly.outerHood.eulerAngles.x
                let forward = SCNVector3(
                    -sinf(yaw) * cosf(pitch),
                    sinf(pitch),
                    0 // Z movement disabled
                )
                let verticalComponent: Float = 0.18 * abs(breathDelta) // Reduced to reduce upward bias
                let moveVecForward = forward.normalized() * abs(breathDelta) * moveSpeed
                let moveVecVertical = SCNVector3(0, verticalComponent, 0)
                moveVec = moveVecForward + moveVecVertical
            } else if breathDelta > 0 {
                moveVec = SCNVector3(0, -1, 0) * breathDelta * moveSpeed
            }
            // Ensure Z movement is zero
            moveVec.z = 0
            // --- Velocity-based movement ---
            // Add movement from breath/animation to velocity
            jelly.velocity += moveVec * 0.2 // blend factor for animation-driven movement
            
            // Add drift to velocity for continuous vertical exploration
            jelly.velocity.y += drift * deltaTime * 2.0
            
            // Add bell rise/fall to velocity for breathing movement
            jelly.velocity.y += bellRise * deltaTime * 0.5
            
            // --- Apply velocity damping (so jellyfish naturally slow down) ---
            let dampingFactor: Float = 0.97 // 3% decay per frame
            jelly.velocity.x *= dampingFactor
            jelly.velocity.y *= dampingFactor
            jelly.velocity.z *= dampingFactor
            
            // --- Water current: gentle global x drift applied to all jellyfish ---
            waterCurrentPhase += deltaTime * 0.25
            let currentX = sin(waterCurrentPhase) * waterCurrentStrength
            jelly.velocity.x += currentX * deltaTime

            // --- Apply velocity damping (so jellyfish naturally slow down) ---
           // //let dampingFactor: Float = 0.97 // 3% decay per frame
            //jelly.velocity.x *= dampingFactor
            //jelly.velocity.y *= dampingFactor
           // jelly.velocity.z *= dampingFactor
            
            // --- Boundary steering with velocity reversal ---
            let pos = jelly.outerHood.position
            var steering = SCNVector3Zero
            var hitBoundary = false
            
            // X boundaries
            if pos.x - minX < marginX {
                let penetration = (marginX - (pos.x - minX)) / marginX
                let strength = boundarySteeringStrength * 1.0 * penetration
                steering.x += strength
                if jelly.velocity.x < 0 {
                    jelly.velocity.x *= -0.3
                    hitBoundary = true
                }
            } else if maxX - pos.x < marginX {
                let penetration = (marginX - (maxX - pos.x)) / marginX
                let strength = -boundarySteeringStrength * 1.0 * penetration
                steering.x += strength
                if jelly.velocity.x > 0 {
                    jelly.velocity.x *= -0.3
                    hitBoundary = true
                }
            }
            
            // Y boundaries
            if pos.y - minY < marginY {
                let penetration = (marginY - (pos.y - minY)) / marginY
                let strength = boundarySteeringStrength * 1.0 * penetration
                steering.y += strength
                if jelly.velocity.y < 0 {
                    jelly.velocity.y *= -0.3
                    hitBoundary = true
                }
            } else if maxY - pos.y < marginY {
                let penetration = (marginY - (maxY - pos.y)) / marginY
                let strength = -boundarySteeringStrength * 1.0 * penetration
                steering.y += strength
                if jelly.velocity.y > 0 {
                    jelly.velocity.y *= -0.3
                    hitBoundary = true
                }
            }
            
            // Z boundaries
            if pos.z - minZ < marginZ {
                let penetration = (marginZ - (pos.z - minZ)) / marginZ
                let strength = boundarySteeringStrength * 1.0 * penetration
                steering.z += strength
                if jelly.velocity.z < 0 {
                    jelly.velocity.z *= -0.3
                    hitBoundary = true
                }
            } else if maxZ - pos.z < marginZ {
                let penetration = (marginZ - (maxZ - pos.z)) / marginZ
                let strength = -boundarySteeringStrength * 1.0 * penetration
                steering.z += strength
                if jelly.velocity.z > 0 {
                    jelly.velocity.z *= -0.3
                    hitBoundary = true
                }
            }
            
            // Apply steering to velocity
            jelly.velocity += steering * deltaTime
            
            // If hit boundary, add randomness to help escape
            if hitBoundary {
                let randomTurn = SCNVector3(
                    Float.random(in: -0.15...0.15),
                    Float.random(in: -0.15...0.15),
                    0
                )
                jelly.velocity += randomTurn
            }
            
            // Clamp velocity
            if jelly.velocity.length() > maxVelocity {
                jelly.velocity = jelly.velocity.normalized() * maxVelocity
            }
            // --- Update position using velocity ---
            let deltaPos = jelly.velocity * deltaTime
            jelly.outerHood.position += deltaPos
            jelly.innerHood.position += deltaPos
            jelly.basePosition += deltaPos
            // Z remains static
            let z = staticZPosition
            jelly.outerHood.position.z = z
            jelly.innerHood.position.z = z
            jelly.basePosition.z = z
            // --- Remove wrapping logic ---
            // (No wrapping, only steering)
            // ...existing code for animation, frills, tentacles, dots...
            jelly.prevOuterBreath = outerBreath
            // REMOVED: Keep glow light between the hoods (move each frame)
            // REMOVED: let oPos = jelly.outerHood.position
            // REMOVED: let iPos = jelly.innerHood.position
            // REMOVED: jelly.glowLightNode.position = SCNVector3((oPos.x + iPos.x) * 0.5, (oPos.y + iPos.y) * 0.5, 0)
            
            // Animate frills (undulate/sway)
            for (fi, frillRoot) in jelly.frillNodes.enumerated() {
                // Use shared frill phases, with offset for jellyfish 2
                let phaseBase = jelly.frillPhases[fi]
                let phase = phaseBase + jelly.frillPhaseOffset
                jelly.frillPhases[fi] += 1.2 * deltaTime
                let baseYaw = 0.28 * cosf(phase + jelly.pulsePhase * 0.7)
                let baseRoll = 0.22 * sinf(phase * 1.1 + jelly.pulsePhase * 0.9)
                let chain = jelly.frillChains[fi]
                let count = max(1, chain.count)
                let frillDragFactor: Float = 0.7
                // Only update root node transform
                frillRoot.eulerAngles = SCNVector3(0, baseYaw, baseRoll)
                // Interpolate every other segment (even indices only)
                for (si, seg) in chain.enumerated() {
                    if si % 2 == 0 {
                        let t = Float(si + 1) / Float(count)
                        let amp = 1.0 + frillDragFactor * (t * t)
                        seg.eulerAngles = SCNVector3(0, baseYaw * amp * 0.5, baseRoll * amp * 0.5)
                    }
                    // Odd indices: leave transform unchanged
                }
            }
            // Animate central tentacle (dangle/sway like frill)
            if jelly.tentacleSegments.count > 0 {
                let centralIndex = jelly.tentacleSegments.count / 2
                if centralIndex < jelly.tentacleSegments.count {
                    let centralTentacle = jelly.tentacleSegments[centralIndex]
                    let phase = jelly.pulsePhase * 0.8 + jelly.swayPhase * 0.6
                    let baseYaw = 0.22 * cosf(phase)
                    let baseRoll = 0.18 * sinf(phase * 1.1)
                    let count = max(1, centralTentacle.count)
                    let dragFactor: Float = 0.7
                    // Only update root node transform
                    centralTentacle.first?.node.eulerAngles = SCNVector3(0, baseYaw, baseRoll)
                    // Interpolate child segments based on root
                    for (si, seg) in centralTentacle.enumerated() where si > 0 {
                        let t = Float(si + 1) / Float(count)
                        let amp = 1.0 + dragFactor * (t * t)
                        seg.node.eulerAngles = SCNVector3(0, baseYaw * amp * 0.5, baseRoll * amp * 0.5)
                    }
                }
            }
            // Tentacles: animate radiating outward, with extremes splayed and water resistance
            let tentacleBaseRadius = jelly.tentacleBaseRadius
            let tentacleSegmentSpacing: Float = 0.72
            let tentacleAttachY = jelly.tentacleAttachY
            let tentacleLength = jelly.tentacleSegments.first?.count ?? 1
            let spreadAmount: Float = tentacleBaseRadius * 2.2
            let dragFactor: Float = 0.3
            let dragExponent: Float = 3.0
            for (ti, segment) in jelly.tentacleSegments.enumerated() {
                // Skip central tentacle; it has its own chain animation and must remain connected
                if ti == jelly.tentacleSegments.count / 2 { continue }
                let baseAngle = segment[0].angle
                // Use frill phase for tentacle modulation
                let frillPhase = jelly.frillPhases.count > 0 ? jelly.frillPhases[ti % jelly.frillPhases.count] : 0.0
                let frillModYaw = 0.18 * cosf(frillPhase + jelly.pulsePhase * 0.7)
                let frillModRoll = 0.14 * sinf(frillPhase * 1.1 + jelly.pulsePhase * 0.9)
                for (_, seg) in segment.enumerated() {
                    let node = seg.node
                    let t = Float(seg.segmentIndex) / Float(max(1, tentacleLength-1))
                    let lateralSway = 0.18 * t * sinf(jelly.swayPhase * 1.2 + Float(ti) * 0.6 + Float(seg.segmentIndex) * 0.3)
                    let effectiveAngle = baseAngle + lateralSway
                    let radius = (tentacleBaseRadius + t * spreadAmount) * (1.0 + 0.05 * sinf(jelly.pulsePhase + Float(ti)))
                    let drag = max(0.05, 1.0 - dragFactor * powf(t, dragExponent))
                    let offsetY = tentacleAttachY - Float(seg.segmentIndex) * tentacleSegmentSpacing * drag
                    node.position = SCNVector3(radius * sin(effectiveAngle), offsetY, radius * cos(effectiveAngle))
                    // Blend frill modulation with tentacle sway
                    node.eulerAngles = SCNVector3(frillModPitch(frillModRoll, t), effectiveAngle + frillModYaw * (1.0 - t), frillModRoll * t)
                }
                // Update connector cylinders between segments (non-central only)
                let connectors = jelly.tentacleConnectors[ti]
                for ci in 0..<connectors.count {
                    let nodeA = segment[ci].node
                    let nodeB = segment[ci+1].node
                    let posA = nodeA.position
                    let posB = nodeB.position
                    let mid = SCNVector3((posA.x + posB.x)/2, (posA.y + posB.y)/2, (posA.z + posB.z)/2)
                    let dir = SCNVector3(posB.x - posA.x, posB.y - posA.y, posB.z - posA.z)
                    let length = sqrt(dir.x*dir.x + dir.y*dir.y + dir.z*dir.z)
                    connectors[ci].position = mid
                    connectors[ci].scale = SCNVector3(1, length/0.1, 1)
                    let up = SCNVector3(0,1,0)
                    let axis = SCNVector3.cross(up, dir.normalized())
                    let angle = acos(SCNVector3.dot(up, dir.normalized()))
                    connectors[ci].rotation = SCNVector4(axis.x, axis.y, axis.z, angle)
                }
            }
            // --- Animate luminescent dots ---
            // Instead of per-dot material changes, update one shared material intensity
            let pulse01 = max(0.0, 0.5 + 0.5 * sinf(jelly.pulsePhase)) // 0..1
            let sharedIntensity = 1.2 + 1.2 * pulse01 // keep dots bright with single update
            jelly.dotSharedMaterial.emission.intensity = CGFloat(sharedIntensity)
            // Skip per-dot scale animation to reduce per-frame node work
            // --- Animate luminescent dots with flicker ---
            // Flicker is PER-JELLYFISH: each jellyfish cycles its own N flickering dots
            let dotCount = jelly.dotNodes.count
            if dotCount > 0 {
                // Throttle flicker update based on dot count
                if dotFlickerFrameCounter >= dotFlickerFrameThreshold {
                    jelly.dotFlickerPhase = (jelly.dotFlickerPhase + 1) % dotCount
                    dotFlickerFrameCounter = 0
                } else {
                    dotFlickerFrameCounter += 1
                }
                let baseIntensity = CGFloat(1.2 + 1.2 * max(0.0, 0.5 + 0.5 * sinf(jelly.pulsePhase)))
                let flickerAmplitude: CGFloat = 0.9 // INCREASED for visibility
                let scaleBase: CGFloat = 1.0
                let scaleFlicker: CGFloat = 0.25 // Flickering dots scale up by 25%
                // Number of flickering dots: 3 for many, 2 for <6, 1 for <3
                let flickerDots = dotCount < 3 ? 1 : (dotCount < 6 ? 2 : 3)
                for di in 0..<dotCount {
                    let dotNode = jelly.dotNodes[di]
                    var intensity = baseIntensity
                    var scale = scaleBase
                    // If this dot is one of the flickering
                    let flickerStart = jelly.dotFlickerPhase
                    let isFlicker = (0..<flickerDots).contains((di - flickerStart + dotCount) % dotCount)
                    if isFlicker {
                        // Flicker: add a larger sine-based offset
                        let flicker = flickerAmplitude * CGFloat(sinf(jelly.pulsePhase * 2 + Float(di)))
                        intensity += flicker
                        scale = scaleFlicker
                    }
                    // Set emission intensity for this dot
                    if let mat = dotNode.geometry?.firstMaterial {
                        mat.emission.intensity = intensity
                    }
                    // Set scale for this dot
                    dotNode.scale = SCNVector3(scale, scale, scale)
                }
            }
            jellyfishList[i] = jelly
        }
        // Enforce spacing between jellyfish each frame
        enforceSeparation(iterations: 1)
        // Clamp Z again in case separation moved them
        if let boundaries = calculateWorldBoundaries() {
            for i in 0..<jellyfishList.count {
                var jelly = jellyfishList[i]
                let pos = jelly.outerHood.position
                var z = pos.z
                if z < boundaries.min.z { z = boundaries.min.z }
                else if z > boundaries.max.z { z = boundaries.max.z }
                if z != pos.z {
                    let dz = z - pos.z
                    let delta = SCNVector3(0, 0, dz)
                    jelly.outerHood.position += delta
                    jelly.innerHood.position += delta
                    jelly.basePosition += delta
                    // REMOVED: Update glow light midpoint after clamp
                    // REMOVED: let oPos = jelly.outerHood.position
                    // REMOVED: let iPos = jelly.innerHood.position
                    // REMOVED: jelly.glowLightNode.position = SCNVector3((oPos.x + iPos.x) * 0.5, (oPos.y + iPos.y) * 0.5, staticZPosition)
                }
                jellyfishList[i] = jelly
            }
        }
    }
    
   
    // --- Dot count property ---
    private var dotCount: Int = 25 // Default number of luminescent dots
    // --- Frill count property ---
    private var frillCount: Int = 7 // Default number of frills
    // --- Alpha properties for runtime control ---
    private var innerAlpha: CGFloat = 0.35
    private var hoodAlpha: CGFloat = 0.35
    private var frillAlpha: CGFloat = 1.0
    private var tentacleAlpha: CGFloat = 1.0
    // --- Flicker throttle ---
    private var dotFlickerFrameCounter: Int = 0
    private var dotFlickerFrameThreshold: Int = 1
    
    // Maintain minimum distance between all jellyfish: >= sum of radii (scaled)
    private func enforceSeparation(iterations: Int) {
        guard jellyfishList.count > 1 else { return }
        let scaleX = Float(rootNode.scale.x)
        for _ in 0..<max(1, iterations) {
            for i in 0..<(jellyfishList.count - 1) {
                for j in (i + 1)..<jellyfishList.count {
                    var a = jellyfishList[i]
                    var b = jellyfishList[j]
                    let posA = a.outerHood.position
                    let posB = b.outerHood.position
                    var delta = posB - posA
                    let distSq = delta.x*delta.x + delta.y*delta.y + delta.z*delta.z
                    let minDist = (a.collisionRadius + b.collisionRadius) * scaleX
                    let minDistSq = minDist * minDist
                    if distSq < minDistSq {
                        let dist = max(1e-5, sqrt(distSq))
                        delta = delta * (1.0 / dist)
                        let correction = (minDist - dist) * 0.5
                        let shiftA = delta * (-correction)
                        let shiftB = delta * (correction)
                        a.outerHood.position += shiftA
                        a.innerHood.position += shiftA
                        a.basePosition += shiftA
                        b.outerHood.position += shiftB
                        b.innerHood.position += shiftB
                        b.basePosition += shiftB
                        // REMOVED: Update lights to midpoint after movement
                        // REMOVED: let aO = a.outerHood.position, aI = a.innerHood.position
                        // REMOVED: a.glowLightNode.position = SCNVector3((aO.x + aI.x) * 0.5, (aO.y + aI.y) * 0.5, (aO.z + aI.z) * 0.5)
                        // REMOVED: let bO = b.outerHood.position, bI = b.innerHood.position
                        // REMOVED: b.glowLightNode.position = SCNVector3((bO.x + bI.x) * 0.5, (bO.y + bI.y) * 0.5, (bO.z + bI.z) * 0.5)
                        jellyfishList[i] = a
                        jellyfishList[j] = b
                    }
                }
            }
        }
    }
    // Helper for pitch blending used by tentacle/frill animation
    private func frillModPitch(_ roll: Float, _ t: Float) -> Float {
        return 0.08 * roll * (1.0 - t)
    }
    // Setter methods
    func setPulseSpeed(_ v: Float) {
        pulseSpeed = v
        for i in 0..<jellyfishList.count {
            jellyfishList[i].pulseSpeed = v
        }
    }
    func setSwaySpeed(_ v: Float) {
        swaySpeed = v
        for i in 0..<jellyfishList.count {
            jellyfishList[i].swaySpeed = v
        }
    }
    func setVerticalDriftSpeed(_ v: Float) {
        verticalDriftSpeed = v
        for i in 0..<jellyfishList.count {
            jellyfishList[i].driftSpeed = v
        }
    }
    func setJellySize(_ newSize: Float) {
        // Clamp to bounds
        let clamped = max(minScale, min(maxScale, newSize))
        jellySize = clamped
        rootNode.scale = SCNVector3(clamped, clamped, clamped)
    }
    func getJellySize() -> Float {
        return jellySize
    }
    //func setRotation(_ v: Float) { rotation = v }
    func setBellCurve(_ curve: CGFloat) {
        bellCurve = curve
        reset() // Rebuild jellyfish with new curve
    }
    func setBellHeight(_ h: CGFloat) { bellHeight = h; reset() }
    func setFrillAmplitude(_ a: CGFloat) { frillAmplitude = a; reset() }
    func setFrillFrequency(_ f: CGFloat) { frillFrequency = f; reset() }
    func setOuterHoodYBreathPhaseOffset(_ rads: Float) { outerHoodYBreathPhaseOffset = rads }
    func setInnerHoodYScale(_ s: CGFloat) { innerHoodYScale = s }
    func setOuterHoodYBreathAmount(_ a: Float) { outerHoodYBreathAmount = a }
    func setOuterHoodYOffset(_ offset: Float) { outerHoodYOffset = offset }
    // --- Scale setter/getter ---
    func setScale(_ newScale: Float) {
        let clamped = max(minScale, min(maxScale, newScale))
        scale = clamped
        rootNode.scale = SCNVector3(scale, scale, scale)
    }
    func getScale() -> Float {
        return scale
    }
    func translate(dx: Float, dy: Float, dz: Float) {
        // Move all jellyfish by delta
        rootNode.position.x += dx
        rootNode.position.y += dy
        rootNode.position.z += dz
    }
    
    // Variation knobs
    func setSecondJellySizeVariationFactor(_ factor: Float) {
        // Clamp to sensible range [0, 1]
        sizeVariationFactor = max(0.0, min(1.0, factor))
        reset() // rebuild to apply
    }
    func setSecondJellyMoveSpeedVariationFactor(_ factor: Float) {
        // Clamp to sensible range [0, 2]
        moveSpeedVariationFactor = max(0.0, min(2.0, factor))
        reset() // rebuild to apply
    }
    
    // MARK: - MIDI / Tracker helpers
    /// Names used by the MIDI menu; now only inner hood and central tentacle tip (if present)
    func trackerNames() -> [String] {
        var names: [String] = []
        for i in 0..<jellyfishList.count {
            names.append("j\(i)_inner")
            // Check for central tentacle
            let jelly = jellyfishList[i]
            let centralIndex = jelly.tentacleSegments.count / 2
            if jelly.tentacleSegments.count > 0 && centralIndex < jelly.tentacleSegments.count {
                let centralTentacle = jelly.tentacleSegments[centralIndex]
                if centralTentacle.count > 0 {
                    names.append("j\(i)_centralTip")
                }
            }
        }
        return names
    }

    /// World position for a given jellyfish index and node type
    /// Only supports "inner" and "centralTip"
    func jellyWorldPosition(index: Int, nodeType: String) -> SCNVector3? {
        guard index >= 0, index < jellyfishList.count else { return nil }
        let j = jellyfishList[index]
        switch nodeType.lowercased() {
        case "inner":
            return j.innerHood.presentation.convertPosition(SCNVector3Zero, to: nil)
        case "centraltip":
            let centralIndex = j.tentacleSegments.count / 2
            if j.tentacleSegments.count > 0 && centralIndex < j.tentacleSegments.count {
                let centralTentacle = j.tentacleSegments[centralIndex]
                if centralTentacle.count > 0 {
                    let tipNode = centralTentacle.last!.node
                    // Return the true bottom tip of the last segment (pivot is at top)
                    if let cyl = tipNode.geometry as? SCNCylinder {
                        let localTip = SCNVector3(0, -Float(cyl.height), 0)
                        return tipNode.presentation.convertPosition(localTip, to: nil)
                    }
                    return tipNode.presentation.convertPosition(SCNVector3Zero, to: nil)
                }
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Individual Jellyfish Position Adjustment
    /// Adjust position of a specific jellyfish by delta (for screen clamping)
    func adjustJellyfishPosition(index: Int, dx: Float, dy: Float, dz: Float) {
        guard index >= 0, index < jellyfishList.count else { return }
        jellyfishList[index].basePosition.x += dx
        jellyfishList[index].basePosition.y += dy
        jellyfishList[index].basePosition.z += dz
        // Update BOTH outer hood AND inner hood positions immediately to reflect change
        jellyfishList[index].outerHood.position = jellyfishList[index].basePosition
        jellyfishList[index].innerHood.position = jellyfishList[index].basePosition
    }
    
    /// Nudge velocity of a specific jellyfish (for screen edge steering)
    func nudgeJellyfishVelocity(index: Int, dx: Float, dy: Float, dz: Float) {
        guard index >= 0, index < jellyfishList.count else { return }
        jellyfishList[index].velocity.x += dx
        jellyfishList[index].velocity.y += dy
        jellyfishList[index].velocity.z += dz
        // Clamp to max velocity
        if jellyfishList[index].velocity.length() > maxVelocity {
            jellyfishList[index].velocity = jellyfishList[index].velocity.normalized() * maxVelocity
        }
    }

    /// Get count of jellyfish for iteration
    var jellyfishCount_exposed: Int { jellyfishList.count }
    

    
    // --- Add rotation setter ---
    func setRotation(_ degrees: Float) {
        rotation = degrees // Ensure rotation property is updated
        let radians = degrees * (.pi / 180)
        // Rotate around Y axis (vertical)
        rootNode.eulerAngles.y = radians
    }
    
    private let baseFieldSize: Float = 100
    var fieldHalfSize: Float { baseFieldSize / 2 }
    
    private var lightShardNode: SCNNode? = nil // Node for visible light shaft

    // Add a directional light diagonally from above (no visible shaft)
    private func addSimpleDirectionalLight() {
        if isWorkbenchMode {
            // In workbench mode, do not add directional light
            return
        }
        let lightNode = SCNNode()
        let light = SCNLight()
        light.type = .directional
        light.color = UIColor.white
        light.intensity = 1200
        light.castsShadow = true
        // Diagonal direction: tilt down and sideways
        lightNode.eulerAngles = SCNVector3(-Float.pi/4, Float.pi/5, 0)
        lightNode.light = light
        // Place above the scene
        lightNode.position = SCNVector3(0, 10, 10)
        rootNode.addChildNode(lightNode)
    }
    
    /// Project jellyfish node into 0-127 screen-space X/Y values (like MeshBird)
    /// Only returns X and Y, ignores Z
    func projectedJellyXY127(index: Int, nodeType: String = "inner") -> (x: Int, y: Int)? {
        guard let scnView = scnView, let worldPos = jellyWorldPosition(index: index, nodeType: nodeType) else { return nil }
        let proj = scnView.projectPoint(worldPos)
        let w = max(scnView.bounds.width, 1)
        let h = max(scnView.bounds.height, 1)
        let xView = CGFloat(proj.x)
        let yView = h - CGFloat(proj.y) // flip to top-left origin
        let x127 = Int(round(min(max(xView, 0), w) / w * 127))
        let y127 = Int(round(min(max(yView, 0), h) / h * 127))
        return (x127, y127)
    }
    
    // --- Low Power Mode setter ---
    public func setLowPowerMode(_ isLowPower: Bool) {
        if isLowPower {
            dotCount = 6 // Lower dot count in low power mode
            frillCount = 3 // Lower frill count in low power mode
            hoodAlpha = 1.0
            innerAlpha = 1.0
            frillAlpha = 1.0
            tentacleAlpha = 1.0
            dotFlickerFrameThreshold = 10
        } else {
            dotCount = 25
            frillCount = 7
            innerAlpha = 0.35
            hoodAlpha = 0.55
            frillAlpha = 1.0
            tentacleAlpha = 1.0
            dotFlickerFrameThreshold = 2
        }
        dotFlickerFrameCounter = 0
        reset()
    }
    // MARK: - Hard scene graph pause (Option A)
    /// Immediately freezes or resumes all node animations & implicit actions.
    /// Keeps async simulation task alive so unpausing is instant.
    public func setSceneGraphPaused(_ paused: Bool) {
        rootNode.isPaused = paused
        rootNode.enumerateChildNodes { node, _ in
            node.isPaused = paused
        }
    }
    
    func teardownAndDispose() {
        // Remove all actions and child nodes from rootNode and its children
        rootNode.removeAllActions()
        rootNode.enumerateChildNodes { n, _ in
            n.removeAllActions()
            n.geometry = nil  // ← Optional
            n.removeFromParentNode()
        }
        // Remove rootNode from scene
        sceneRef?.rootNode.childNodes.forEach { node in
            if node === rootNode { node.removeFromParentNode() }
        }
        // Clear jellyfish list and all references
        jellyfishList.removeAll(keepingCapacity: false)
        sceneRef = nil
        scnView = nil
        lastViewSize = .zero
        lightShardNode = nil
        // Remove any other retained nodes/materials if needed
        // No print(m) (remove stray print)
    }
    
    deinit{ print("jellyfish deinit") }
}
