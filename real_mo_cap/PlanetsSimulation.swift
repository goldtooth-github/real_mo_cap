import SceneKit
import UIKit

// MARK: - Data Structures

/// Represents a planet in the simulation
struct Planet {
    let name: String
    var position: SIMD3<Float>  // Current position
    var velocity: SIMD3<Float>  // Current velocity vector
    let mass: Float             // Planet mass (affects gravitational force)
    var radius: Float           // Visual size
    let color: UIColor          // Planet color
    var node: SCNNode?          // The SceneKit node representing this planet
    
    // Original values for scaling and reset
    let originalPosition: SIMD3<Float>    // Initial position
    let originalVelocity: SIMD3<Float>    // Initial velocity
    let originalRadius: Float             // Original radius before scaling
    let originalDistance: Float           // Original distance from sun
    let eccentricity: Float               // Orbit eccentricity (0=circle, >0=ellipse)
    var speedMultiplier: Float = 1.0      // Custom speed multiplier
    
}

/// Class to handle the planetary system simulation
class PlanetsSimulation: LifeformSimulation {
    
    // MARK: - Properties
    
    /// Collection of planets in the simulation
    var planets: [Planet] = []
    
    // Keep a reference to the scene
    private weak var sceneReference: SCNScene?
    private let rootNode = SCNNode()
    // Expose the SCNView so callers can project world positions to screen space
    weak var scnView: SCNView?
    
    // Simulation parameters
    let maxCoord: Int = 10
    let sceneScale: Float = CameraOrbitState.sceneScale
    
    // Physics constants
    private let gravitationalConstant: Float = 0.002
    private var simulationSpeed: Float = 10.0
    var internalSpeedFactor: Float { simulationSpeed }
    private var time: Float = 0.0
    private var userOffset: SCNVector3 = .zero
    // Scaling
    var currentSystemScale: Float = 1.0
    
    // Rotation (around Z axis) applied visually (render-only) about the sun
    private var systemRotationAngle: Float = 0.0 // radians (render transform only)
    private var systemTiltAngleX: Float = 0.0    // radians (render transform only)
    
    // User controls
    var userSimulationSpeed: Float = 5.0 {
        didSet {
            // Expanded mapping for very high speeds while keeping low-end control.
            // At 0 -> ~1, at 10 -> large, at 20 -> extreme.
            simulationSpeed = pow(1.6, userSimulationSpeed * 0.9) + (userSimulationSpeed * 1.5)
        }
    }
    
    // Physics tuning (stability): clamp large steps & substep
    private let maxPhysicsChunk: Float = 0.05   // largest chunk processed per outer loop
    private let targetSubstep: Float = 0.008    // substep size for Verlet integration
    
    // Remember the initial planet count for reset
    private var initialPlanetCount: Int = 0
    
    // Reused acceleration buffer
    private var accelBuffer: [SIMD3<Float>] = []
    
    private var systemOffset: SIMD3<Float> = .zero // accumulated translation applied to all planets (including sun)
    private let maxSystemOffset: Float = 30.0      // definable movement bound in world units (pre-scale)
    private let maxSystemOffsetY: Float = 30.0
    
    // Per-planet spin speed (radians/sec), keyed by node identity
    private var spinSpeedByNode: [ObjectIdentifier: Float] = [:]
    private func setSpinSpeed(for node: SCNNode, speed: Float) { spinSpeedByNode[ObjectIdentifier(node)] = speed }
    // Global multiplier to scale all planet self-rotation speeds
    private var spinGlobalMultiplier: Float = 5.0
    public func setSpinGlobalMultiplier(_ m: Float) { spinGlobalMultiplier = max(0, m) }
    
    // Center offset so sun appears in middle of wireframe cube
    private let centerOffset: SIMD3<Float> = {
        // Camera now centers on origin; keep planets centered there
        return SIMD3<Float>(0, 0, 0)
    }()
    
    // MARK: - Initialization
    /// Initialize the simulation with the specified scene
    init(scene: SCNScene, scnView: SCNView?, deferBuild: Bool = false) {
        self.sceneReference = scene
        self.scnView = scnView
        scene.rootNode.addChildNode(rootNode)
        setupPlanetarySystem(in: scene)
        initialPlanetCount = 0 // Use predefined system
        // Align to screen-space orthographic view if possible
        alignSceneWithScreenSpace()
    }
    /// Create a specified number of planets in the scene
    init(planetCount: Int, scene: SCNScene) {
        self.sceneReference = scene
        initialPlanetCount = planetCount
        setupRandomPlanetarySystem(planetCount: planetCount, in: scene)
        // Removed ambient light
        // Align to screen-space orthographic view if possible
        alignSceneWithScreenSpace()
    }
    
    // MARK: - Screen-space Orthographic Alignment (mirrors Jellyfish)
    public func realignAfterViewAttached() { alignSceneWithScreenSpace() }
    
    private func alignSceneWithScreenSpace() {
        guard let scnView = scnView, let scene = sceneReference else { return }
        // Ensure a camera exists; if none, create one
        let cameraNode: SCNNode = {
            if let n = scene.rootNode.childNodes.first(where: { $0.camera != nil }) {
                return n
            }
            let n = SCNNode(); n.camera = SCNCamera(); scene.rootNode.addChildNode(n); return n
        }()
        guard let cam = cameraNode.camera else { return }
        // Use orthographic projection to get a 2D screen-space feel
        cam.usesOrthographicProjection = true
        // Choose a scale that comfortably frames our system; tie to currentSystemScale
        // Larger orthographicScale => shows more world; keep stable baseline and let user scale planets separately
        cam.orthographicScale = 20.0
        // Prevent near-plane clipping when bodies get very close to the camera
        cam.zNear = 0.001
        cam.zFar = 2000.0
        cam.automaticallyAdjustsZRange = true
        // Center on world origin (planets are centered there)
        let center = SCNVector3(0, 0, 0)
        cameraNode.position = SCNVector3(center.x, center.y, 10)
        cameraNode.eulerAngles = SCNVector3Zero
        cameraNode.look(at: center)
        // Ensure SCNView uses our camera
        if scnView.pointOfView !== cameraNode { scnView.pointOfView = cameraNode }
    }
    
    // MARK: - Planet Setup
    
    /// Set up a predefined planetary system (like our solar system)
    private func setupPlanetarySystem(in scene: SCNScene) {
        let sunPos = centerOffset
        // SUN
        let sunSphere = SCNSphere(radius: 0.3)
        sunSphere.segmentCount = 24 // Reduced from default 48 for better performance
        let sunMaterial = SCNMaterial()
        if let sunImage = loadTexture(named: "sun_texture") {
            sunMaterial.diffuse.contents = sunImage
            sunMaterial.emission.contents = sunImage
        } else {
            sunMaterial.diffuse.contents = UIColor.orange
            sunMaterial.emission.contents = UIColor.yellow // Make the sun glow
        }
        sunMaterial.specular.contents = UIColor.white
        sunMaterial.shininess = 0.1 // Slightly shinier
        sunMaterial.lightingModel = .constant // Changed from phong to reduce GPU cost
        sunSphere.firstMaterial = sunMaterial
        let sunNode = SCNNode(geometry: sunSphere)
        sunNode.position = SCNVector3(sunPos)
        scene.rootNode.addChildNode(sunNode)
        // Spin: slow rotation for the sun
        setSpinSpeed(for: sunNode, speed: 0.02)
        let sun = Planet(
            name: "Sun",
            position: sunPos,
            velocity: SIMD3<Float>(0, 0, 0),
            mass: 100.0,
            radius: 0.3,
            color: .orange,
            node: sunNode,
            originalPosition: sunPos,
            originalVelocity: SIMD3<Float>(0, 0, 0),
            originalRadius: 0.3,
            originalDistance: 0,
            eccentricity: 0,
            speedMultiplier: 1.0
        )
        planets.append(sun)
        // EARTH
        let earthPos = sunPos + SIMD3<Float>(4, 0, 0)
        let earthSphere = SCNSphere(radius: 0.3)
        earthSphere.segmentCount = 24 // Reduced from default 48 for better performance
        let earthMaterial = SCNMaterial()
        if let earthImage = loadTexture(named: "earth_texture") {
            earthMaterial.diffuse.contents = earthImage
        } else {
            earthMaterial.diffuse.contents = UIColor.blue
        }
        earthMaterial.specular.contents = UIColor.white
        earthMaterial.shininess = 0.6
        earthMaterial.lightingModel = .constant // Changed from phong to reduce GPU cost
        earthSphere.firstMaterial = earthMaterial
        let earthNode = SCNNode(geometry: earthSphere)
        earthNode.position = SCNVector3(earthPos)
        // Axial tilt ~23 degrees: tilt the local rotation axis using pivot (around X)
        let tiltRad = Float(23.0 * .pi / 180.0)
        earthNode.pivot = SCNMatrix4MakeRotation(tiltRad, 1, 0, 0)
        scene.rootNode.addChildNode(earthNode)
        // Spin: moderate rotation for Earth
        setSpinSpeed(for: earthNode, speed: 0.06)
        let earth = Planet(
            name: "Earth",
            position: earthPos,
            velocity: SIMD3<Float>(0, 0.05, 0.5),
            mass: 10.0,
            radius: 0.3,
            color: .blue,
            node: earthNode,
            originalPosition: earthPos,
            originalVelocity: SIMD3<Float>(0, 0.05, 0.5),
            originalRadius: 0.3,
            originalDistance: 4,
            eccentricity: 0.02,
            speedMultiplier: 1.0
        )
        planets.append(earth)
        // MARS
        let marsPos = sunPos + SIMD3<Float>(6, 0, 0)
        let marsSphere = SCNSphere(radius: 0.25)
        marsSphere.segmentCount = 20 // Reduced from default 48 for better performance
        let marsMaterial = SCNMaterial()
        if let marsImage = loadTexture(named: "mars_texture") {
            marsMaterial.diffuse.contents = marsImage
        } else {
            marsMaterial.diffuse.contents = UIColor.red
        }
        marsMaterial.specular.contents = UIColor.white
        marsMaterial.shininess = 0.6
        marsMaterial.lightingModel = .constant // Changed from phong to reduce GPU cost
        marsSphere.firstMaterial = marsMaterial
        let marsNode = SCNNode(geometry: marsSphere)
        marsNode.position = SCNVector3(marsPos)
        scene.rootNode.addChildNode(marsNode)
        // Spin: moderate rotation for Mars
        setSpinSpeed(for: marsNode, speed: 0.05)
        let mars = Planet(
            name: "Mars",
            position: marsPos,
            velocity: SIMD3<Float>(0, 0.04, 0.4),
            mass: 5.0,
            radius: 0.25,
            color: .red,
            node: marsNode,
            originalPosition: marsPos,
            originalVelocity: SIMD3<Float>(0, 0.04, 0.4),
            originalRadius: 0.25,
            originalDistance: 6,
            eccentricity: 0.09,
            speedMultiplier: 0.8
        )
        planets.append(mars)
        // MERCURY
        let mercuryPos = sunPos + SIMD3<Float>(2, 0, 0)
        let mercurySphere = SCNSphere(radius: 0.15)
        mercurySphere.segmentCount = 16 // Reduced from default 48 for better performance
        let mercuryMaterial = SCNMaterial()
        if let mercuryImage = loadTexture(named: "mercury_texture") {
            mercuryMaterial.diffuse.contents = mercuryImage
        } else {
            mercuryMaterial.diffuse.contents = UIColor.gray
        }
        mercuryMaterial.specular.contents = UIColor.white
        mercuryMaterial.shininess = 0.6
        mercuryMaterial.lightingModel = .constant // Changed from phong to reduce GPU cost
        mercurySphere.firstMaterial = mercuryMaterial
        let mercuryNode = SCNNode(geometry: mercurySphere)
        mercuryNode.position = SCNVector3(mercuryPos)
        scene.rootNode.addChildNode(mercuryNode)
        // Spin: faster rotation for Mercury
        setSpinSpeed(for: mercuryNode, speed: 0.08)
        let mercury = Planet(
            name: "Mercury",
            position: mercuryPos,
            velocity: SIMD3<Float>(0, 0.07, 0.7),
            mass: 3.0,
            radius: 0.15,
            color: .gray,
            node: mercuryNode,
            originalPosition: mercuryPos,
            originalVelocity: SIMD3<Float>(0, 0.07, 0.7),
            originalRadius: 0.15,
            originalDistance: 2,
            eccentricity: 0.2,
            speedMultiplier: 1.2
        )
        planets.append(mercury)
        // COMET
        let cometPos = sunPos + SIMD3<Float>(8, 0, 0)
        let cometSphere = SCNSphere(radius: 0.1)
        cometSphere.segmentCount = 16 // Reduced from default 48 for better performance
        let cometMaterial = SCNMaterial()
        if let cometImage = loadTexture(named: "comet_texture") {
            cometMaterial.diffuse.contents = cometImage
        } else {
            cometMaterial.diffuse.contents = UIColor.cyan
        }
        cometMaterial.specular.contents = UIColor.white
        cometMaterial.shininess = 0.6
        cometMaterial.lightingModel = .constant // Changed from phong to reduce GPU cost
        cometSphere.firstMaterial = cometMaterial
        let cometNode = SCNNode(geometry: cometSphere)
        cometNode.position = SCNVector3(cometPos)
        scene.rootNode.addChildNode(cometNode)
        // Spin: fastest rotation for Comet (for visual interest)
        setSpinSpeed(for: cometNode, speed: 0.10)
        let comet = Planet(
            name: "Comet",
            position: cometPos,
            velocity: SIMD3<Float>(0, 0.1, 0.6),
            mass: 0.1,
            radius: 0.1,
            color: .cyan,
            node: cometNode,
            originalPosition: cometPos,
            originalVelocity: SIMD3<Float>(0, 0.1, 0.6),
            originalRadius: 0.1,
            originalDistance: 8,
            eccentricity: 0.6,
            speedMultiplier: 1.3
        )
        planets.append(comet)
        // Add a light to the sun (optimized intensity)
        if let sunNode = sun.node {
            let light = SCNLight()
            light.type = .omni
            light.color = UIColor.white
            light.intensity = 800 // Reduced from 4000 to minimize GPU overhead
            light.temperature = 6500 // Daylight
            light.castsShadow = false // Sun usually doesn't cast hard shadows in space
            light.attenuationStartDistance = 0
            light.attenuationEndDistance = 100
            light.attenuationFalloffExponent = 2
            sunNode.light = light // <-- Attach the light to the sun node
        }
    }
    
    /// Set up a random planetary system
    private func setupRandomPlanetarySystem(planetCount: Int, in scene: SCNScene) {
        let sunPos = centerOffset
        // Create center star/sun
        let sun = createPlanet(
            name: "Sun",
            position: sunPos,
            velocity: SIMD3<Float>(0, 0, 0),
            mass: 100.0,
            radius: 0.3,
            color: .yellow,
            eccentricity: 0,
            speedMultiplier: 1.0,
            sunReferencePosition: sunPos,
            in: scene
        )
        planets.append(sun)
        
     /*/   // Add a light to the sun
        if let sunNode = sun.node {
            let light = SCNLight(); light.type = .omni; light.color = UIColor.yellow; light.intensity = 1800; sunNode.light = light
        }*/
        
        // Create random planets
        let planetColors: [UIColor] = [.blue, .red, .green, .orange, .purple, .gray, .brown, .cyan]
        
        // Create planets with increasing distances but varied parameters
        for i in 0..<planetCount {
            // Calculate position (distance from sun increases with index)
            let angle = Float.random(in: 0..<Float.pi*2)
            let distance = Float(i + 2) * 1.0 + Float.random(in: -0.3...0.3)
            
            // Add inclination for 3D orbits
            let inclination = Float.random(in: -0.2...0.2)
            
            let localPos = SIMD3<Float>(
                distance * sin(angle),
                inclination * distance,
                distance * cos(angle)
            )
            let position = sunPos + localPos
            
            // Calculate initial velocity for orbit
            let eccentricity = Float.random(in: 0.0...0.3)
            let speedMultiplier = Float.random(in: 0.7...1.3)
            
            // Compute baseline orbital velocity using gravitational formula v = √(GM/r)
            let baseOrbitSpeed = sqrt(gravitationalConstant * sun.mass / distance)
            
            // Get perpendicular direction for orbit
            let toSun = sunPos - position
            let up = SIMD3<Float>(0, 1, 0)
            var perpendicular = normalize(cross(up, normalize(toSun)))
            
            // Handle case where perpendicular calculation fails (planet on y-axis)
            if length(perpendicular) < 0.1 {
                perpendicular = normalize(cross(SIMD3<Float>(1,0,0), normalize(toSun)))
            }
            
            // Tilt the orbit plane slightly
            let tiltAngle = Float.random(in: -0.2...0.2)
            let tiltAxis = normalize(toSun)
            perpendicular = rotateVector(perpendicular, around: tiltAxis, by: tiltAngle)
            
            // Add radial component for eccentricity
            let radialComponent = normalize(toSun) * -eccentricity * 0.3
            let velocity = (perpendicular + radialComponent).normalized() * baseOrbitSpeed * speedMultiplier
            
            // Create the planet
            let colorIndex = i % planetColors.count
            let planet = createPlanet(
                name: "Planet-\(i+1)",
                position: position,
                velocity: velocity,
                mass: Float.random(in: 1...20),
                radius: Float.random(in: 0.1...0.4),
                color: planetColors[colorIndex],
                eccentricity: eccentricity,
                speedMultiplier: speedMultiplier,
                sunReferencePosition: sunPos,
                in: scene
            )
            planets.append(planet)
        }
    }
    
    /// Create a planet and add it to the scene
    private func createPlanet(name: String, position: SIMD3<Float>, velocity: SIMD3<Float>,
                             mass: Float, radius: Float, color: UIColor, eccentricity: Float,
                             speedMultiplier: Float, sunReferencePosition: SIMD3<Float>, in scene: SCNScene) -> Planet {
        // Create the visual representation
        let sphere = SCNSphere(radius: CGFloat(radius))
        // Optimize segment count based on size - smaller planets need fewer segments
        sphere.segmentCount = radius < 0.15 ? 12 : (radius < 0.25 ? 16 : 20)
        let material = SCNMaterial()
        // Use texture if known by name, otherwise fallback to solid color
        let lower = name.lowercased()
        let texName: String? = (
            lower.contains("sun") ? "sun_texture" :
            lower.contains("earth") ? "earth_texture" :
            lower.contains("mars") ? "mars_texture" :
            lower.contains("mercury") ? "mercury_texture" :
            lower.contains("comet") ? "comet_texture" : nil
        )
        if let t = texName, let img = loadTexture(named: t) {
            material.diffuse.contents = img
            if t == "sun_texture" { material.emission.contents = img }
        } else {
            material.diffuse.contents = color
        }
        material.specular.contents = UIColor.white
        material.shininess = 0.6
        material.lightingModel = .constant // Changed from phong to reduce GPU cost
        sphere.firstMaterial = material
        // Create the node and position it
        let node = SCNNode(geometry: sphere)
        node.position = SCNVector3(position)
        scene.rootNode.addChildNode(node)
        // Calculate distance from sun (if not sun itself)
        let distanceFromSun: Float = (name == "Sun") ? 0 : length(position - sunReferencePosition)
        // Create and return the planet
        let planet = Planet(
            name: name,
            position: position,
            velocity: velocity,
            mass: mass,
            radius: radius,
            color: color,
            node: node,
            originalPosition: position,
            originalVelocity: velocity,
            originalRadius: radius,
            originalDistance: distanceFromSun,
            eccentricity: eccentricity,
            speedMultiplier: speedMultiplier
        )
        
        // Set default spin speed (radians per second) based on known names, or randomize for generics
        let spin: Float = {
            if lower.contains("sun") { return 0.02 }
            if lower.contains("earth") { return 0.06 }
            if lower.contains("mars") { return 0.05 }
            if lower.contains("mercury") { return 0.08 }
            if lower.contains("comet") { return 0.10 }
            var v = Float.random(in: 0.02...0.12)
            if Bool.random() { v = -v }
            return v
        }()
        setSpinSpeed(for: node, speed: spin)
        
        return planet
    }
    
    // MARK: - Simulation Implementation
    func translate(dx: Float, dy: Float, dz: Float) {
        // Move all jellyfish by delta
        rootNode.position.x += dx
        rootNode.position.y += dy
        rootNode.position.z += dz
    }
    
    /// Update the simulation for the current frame
    func update(deltaTime: Float) {
        var remaining = deltaTime * simulationSpeed
     if remaining <= 0 { return }
        time += remaining
        while remaining > 0 {
            let chunk = min(maxPhysicsChunk, remaining)
            advanceChunk(chunk)
            remaining -= chunk
        }
        // After physics integration, apply visual rotation to node positions only
        applyRenderRotation()
        
        // Apply per-planet spin
        for planet in planets {
            if let node = planet.node {
                let base = spinSpeedByNode[ObjectIdentifier(node)] ?? 0.0
                let spinSpeed = base * spinGlobalMultiplier
                let currentRotation = node.eulerAngles.y
                node.eulerAngles.y = currentRotation + spinSpeed * deltaTime
            }
        }
    }
    
    /// Reset the simulation to initial state
    func reset() {
        // Keep a reference to the scene
        guard let scene = sceneReference else { return }
        
        // Remove all existing planets from the scene
        for planet in planets {
            planet.node?.removeFromParentNode()
        }
        
        // Clear planets array and spin state
        planets.removeAll()
        spinSpeedByNode.removeAll()
        
        // Reset scale
        currentSystemScale = 1.0
        
        // Recreate the planetary system from scratch
        if initialPlanetCount > 0 {
            setupRandomPlanetarySystem(planetCount: initialPlanetCount, in: scene)
        } else {
            setupPlanetarySystem(in: scene)
        }
        
        // Reset time
        time = 0.0
        
        systemOffset = .zero
        // Re-align camera after reset if view is available
        alignSceneWithScreenSpace()
    }
    
    // MARK: - Physics Calculations
    
    // Velocity Verlet chunk advancement with substeps
    private func advanceChunk(_ chunk: Float) {
        guard planets.count > 1 else { return }
        let substeps = max(1, Int(ceil(chunk / targetSubstep)))
        let dt = chunk / Float(substeps)
        let sunMass = planets[0].mass
        let sunPos = planets[0].position
        let boundaryRadius: Float = Float(maxCoord) * 0.8 * currentSystemScale
        if accelBuffer.count != planets.count { accelBuffer = Array(repeating: .zero, count: planets.count) }
        for _ in 0..<substeps {
            for i in 1..<planets.count { accelBuffer[i] = acceleration(toward: sunPos, sunMass: sunMass, position: planets[i].position) }
            for i in 1..<planets.count {
                let a0 = accelBuffer[i]
                planets[i].velocity += 0.5 * a0 * dt
                planets[i].position += planets[i].velocity * dt
                let rel = planets[i].position - sunPos
                let rLen = length(rel)
                if rLen > boundaryRadius { planets[i].position = sunPos + (rel / rLen) * boundaryRadius }
            }
            for i in 1..<planets.count {
                let a1 = acceleration(toward: sunPos, sunMass: sunMass, position: planets[i].position)
                planets[i].velocity += 0.5 * a1 * dt
                // node position update deferred to applyRenderRotation()
            }
        }
    }
    private func acceleration(toward sunPos: SIMD3<Float>, sunMass: Float, position: SIMD3<Float> ) -> SIMD3<Float> {
        let toSun = sunPos - position
        let distSq = max(length_squared(toSun), 0.01)
        let invDist = 1.0 / sqrt(distSq)
        let aMag = gravitationalConstant * sunMass / distSq
        return toSun * invDist * aMag
    }
    
    // Obsolete legacy step (kept to satisfy references if any)
    private func stepPhysics(_ dt: Float) { /* replaced by advanceChunk */ }
    
    // MARK: - User Controls
    
    /// Set the simulation speed
    func setSimulationSpeed(_ speed: Float) { userSimulationSpeed = speed }
    
    /// Set the system scale
    func setSystemScale(_ newScale: Float) {
        guard newScale > 0 else { return }
        let sunPosition = planets[0].position
        for i in 0..<planets.count {
            if i > 0 {
                // Preserve orbital plane using original angular momentum (r x v)
                let r0 = planets[i].originalPosition - planets[0].originalPosition
                let v0 = planets[i].originalVelocity
                var normal = cross(r0, v0)
                let nLen = length(normal)
                if nLen < 1e-5 {
                    // Fallback: use world up if degenerate
                    normal = SIMD3<Float>(0, 1, 0)
                } else {
                    normal /= nLen
                }
                // Direction from sun to current position
                var fromSunToPlanet = normalize(planets[i].position - sunPosition)
                if length(fromSunToPlanet) < 1e-5 { fromSunToPlanet = normalize(r0) }
                // New distance and position along the same radial direction
                let newDistance = max(1e-5, planets[i].originalDistance * newScale)
                planets[i].position = sunPosition + fromSunToPlanet * newDistance
                // Tangent direction lies in orbital plane and perpendicular to radial
                var tangent = cross(normal, fromSunToPlanet)
                let tLen = length(tangent)
                if tLen < 1e-5 {
                    // Fallback to previous perpendicular logic
                    let up = SIMD3<Float>(0, 1, 0)
                    tangent = cross(fromSunToPlanet, up)
                } else {
                    tangent /= tLen
                }
                // Speed magnitude from GM/r
                let baseOrbitSpeed = sqrt(gravitationalConstant * planets[0].mass / newDistance)
                // Eccentricity radial component within the same plane
                let eccentricityComponent = fromSunToPlanet * -planets[i].eccentricity * 0.3
                let velDir = normalize(tangent + eccentricityComponent)
                planets[i].velocity = velDir * baseOrbitSpeed * planets[i].speedMultiplier
            }
            let newRadius = planets[i].originalRadius * newScale
            planets[i].radius = newRadius
            if let node = planets[i].node, let sphere = node.geometry as? SCNSphere { sphere.radius = CGFloat(newRadius) }
        }
        currentSystemScale = newScale
        applyRenderRotation()
    }
    
    /// Translate entire system (moves sun + planets) clamped to bounds (XZ plane)
    func translateSystem(dx: Float, dz: Float) {
        let proposed = systemOffset + SIMD3<Float>(dx, 0, dz)
        let clamped = SIMD3<Float>(
            max(-maxSystemOffset, min(maxSystemOffset, proposed.x)),
            proposed.y,
            max(-maxSystemOffset, min(maxSystemOffset, proposed.z))
        )
        let applied = clamped - systemOffset
        guard length(applied) > 0 else { return }
        systemOffset = clamped
        for i in 0..<planets.count { planets[i].position += applied }
        applyRenderRotation()
    }
    /// Translate entire system in X/Y (vertical) only, leaving Z unchanged.
    func translateSystemXY(dx: Float, dy: Float) {
        let proposed = systemOffset + SIMD3<Float>(dx, dy, 0)
        let clamped = SIMD3<Float>(
            max(-maxSystemOffset, min(maxSystemOffset, proposed.x)),
            max(-maxSystemOffsetY, min(maxSystemOffsetY, proposed.y)),
            systemOffset.z
        )
        let applied = clamped - systemOffset
        guard (abs(applied.x) + abs(applied.y)) > 0 else { return }
        systemOffset = clamped
        for i in 0..<planets.count { planets[i].position += SIMD3<Float>(applied.x, applied.y, 0) }
        applyRenderRotation()
    }
    

    /// Set rotation (API expects radians; caller converts from degrees) around Z axis.
    /// Render-only: does not modify underlying physics positions/velocities.
    func setSystemRotation(angle: Float) {
        systemRotationAngle = angle
        applyRenderRotation()
    }
    /// Set a visual tilt around the X axis (radians) to reveal Z-plane motion on screen.
    func setSystemTiltX(angle: Float) {
        systemTiltAngleX = angle
        applyRenderRotation()
    }
    
    /// Apply a visual-only rotation about the sun (planet[0]) combining Z rotation and X tilt.
    private func applyRenderRotation() {
        guard planets.count > 0 else { return }
        let sunPos = planets[0].position
        planets[0].node?.position = SCNVector3(sunPos)
        for i in 1..<planets.count {
            let rel = planets[i].position - sunPos
            let rotatedZ = (systemRotationAngle == 0) ? rel : rotateZ(rel, systemRotationAngle)
            let rotatedZX = (systemTiltAngleX == 0) ? rotatedZ : rotateX(rotatedZ, systemTiltAngleX)
            planets[i].node?.position = SCNVector3(sunPos + rotatedZX)
        }
    }
    
    // MARK: - Helper Rotation Functions (restored)
    /// General rotation of a vector around an arbitrary axis using Rodrigues' formula.
    private func rotateVector(_ v: SIMD3<Float>, around axis: SIMD3<Float>, by angle: Float) -> SIMD3<Float> {
        let k = normalize(axis)
        let c = cosf(angle)
        let s = sinf(angle)
        // v_rot = v*c + (k x v)*s + k*(k·v)*(1-c)
        return v * c + cross(k, v) * s + k * (dot(k, v) * (1 - c))
    }
    /// Fast rotation around global Z axis.
    private func rotateZ(_ v: SIMD3<Float>, _ angle: Float) -> SIMD3<Float> {
        let c = cosf(angle)
        let s = sinf(angle)
        return SIMD3<Float>(v.x * c - v.y * s, v.x * s + v.y * c, v.z)
    }
    /// Fast rotation around global X axis.
    private func rotateX(_ v: SIMD3<Float>, _ angle: Float) -> SIMD3<Float> {
        let c = cosf(angle)
        let s = sinf(angle)
        return SIMD3<Float>(v.x, v.y * c - v.z * s, v.y * s + v.z * c)
    }
    
    /// Texture cache to avoid repeated loading
    private static var textureCache: [String: UIImage] = [:]
    private func loadTexture(named name: String) -> UIImage? {
        if let cached = PlanetsSimulation.textureCache[name] { return cached }
        let start = CFAbsoluteTimeGetCurrent()
        let img = UIImage(named: name)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("[DBG] Loaded texture '", name, "' in ", String(format: "%.3f", elapsed), "s")
        if let img = img { PlanetsSimulation.textureCache[name] = img }
        return img
    }
}

// MARK: - Helper Extensions

extension SIMD3 where Scalar == Float {
    func normalized() -> SIMD3<Float> {
        let len = length(self)
        if len > 0 {
            return self / len
        }
        return self
    }
}
