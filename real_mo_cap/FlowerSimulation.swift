import SceneKit
import UIKit
import simd

/// Configuration for a flower's physical and visual properties.
struct FlowerConfig {
    var numPetals: Int = 12
    var numPetalsLayer2: Int? = nil // Optional: if nil, matches numPetals
    var stemHeight: Float = 8.2
    var stemRadius: Float = 0.08
    var headRadius: Float = 0.35
    var petalLength: Float = 1.5
    var petalWidth: Float = 0.28
    var petalThickness: Float = 0.04
    var petalColor: UIColor = .systemYellow
    var secondaryPetalColor: UIColor? = nil // If nil, will be set to complimentary
    var headColor: UIColor = .brown
    var stemColor: UIColor = UIColor(red: 0.1, green: 0.9, blue: 0.6, alpha: 1.0)
    var numStars: Int = 300
    // Add more as needed
}

/// Simulation of a flower that reacts to sun and rain, for SceneKit rendering.
class FlowerSimulation: LifeformSimulation {
    // New replication/environment control flags
    private let buildEnvironment: Bool
    private let updateEnvironment: Bool
    private let initialPosition: SCNVector3
    // Shared environment sun reference (set by the instance that updates environment)
    private static weak var sharedEnvironmentSunNode: SCNNode?
    // MARK: - Flower Geometry Config
    private let config: FlowerConfig
    private let sunDistance: Float = 15.0 // Distance of sun from origin
    private var sunOrbitSpeed: Float = 0.25 // Speed of sun orbit
    private var sunHeightMultiplier: Float = 1.0 // Multiplier for sun height
    private let groundY: Float = 0 // Y position of ground
    private let closeAtNight: Bool = true // Whether flower closes at night
    private var globalScale: Float = 1 // Overall scale of flower
    private let sunPathZOffset: Float = 10 // Z offset for sun path
    private let moonPathZOffset: Float = -25 // Z offset for moon path
    private let stemSegmentCount: Int = 6 // Number of stem segments
    private var stemTopNode: SCNNode? = nil // Top node of stem
    private var stemSegments: [SCNNode] = [] // Stem segment nodes
    private var stemJoints: [SCNNode] = [] // Stem joint nodes
    private var currentStemCumulativeBend: Float = 0 // Current stem bend
    private let dayNightBlendStart: Float = 0.3 // Start blend for day/night
    private let dayNightBlendEnd: Float = 0.7 // End blend for day/night
    
    // MARK: - Scene Nodes
    public var rootNode = SCNNode() // Root node for all geometry
    private var stemNode = SCNNode() // Legacy placeholder
    private var headNode = SCNNode() // Flower head node
    private var centerDiscNode = SCNNode() // Center disc node
    private var petalHinges: [SCNNode] = [] // Petal hinge nodes
    private var petalMeshes: [SCNNode] = [] // Petal mesh nodes
    private var sunNode = SCNNode() // Sun node
    private var skyNode = SCNNode() // Sky node
    private var moonNode = SCNNode() // Moon node
    private var starNodes: [SCNNode] = [] // Star nodes
    private var starOriginalPositions: [SCNVector3] = [] // Store original positions for correct rotation
    // Directional light node (added)
    private var directionalLightNode: SCNNode? = nil
    // Ambient light node (added)
    private var ambientLightNode: SCNNode? = nil
    
    // MARK: - Simulation State
    private var currentOpenness: Float = 0 // Current openness of petals
    private var targetOpenness: Float = 0 // Target openness
    
    private var manualOverrideOpenness: Float? = nil // Manual override for openness
    private var sunAngle: Float = .pi / 2 // Current sun angle
    private var userOffset: SCNVector3 = .zero // User translation offset
    private var headTargetOrientation: SCNVector4? = nil // Target orientation for head
    private weak var sceneRef: SCNScene? // Reference to SceneKit scene (now weak)
    weak var scnView: SCNView? // Reference to SCNView (already weak)
    private let debugLogging = false // Debug logging flag
    private var numStars: Int { config.numStars } // Number of stars in sky
    
    // MARK: - Sun/Moon Positioning
    private var sunAzimuth: Float = 0.0 // Sun azimuth
    private var sunElevation: Float = .pi / 2 // Sun elevation
    private var sunAxisTilt: Float = 0.0 // Sun axis tilt
    private var moonAngle: Float = 0.0 // Current moon angle
    private var moonOrbitSpeed: Float = 0.18 // Speed of moon orbit
    // Night sway timing & behavior
    private var simulationTime: Float = 0
    private let nightSwaySpeed: Float = 0.6
    private let nightSwayAmplitudeFactor: Float = 0.4 // relative to max night bend
    private let nightDroopBaseFactor: Float = 0.85 // baseline droop as fraction of max night bend
    private let nightSwayPhaseOffset: Float = Float.random(in: 0...(2 * .pi))
    private let nightSwayDirection: Float = (Bool.random() ? 1.0 : -1.0)
    
    // MARK: - Rain Properties
    private var rainIntensity: Float = 0 // Rain intensity (0 = none)
    private var petalBounceTimers: [Float] = [] // Bounce timers for petals
    private let petalBounceDuration: Float = 0.25 // Duration of petal bounce
    private let petalBounceAmplitude: Float = 0.22 // Amplitude of petal bounce
    
    // MARK: - Raindrop Visuals
    private class Raindrop {
        var node: SCNNode // Raindrop node
        var velocity: Float // Fall velocity
        var targetPetal: Int // Target petal index
        var active: Bool = true // Is raindrop active
        init(node: SCNNode, velocity: Float, targetPetal: Int) {
            self.node = node; self.velocity = velocity; self.targetPetal = targetPetal
        }
    }
    private var raindrops: [Raindrop] = [] // Active raindrops
    private let raindropRadius: CGFloat = 0.07 // Raindrop radius
    private let raindropColor = UIColor.systemBlue // Raindrop color
    private let raindropFallSpeed: Float = 6.0 // Raindrop fall speed
    
    // MARK: - Initialization
    /// Create a new flower simulation for a given SceneKit scene.
    init(scene: SCNScene, scnView: SCNView?, buildEnvironment: Bool = true, updateEnvironment: Bool = true, position: SCNVector3 = .zero, config: FlowerConfig = FlowerConfig()) {
        self.sceneRef = scene
        self.scnView = scnView
        self.buildEnvironment = buildEnvironment
        self.updateEnvironment = updateEnvironment
        self.initialPosition = position
        self.config = config
        setup(in: scene)
    }
    
    // MARK: - Public Control API
    /// Set the sun's orbit speed.
    func setSunOrbitSpeed(_ v: Float) { sunOrbitSpeed = max(0.01, v) }
    /// Set the sun's height multiplier.
    func setSunHeightMultiplier(_ v: Float) { sunHeightMultiplier = max(0, min(2, v)) }
    /// Set the global scale of the flower.
    func setGlobalScale(_ s: Float) { globalScale = max(0.1, s); rootNode.scale = SCNVector3(globalScale, globalScale, globalScale) }
    /// Translate the flower in the scene.
    func translate(dx: Float, dy: Float, dz: Float) { userOffset.x += dx; userOffset.y += dy; userOffset.z += dz }
    /// Set the rain intensity.
    func setRainIntensity(_ v: Float) {
        rainIntensity = max(0, min(5, v))
        if petalBounceTimers.count != config.numPetals {
            petalBounceTimers = Array(repeating: 0, count: config.numPetals)
        }
    }
    private let minAllowedOpenness: Float = 0.05 // Minimum allowed openness
    private let maxAllowedOpenness: Float = 0.9 // Maximum allowed openness
    /// Set the openness of the petals.
    func setOpenness(_ v: Float) {
        let c = max(minAllowedOpenness, min(maxAllowedOpenness, v))
        manualOverrideOpenness = c
        targetOpenness = c
    }
    /// Set sun azimuth.
    func setSunAzimuth(_ v: Float) { sunAzimuth = v }
    /// Set sun elevation.
    func setSunElevation(_ v: Float) { sunElevation = v }
    /// Set sun axis tilt.
    func setSunAxisTilt(_ v: Float) { sunAxisTilt = v }
    /// Reset simulation to initial state.
    func reset() {
        userOffset = .zero
        sunAngle = .pi * 0.75
        currentOpenness = 0
        targetOpenness = 0
        manualOverrideOpenness = nil
        headTargetOrientation = nil
        sunHeightMultiplier = 1.0
        if let sceneRef { setup(in: sceneRef) }
    }
    
    // MARK: - Scene Setup
    /// Set up all geometry and nodes in the scene.
    private func setup(in scene: SCNScene) {
        rootNode.removeFromParentNode()
        rootNode = SCNNode()
        rootNode.eulerAngles.y = .pi / 2
        rootNode.position = initialPosition
        scene.rootNode.addChildNode(rootNode)
        petalHinges.removeAll(); petalMeshes.removeAll();
        if buildEnvironment {
            buildGround(); buildSky(); buildSun(); setupDirectionalLight(); setupAmbientLight()
        }
        buildStem(); buildHead(); buildPetals()
        if updateEnvironment { FlowerSimulation.sharedEnvironmentSunNode = sunNode }
        rootNode.scale = SCNVector3(globalScale, globalScale, globalScale)
    }
    /// Create and add a directional light that follows the sun and targets the flower base.
    private func setupDirectionalLight() {
        // Create a new directional light
        let light = SCNLight()
        light.type = .directional // Directional light simulates sunlight
        light.intensity = 1800 // Brightness of the light
        light.color = UIColor.white // Color of the light
        light.castsShadow = true // Enable shadobungw casting
        light.shadowMapSize = CGSize(width: 2048, height: 2048) // Shadow map resolution
        light.shadowSampleCount = 8 // Number of samples for soft shadow edges
        light.shadowRadius = 20 // Blur radius for shadow edges
        light.shadowBias = 4 // Shadow bias to reduce artifacts
        light.shadowColor = UIColor.black.withAlphaComponent(0.5) // Color and opacity of shadows
        light.orthographicScale = 20 // Size of the area covered by the shadow map (orthographic frustum)
        light.zNear = 1 // Near clipping plane for shadows
        light.zFar = 80 // Far clipping plane for shadows
        // Attach the light to a node
        let node = SCNNode()
        node.light = light
        node.castsShadow = true
        rootNode.addChildNode(node)
        directionalLightNode = node
        updateDirectionalLight() // Initial orientation
    }
    /// Create and add an ambient light whose intensity tracks the sun's y position.
    private func setupAmbientLight() {
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 0 // Start with zero
        ambientLight.color = UIColor.white
        let node = SCNNode()
        node.light = ambientLight
        rootNode.addChildNode(node)
        ambientLightNode = node
    }
    /// Update directional light position to match sun and orient toward flower base.
    private func updateDirectionalLight() {
        guard let node = directionalLightNode else { return }
        // Position matches sun
        node.position = sunNode.position
        // Target is flower base
        let target = SCNVector3(0, groundY, 0)
        node.look(at: target)
    }
    /// Update ambient light intensity based on sun's y position.
    private func updateAmbientLightIntensity() {
        guard let ambientLight = ambientLightNode?.light else { return }
        let sunY = sunNode.position.y
        let minY: Float = groundY
        let maxY: Float = sunDistance * sunHeightMultiplier
        let normalizedY = min(max((sunY - minY) / max(0.001, (maxY - minY)), 0), 1)
        ambientLight.intensity = sunY < groundY ? 0 : CGFloat(500 * normalizedY)
    }
    
    /// Build the ground plane.
    private func buildGround() {
        // Remove previous ground node if present
        rootNode.childNodes.filter { $0.name == "GroundWad" }.forEach { $0.removeFromParentNode() }
        // Earth wad: brown cylinder
        let wadRadius: CGFloat = 7
        let wadHeight: CGFloat = 1.2
        let earthCylinder = SCNCylinder(radius: wadRadius, height: wadHeight)
        let earthMaterial = SCNMaterial()
        earthMaterial.diffuse.contents = UIColor(red: 0.45, green: 0.32, blue: 0.18, alpha: 1.0)
        earthMaterial.lightingModel = .physicallyBased
        earthCylinder.firstMaterial = earthMaterial
        let earthNode = SCNNode(geometry: earthCylinder)
        earthNode.position = SCNVector3(0, wadHeight / 2, 0)
        earthNode.castsShadow = true
        // Grass disk: green cylinder
        let grassRadius: CGFloat = 7
        let grassHeight: CGFloat = 0.18
        let grassCylinder = SCNCylinder(radius: grassRadius, height: grassHeight)
        let grassMaterial = SCNMaterial()
        grassMaterial.lightingModel = .physicallyBased
        grassMaterial.diffuse.contents = UIColor(red: 0.22, green: 0.55, blue: 0.22, alpha: 1.0)
        grassCylinder.firstMaterial = grassMaterial
        let grassNode = SCNNode(geometry: grassCylinder)
        grassNode.position = SCNVector3(0, wadHeight + grassHeight / 2, 0)
        grassNode.castsShadow = true
        // Container node for wad
        let wadNode = SCNNode()
        wadNode.name = "GroundWad"
        wadNode.addChildNode(earthNode)
        wadNode.addChildNode(grassNode)
        // Add grass blades for extra detail
        addGrassBlades(to: wadNode, wadRadius: wadRadius, wadHeight: wadHeight + grassHeight)
        // Position the wad at groundY
        wadNode.position = SCNVector3(0, groundY, 0)
        rootNode.addChildNode(wadNode)
    }

    /// Add a few blades of grass randomly on the wad of earth.
    private func addGrassBlades(to wadNode: SCNNode, wadRadius: CGFloat, wadHeight: CGFloat) {
        let numBlades = Int.random(in: 8...40)
        for _ in 0..<numBlades {
            // Random position on top surface
            let angle = Float.random(in: 0..<(2 * .pi))
            let radius = Float.random(in: 0.5...(Float(wadRadius) - 0.5))
            let x = radius * cos(angle)
            let z = radius * sin(angle)
            let y = Float(wadHeight/2) + 0.02 // Slightly above top
            // Blade geometry: thin, slightly curved cylinder
            let bladeHeight = CGFloat.random(in: 0.5...1.2)
            let bladeRadius = CGFloat.random(in: 0.015...0.03)
            let bladeGeom = SCNCylinder(radius: bladeRadius, height: bladeHeight)
            let bladeMat = SCNMaterial()
            bladeMat.diffuse.contents = UIColor(red: 0.2 + CGFloat.random(in: 0...0.3), green: 0.7 + CGFloat.random(in: 0...0.3), blue: 0.2, alpha: 1.0)
            bladeMat.lightingModel = .lambert
            bladeGeom.materials = [bladeMat]
            let bladeNode = SCNNode(geometry: bladeGeom)
            bladeNode.position = SCNVector3(x, y + Float(bladeHeight/2), z)
            // Random tilt and bend
            bladeNode.eulerAngles.x = Float.random(in: -.pi/8 ... .pi/8)
            bladeNode.eulerAngles.z = Float.random(in: -.pi/6 ... .pi/6)
            // Optionally, add a slight curve by scaling/skewing
            bladeNode.scale.x = 1.0 + Float.random(in: -0.1...0.1)
            bladeNode.scale.z = 1.0 + Float.random(in: -0.1...0.1)
            bladeNode.castsShadow = true
            wadNode.addChildNode(bladeNode)
        }
    }
    
    /// Build the stem from segments and joints.
    private func buildStem() {
        stemTopNode = nil; stemSegments.removeAll(); stemJoints.removeAll()
        let segmentCount = stemSegmentCount
        let segmentHeight = config.stemHeight / Float(segmentCount)
        let baseJoint = SCNNode(); baseJoint.position = SCNVector3(0, groundY, 0); rootNode.addChildNode(baseJoint); stemJoints.append(baseJoint)
        var currentJoint = baseJoint
        for i in 0..<segmentCount {
            let cyl = SCNCylinder(radius: CGFloat(config.stemRadius), height: CGFloat(segmentHeight))
            let mat = SCNMaterial(); mat.diffuse.contents =  config.stemColor; mat.lightingModel = .lambert; cyl.materials = [mat]
            let segmentNode = SCNNode(geometry: cyl)
            segmentNode.castsShadow = true
            segmentNode.position = SCNVector3(0, segmentHeight/2, 0)
            currentJoint.addChildNode(segmentNode)
            stemSegments.append(segmentNode)
            if i < segmentCount - 1 {
                let sphere = SCNSphere(radius: CGFloat(config.stemRadius * 1.05))
                let sm = SCNMaterial(); sm.diffuse.contents = config.stemColor; sm.lightingModel = .lambert; sphere.materials = [sm]
                let sNode = SCNNode(geometry: sphere)
                sNode.castsShadow = true
                sNode.position = SCNVector3(0, segmentHeight, 0)
                currentJoint.addChildNode(sNode)
            }
            if i < segmentCount - 1 {
                let nextJoint = SCNNode(); nextJoint.position = SCNVector3(0, segmentHeight, 0)
                currentJoint.addChildNode(nextJoint)
                stemJoints.append(nextJoint)
                currentJoint = nextJoint
            } else {
                let topJoint = SCNNode(); topJoint.position = SCNVector3(0, segmentHeight, 0)
                currentJoint.addChildNode(topJoint)
                stemJoints.append(topJoint)
                stemTopNode = topJoint
            }
        }
        if stemTopNode == nil { stemTopNode = currentJoint }
    }
    
    /// Build the flower head.
    private func buildHead() {
        headNode = SCNNode(); headNode.castsShadow = true
        if let top = stemTopNode {
            headNode.position = SCNVector3(0, config.headRadius, 0)
            top.addChildNode(headNode)
        } else {
            headNode.position = SCNVector3(0, config.stemHeight + groundY, 0)
            rootNode.addChildNode(headNode)
        }
        let disc = SCNSphere(radius: CGFloat(config.headRadius))
        let mat = SCNMaterial(); mat.diffuse.contents = config.headColor; mat.emission.contents = config.headColor; mat.lightingModel = .lambert; disc.materials = [mat]
        centerDiscNode = SCNNode(geometry: disc); centerDiscNode.castsShadow = true; headNode.addChildNode(centerDiscNode)
    }
    
    /// Build all petals and their hinges.
    private func buildPetals() {
        for i in 0..<config.numPetals {
            let theta = Float(i) / Float(config.numPetals) * (.pi * 2)
            let hinge = SCNNode(); hinge.position = SCNVector3(config.headRadius * sin(theta), 0, config.headRadius * cos(theta)); hinge.eulerAngles.y = theta; headNode.addChildNode(hinge)
            let petalGeom = SCNBox(width: CGFloat(config.petalWidth), height: CGFloat(config.petalLength), length: CGFloat(config.petalThickness), chamferRadius: CGFloat(config.petalWidth * 0.3))
            let pm = SCNMaterial(); pm.diffuse.contents = config.petalColor; pm.emission.contents = config.petalColor; pm.lightingModel = .lambert; petalGeom.materials = [pm]
            let petal = SCNNode(geometry: petalGeom); petal.pivot = SCNMatrix4MakeTranslation(0, Float(config.petalLength/2), 0); petal.eulerAngles.x = -.pi / 2; hinge.addChildNode(petal); petal.castsShadow = true; hinge.castsShadow = true; petalHinges.append(hinge); petalMeshes.append(petal)
        }
        applyOpenness(0)
    }
    
    /// Build the sun sphere.
    private func buildSun() {
        let sunSphere = SCNSphere(radius: 0.6)
        let sm = SCNMaterial(); sm.diffuse.contents = UIColor.systemOrange; sm.emission.contents = UIColor.systemYellow; sm.lightingModel = .lambert; sunSphere.materials = [sm]
        sunNode = SCNNode(geometry: sunSphere); sunNode.renderingOrder = 5; sunNode.castsShadow = false; rootNode.addChildNode(sunNode)
    }
    
    /// Build the sky, moon, and stars.
    private func buildSky() {
        let skySphere = SCNSphere(radius: 60); skySphere.segmentCount = 48
        let mat = SCNMaterial(); mat.diffuse.contents = UIColor(red: 0.53, green: 0.81, blue: 0.98, alpha: 1.0); mat.isDoubleSided = true; mat.lightingModel = .constant; skySphere.materials = [mat]
        skyNode = SCNNode(geometry: skySphere); skyNode.position = SCNVector3(0, groundY, 0); skyNode.renderingOrder = -100; rootNode.addChildNode(skyNode)
        let moonSphere = SCNSphere(radius: 0.5); let moonMat = SCNMaterial(); moonMat.diffuse.contents = UIColor(white: 0.95, alpha: 1.0); moonMat.emission.contents = UIColor(white: 0.8, alpha: 0.9); moonMat.lightingModel = .constant; moonSphere.materials = [moonMat]; moonNode = SCNNode(geometry: moonSphere); moonNode.renderingOrder = 2; skyNode.addChildNode(moonNode)
        starNodes = []
        starOriginalPositions = []
        let starRadius: CGFloat = 0.08
        for _ in 0..<numStars {
            let phi = Float.random(in: 0...(Float.pi * 2))
            let theta = Float.random(in: 0...(Float.pi))
            let r: Float = 29.5
            let x = r * sin(theta) * cos(phi)
            let y = r * cos(theta)
            let z = r * sin(theta) * sin(phi)
            let star = SCNNode(geometry: SCNSphere(radius: starRadius))
            let starMat = SCNMaterial()
            starMat.diffuse.contents = UIColor.white
            starMat.emission.contents = UIColor.white
            starMat.lightingModel = .constant
            star.geometry?.materials = [starMat]
            let pos = SCNVector3(x, y, z)
            star.position = pos
            star.renderingOrder = 1
            skyNode.addChildNode(star)
            starNodes.append(star)
            starOriginalPositions.append(pos) // Store original position
        }
    }
    
    // MARK: - Simulation Update
    /// Update simulation state for each frame.
    func update(deltaTime: Float) {
        simulationTime += deltaTime
        // If this instance controls the environment, advance sun & sky.
        if updateEnvironment {
            sunAngle += sunOrbitSpeed * deltaTime
            let r = sunDistance; let axisTilt = sunAxisTilt; let sunZ: Float = sunPathZOffset
            let sunX = r * cos(sunAngle) * max(0, sunHeightMultiplier); let sunY = r * sin(sunAngle) * max(0, sunHeightMultiplier)
            let tiltMatrix = simd_float4x4(SCNMatrix4MakeRotation(axisTilt, 0, 0, 1)); let sunPos = simd_mul(tiltMatrix, simd_float4(sunX, sunY, sunZ, 1))
            sunNode.position = SCNVector3(sunPos.x, sunPos.y, sunPos.z)
            updateDirectionalLight() // Update light position/orientation
            updateAmbientLightIntensity() // Update ambient light intensity
            FlowerSimulation.sharedEnvironmentSunNode = sunNode
            // Moon (independent orbit)
            moonAngle += moonOrbitSpeed * deltaTime
            let moonRadius: Float = sunDistance * 1.2 // Slightly larger orbit than sun
            let moonX = moonRadius * cos(moonAngle)
            let moonY = moonRadius * sin(moonAngle)
            moonNode.position = SCNVector3(moonX, groundY + moonY, moonPathZOffset)
            // Blend sky & stars by height (simple day/night cue)
            let minY: Float = groundY; let maxY: Float = sunDistance * sunHeightMultiplier
            let normalizedY = min(max((sunNode.position.y - minY) / max(0.001, (maxY - minY)), 0), 1)
            let blend: Float = normalizedY <= dayNightBlendStart ? 0 : (normalizedY >= dayNightBlendEnd ? 1 : (normalizedY - dayNightBlendStart) / max(0.001, (dayNightBlendEnd - dayNightBlendStart)))
            moonNode.opacity = CGFloat(1.0 - blend)
            let skyBlue = UIColor(red: 0.53, green: 0.81, blue: 0.98, alpha: 1.0); let skyBlack = UIColor.black; let lerpedSky = blendColors(color1: skyBlack, color2: skyBlue, t: CGFloat(blend))
            if let m = skyNode.geometry?.materials.first { m.diffuse.contents = lerpedSky }
            // Stars slow rotation + fade
            let starRotationSpeed: Float = 0.0001
            let starRotation = sunAngle * starRotationSpeed
            for (i, star) in starNodes.enumerated() {
                let p = starOriginalPositions[i] // Use original position
                let angle = starRotation
                let cosA = cos(angle)
                let sinA = sin(angle)
                let x = p.x * cosA - p.z * sinA
                let z = p.x * sinA + p.z * cosA
                star.position = SCNVector3(CGFloat(x), CGFloat(p.y), CGFloat(z))
                star.opacity = CGFloat(1.0 - blend)
            }
        }
        // Determine sun position for plant logic (either own or shared environment sun)
        let effectiveSunNode: SCNNode? = updateEnvironment ? sunNode : FlowerSimulation.sharedEnvironmentSunNode
        if let s = effectiveSunNode {
            let sunY = s.position.y
            let sunXWorld = s.position.x
            if sunY > groundY {
                currentOpenness = (sunY * (-0.05) + 0.5)
                stemTopNode?.eulerAngles.z = 20
            }
            applyOpenness(currentOpenness)
            updateStemBend(sunXWorld: -sunXWorld, sunYWorld: sunY, deltaTime: deltaTime)
        }
        updateRainOnPetals(deltaTime: deltaTime)
        updateRaindrops(deltaTime: deltaTime)
    }
    
    /// Update raindrop positions and handle collisions.
    private func updateRaindrops(deltaTime: Float) {
        guard rainIntensity > 0, petalHinges.count == config.numPetals else { return }
        let spawnRate = rainIntensity * 24; let expectedNew = spawnRate * deltaTime; var toSpawn = Int(expectedNew); if Float.random(in: 0...1) < expectedNew - Float(toSpawn) { toSpawn += 1 }
        let rainAreaRadius: Float = 12.0; let rainSpawnHeight: Float = groundY + 12.0
        for _ in 0..<toSpawn {
            let angle = Float.random(in: 0..<(2 * .pi)); let radius = Float.random(in: 0...rainAreaRadius); let x = radius * cos(angle); let z = radius * sin(angle)
            let dropNode = SCNNode(geometry: SCNSphere(radius: raindropRadius)); let mat = SCNMaterial(); mat.diffuse.contents = raindropColor; mat.emission.contents = raindropColor; mat.lightingModel = .constant; dropNode.geometry?.materials = [mat]; dropNode.position = SCNVector3(x, rainSpawnHeight, z); rootNode.addChildNode(dropNode)
            var closestPetal = 0; var minDist = Float.greatestFiniteMagnitude
            for (i, hinge) in petalHinges.enumerated() {
                let petalPos = hinge.convertPosition(SCNVector3Zero, to: rootNode); let dx = petalPos.x - x; let dz = petalPos.z - z; let dist = dx*dx + dz*dz; if dist < minDist { minDist = dist; closestPetal = i }
            }
            let drop = Raindrop(node: dropNode, velocity: raindropFallSpeed, targetPetal: closestPetal); raindrops.append(drop)
        }
        for drop in raindrops where drop.active {
            drop.node.position.y -= drop.velocity * deltaTime
            let hinge = petalHinges[drop.targetPetal]; let petalWorld = hinge.convertPosition(SCNVector3Zero, to: rootNode); let dx = drop.node.position.x - petalWorld.x; let dz = drop.node.position.z - petalWorld.z; let distXZ = sqrt(dx*dx + dz*dz
            )
            if distXZ < 0.35 && drop.node.position.y <= petalWorld.y + 0.1 {
                petalBounceTimers[drop.targetPetal] = petalBounceDuration; drop.active = false; drop.node.removeFromParentNode()
            } else if drop.node.position.y < groundY - 0.5 {
                drop.active = false; drop.node.removeFromParentNode()
            }
        }
        raindrops.removeAll { !$0.active }
    }
    
    /// Animate petal bounce from rain.
    private func updateRainOnPetals(deltaTime: Float) {
        guard rainIntensity > 0, petalHinges.count == config.numPetals else { return }
        for i in 0..<config.numPetals {
            if petalBounceTimers[i] > 0 {
                let progress = 1 - petalBounceTimers[i] / petalBounceDuration
                let bounce = sin(progress * .pi) * petalBounceAmplitude
                petalHinges[i].eulerAngles.x += bounce
                petalBounceTimers[i] -= deltaTime
                if petalBounceTimers[i] < 0 { petalBounceTimers[i] = 0 }
            }
        }
    }
    
    /// Set openness for all petals.
    private func applyOpenness(_ o: Float) {
        let c = max(minAllowedOpenness, min(o, maxAllowedOpenness))
        let angle = -maxPetalOpenAngle * c
        for hinge in petalHinges { hinge.eulerAngles.x = angle }
    }
    
    // MARK: - World position helpers
    /// World position of the flower head center (for screen-space clamping/tracking)
    func flowerHeadWorldPosition() -> SCNVector3? {
        return centerDiscNode.presentation.worldPosition
    }
    
    // MARK: - MIDI/LFO Tracking
    /// Get tracker names for MIDI/LFO output.
    func trackerNames() -> [String] { ["FlowerHead"] + (0..<config.numPetals).map { "Petal-\($0+1)" } }
    /// Get normalized petal state for MIDI/LFO.
    func petalState(index: Int) -> Float? { (index >= 0 && index < config.numPetals) ? currentOpenness : nil }
    /// Project flower head to 2D screen coordinates (0-127).
    func projectedFlowerHeadXY127() -> (x: Int, y: Int)? { project(node: centerDiscNode) }
    /// Project petal to 2D screen coordinates (0-127).
    func projectedPetalXY127(index: Int) -> (x: Int, y: Int)? { guard index >= 0 && index < petalMeshes.count else { return nil }; return project(node: petalMeshes[index]) }
    func projectedPetalXY127(layer: Int, index: Int) -> (x: Int, y: Int)? { projectedPetalXY127(index: index) }
    /// Project sun to 2D screen coordinates (0-127).
    func projectedSunXY127() -> (x: Int, y: Int)? { project(node: sunNode) }
    func projectedMoonXY127() -> (x: Int, y: Int)? { project(node: moonNode) }
    
    /// Returns the screen-referenced x/y coordinates and openness radius for MIDI/LFO output.
    func flowerLFOOutput() -> (x: Int, y: Int, opennessRadius: Float)? {
        guard let (x, y) = projectedFlowerHeadXY127() else { return nil }
        let radius = petalTipRadius()
        return (x, y, radius)
    }

    /// Computes the current petal tip radius from the center, based on openness and geometry.
    private func petalTipRadius() -> Float {
        // The tip position is affected by headRadius, petalLength, and openness
        // When fully open, tip is at headRadius + petalLength
        // When closed, tip is at headRadius + petalLength * cos(angle)
        let openAngle = maxPetalOpenAngle * currentOpenness
        let tipOffset = config.petalLength * cos(openAngle)
        return config.headRadius + tipOffset
    }
    
    /// Project a node to 2D screen coordinates (0-127).
    private func project(node: SCNNode) -> (x: Int, y: Int)? {
        guard let scnView else { return nil }
        let p = scnView.projectPoint(node.presentation.worldPosition)
        let w = max(scnView.bounds.width, 1)
        let h = max(scnView.bounds.height, 1)
        let x127 = Int(round(min(max(CGFloat(p.x), 0), w) / w * 127))
        let y127 = Int(round(min(max(h - CGFloat(p.y), 0), h) / h * 127))
        return (x127, y127)
    }
    
    /// Update stem bend toward sun position.
    private func updateStemBend(sunXWorld: Float, sunYWorld: Float, deltaTime: Float) {
        guard stemJoints.count > 1 else { return }
        let base = stemJoints[0]
        let baseWorldPos = base.convertPosition(SCNVector3Zero, to: rootNode)
        let dx = sunXWorld - baseWorldPos.x
        let ground = groundY
        // --- Compute day and night target angles ---
        let nightBendMultiplier: Float = 3.0
        let baseMaxRadiansNight = maxStemBendDegrees * nightBendMultiplier * (.pi / 180)
        let droopBase = baseMaxRadiansNight * nightDroopBaseFactor * nightSwayDirection
        let sway = sin(simulationTime * nightSwaySpeed + nightSwayPhaseOffset) * baseMaxRadiansNight * nightSwayAmplitudeFactor
        let nightAngle = droopBase + sway
        let dayBendMultiplier: Float = 1.0
        let baseMaxRadiansDay = maxStemBendDegrees * dayBendMultiplier * (.pi / 180)
        let norm = dx / (sunDistance * stemBendResponseScale)
        var unclampedAngle = norm * baseMaxRadiansDay
        let minY: Float = -0.01
        let maxY: Float = sunDistance * sunHeightMultiplier
        let normalizedY = min(max((sunYWorld - minY) / max(0.001, (maxY - minY)), 0), 1)
        let heightFactor = 1 - normalizedY
        let dynamicScale = 0.6 + heightFactor * 1.6
        let dynamicMax = baseMaxRadiansDay * dynamicScale
        if unclampedAngle > dynamicMax { unclampedAngle = dynamicMax } else if unclampedAngle < -dynamicMax { unclampedAngle = -dynamicMax }
        let dayAngle = unclampedAngle
        // --- Blend between day and night angles ---
        let blendWidth = nightDayBlendWidth
        let blend: Float
        if sunYWorld < ground - blendWidth {
            blend = 0 // full night
        } else if sunYWorld > ground + blendWidth {
            blend = 1 // full day
        } else {
            blend = (sunYWorld - (ground - blendWidth)) / (2 * blendWidth)
        }
        let targetAngle = blend * dayAngle + (1 - blend) * nightAngle
        // Smooth toward target
        let bendLerpSpeed: Float = blend < 0.5 ? 2.0 : 4.0 // slower at night
        currentStemCumulativeBend += (targetAngle - currentStemCumulativeBend) * min(1, bendLerpSpeed * deltaTime)
        var cumulativePrev: Float = 0
        for (i, joint) in stemJoints.enumerated() {
            if i == 0 { joint.eulerAngles.z = 0; continue }
            let t = Float(i) / Float(stemJoints.count - 1)
            let eased = pow(t, stemBendEasePower)
            let cumulative = currentStemCumulativeBend * eased
            let localIncrement = cumulative - cumulativePrev
            joint.eulerAngles.z = localIncrement
            cumulativePrev = cumulative
        }
    }
    
    /// Blend two UIColors by t (0-1).
    private func blendColors(color1: UIColor, color2: UIColor, t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        color1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        color2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let r = r1 + (r2 - r1) * t
        let g = g1 + (g2 - g1) * t
        let b = b1 + (b2 - b1) * t
        let a = a1 + (a2 - a1) * t
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
    
    /// Restore missing constants.
    private let maxPetalOpenAngle: Float = .pi * 0.85 // Maximum open angle for petals
    private let maxStemBendDegrees: Float = 25 // Max bend at top of stem
    private let stemBendEasePower: Float = 1.0 // Bend ease power
    private let stemBendResponseScale: Float = 1.0 // Bend response scale
    private let nightDayBlendWidth: Float = 1.0 // units around horizon for smooth transition
}

/// Utility to generate a random flower configuration.
extension FlowerConfig {
    static func random() -> FlowerConfig {
        return FlowerConfig(
            numPetals: Int.random(in: 6...20),
            stemHeight: Float.random(in: 2.0...5.0),
            stemRadius: Float.random(in: 0.05...0.15),
            headRadius: Float.random(in: 0.2...0.5),
            petalLength: Float.random(in: 0.2...1.5),
            petalWidth: Float.random(in: 0.15...0.4),
            petalThickness: Float.random(in: 0.03...0.08),
            petalColor: UIColor(
                red: CGFloat.random(in: 0.5...1.0),
                green: CGFloat.random(in: 0.5...1.0),
                blue: CGFloat.random(in: 0.5...1.0),
                alpha: 1.0
            ),
            headColor: UIColor(
                red: CGFloat.random(in: 0.3...1.0),
                green: CGFloat.random(in: 0.2...0.8),
                blue: CGFloat.random(in: 0.1...0.6),
                alpha: 1.0
            ),
            stemColor: UIColor(
                red: CGFloat.random(in: 0.1...0.4),
                green: CGFloat.random(in: 0.6...1.0),
                blue: CGFloat.random(in: 0.2...0.5),
                alpha: 1.0
            ),
            numStars: Int.random(in: 100...500)
        )
    }
}

/// Utility to generate a complimentary color for a given UIColor.
extension UIColor {
    func complimentary() -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        self.getRed(&r, green: &g, blue: &b, alpha: &a)
        // Convert to HSB, rotate hue by 0.5 (180 degrees)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0
        UIColor(red: r, green: g, blue: b, alpha: a).getHue(&hue, saturation: &sat, brightness: &bri, alpha: nil)
        let newHue = fmod(hue + 0.5, 1.0)
        return UIColor(hue: newHue, saturation: sat, brightness: bri, alpha: a)
    }
}
