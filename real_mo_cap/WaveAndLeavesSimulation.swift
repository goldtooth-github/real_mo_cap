import SceneKit
import UIKit
import simd

private extension UIColor {
    func rgb() -> (Float, Float, Float) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if self.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (Float(r), Float(g), Float(b))
        }
        // Fallback (should not happen with standard colors)
        return (1,1,1)
    }
}

/// Represents a piece of sea debris floating on the wave
struct FloatingDebris {
    enum DebrisType { case bottle }
    var type: DebrisType
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var node: SCNNode?
    var lastOrientation: simd_quatf // for rocking/swaying
}

/// Parameters for configuring a lighthouse buoy
struct LighthouseBuoyParameters {
    var baseRadius: Float          // Radius of cylindrical hull
    var sphereRadius: Float        // Radius of spherical base (independent)
    var height: Float              // Total visual height above water line
    var stripeCount: Int           // Number of red/white stripes
    var floatOffset: Float         // Vertical offset above wave height for buoy center
    var tetherStiffness: Float     // Horizontal spring stiffness pulling toward anchor
    var tetherDamping: Float       // Horizontal velocity damping
    var rockingStrength: Float     // Scales rotation toward wave normal
    var orientationSmoothing: Float // 0..1 smoothing factor per frame for orientation
    var colorPrimary: UIColor      // First stripe color (red)
    var colorSecondary: UIColor    // Second stripe color (white)

    static var `default`: LighthouseBuoyParameters { .init(
        baseRadius: 0.35,
        sphereRadius: 0.8, // larger sphere by default
        height: 2.2,
        stripeCount: 6,
        floatOffset: 0.15,
        tetherStiffness: 0.15,
        tetherDamping: 0.42,
        rockingStrength: 0.85,
        orientationSmoothing: 0.18,
        colorPrimary: .red,
        colorSecondary: .white
    ) }
}

/// Runtime state of a lighthouse buoy
private struct LighthouseBuoy {
    var anchor: SIMD3<Float>              // World anchor point on seabed
    var position: SIMD3<Float>            // Current world position (at geometric center near waterline)
    var velocity: SIMD3<Float>            // Horizontal velocity (y governed by wave)
    var params: LighthouseBuoyParameters  // Config params
    var node: SCNNode                     // Root node
    var lastOrientation: simd_quatf       // Smoothed orientation
    var spotlightNode: SCNNode?           // Rotating spotlight node
}

/// Simulation of a 3D ocean wave with a leaf floating on top
class WaveAndLeavesSimulation: LifeformSimulation {
    // MARK: - Properties
    var waveNode: SCNNode?
    var simulationRootNode: SCNNode = SCNNode()
    weak var scnView: SCNView?
    weak var sceneReference: SCNScene?
    
    private var jointPositions: [String: SCNVector3] = [:]
    private var jointNodes: [String: SCNNode] = [:]
    private var rootNode: SCNNode = SCNNode()
    private var time: Float = 0.0
    var userSimulationSpeed: Float = 1.0
    var waveAmplitude: Float = 0.6
    var waveFrequency: Float = 1.2
    var globalScale: Float = 1.0
    var debris: [FloatingDebris] = []
    private let waterRadius: Float = 7.0
    private let waterHeight: Float = 2.0
    private var waveResolution: Int = 12
    // Primary directional wave parameters
    var primaryWaveDirectionRadians: Float = 0.0
    var primaryWavePhaseOffset: Float = 0.0
    var primaryWaveSpeedFactor: Float = 1.0
    var primaryAmpModDepth: Float = 0.15
    var primaryAmpModSpatialFreq: Float = 0.3
    var primaryAmpModPhase: Float = 0.0
    var primaryFreqModDepth: Float = 0.10
    var primaryFreqModSpatialFreq: Float = 0.3
    var primaryFreqModPhase: Float = Float.pi * 0.5
    // Second directional traveling wave
    var secondWaveAmplitude: Float = 0.0
    var secondWaveAmplitudeMultiplier: Float = 0.7
    var secondWaveFrequency: Float = 1.0
    var secondWaveDirectionRadians: Float = 0.0
    var secondWavePhaseOffset: Float = 0.0
    var secondWaveSpeedFactor: Float = 1.0
    // Third directional traveling wave
    var thirdWaveAmplitude: Float = 0.6
    var thirdWaveAmplitudeMultiplier: Float = 0.5
    var thirdWaveFrequency: Float = 1.7
    var thirdWaveDirectionRadians: Float = 0.4
    var thirdWavePhaseOffset: Float = 0.0
    var thirdWaveSpeedFactor: Float = 1.0
    // Wind gust temporal modulation
    var windGustEnabled: Bool = false
    var windGustFrequency: Float = 0.15
    var windSecondaryFrequency: Float = 0.41
    var windSecondaryMix: Float = 0.35
    var windGustAmplitude: Float = 0.4
    var windSpeedModFactor: Float = 0.6
    var windPhase: Float = 0.0
    private var currentGustAmplitudeFactor: Float = 1.0
    private var currentGustSpeedFactor: Float = 1.0
    // Foam parameters
    var foamEnabled: Bool = false
    var foamSlopeThreshold: Float = 0.45
    var foamSlopeRange: Float = 0.35
    var foamHeightThreshold: Float = 0.15
    var foamIntensity: Float = 1.0
    var foamColor: SIMD3<Float> = SIMD3<Float>(0.95, 0.97, 0.98)
    // NEW: Lighthouse buoy state
    private var lighthouseBuoy: LighthouseBuoy?

    // --- Sky and Stars ---
    private var skyNode = SCNNode() // Sky dome node
    private var starNodes: [SCNNode] = [] // Star nodes
    private var numStars: Int { 80 } // Number of stars in sky
    private var isNight: Bool = false // Nighttime toggle

    // --- Adaptive Resolution ---
    private var frameTimes: [Float] = []
    private var lastResolutionCheckTime: Float = 0.0
    private let resolutionCheckInterval: Float = 3.0 // seconds
    private let targetFrameTime: Float = 1.0 / 30.0 // 30 FPS target
    private let maxWaveResolution: Int = 15
    private let minWaveResolution: Int = 4
    private let frameTimeSampleCount: Int = 30

    // MARK: - Initialization
    /// Create the wave simulation.
    /// - Parameters:
    ///   - scene: SceneKit scene to populate.
    ///   - scnView: Optional SCNView reference used for projections.
    ///   - buoyParams: Optional lighthouse buoy parameters; if nil defaults are used.
    ///   - buoyAnchorXZ: Optional XZ anchor position for the buoy (meters). If nil a random position is chosen.
    ///   - addBuoy: Pass false to skip creating a buoy automatically.
    init(scene: SCNScene, scnView: SCNView?, buoyParams: LighthouseBuoyParameters? = nil, buoyAnchorXZ: SIMD2<Float>? = nil, addBuoy: Bool = true) {
        self.sceneReference = scene
        self.scnView = scnView
        simulationRootNode = SCNNode()
        scene.rootNode.addChildNode(simulationRootNode)
        // Removed water boundary cylinder/tube per user request
        if let oldShell = scene.rootNode.childNode(withName: "WaterBoundaryShell", recursively: false) { oldShell.removeFromParentNode() }
        if let oldCyl = scene.rootNode.childNode(withName: "WaterCylinder", recursively: false) { oldCyl.removeFromParentNode() }
        setupSkyAndStars(in: scene)
        setupWave(in: scene)
        setupDebris(in: scene)
        if addBuoy { addLighthouseBuoy(anchorXZ: buoyAnchorXZ, params: buoyParams ?? .default) }
        // Set night mode after everything is set up
        setNight(true)
    }
    // MARK: - Setup
    private func setupWave(in scene: SCNScene) {
        let mesh = waveMeshGrid(size: waveResolution, amplitude: waveAmplitude, frequency: waveFrequency, time: time)
        let waveNode = SCNNode(geometry: mesh)
        waveNode.position = SCNVector3(0, 0, 0)
        simulationRootNode.addChildNode(waveNode)
        self.waveNode = waveNode
    }
    
    
    var visualBounds: Float {
        if let scene = sceneReference,
           let cameraState = (scene as NSObject).value(forKey: "cameraState") as? CameraOrbitState {
            return cameraState.visualBounds
        }
        return 30.0
    }

    
    private func setupDebris(in scene: SCNScene) {
        debris.removeAll()
        // --- Bottle ---
        let bottlePos = randomDebrisPosition()
        let bottleNode = makeBottleNode()
        bottleNode.position = SCNVector3(bottlePos)
        let bottleQuat = simd_quatf(angle: 0, axis: SIMD3<Float>(0,1,0))
        simulationRootNode.addChildNode(bottleNode)
        debris.append(FloatingDebris(type: .bottle, position: bottlePos, velocity: randomDebrisVelocity(), node: bottleNode, lastOrientation: bottleQuat))
    }
    private func randomDebrisPosition() -> SIMD3<Float> {
        let angle = Float.random(in: 0..<(2*Float.pi))
        let radius = Float.random(in: 0.5...(waterRadius-0.5))
        let x = cos(angle) * radius
        let z = sin(angle) * radius
        let y = waveHeightAt(x: x, z: z, time: time) + 0.1
        return SIMD3<Float>(x, y, z)
    }
    private func randomDebrisVelocity() -> SIMD3<Float> {
        return SIMD3<Float>(Float.random(in: -0.02...0.02), 0, Float.random(in: -0.02...0.02))
    }
    private func makeBottleNode() -> SCNNode {
        let root = SCNNode()
        // Body
        let body = SCNCylinder(radius: 0.1, height: 0.42)
        let bodyMat = SCNMaterial()
        bodyMat.diffuse.contents = UIColor(red: 0.2, green: 0.9, blue: 0.2, alpha: 0.7) // green glass
        bodyMat.transparency = 0.7
        body.firstMaterial = bodyMat
        let bodyNode = SCNNode(geometry: body)
        bodyNode.position = SCNVector3(0, 0.2, 0)
        root.addChildNode(bodyNode)
        // Neck
        let neck = SCNCylinder(radius: 0.06, height: 0.32)
        let neckMat = SCNMaterial()
        neckMat.diffuse.contents = UIColor(red: 0.2, green: 0.9, blue: 0.2, alpha: 0.7)
        neckMat.transparency = 0.8
        neck.firstMaterial = neckMat
        let neckNode = SCNNode(geometry: neck)
        neckNode.position = SCNVector3(0, 0.505, 0)
        root.addChildNode(neckNode)
        // Cap
        let cap = SCNCylinder(radius: 0.06, height: 0.025)
        let capMat = SCNMaterial()
        capMat.diffuse.contents = UIColor.white
        cap.firstMaterial = capMat
        let capNode = SCNNode(geometry: cap)
        capNode.position = SCNVector3(0, 0.65, 0)
        root.addChildNode(capNode)
        return root
    }
    // MARK: - Wave Mesh Generation
    private func waveMeshGrid(size: Int, amplitude: Float, frequency: Float, time: Float) -> SCNGeometry {
        // Radial/Angular disc mesh (flat shaded) with vertical sides & bottom; avoids missing edge triangles.
        // size parameter interpreted as radialSegments; angularSegments = radialSegments * 4 for smoother circle.
        let radialSegments = max(4, size)
        let angularSegments = radialSegments * 4
        // Top surface vertex grid indices: (rIndex, aIndex) -> Int32
        var topVertices: [SCNVector3] = []
        topVertices.reserveCapacity((radialSegments + 1) * angularSegments)
        var ringStartIndex: [Int32] = [] // starting index per radial ring
        ringStartIndex.reserveCapacity(radialSegments + 1)
        var currentIndex: Int32 = 0
        let topVertexBaseCountEstimate = (radialSegments + 1) * angularSegments
        var foamFactors: [Float] = Array(repeating: 0, count: topVertexBaseCountEstimate)
        for rIndex in 0...radialSegments {
            ringStartIndex.append(currentIndex)
            let r = waterRadius * Float(rIndex) / Float(radialSegments)
            for aIndex in 0..<angularSegments {
                let theta = (2.0 * Float.pi) * Float(aIndex) / Float(angularSegments)
                let x = r * cos(theta)
                let z = r * sin(theta)
                let y = waveHeightAt(x: x, z: z, time: time)
                topVertices.append(SCNVector3(x, y, z))
                if foamEnabled {
                    // Approximate slope using central differences along world X & Z
                    let dx: Float = 0.15
                    let dz: Float = 0.15
                    let hL = waveHeightAt(x: x - dx, z: z, time: time)
                    let hR = waveHeightAt(x: x + dx, z: z, time: time)
                    let hD = waveHeightAt(x: x, z: z - dz, time: time)
                    let hU = waveHeightAt(x: x, z: z + dz, time: time)
                    let ddx = (hR - hL) / (2*dx)
                    let ddz = (hU - hD) / (2*dz)
                    let slopeMag = sqrt(ddx*ddx + ddz*ddz)
                    let relHeight = y / max(0.0001, waveAmplitude * currentGustAmplitudeFactor)
                    let heightFactor = relHeight <= foamHeightThreshold ? 0 : min(1, (relHeight - foamHeightThreshold) / max(0.0001, 1 - foamHeightThreshold))
                    let st = (slopeMag - foamSlopeThreshold) / foamSlopeRange
                    let slopeFactor = st <= 0 ? 0 : st >= 1 ? 1 : (st * st * (3 - 2*st))
                    let combined = min(1, (slopeFactor * 0.7 + heightFactor * 0.5)) * foamIntensity
                    foamFactors[Int(currentIndex)] = combined
                }
                currentIndex += 1
            }
        }
        // Helper to index into top vertex ring with angular wrap
        func topIndex(_ r: Int, _ a: Int) -> Int32 {
            let aWrapped = (a % angularSegments + angularSegments) % angularSegments
            return ringStartIndex[r] + Int32(aWrapped)
        }
        let topCount = currentIndex
        // Collect triangle indices for top surface
        var topIndices: [Int32] = []
        topIndices.reserveCapacity(radialSegments * angularSegments * 2 * 3)
        for r in 0..<radialSegments {
            for a in 0..<angularSegments {
                let i00 = topIndex(r, a)
                let i01 = topIndex(r, a+1)
                let i10 = topIndex(r+1, a)
                let i11 = topIndex(r+1, a+1)
                // Two triangles
                topIndices.append(i00); topIndices.append(i01); topIndices.append(i10)
                topIndices.append(i10); topIndices.append(i01); topIndices.append(i11)
            }
        }
        // Perimeter (outer ring) indices in order
        var perimeter: [Int32] = []
        perimeter.reserveCapacity(angularSegments)
        for a in 0..<angularSegments { perimeter.append(topIndex(radialSegments, a)) }
        // Build side wall by extruding perimeter downward
        let bottomY: Float = -waterHeight + 0.001
        var sideBottomIndices: [Int32] = []
        sideBottomIndices.reserveCapacity(angularSegments)
        for idx in perimeter {
            let v = topVertices[Int(idx)]
            topVertices.append(SCNVector3(v.x, bottomY, v.z))
            sideBottomIndices.append(Int32(topVertices.count - 1))
        }
        // Side wall indices (two triangles per segment)
        var sideIndices: [Int32] = []
        sideIndices.reserveCapacity(angularSegments * 6)
        for a in 0..<angularSegments {
            let next = (a + 1) % angularSegments
            let topA = perimeter[a]
            let topB = perimeter[next]
            let botA = sideBottomIndices[a]
            let botB = sideBottomIndices[next]
            sideIndices.append(topA); sideIndices.append(topB); sideIndices.append(botA)
            sideIndices.append(botA); sideIndices.append(topB); sideIndices.append(botB)
        }
        // Bottom disk (fan) using bottom ring indices
        var bottomIndices: [Int32] = []
        if !sideBottomIndices.isEmpty {
            let centerIndex = Int32(topVertices.count)
            topVertices.append(SCNVector3(0, bottomY, 0))
            for a in 0..<angularSegments {
                let next = (a + 1) % angularSegments
                // Winding for downward normal (we'll duplicate normals anyway)
                bottomIndices.append(centerIndex)
                bottomIndices.append(sideBottomIndices[next])
                bottomIndices.append(sideBottomIndices[a])
            }
        }
        // Combine all triangle indices
        let allIndices = topIndices + sideIndices + bottomIndices
        // Flat shading: duplicate vertices per triangle
        var flatVertices: [SCNVector3] = []
        var flatNormals: [SCNVector3] = []
        var flatColors: [Float] = [] // RGBA sequence
        flatVertices.reserveCapacity(allIndices.count)
        flatNormals.reserveCapacity(allIndices.count)
        flatColors.reserveCapacity(allIndices.count * 4)
        var flatIndices: [Int32] = []
        flatIndices.reserveCapacity(allIndices.count)
        var nextFlat: Int32 = 0
        let baseWaterColor = SIMD3<Float>(0.10, 0.35, 0.60)
        for t in stride(from: 0, to: allIndices.count, by: 3) {
            let i0 = Int(allIndices[t])
            let i1 = Int(allIndices[t+1])
            let i2 = Int(allIndices[t+2])
            let v0 = topVertices[i0]
            let v1 = topVertices[i1]
            let v2 = topVertices[i2]
            let n = SCNVector3.cross(v1 - v0, v2 - v0).normalized()
            // Determine foam blend for this triangle (top surface triangles only)
            var triFoam: Float = 0.0
            if foamEnabled && i0 < topCount && i1 < topCount && i2 < topCount {
                let f0 = foamFactors[i0]
                let f1 = foamFactors[i1]
                let f2 = foamFactors[i2]
                triFoam = min(1.0, max(0.0, max(f0, max(f1, f2))))
            }
            let blended = baseWaterColor * (1 - triFoam) + foamColor * triFoam
            // Append 3 duplicated vertices w/ same normal & color (flat shading)
            flatVertices.append(v0); flatNormals.append(n); flatIndices.append(nextFlat); flatColors.append(contentsOf: [blended.x, blended.y, blended.z, 1.0]); nextFlat += 1
            flatVertices.append(v1); flatNormals.append(n); flatIndices.append(nextFlat); flatColors.append(contentsOf: [blended.x, blended.y, blended.z, 1.0]); nextFlat += 1
            flatVertices.append(v2); flatNormals.append(n); flatIndices.append(nextFlat); flatColors.append(contentsOf: [blended.x, blended.y, blended.z, 1.0]); nextFlat += 1
        }
        let vertexSource = SCNGeometrySource(vertices: flatVertices)
        let normalSource = SCNGeometrySource(normals: flatNormals)
        let colorData = Data(bytes: flatColors, count: flatColors.count * MemoryLayout<Float>.size)
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: flatVertices.count, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<Float>.size * 4)
        let indexData = Data(bytes: flatIndices, count: flatIndices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: flatIndices.count/3, bytesPerIndex: MemoryLayout<Int32>.size)
        let geometry = SCNGeometry(sources: [vertexSource, normalSource, colorSource], elements: [element])
        if geometry.firstMaterial == nil { geometry.firstMaterial = SCNMaterial() }
        let mat = geometry.firstMaterial!
        mat.diffuse.contents = UIColor.white // allow vertex colors to show fully
        mat.isDoubleSided = true
        mat.lightingModel = .physicallyBased
        mat.roughness.contents = 0.5
        mat.metalness.contents = 0.0
        // Depth gradient shader modifier (darkens with depth for better volume illusion)
        let depth = waterHeight
        let frag = """
        float depthFactor = clamp((-_surface.position.y)/\(depth), 0.0, 1.0);
        _output.color.rgb = mix(_output.color.rgb, vec3(0.02,0.07,0.12), depthFactor * 0.5);
        """
        mat.shaderModifiers = [.fragment: frag]
        return geometry
    }
    private func waveHeightAt(x: Float, z: Float, time: Float) -> Float {
        // Direction vectors
        let dirX1 = cos(primaryWaveDirectionRadians)
        let dirZ1 = sin(primaryWaveDirectionRadians)
        // Perpendicular (rotate 90° CCW)
        let perpX = -dirZ1
        let perpZ = dirX1
        // Project coordinates
        let proj1 = dirX1 * x + dirZ1 * z
        let perp = perpX * x + perpZ * z
        // Modulation signals (bounded)
        let ampModSignal = sin(primaryAmpModSpatialFreq * perp + primaryAmpModPhase)
        let freqModSignal = sin(primaryFreqModSpatialFreq * perp + primaryFreqModPhase)
        let ampMod = 1.0 + max(-0.95, min(0.95, primaryAmpModDepth)) * ampModSignal
        let freqMod = 1.0 + max(-0.95, min(0.95, primaryFreqModDepth)) * freqModSignal
        // Primary directional traveling wave with perpendicular modulation & wind gust factors
        let primaryPhase = (waveFrequency * freqMod) * proj1 + (primaryWaveSpeedFactor * currentGustSpeedFactor) * time + primaryWavePhaseOffset
        let primary = (waveAmplitude * ampMod * currentGustAmplitudeFactor) * sin(primaryPhase)
        // Optional second directional traveling wave for interference (only if amplitude > 0)
        var secondary: Float = 0.0
        if secondWaveAmplitude > 0.0001 {
            let dirX2 = cos(secondWaveDirectionRadians)
            let dirZ2 = sin(secondWaveDirectionRadians)
            let proj2 = dirX2 * x + dirZ2 * z
            secondary = secondWaveAmplitude * sin(secondWaveFrequency * proj2 + secondWaveSpeedFactor * time + secondWavePhaseOffset)
        }
        // Third wave
        var third: Float = 0.0
        if thirdWaveAmplitude > 0.0001 {
            let dirX3 = cos(thirdWaveDirectionRadians)
            let dirZ3 = sin(thirdWaveDirectionRadians)
            let proj3 = dirX3 * x + dirZ3 * z
            third = thirdWaveAmplitude * sin(thirdWaveFrequency * proj3 + thirdWaveSpeedFactor * time + thirdWavePhaseOffset)
        }
        return primary + secondary + third
    }
    // MARK: - Simulation Update
    func update(deltaTime: Float) {
        time += deltaTime * userSimulationSpeed
        // --- Adaptive Resolution Logic ---
        frameTimes.append(deltaTime)
        if frameTimes.count > frameTimeSampleCount {
            frameTimes.removeFirst()
        }
        lastResolutionCheckTime += deltaTime
        if lastResolutionCheckTime >= resolutionCheckInterval {
            let avgFrameTime = frameTimes.reduce(0, +) / Float(frameTimes.count)
            if avgFrameTime > targetFrameTime * 1.25, waveResolution > minWaveResolution {
                // Too slow, decrease resolution
                setWaveResolution(waveResolution - 2)
            }
            //just decrease do not increase as just  makes things look odd
            //else if avgFrameTime < targetFrameTime * 0.7, waveResolution < maxWaveResolution {
                // Fast, increase resolution
            //    setWaveResolution(waveResolution + 1)
           // }
            lastResolutionCheckTime = 0.0
        }
        if let waveNode = waveNode {
            waveNode.geometry = waveMeshGrid(size: waveResolution, amplitude: waveAmplitude, frequency: waveFrequency, time: time)
        }
        
        // Animate stars with twinkling and slow rotation
        if isNight && !starNodes.isEmpty {
            animateStars()
        }
        
        // Animate debris floating and moving
        for i in 0..<debris.count {
            var d = debris[i]
            d.position.x += d.velocity.x
            d.position.z += d.velocity.z
            // Constrain debris to cylinder
            let r = sqrt(d.position.x*d.position.x + d.position.z*d.position.z)
            if r > waterRadius-0.15 {
                let angle = atan2(d.position.z, d.position.x)
                d.position.x = cos(angle) * (waterRadius-0.15)
                d.position.z = sin(angle) * (waterRadius-0.15)
                d.velocity.x *= -0.7
                d.velocity.z *= -0.7
            }
            // Update y based on wave, half-submerged
            let waveY = waveHeightAt(x: d.position.x, z: d.position.z, time: time)
            let submergeOffset: Float = -0.16 // half bottle height
            d.position.y = waveY + submergeOffset
            // Apply to node
            d.node?.position = SCNVector3(d.position.x, d.position.y, d.position.z)
            debris[i] = d
        }
        // Update buoy after wave updated so it samples latest surface
        if var buoy = lighthouseBuoy {
            // Horizontal spring toward anchor (ignore Y)
            var horiz = SIMD2<Float>(buoy.position.x - buoy.anchor.x, buoy.position.z - buoy.anchor.z)
            let dist = length(horiz)
            if dist > 0 { horiz /= dist }
            let stiffness = buoy.params.tetherStiffness
            let damping = buoy.params.tetherDamping
            // Velocity integration (explicit Euler)
            let toAnchor = SIMD2<Float>(buoy.anchor.x - buoy.position.x, buoy.anchor.z - buoy.position.z)
            let vel2 = SIMD2<Float>(buoy.velocity.x, buoy.velocity.z)
            let accel = toAnchor * stiffness - vel2 * damping
            let newVel2 = vel2 + accel * deltaTime
            let newPos2 = SIMD2<Float>(buoy.position.x, buoy.position.z) + newVel2 * deltaTime
            buoy.velocity.x = newVel2.x
            buoy.velocity.z = newVel2.y
            buoy.position.x = newPos2.x
            buoy.position.z = newPos2.y
            // Constrain within water disc
            let r = hypot(buoy.position.x, buoy.position.z)
            if r > waterRadius * 0.95 {
                let scale = (waterRadius * 0.95) / r
                buoy.position.x *= scale
                buoy.position.z *= scale
                buoy.velocity.x *= -0.3
                buoy.velocity.z *= -0.3
            }
            // Vertical follow of wave
            let wY = waveHeightAt(x: buoy.position.x, z: buoy.position.z, time: time)
            buoy.position.y = wY + buoy.params.floatOffset
            // Rocking: align local up with wave normal (scaled)
            let n = waveNormalAt(x: buoy.position.x, z: buoy.position.z, time: time)
            let up = SIMD3<Float>(0,1,0)
            let dotUN = max(-1, min(1, dot(up, n)))
            if dotUN < 0.999 { // avoid numerical issues for tiny angles
                let axis = normalize(cross(up, n))
                let angle = acos(dotUN) * buoy.params.rockingStrength
                let targetQ = simd_quatf(angle: angle, axis: axis)
                // Slerp smoothing
                let s = max(0, min(1, buoy.params.orientationSmoothing))
                let blended = simd_slerp(buoy.lastOrientation, targetQ, 1 - exp(-6 * s * deltaTime))
                buoy.lastOrientation = blended
                buoy.node.simdOrientation = blended
            }
            // Apply to node
            buoy.node.position = SCNVector3(buoy.position)
            // Animate spotlight rotation (lighthouse beam)
            if let spotlightNode = buoy.spotlightNode {
                // Rotate around Y axis at a fixed speed
                let rotationSpeed: Float = .pi / 4 // radians per second (45 deg/sec)
                let yaw = time * rotationSpeed
                spotlightNode.eulerAngles.y = yaw
                // --- Update cone length to avoid protruding below water ---
                if let beamNode = spotlightNode.childNodes.first,
                   let cone = beamNode.geometry as? SCNCone {
                    // Get spotlight world position and direction
                    let worldPos = spotlightNode.convertPosition(SCNVector3Zero, to: nil)
                    let dir = spotlightNode.simdWorldFront // SceneKit: -Z is forward
                    let direction = SCNVector3(dir.x, dir.y, dir.z)
                    let newLength = maxConeLength(spotlightPos: worldPos, direction: direction)
                    if abs(cone.height - newLength) > 0.01 {
                        cone.height = newLength
                        beamNode.position = SCNVector3(0, 0, -Float(newLength)/2)
                    }
                }
            }
            lighthouseBuoy = buoy
        }
    }
    /// Calculate max cone length so tip stays above water and within water boundary
    private func maxConeLength(spotlightPos: SCNVector3, direction: SCNVector3) -> CGFloat {
        // Water is at y=0, boundary is circle of radius waterRadius in XZ
        let h = spotlightPos.y
        let dirY = direction.y
        let bx = spotlightPos.x
        let bz = spotlightPos.z
        let dx = direction.x
        let dz = direction.z
        let r = CGFloat(waterRadius)
        
        var maxLBelowWater: CGFloat = 7.0
        // Limit so tip does not go below water
        if dirY < 0.0 {
            let l = -CGFloat(h) / CGFloat(dirY)
            maxLBelowWater = max(0.1, min(7.0, l))
        }
        
        // Limit so tip does not go outside water boundary in XZ
        // (bx + dx*L)^2 + (bz + dz*L)^2 = r^2
        let A = CGFloat(dx*dx + dz*dz)
        let B = CGFloat(2 * (bx*dx + bz*dz))
        let C = CGFloat(bx*bx + bz*bz) - r*r
        
        var maxLBoundary: CGFloat = 7.0
        if abs(A) > 1e-6 {
            let B2 = B * B
            let fourAC = 4 * A * C
            let discriminant = B2 - fourAC
            
            if discriminant >= 0 {
                let sqrtD = sqrt(discriminant)
                let denom = 2 * A
                let l1 = (-B + sqrtD) / denom
                let l2 = (-B - sqrtD) / denom
                
                // We want the smallest positive L (forward intersection)
                let candidates = [l1, l2].filter { $0 > 0 }
                if let minL = candidates.min() {
                    maxLBoundary = min(7.0, minL)
                }
            }
        }
        
        // Return the minimum of both constraints
        let finalConstraints = [maxLBelowWater, maxLBoundary, 7.0]
        return max(0.1, finalConstraints.min() ?? 7.0)
    }
    // MARK: - User Controls
    func setSimulationSpeed(_ speed: Float) { userSimulationSpeed = speed }
    func setWaveAmplitude(_ amp: Float) {
        waveAmplitude = amp
        secondWaveAmplitude = amp * secondWaveAmplitudeMultiplier
        thirdWaveAmplitude = amp * thirdWaveAmplitudeMultiplier
    }
    func setWaveFrequency(_ freq: Float) { waveFrequency = freq }
    func setLeafBuoyancy(_ buoy: Float) { }
    func setGlobalScale(_ scale: Float) {
        globalScale = scale
        print("[DEBUG] setGlobalScale called with scale: \(scale)")
        simulationRootNode.scale = SCNVector3(globalScale, globalScale, globalScale)
    }
    func setWaveResolution(_ res: Int) {
        let clamped = max(4, min(20, res))
        guard clamped != waveResolution else { return }
        waveResolution = clamped
        // Rebuild immediately for responsiveness
        if let node = waveNode {
            node.geometry = waveMeshGrid(size: waveResolution, amplitude: waveAmplitude, frequency: waveFrequency, time: time)
        }
        // Rebuild buoy geometry with new segment count
        if lighthouseBuoy != nil {
            if let currentParams = lighthouseBuoy?.params, let anchorXZ = lighthouseBuoy.map({ SIMD2<Float>($0.anchor.x, $0.anchor.z) }) {
                addLighthouseBuoy(anchorXZ: anchorXZ, params: currentParams)
            }
        }
    }
    // Second wave setters
    func setSecondWaveAmplitude(_ amp: Float) { secondWaveAmplitude = max(0, amp) }
    func setSecondWaveFrequency(_ freq: Float) { secondWaveFrequency = max(0.01, freq) }
    func setSecondWaveDirectionDegrees(_ deg: Float) { secondWaveDirectionRadians = deg * .pi / 180.0 }
    func setSecondWavePhaseOffset(_ phase: Float) { secondWavePhaseOffset = phase }
    func setSecondWaveSpeedFactor(_ factor: Float) { secondWaveSpeedFactor = factor }
    // Third wave setters
    func setThirdWaveAmplitude(_ amp: Float) { thirdWaveAmplitude = max(0, amp) }
    func setThirdWaveFrequency(_ freq: Float) { thirdWaveFrequency = max(0.01, freq) }
    func setThirdWaveDirectionDegrees(_ deg: Float) { thirdWaveDirectionRadians = deg * .pi / 180.0 }
    func setThirdWavePhaseOffset(_ phase: Float) { thirdWavePhaseOffset = phase }
    func setThirdWaveSpeedFactor(_ factor: Float) { thirdWaveSpeedFactor = factor }
    // Primary wave setters (exposed for future UI if desired)
    func setPrimaryWaveDirectionDegrees(_ deg: Float) { primaryWaveDirectionRadians = deg * .pi / 180.0 }
    func setPrimaryWavePhaseOffset(_ phase: Float) { primaryWavePhaseOffset = phase }
    func setPrimaryWaveSpeedFactor(_ factor: Float) { primaryWaveSpeedFactor = factor }
    func setPrimaryAmpMod(depth: Float? = nil, spatialFreq: Float? = nil, phase: Float? = nil) {
        if let d = depth { primaryAmpModDepth = max(0, min(1, d)) }
        if let s = spatialFreq { primaryAmpModSpatialFreq = max(0, s) }
        if let p = phase { primaryAmpModPhase = p }
    }
    func setPrimaryFreqMod(depth: Float? = nil, spatialFreq: Float? = nil, phase: Float? = nil) {
        if let d = depth { primaryFreqModDepth = max(0, min(1, d)) }
        if let s = spatialFreq { primaryFreqModSpatialFreq = max(0, s) }
        if let p = phase { primaryFreqModPhase = p }
    }
    func setWindGust(enabled: Bool? = nil, frequency: Float? = nil, secondaryFrequency: Float? = nil, secondaryMix: Float? = nil, amplitude: Float? = nil, speedFactor: Float? = nil, phase: Float? = nil) {
        if let v = enabled { windGustEnabled = v }
        if let v = frequency { windGustFrequency = max(0, v) }
        if let v = secondaryFrequency { windSecondaryFrequency = max(0, v) }
        if let v = secondaryMix { windSecondaryMix = max(0, min(1, v)) }
        if let v = amplitude { windGustAmplitude = max(0, v) }
        if let v = speedFactor { windSpeedModFactor = max(0, v) }
        if let v = phase { windPhase = v }
    }
    func setFoam(enabled: Bool? = nil, slopeThreshold: Float? = nil, slopeRange: Float? = nil, heightThreshold: Float? = nil, intensity: Float? = nil) {
        if let v = enabled { foamEnabled = v }
        if let v = slopeThreshold { foamSlopeThreshold = max(0, v) }
        if let v = slopeRange { foamSlopeRange = max(0.001, v) }
        if let v = heightThreshold { foamHeightThreshold = max(0, v) }
        if let v = intensity { foamIntensity = max(0, min(1, v)) }
    }
    private func updateWindGustFactors() {
        guard windGustEnabled && (windGustAmplitude > 0 || windSpeedModFactor > 0) else {
            currentGustAmplitudeFactor = 1.0
            currentGustSpeedFactor = 1.0
            return
        }
        let g1 = sin(windGustFrequency * time + windPhase)
        let g2 = sin(windSecondaryFrequency * time + windPhase * 0.7)
        let raw = 0.5 * g1 + windSecondaryMix * g2
        let positive = max(0, raw) // only gust on positive cycles
        currentGustAmplitudeFactor = 1 + positive * windGustAmplitude
        currentGustSpeedFactor = 1 + positive * windSpeedModFactor
    }
    func reset() {
        time = 0.0
        waveAmplitude = 0.33
        waveFrequency = 1.2
        globalScale = 1.0
        secondWaveAmplitude = 0.0
        secondWaveFrequency = 1.0
        secondWaveDirectionRadians = 0.0
        secondWavePhaseOffset = 0.0
        secondWaveSpeedFactor = 1.0
        thirdWaveAmplitude = 0.6
        thirdWaveFrequency = 1.0
        thirdWaveDirectionRadians = 0.4
        thirdWavePhaseOffset = 0.0
        thirdWaveSpeedFactor = 1.0
        primaryWaveDirectionRadians = 0.0
        primaryWavePhaseOffset = 0.0
        primaryWaveSpeedFactor = 1.0
        primaryAmpModDepth = 0.15
        primaryAmpModSpatialFreq = 0.3
        primaryAmpModPhase = 0.0
        primaryFreqModDepth = 0.10
        primaryFreqModSpatialFreq = 0.3
        primaryFreqModPhase = Float.pi * 0.5
        windGustEnabled = false
        windGustFrequency = 0.15
        windSecondaryFrequency = 0.41
        windSecondaryMix = 0.35
        windGustAmplitude = 0.4
        windSpeedModFactor = 0.6
        windPhase = 0.0
        currentGustAmplitudeFactor = 1.0
        currentGustSpeedFactor = 1.0
        foamEnabled = false
        foamSlopeThreshold = 0.45
        foamSlopeRange = 0.35
        foamHeightThreshold = 0.15
        foamIntensity = 1.0
        // Removed leaf node reset
        thirdWaveAmplitudeMultiplier = Float.random(in: 0.3...0.9)
        thirdWaveFrequency = Float.random(in: 0.7...2.0)
        thirdWaveDirectionRadians = Float.random(in: 0..<(2 * .pi))
        thirdWavePhaseOffset = Float.random(in: 0..<(2 * .pi))
        thirdWaveSpeedFactor = Float.random(in: 0.7...1.3)
        thirdWaveAmplitude = waveAmplitude * thirdWaveAmplitudeMultiplier
        
        // Randomly reposition the lighthouse buoy
        if lighthouseBuoy != nil {
            // Generate new random anchor position
            let angle = Float.random(in: 0..<(2*Float.pi))
            let r = Float.random(in: 0.3...(waterRadius * 0.55))
            let newAnchorXZ = SIMD2<Float>(cos(angle) * r, sin(angle) * r)
            
            // Re-add the buoy at the new position with current parameters
            if let currentParams = lighthouseBuoy?.params {
                addLighthouseBuoy(anchorXZ: newAnchorXZ, params: currentParams)
            }
        }
    }
    
    func projectedJointXY127(jointName: String) -> (x: Int, y: Int)?{
        guard let scnView = scnView, let worldPos = jointWorldPosition(jointName) else { return nil }
        let proj = scnView.projectPoint(worldPos)
        let w = max(scnView.bounds.width, 1)
        let h = max(scnView.bounds.height, 1)
        let xView = CGFloat(proj.x)
        let yView = h - CGFloat(proj.y) // flip to top-left origin
        let x127 = Int(round(min(max(xView, 0), w) / w * 127))
        let y127 = Int(round(min(max(yView, 0), h) / h * 127))
        return (x127, y127)
    }
    func translate(dx: Float, dy: Float, dz: Float) {
        simulationRootNode.position.x += dx
        simulationRootNode.position.y += dy
        simulationRootNode.position.z += dz
    }
    
    func jointWorldPosition(_ name: String) -> SCNVector3? {
        if let node = jointNodes[name] { return node.worldPosition }
        if let pos = jointPositions[name] {
            // Convert local pos to world by applying rootNode transform
            let world = pos.applyingMatrix(rootNode.worldTransform)
            return world
        }
        return nil
    }
    
    /// Public API: add (or replace) lighthouse buoy
    func addLighthouseBuoy(anchorXZ: SIMD2<Float>? = nil, params: LighthouseBuoyParameters = .default) {
        if let buoy = lighthouseBuoy { buoy.node.removeFromParentNode() }
        guard let scene = sceneReference else { return }
        let chosenAnchorXZ: SIMD2<Float> = anchorXZ ?? {
            let angle = Float.random(in: 0..<(2*Float.pi))
            let r = Float.random(in: 0.3...(waterRadius * 0.55))
            return SIMD2<Float>(cos(angle) * r, sin(angle) * r)
        }()
        let anchorY = -waterHeight // seabed
        let anchor = SIMD3<Float>(chosenAnchorXZ.x, anchorY, chosenAnchorXZ.y)
        let waveY = waveHeightAt(x: chosenAnchorXZ.x, z: chosenAnchorXZ.y, time: time)
        let pos = SIMD3<Float>(chosenAnchorXZ.x, waveY + params.floatOffset, chosenAnchorXZ.y)
        let root = SCNNode()
        root.name = "LighthouseBuoy"
        root.position = SCNVector3(pos)
        // === Spherical base (half submerged) ===
        let sphereRadius: Float = params.sphereRadius // now independent
        let (r1,g1,b1) = params.colorPrimary.rgb()
        let (r2,g2,b2) = params.colorSecondary.rgb() // secondary still used for band
        let buoySegCount = buoySegmentCount(forWaveResolution: waveResolution)
        let sphere = SCNSphere(radius: CGFloat(sphereRadius))
        sphere.segmentCount = buoySegCount
        let sphereMat = SCNMaterial()
        sphereMat.lightingModel = .physicallyBased
        sphereMat.diffuse.contents = UIColor(red: CGFloat(r1), green: CGFloat(g1), blue: CGFloat(b1), alpha: 1)
        sphereMat.metalness.contents = 0.0
        sphereMat.roughness.contents = 0.4
        sphere.firstMaterial = sphereMat
        let sphereNode = SCNNode(geometry: sphere)
        sphereNode.position = SCNVector3(0, -0.5, 0) // center at waterline so half below
        root.addChildNode(sphereNode)
        // Add a physical white stripe band as a very thin cylinder hugging equator
        let bandHeight: CGFloat = CGFloat(sphereRadius * 0.25) // thickness of stripe proportional to sphereRadius
        let band = SCNCylinder(radius: CGFloat(sphereRadius * 1.001), height: bandHeight)
        band.radialSegmentCount = buoySegCount
        let bandMat = SCNMaterial()
        bandMat.lightingModel = .physicallyBased
        bandMat.diffuse.contents = UIColor(red: CGFloat(r2), green: CGFloat(g2), blue: CGFloat(b2), alpha: 1)
        bandMat.metalness.contents = 0.0
        bandMat.roughness.contents = 0.35
        band.firstMaterial = bandMat
        let bandNode = SCNNode(geometry: band)
        bandNode.position = SCNVector3(0,-0.5, 0) // centered at sphere center
        let outwardScale: Float = 1.002
        bandNode.scale = SCNVector3(outwardScale, 1.0, outwardScale)
        root.addChildNode(bandNode)
        // Build striped cylindrical tower above sphere top
        let stripeH = params.height / Float(max(1, params.stripeCount))
        let towerYOffset: Float = -0.3 // tower sits on top of base cylinder, not sphere
        for i in 0..<params.stripeCount {
            let cyl = SCNCylinder(radius: CGFloat(params.baseRadius), height: CGFloat(stripeH))
            cyl.radialSegmentCount = max(8, buoySegCount / 2)
            let mat = SCNMaterial()
            mat.diffuse.contents = (i % 2 == 0) ? params.colorPrimary : params.colorSecondary
            mat.lightingModel = .physicallyBased
            cyl.firstMaterial = mat
            let segmentNode = SCNNode(geometry: cyl)
            segmentNode.position = SCNVector3(0, towerYOffset + (Float(i) + 0.5) * stripeH, 0)
            root.addChildNode(segmentNode)
        }
        // Top beacon
        let topSphere = SCNSphere(radius: CGFloat(params.baseRadius * 0.35))
        let topMat = SCNMaterial()
        topMat.emission.contents = UIColor.yellow.withAlphaComponent(0.9)
        topMat.diffuse.contents = UIColor.yellow
        topSphere.firstMaterial = topMat
        let topNode = SCNNode(geometry: topSphere)
        topNode.position = SCNVector3(0, towerYOffset + params.height + stripeH * 0.15, 0)
            
        root.addChildNode(topNode)
        // Rotating spotlight (lighthouse beam)
        let spotlightNode = SCNNode()
        spotlightNode.position = topNode.position
        let spotlight = SCNLight()
        spotlight.type = .spot
        spotlight.color = UIColor(red: 1.0, green: 1.0, blue: 0.7, alpha: 1.0) // bright yellow-white
        spotlight.intensity = 100 // much brighter
        spotlight.spotInnerAngle = 30 // wider
        spotlight.spotOuterAngle = 60 // much wider
        spotlight.castsShadow = false // disable shadows for visibility
        spotlight.attenuationStartDistance = 0.1
        spotlight.attenuationEndDistance = 20.0
        spotlightNode.light = spotlight
        // Point the spotlight horizontally (default orientation is fine)
        root.addChildNode(spotlightNode)
        // Add a visible beam cone geometry (correct geometry: large end at spotlight, offset by length)
        let beamLength: CGFloat = 10.05
        let beamCone = SCNCone(topRadius: 1.0, bottomRadius: 0.01, height: 7)
        let beamMat = SCNMaterial()
        beamMat.diffuse.contents = UIColor(red: 1.0, green: 1.0, blue: 0.7, alpha: 0.02) // more visible
        beamMat.isDoubleSided = true
        beamMat.lightingModel = .constant
        beamCone.firstMaterial = beamMat
        let beamNode = SCNNode(geometry: beamCone)
        beamNode.position = SCNVector3(0, 0, -Float(beamLength)/2) // offset by -length/2 so base is at spotlight
        beamNode.eulerAngles.x = -.pi / 2 // rotate cone to point along Z
        spotlightNode.addChildNode(beamNode)
        simulationRootNode.addChildNode(root)
        lighthouseBuoy = LighthouseBuoy(
            anchor: anchor,
            position: pos,
            velocity: SIMD3<Float>(repeating: 0),
            params: params,
            node: root,
            lastOrientation: simd_quatf(angle: 0, axis: SIMD3<Float>(0,1,0)),
            spotlightNode: spotlightNode
        )
    }
    /// Remove buoy
    func removeLighthouseBuoy() {
        if let buoy = lighthouseBuoy { buoy.node.removeFromParentNode() }
        lighthouseBuoy = nil
    }
    /// Update buoy parameters in-place
    func updateLighthouseBuoyParameters(_ mutate: (inout LighthouseBuoyParameters) -> Void) {
        guard var buoy = lighthouseBuoy else { return }
        mutate(&buoy.params)
        lighthouseBuoy = buoy // geometry not rebuilt unless structural values changed
    }
    private func waveNormalAt(x: Float, z: Float, time: Float) -> SIMD3<Float> {
        let d: Float = 0.10
        let hC = waveHeightAt(x: x, z: z, time: time)
        let hX = waveHeightAt(x: x + d, z: z, time: time)
        let hZ = waveHeightAt(x: x, z: z + d, time: time)
        // Partial derivatives
        let dHdX = (hX - hC) / d
        let dHdZ = (hZ - hC) / d
        let n = normalize(SIMD3<Float>(-dHdX, 1.0, -dHdZ))
        return n
    }

    // MARK: - Sky and Stars Setup
    private func setupSkyAndStars(in scene: SCNScene) {
        let skySphere = SCNSphere(radius: 30)
        skySphere.segmentCount = 48
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor(red: 0.53, green: 0.81, blue: 0.98, alpha: 1.0)
        mat.isDoubleSided = false
        mat.lightingModel = .constant
        mat.writesToDepthBuffer = false // do not occlude foreground
        mat.readsFromDepthBuffer = false
        skySphere.materials = [mat]
        skyNode = SCNNode(geometry: skySphere)
        skyNode.position = SCNVector3(0, 0, 0)
        skyNode.renderingOrder = -1000 // ensure it renders far behind
        simulationRootNode.addChildNode(skyNode)
        // Add stars
        starNodes = []
        let starRadius: CGFloat = 0.08
        for _ in 0..<numStars {
            let theta = Float.random(in: 0..<(2 * .pi))
            let phi = acos(Float.random(in: -1.0...1.0))
            let r: Float = 29.5
            let x = r * sin(phi) * cos(theta)
            let y = r * cos(phi)
            let z = r * sin(phi) * sin(theta)
            let star = SCNNode(geometry: SCNSphere(radius: starRadius))
            let starMat = SCNMaterial()
            starMat.diffuse.contents = UIColor.white
            starMat.emission.contents = UIColor.white
            starMat.lightingModel = .constant
            starMat.writesToDepthBuffer = false
            starMat.readsFromDepthBuffer = false
            star.geometry?.materials = [starMat]
            star.position = SCNVector3(x, y, z)
            star.renderingOrder = 1
            skyNode.addChildNode(star)
            starNodes.append(star)
        }
        updateSkyForDayNight()
    }

    /// Blend sky color and star opacity for day/night
    private func updateSkyForDayNight() {
        let skyBlue = UIColor(red: 0.53, green: 0.81, blue: 0.98, alpha: 1.0)
        let skyBlack = UIColor.black
        let blend: CGFloat = isNight ? 0.0 : 1.0 // 0 = night, 1 = day
        let lerpedSky = blendColors(color1: skyBlack, color2: skyBlue, t: blend)
        if let m = skyNode.geometry?.materials.first { m.diffuse.contents = lerpedSky }
        for star in starNodes { star.opacity = CGFloat(1.0 - blend) }
    }

    /// Set day or night
    func setNight(_ night: Bool) {
        isNight = night
        updateSkyForDayNight()
    }

    /// Utility: blend two UIColors
    private func blendColors(color1: UIColor, color2: UIColor, t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        color1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        color2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let r = r1 * (1-t) + r2 * t
        let g = g1 * (1-t) + g2 * t
        let b = b1 * (1-t) + b2 * t
        let a = a1 * (1-t) + a2 * t
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
    
    private func animateStars() {
        for (index, star) in starNodes.enumerated() {
            // Twinkling effect: vary brightness over time with different speeds per star
            let twinkleSpeed = 2.0 + Float(index % 10) * 0.3 // Vary speed based on star index
            let twinklePhase = Float(index) * 0.5 // Phase offset for each star
            let twinkle = 0.4 + 0.6 * sin(time * twinkleSpeed + twinklePhase)
            
            // Update star brightness
            if let starMat = star.geometry?.materials.first {
                starMat.emission.contents = UIColor.white.withAlphaComponent(CGFloat(twinkle))
            }
            
            // Very slow rotation effect around the sky center
            let rotationSpeed = Float(index % 100) * 0.001 // Very slow, different per star
            star.eulerAngles.y = time * rotationSpeed
        }
    }
    
    // --- Buoy and Light Tracking ---
    /// Buoy base world position (center of sphere)
    func buoyBaseWorldPosition() -> SCNVector3? {
        guard let buoy = lighthouseBuoy else { return nil }
        // Sphere node is first child
        if let sphereNode = buoy.node.childNodes.first {
            return sphereNode.convertPosition(SCNVector3Zero, to: nil)
        }
        return buoy.node.convertPosition(SCNVector3Zero, to: nil)
    }
    /// Buoy light world position (spotlight node)
    func buoyLightWorldPosition() -> SCNVector3? {
        guard let buoy = lighthouseBuoy, let spot = buoy.spotlightNode else { return nil }
        return spot.convertPosition(SCNVector3Zero, to: nil)
    }
    // WaveAndLeavesSimulation.swift
    func buoyBaseScreenXY127() -> (x: Int, y: Int)? {
        guard Thread.isMainThread else { return nil }
        guard let scnView = scnView, scnView.scene != nil,
              let worldPos = buoyBaseWorldPosition() else { return nil }
        let proj = scnView.projectPoint(worldPos)
        let w = max(scnView.bounds.width, 1)
        let h = max(scnView.bounds.height, 1)
        let xView = CGFloat(proj.x)
        let yView = h - CGFloat(proj.y)
        let x127 = Int(round(min(max(xView, 0), w) / w * 127))
        let y127 = Int(round(min(max(yView, 0), h) / h * 127))
        return (x127, y127)
    }

    func buoyLightScreenXY127() -> (x: Int, y: Int)? {
        guard Thread.isMainThread else { return nil }
        guard let scnView = scnView, scnView.scene != nil,
              let worldPos = buoyLightWorldPosition() else { return nil }
        let proj = scnView.projectPoint(worldPos)
        let w = max(scnView.bounds.width, 1)
        let h = max(scnView.bounds.height, 1)
        let xView = CGFloat(proj.x)
        let yView = h - CGFloat(proj.y)
        let x127 = Int(round(min(max(xView, 0), w) / w * 127))
        let y127 = Int(round(min(max(yView, 0), h) / h * 127))
        return (x127, y127)
    }

    // Do the same guard in projectedJointXY127 if needed.
    /// Buoy angle (rocking/orientation, degrees)
    func buoyAngle() -> Float? {
        guard let buoy = lighthouseBuoy else { return nil }
        // Angle between up and buoy's orientation up
        let up = SIMD3<Float>(0,1,0)
        let buoyUp = buoy.lastOrientation.act(up)
        let dotVal = max(-1, min(1, dot(up, buoyUp)))
        let angleRad = acos(dotVal)
        return angleRad * (180.0 / .pi)
    }
    /// Light rotation (yaw, degrees)
    func lightRotation() -> Float? {
        guard let buoy = lighthouseBuoy, let spot = buoy.spotlightNode else { return nil }
        // Yaw is eulerAngles.y in radians
        return spot.eulerAngles.y * (180.0 / .pi)
    }
    
    /// Compute buoy segment count based on wave resolution
    private func buoySegmentCount(forWaveResolution res: Int) -> Int {
        // Map waveResolution (4..20) to segmentCount (16..64)
        let minSeg = 16, maxSeg = 64
        let seg = minSeg + (maxSeg - minSeg) * (res - minWaveResolution) / max(1, maxWaveResolution - minWaveResolution)
        return max(minSeg, min(maxSeg, seg))
    }
}
