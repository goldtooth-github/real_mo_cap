import SceneKit
import UIKit

// MARK: - BoidsSimulation (synchronous core)
final class BoidsSimulation: LifeformSimulation {
    struct Boid {
        var position: SCNVector3
        var velocity: SCNVector3
        var node: SCNNode
        var color: UIColor
        var wanderTime: Float
        var wanderDir: SCNVector3
        var swimPhase: Float
        var spine: [SCNNode]
        var tailNode: SCNNode?
    }
    
    // MARK: - Core Craig Reynolds Parameters (minimal)
      // Ratios are fractions of field size (edge length). They are converted to absolute distances each frame.
      public var visualRangeRatio: Float = 0.18 { didSet { visualRangeRatio = max(0.01, min(0.9, visualRangeRatio)) } }      // Neighborhood radius / fieldSize
      public var protectedRangeRatio: Float = 0.05 { didSet { protectedRangeRatio = max(0.005, min(visualRangeRatio * 0.9, protectedRangeRatio)) } } // Collision radius / fieldSize
      // Behavior factors (classic algorithm style)
      public var separationFactor: Float = 0.05 { didSet { separationFactor = max(0, separationFactor) } }  // aka avoidFactor
      public var alignmentFactor: Float = 0.05 { didSet { alignmentFactor = max(0, alignmentFactor) } }    // aka matchingFactor // was 0.05
      public var cohesionFactor: Float = 0.005 { didSet { cohesionFactor = max(0, cohesionFactor) } }      // aka centeringFactor // was 0.005
      // Speed limits
      public var maxSpeed: Float = 0.35 { didSet { maxSpeed = max(0.01, maxSpeed); if minSpeed > maxSpeed { minSpeed = maxSpeed * 0.5 } } }
      public var minSpeed: Float = 0.12 { didSet { minSpeed = max(0, minSpeed); if minSpeed > maxSpeed { minSpeed = maxSpeed * 0.5 } } }
      // Boundary turning (only when wrapping disabled)
    public var turnMargin: Float = 0.9 { didSet { turnMargin = max(0.01, min(fieldHalfSize * 0.9, turnMargin)) } }
      public var turnFactor: Float = 0.06 { didSet { turnFactor = max(0, turnFactor) } }
      // Smooth edge steering options
      public var smoothEdgeTurning: Bool = true // if true use graded inward steering
    private var omglights: SCNNode?
      public var edgeSoftMultiplier: Float = 2.0 { didSet { edgeSoftMultiplier = max(1.0, min(4.0, edgeSoftMultiplier)) } } // soft zone = turnMargin * this
      public var edgePredictionTime: Float = 0.35 { didSet { edgePredictionTime = max(0, min(2, edgePredictionTime)) } } // lookahead (scaled by current speed)
      // Optional bounds visualization (disabled)
      public var showBoundsWireframe: Bool = false // deprecated: wireframe cube disabled
      
      // MARK: - Wander Parameters
      public var wanderEnabled: Bool = true
      public var wanderChancePerSecond: Float = 0.12 { didSet { wanderChancePerSecond = max(0, wanderChancePerSecond) } }
      public var wanderDurationRange: (Float,Float) = (0.2, 1.5) // seconds
      // During wandering, alignment & cohesion are scaled by these multipliers (<1 loosens formation)
      public var wanderAlignmentScale: Float = 0.25 { didSet { wanderAlignmentScale = max(0, min(1, wanderAlignmentScale)) } }
      public var wanderCohesionScale: Float = 0.15 { didSet { wanderCohesionScale = max(0, min(1, wanderCohesionScale)) } }
      // Random jitter impulse strength applied each frame while wandering (acts like extra acceleration)
      public var wanderJitterStrength: Float = 0.02 { didSet { wanderJitterStrength = max(0, wanderJitterStrength) } }
      public var maxSimultaneousWanderers: Int = 6 { didSet { maxSimultaneousWanderers = max(0, maxSimultaneousWanderers) } }
    
    // --- Spatial grid for neighbor search ---
    private struct GridCell: Hashable {
        let x: Int
        let y: Int
        let z: Int
    }
    
  //  let visualRange = visualRangeRatio * baseFieldSize
   // let protectedRange = protectedRangeRatio * baseFieldSize
   // let vr2 = visualRange * visualRange
    //let pr2 = protectedRange * protectedRange
    //let half = fieldHalfSize
    //var newBoids: [Boid] = []
    
    
      // MARK: - Internal State
   //   private let baseFieldSize: Float = 8.0
  //    private var boundsNode: SCNNode? = nil
   //   private var wrappingEnabled: Bool = false
    //  private var userOffset: SCNVector3 = SCNVector3Zero
   //   private var globalScale: Float = 1.0
  //    private var boids: [Boid] = []
   //   private var rootNode: SCNNode = SCNNode()
   //   weak var scnView: SCNView?
   //   private var sceneReference: SCNScene?
   //   private let numBoids = 50
      private let boidSize: Float = 0.05
  //    private var speedMultiplier: Float = 1.0
   //   private var boundsCircleNode: SCNNode? = nil
      //public var showBoundsCircle: Bool = false { didSet { if showBoundsCircle { ensureBoundsCircleNode() } else { boundsCircleNode?.removeFromParentNode(); boundsCircleNode = nil } } }
     // private var boundsFlashWork: DispatchWorkItem? = nil
      
      // Derived
  //    var fieldHalfSize: Float { baseFieldSize / 2 }
   //   var visualBounds: Float { baseFieldSize } // simple now
    
    
    
    
    weak var scnView: SCNView?
    var sceneReference: SCNScene?
    private let rootNode = SCNNode()
    private(set) var boids: [Boid] = []
    private let numBoids = 20
    private var fishSize: Float = 0.5
    private var speedMultiplier: Float = 1.0
    private var globalScale: Float = 1.0
    private var userOffset: SCNVector3 = SCNVector3Zero
    private var wrappingEnabled: Bool = false
    
    private var boundsNode: SCNNode? = nil
    private var boundsCircleNode: SCNNode? = nil
    private var backgroundSphereNode: SCNNode? = nil
    private let baseFieldSize: Float = 20.0
    var visualBounds: Float { baseFieldSize }
    var fieldHalfSize: Float { baseFieldSize / 2 }
    var rootWorldPosition: SCNVector3 { rootNode.worldPosition }
  
    
    // MARK: - Init
    init(scene: SCNScene, scnView: SCNView?) {
        self.sceneReference = scene
        self.scnView = scnView
        scene.rootNode.addChildNode(rootNode)
        setupLighting(in: scene)
        setupBackgroundSphere(in: scene)
        setupBoids(in: scene)
    }
    
    // MARK: - Simulation Logic
    // --- Begin restored boids update logic ---
    // MARK: - Simulation Update
    
    
    
    
    func update(deltaTime: Float) {
        // Precompute absolute ranges
        let visualRangeRatio: Float = 0.18
        let protectedRangeRatio: Float = 0.12
        let separationFactor: Float = 0.004
        let alignmentFactor: Float = 0.028 //18
        let cohesionFactor: Float = 0.0035 //15
        let maxSpeed: Float = 0.35
        let minSpeed: Float = 0.12
        let turnMargin: Float = 0.9
        let turnFactor: Float = 0.06
        let smoothEdgeTurning: Bool = true
        let edgeSoftMultiplier: Float = 2.0
        let edgePredictionTime: Float = 0.35
        let wanderEnabled: Bool = true
        let wanderChancePerSecond: Float = 0.12
        let wanderDurationRange: (Float,Float) = (0.2, 1.5)
        let wanderAlignmentScale: Float = 0.25
        let wanderCohesionScale: Float = 0.15
        let wanderJitterStrength: Float = 0.012
        let maxSimultaneousWanderers: Int = 6
        let velocitySmoothFactor: Float = 0.6
        let maxSteeringForce: Float = 0.18
        // Precompute absolute ranges
       // private var topDir: SCNNode?
        let visualRange = visualRangeRatio * baseFieldSize
        let protectedRange = protectedRangeRatio * baseFieldSize
        let vr2 = visualRange * visualRange
        let pr2 = protectedRange * protectedRange
        let half = fieldHalfSize
        var newBoids: [Boid] = []
        newBoids.reserveCapacity(boids.count)
        // --- Build spatial grid ---
        let cellSize = visualRange
        var grid: [GridCell: [Int]] = [:]
        for (i, boid) in boids.enumerated() {
            let cell = gridCell(for: boid.position, cellSize: cellSize)
            grid[cell, default: []].append(i)
        }
        // Count current wanderers
        var activeWanderers = 0
        for b in boids { if b.wanderTime > 0 { activeWanderers += 1 } }
        for i in 0..<boids.count {
            var b = boids[i]
            // Possibly start wandering
            if wanderEnabled && b.wanderTime <= 0 && activeWanderers < maxSimultaneousWanderers {
                let p = wanderChancePerSecond * deltaTime
                if Float.random(in: 0...1) < p {
                    b.wanderTime = Float.random(in: wanderDurationRange.0...wanderDurationRange.1)
                    b.wanderDir = randomUnitVector()
                    activeWanderers += 1
                }
            }
            var close = SCNVector3Zero
            var avgPos = SCNVector3Zero
            var avgVel = SCNVector3Zero
            var count: Float = 0
            var alignmentWeight: Float = 0
            var cohesionWeight: Float = 0
            // --- Optimized neighbor search ---
            let myCell = gridCell(for: b.position, cellSize: cellSize)
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let neighborCell = GridCell(x: myCell.x + dx, y: myCell.y + dy, z: myCell.z + dz)
                        if let indices = grid[neighborCell] {
                            for j in indices where j != i {
                                let other = boids[j]
                                let dx = b.position.x - other.position.x
                                let dy = b.position.y - other.position.y
                                let dz = b.position.z - other.position.z
                                let dist2 = dx*dx + dy*dy + dz*dz
                                let dist = sqrt(dist2)
                                if dist2 < pr2 {
                                    close.x += dx; close.y += dy; close.z += dz
                                } else if dist2 < vr2 {
                                    // Quadratic easing for alignment/cohesion
                                    let t = max(0, min(1, 1.0 - dist / visualRange))
                                    let ease = t * t
                                    avgPos = SCNVector3Add(avgPos, SCNVector3Multiply(other.position, ease))
                                    avgVel = SCNVector3Add(avgVel, SCNVector3Multiply(other.velocity, ease))
                                    alignmentWeight += ease
                                    cohesionWeight += ease
                                    count += ease
                                }
                            }
                        }
                    }
                }
            }
            // Factors may be reduced if wandering
            let alignmentScale = (b.wanderTime > 0) ? wanderAlignmentScale : 1.0
            let cohesionScale = (b.wanderTime > 0) ? wanderCohesionScale : 1.0
            if count > 0 {
                let inv = 1.0 / count
                avgPos = SCNVector3Multiply(avgPos, inv)
                avgVel = SCNVector3Multiply(avgVel, inv)
                // Cohesion
                let toCenter = SCNVector3Subtract(avgPos, b.position)
                var cohesionSteer = SCNVector3Multiply(toCenter, cohesionFactor * cohesionScale)
                // Clamp steering force
                let cohLen = cohesionSteer.length()
                if cohLen > maxSteeringForce { cohesionSteer = SCNVector3Multiply(cohesionSteer, maxSteeringForce / cohLen) }
                b.velocity = SCNVector3Add(b.velocity, cohesionSteer)
                // Alignment
                let match = SCNVector3Subtract(avgVel, b.velocity)
                var alignmentSteer = SCNVector3Multiply(match, alignmentFactor * alignmentScale)
                let alignLen = alignmentSteer.length()
                if alignLen > maxSteeringForce { alignmentSteer = SCNVector3Multiply(alignmentSteer, maxSteeringForce / alignLen) }
                b.velocity = SCNVector3Add(b.velocity, alignmentSteer)
            }
            if (close.x != 0 || close.y != 0 || close.z != 0) { // Separation (push away)
                var sepSteer = SCNVector3Multiply(close, separationFactor)
                let sepLen = sepSteer.length()
                if sepLen > maxSteeringForce { sepSteer = SCNVector3Multiply(sepSteer, maxSteeringForce / sepLen) }
                b.velocity = SCNVector3Add(b.velocity, sepSteer)
            }
            // Wander jitter & gentle steering while active
            if wanderEnabled && b.wanderTime > 0 {
                b.wanderTime -= deltaTime
                if b.wanderTime <= 0 { b.wanderTime = 0 }
                // Slightly change direction over time for smoothness
                let jitterDir = randomUnitVector()
                // Blend old wanderDir and new random to avoid harsh changes
                b.wanderDir = SCNVector3(
                    (b.wanderDir.x * 0.85 + jitterDir.x * 0.15),
                    (b.wanderDir.y * 0.85 + jitterDir.y * 0.15),
                    (b.wanderDir.z * 0.85 + jitterDir.z * 0.15)
                )
                // Normalize
                let len = b.wanderDir.length()
                if len > 0.0001 { b.wanderDir = SCNVector3(b.wanderDir.x/len, b.wanderDir.y/len, b.wanderDir.z/len) }
                b.velocity = SCNVector3Add(b.velocity, SCNVector3MultiplyScalar(b.wanderDir, wanderJitterStrength))
            }
            // Boundaries
            if wrappingEnabled {
                b.position = wrap(b.position, half: half)
            } else {
                if smoothEdgeTurning {
                    // Soft steering with distance-based scaling + simple lookahead
                    let softMargin = min(turnMargin * edgeSoftMultiplier, half * 0.95)
                    func steerAxis(pos: Float, vel: Float) -> Float {
                        let future = pos + vel * edgePredictionTime
                        let aPos = abs(future)
                        let innerStart = half - softMargin
                        if aPos <= innerStart { return vel } // far from wall
                        let distToEdge = half - aPos // ( <= softMargin )
                        let t = max(0, min(1, 1 - distToEdge / softMargin)) // 0..1 ramp
                        // Apply proportional inward push scaled by t (smooth), squared easing for gentler entry
                        let strength = turnFactor * (t * t + 0.05) // small base to start early
                        let direction: Float = (future > 0) ? -1 : 1
                        return vel + direction * strength
                    }
                    b.velocity.x = steerAxis(pos: b.position.x, vel: b.velocity.x)
                    b.velocity.y = steerAxis(pos: b.position.y, vel: b.velocity.y)
                    b.velocity.z = steerAxis(pos: b.position.z, vel: b.velocity.z)
                } else {
                    // Original abrupt turning
                    if b.position.x > half - turnMargin { b.velocity.x -= turnFactor } else if b.position.x < -half + turnMargin { b.velocity.x += turnFactor }
                    if b.position.y > half - turnMargin { b.velocity.y -= turnFactor } else if b.position.y < -half + turnMargin { b.velocity.y += turnFactor }
                    if b.position.z > half - turnMargin { b.velocity.z -= turnFactor } else if b.position.z < -half + turnMargin { b.velocity.z += turnFactor }
                }
            }
            // Speed clamp
            let sp = b.velocity.length()
            if sp > maxSpeed { b.velocity = SCNVector3MultiplyScalar(b.velocity, maxSpeed / max(sp, 0.0001)) }
            else if sp < minSpeed && sp > 0 { b.velocity = SCNVector3MultiplyScalar(b.velocity, minSpeed / sp) }
            // Integrate
            b.position = SCNVector3Add(b.position, SCNVector3Multiply(b.velocity, speedMultiplier))
            if !wrappingEnabled { // keep inside
                b.position.x = min(max(b.position.x, -half), half)
                b.position.y = min(max(b.position.y, -half), half)
                b.position.z = min(max(b.position.z, -half), half)
            }
            b.node.position = b.position
            orientTetra(node: b.node, velocity: b.velocity)
            applySwimAnimation(boid: &b, deltaTime: deltaTime)
            // --- After all steering forces, blend velocity for smoothness ---
            b.velocity = SCNVector3Lerp(boids[i].velocity, b.velocity, velocitySmoothFactor)
            newBoids.append(b)
        }
        boids = newBoids
        rootNode.position = userOffset
        if let v = scnView { updateBoundsCircleNode(in: v) }
    }
    // --- End restored boids update logic ---
    private func SCNVector3Lerp(_ a: SCNVector3, _ b: SCNVector3, _ t: Float) -> SCNVector3 {
        return SCNVector3(
            a.x + (b.x - a.x) * t,
            a.y + (b.y - a.y) * t,
            a.z + (b.z - a.z) * t
        )
    }
    private func wrap(_ p: SCNVector3, half: Float) -> SCNVector3 {
           var r = p
           let h = half
           if r.x < -h { r.x = h } else if r.x > h { r.x = -h }
           if r.y < -h { r.y = h } else if r.y > h { r.y = -h }
           if r.z < -h { r.z = h } else if r.z > h { r.z = -h }
           return r
       }
    
    
    
    private func applySwimAnimation(boid b: inout Boid, deltaTime: Float) {
        let sp = b.velocity.length()
        let speedFactor = min(1.0, sp / max(0.0001, 0.35))
        let baseFreq: Float = 4.0
        let speedFreq: Float = 12.0
        b.swimPhase += deltaTime * (baseFreq + speedFreq * speedFactor)
        let spineAmp: Float = 0.25 * (0.7 + 0.7 * speedFactor)
        let spineAngle = sin(b.swimPhase) * spineAmp
        // Use the boid's node directly; it's already the "Model" node
        let model = b.node
        let bodyA = model.childNode(withName: "BodyA", recursively: false)
        let bodyB = model.childNode(withName: "BodyB", recursively: false)
        bodyA?.eulerAngles.z = spineAngle
        bodyB?.eulerAngles.z = -spineAngle
        if let tail = b.tailNode {
            let tailAmp: Float = 0.65 * (0.7 + 0.7 * speedFactor)
            tail.eulerAngles.z = sin(b.swimPhase + 0.6) * tailAmp
        }
    }
    
    func reset() {
        // ...reset boid positions, velocities, etc...
    }
    private func updateBoundsCircleNode(in scnView: SCNView) {
            guard showBoundsCircle else { return }
            ensureBoundsCircleNode()
            guard let ring = boundsCircleNode else { return }
            // Project center
            let centerWorld = rootNode.convertPosition(SCNVector3Zero, to: nil)
            let pCenter = scnView.projectPoint(centerWorld)
            if pCenter.x.isNaN || pCenter.y.isNaN { return }
            // Find max screen distance to cube corners (like projectedFieldCircle but unflipped)
            let half = fieldHalfSize
            var maxDist2: CGFloat = 0
            for sx in [-half, half] {
                for sy in [-half, half] {
                    for sz in [-half, half] {
                        let local = SCNVector3(sx, sy, sz)
                        let world = rootNode.convertPosition(local, to: nil)
                        let p = scnView.projectPoint(world)
                        if p.x.isNaN || p.y.isNaN { continue }
                        let dx = CGFloat(p.x - pCenter.x)
                        let dy = CGFloat(p.y - pCenter.y)
                        let d2 = dx*dx + dy*dy
                        if d2 > maxDist2 { maxDist2 = d2 }
                    }
                }
            }
            if maxDist2 <= 0 { return }
            let radiusScreen = sqrt(maxDist2)
            // Compute world radius by unprojecting a point at same depth offset by radiusScreen in x
            let edgeScreen = SCNVector3(pCenter.x + Float(radiusScreen), pCenter.y, pCenter.z)
            let edgeWorld = scnView.unprojectPoint(edgeScreen)
            let rVec = SCNVector3(edgeWorld.x - centerWorld.x, edgeWorld.y - centerWorld.y, edgeWorld.z - centerWorld.z)
            let rWorld = max(0.0001, sqrt(rVec.x*rVec.x + rVec.y*rVec.y + rVec.z*rVec.z))
            if let tube = ring.geometry as? SCNTube {
                tube.innerRadius = CGFloat(rWorld) - 0.005 * CGFloat(rWorld)
                tube.outerRadius = CGFloat(rWorld) + 0.005 * CGFloat(rWorld)
                tube.height = 0.0005 * CGFloat(rWorld)
            }
            // Position ring at simulation center (includes userOffset via rootNode positioning)
            ring.position = SCNVector3Zero
            // Slightly raise on Z to reduce z-fighting
            ring.renderingOrder = 1000
        }
        
    
    private func orientTetra(node: SCNNode, velocity: SCNVector3) { // now generic orient helper
           let len = velocity.length(); if len < 0.0001 { return }
           let dir = SCNVector3(velocity.x/len, velocity.y/len, velocity.z/len)
           let up = SCNVector3(0,1,0)
           var dot = up.x*dir.x + up.y*dir.y + up.z*dir.z
           dot = max(-1, min(1, dot))
           if dot > 0.9995 { node.rotation = SCNVector4(0,0,1,0); return }
           if dot < -0.9995 { node.rotation = SCNVector4(1,0,0,Float.pi); return }
           let ax = SCNVector3(up.y*dir.z - up.z*dir.y, up.z*dir.x - up.x*dir.z, up.x*dir.y - up.y*dir.x)
           let axLen = sqrt(ax.x*ax.x + ax.y*ax.y + ax.z*ax.z); if axLen < 0.0001 { return }
           let n = SCNVector3(ax.x/axLen, ax.y/axLen, ax.z/axLen)
           let angle = acos(dot)
           node.rotation = SCNVector4(n.x, n.y, n.z, angle)
       }
    
    private func randomUnitVector() -> SCNVector3 {
           while true {
               let x = Float.random(in: -1...1)
               let y = Float.random(in: -1...1)
               let z = Float.random(in: -1...1)
               let l2 = x*x + y*y + z*z
               if l2 > 0.0001 && l2 <= 1 { let inv = 1 / sqrt(l2); return SCNVector3(x*inv,y*inv,z*inv) }
           }
       }
       // Bridging helpers (legacy naming used by existing flock logic)
       @inline(__always) private func SCNVector3Add(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 { a + b }
       @inline(__always) private func SCNVector3Subtract(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 { a - b }
       @inline(__always) private func SCNVector3Multiply(_ v: SCNVector3, _ s: Float) -> SCNVector3 { v * s }
       @inline(__always) private func SCNVector3MultiplyScalar(_ v: SCNVector3, _ s: Float) -> SCNVector3 { v * s }
       
    
    // MARK: - Public Controls
    func setSpeedMultiplier(_ multiplier: Float) { speedMultiplier = max(0, multiplier) }
    func setWrappingEnabled(_ enabled: Bool) { wrappingEnabled = enabled }
    func translate(dx: Float, dy: Float, dz: Float) { userOffset.x += dx; userOffset.y += dy; userOffset.z += dz }
    func setGlobalScale(_ scale: Float) { let s = max(0.1, scale); globalScale = s; rootNode.scale = SCNVector3(s,s,s) }
    func setShowBoundsCircle(_ v: Bool) { if v { ensureBoundsCircleNode() } else { boundsCircleNode?.removeFromParentNode(); boundsCircleNode = nil } }
    func setShowBoundsCube(_ v: Bool) { if v { ensureBoundsCubeNode() } else { boundsNode?.removeFromParentNode(); boundsNode = nil } }
    func setFishSize(_ size: Float) {
        let clamped = max(0.1, min(size, 5.0))
        fishSize = clamped
        let bodyLength: Float = fishSize * 3.0
        let bodyRadius: Float = fishSize * 0.55
        for boid in boids {
            // Use the boid's node directly; it's already the "Model" node
            let model = boid.node
            let bodyA = model.childNode(withName: "BodyA", recursively: false)
            let bodyB = model.childNode(withName: "BodyB", recursively: false)
            if let sphereA = bodyA?.geometry as? SCNSphere { sphereA.radius = CGFloat(bodyRadius) }
            bodyA?.scale = SCNVector3(0.75, 2.2, 0.75)
            bodyA?.position = SCNVector3(0, bodyLength * 0.18, 0)
            if let sphereB = bodyB?.geometry as? SCNSphere { sphereB.radius = CGFloat(bodyRadius) }
            bodyB?.scale = SCNVector3(0.5, 1.5, 0.5)
            bodyB?.position = SCNVector3(0, -bodyLength * 0.15, 0)
            if let tail = model.childNode(withName: "Tail", recursively: false), let tailGeom = tail.geometry as? SCNPyramid {
                tailGeom.width = CGFloat(bodyRadius) * 0.4
                tailGeom.length = CGFloat(bodyRadius) * 1.0
                tailGeom.height = CGFloat(bodyRadius) * 1.0
                tail.position = SCNVector3(0, -bodyLength * 0.5, 0)
            }
            if let bodyA = bodyA {
                for eye in bodyA.childNodes { // eyes are children of BodyA
                    if let eyeGeom = eye.geometry as? SCNSphere {
                        eyeGeom.radius = CGFloat(bodyRadius * 0.22)
                        let eyeYOffset = bodyLength * 0.30
                        let eyeXOffset = bodyRadius * 0.6
                        let eyeZOffset = bodyRadius * 0.25
                        let side = eye.position.x < 0 ? -1.0 : 1.0
                        eye.position = SCNVector3(eyeXOffset * Float(side), eyeYOffset - bodyA.position.y, eyeZOffset)
                    }
                }
            }
        }
    }
    
    // MARK: - Geometry Setup
    private func setupLighting(in scene: SCNScene) {
        let topDir = SCNNode(); topDir.light = SCNLight(); topDir.light?.type = .directional; topDir.light?.color = UIColor(white: 1.0, alpha: 1); topDir.light?.intensity = 1800; topDir.position = SCNVector3(5, 10, 0); topDir.eulerAngles = SCNVector3(-Float.pi/2, 0, 0); scene.rootNode.addChildNode(topDir)
        omglights = topDir
    }
    private func setupBoids(in scene: SCNScene) {
        rootNode.removeAllActions()
        rootNode.enumerateChildNodes { n, _ in n.removeFromParentNode() }; boids.removeAll()
        let half = fieldHalfSize
        let palette: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue]
        let bodyLength: Float = fishSize * 3.0
        let bodyRadius: Float = fishSize * 0.55
        for i in 0..<numBoids {
            let pos = SCNVector3(Float.random(in: -half...half), Float.random(in: -half...half), Float.random(in: -half...half))
            let vel = SCNVector3(Float.random(in: -0.15...0.15), Float.random(in: -0.15...0.15), Float.random(in: -0.15...0.15))
            let color = i < palette.count ? palette[i] : .systemTeal
            let node = makeFishNode(bodyLength: CGFloat(bodyLength), bodyRadius: CGFloat(bodyRadius), color: color)
            node.position = pos
            rootNode.addChildNode(node)
            var boid = Boid(position: pos, velocity: vel, node: node, color: color, wanderTime: 0, wanderDir: SCNVector3Zero, swimPhase: 0, spine: [], tailNode: nil)
            let rig = getFishRigNodes(from: node)
            boid.spine = rig.spine
            boid.tailNode = rig.tail
            boids.append(boid)
        }
        scene.rootNode.addChildNode(rootNode)
        rootNode.scale = SCNVector3(globalScale, globalScale, globalScale)
    }
    private func setupBackgroundSphere(in scene: SCNScene) {
        backgroundSphereNode?.removeFromParentNode()
        let sphere = SCNSphere(radius: 20)
        sphere.segmentCount = 48
        let mat = SCNMaterial()
        mat.diffuse.contents = makeBlueGradientImage(size: CGSize(width: 5, height: 5))
        mat.isDoubleSided = true
        mat.lightingModel = .constant
        sphere.materials = [mat]
        let node = SCNNode(geometry: sphere)
        node.position = SCNVector3Zero
        node.renderingOrder = -100
        scene.rootNode.addChildNode(node)
        backgroundSphereNode = node
    }
    private func ensureBoundsCircleNode() {
        guard boundsCircleNode == nil else { return }
        let tube = SCNTube(innerRadius: 0.9, outerRadius: 1.0, height: 0.0005)
        let m = SCNMaterial()
        m.diffuse.contents = UIColor.white
        m.emission.contents = UIColor.white
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
        tube.materials = [m]
        let node = SCNNode(geometry: tube)
        let bb = SCNBillboardConstraint()
        bb.freeAxes = []
        node.constraints = [bb]
        node.name = "BoundsCircle"
        rootNode.addChildNode(node)
        boundsCircleNode = node
    }
    private func ensureBoundsCubeNode() {
        guard boundsNode == nil else { return }
        let half = fieldHalfSize
        let box = SCNBox(width: CGFloat(half * 2), height: CGFloat(half * 2), length: CGFloat(half * 2), chamferRadius: 0)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.13)
        material.emission.contents = UIColor.white.withAlphaComponent(0.18)
        material.lightingModel = .constant
        material.isDoubleSided = true
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.position = SCNVector3Zero
        node.name = "BoundsCube"
        node.opacity = 0.7
        node.renderingOrder = 1000
        rootNode.addChildNode(node)
        boundsNode = node
    }
    
    private func gridCell(for position: SCNVector3, cellSize: Float) -> GridCell {
        return GridCell(
            x: Int(floor(position.x / cellSize)),
            y: Int(floor(position.y / cellSize)),
            z: Int(floor(position.z / cellSize))
        )
    }
    // MARK: - Helper Functions for Boid Node Creation and Rigging
    private func makeFishNode(bodyLength: CGFloat, bodyRadius: CGFloat, color: UIColor) -> SCNNode {
        let node = SCNNode()
        node.name = "Model"
        // Body A (main)
        let bodyA = SCNNode(geometry: SCNSphere(radius: bodyRadius))
        bodyA.name = "BodyA"
        bodyA.geometry?.firstMaterial?.diffuse.contents = color
        bodyA.scale = SCNVector3(0.75, 2.2, 0.75)
        bodyA.position = SCNVector3(0, bodyLength * 0.18, 0)
        node.addChildNode(bodyA)
        // Body B (lower)
        let bodyB = SCNNode(geometry: SCNSphere(radius: bodyRadius))
        bodyB.name = "BodyB"
        bodyB.geometry?.firstMaterial?.diffuse.contents = color.withAlphaComponent(1.0)
        bodyB.scale = SCNVector3(0.5, 1.5, 0.5)
        bodyB.position = SCNVector3(0, -bodyLength * 0.15, 0)
        node.addChildNode(bodyB)
        // Tail
        let tail = SCNNode(geometry: SCNPyramid(
            width: CGFloat(bodyRadius) * 0.4,
            height: CGFloat(bodyRadius) * 1.0,
            length: CGFloat(bodyRadius) * 1.0
        ))
        tail.geometry?.firstMaterial?.diffuse.contents = color.withAlphaComponent(1.0)
        tail.position = SCNVector3(0, -bodyLength * 0.5, 0)
        tail.name = "Tail"
        node.addChildNode(tail)
        // Eyes (optional, simple)
        let eyeL = SCNNode(geometry: SCNSphere(radius: bodyRadius * 0.22))
        eyeL.geometry?.firstMaterial?.diffuse.contents = UIColor.white
        eyeL.position = SCNVector3(-bodyRadius * 0.6, bodyLength * 0.30 - CGFloat(bodyA.position.y), bodyRadius * 0.25)
        let eyeR = SCNNode(geometry: SCNSphere(radius: bodyRadius * 0.22))
        eyeR.geometry?.firstMaterial?.diffuse.contents = UIColor.white
        eyeR.position = SCNVector3(bodyRadius * 0.6, bodyLength * 0.30 - CGFloat(bodyA.position.y), bodyRadius * 0.25)
        bodyA.addChildNode(eyeL)
        bodyA.addChildNode(eyeR)
        return node
    }
    
    private func getFishRigNodes(from node: SCNNode) -> (spine: [SCNNode], tail: SCNNode?) {
        let bodyA = node.childNode(withName: "BodyA", recursively: false)
        let bodyB = node.childNode(withName: "BodyB", recursively: false)
        let tail = node.childNode(withName: "Tail", recursively: false)
        var spine: [SCNNode] = []
        if let a = bodyA { spine.append(a) }
        if let b = bodyB { spine.append(b) }
        return (spine, tail)
    }
    
    public var showBoundsCircle: Bool = false { didSet { if showBoundsCircle { ensureBoundsCircleNode() } else { boundsCircleNode?.removeFromParentNode(); boundsCircleNode = nil } } }
    
    private func makeBlueGradientImage(size: CGSize) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }
        let colors = [UIColor.systemBlue.cgColor, UIColor.black.cgColor] // darker gradient
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: [0, 1]) else {
        
            // Fallback: use a solid color or skip gradient usage
            return UIImage()
        }
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size.height), options: [])
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image
    }
    // MARK: - MIDI/Tracker API
    func projectedBoidXY127(index: Int) -> (x: Int, y: Int)? {
        guard boids.indices.contains(index), let scnView = scnView else { return nil }
        let boid = boids[index]
        let worldPos = boid.node.worldPosition
        let projected = scnView.projectPoint(worldPos)
        // Map to 0...127 range (screen coordinates)
        let width = Float(scnView.bounds.width)
        let height = Float(scnView.bounds.height)
        guard width > 0, height > 0 else { return nil }
        let xNorm = min(max(projected.x / width, 0), 1)
        let yNorm = min(max(1.0 - (projected.y / height), 0), 1) // flip y
        let x127 = Int(round(xNorm * 127))
        let y127 = Int(round(yNorm * 127))
        return (x: x127, y: y127)
    }
    func boidVelocity(index: Int) -> SCNVector3? {
        guard boids.indices.contains(index) else { return nil }
        return boids[index].velocity
    }
    func maxSpeedValue() -> Float {
        // Estimate a reasonable max speed for normalization
        return 0.3 * speedMultiplier
    }
    // ...existing code...
    
    func teardownAndDispose() {
        // Remove all actions and child nodes from rootNode and its children
        rootNode.removeAllActions()
        rootNode.enumerateChildNodes { n, _ in
            n.removeAllActions()
            n.removeFromParentNode()
        }
        // Remove rootNode from scene
        sceneReference?.rootNode.childNodes.forEach { node in
            if node === rootNode { node.removeFromParentNode() }
        }
       
        // Remove lights
        omglights?.removeFromParentNode(); omglights = nil
       // directionalLightNode?.removeFromParentNode(); directionalLightNode = nil
      //  // Clear dictionaries and arrays
       // jointNodes.removeAll(); splineNodes.removeAll(); jointPositions.removeAll(); baseJointPositions.removeAll()
        // Clear scene/scnView refs
        sceneReference = nil
        scnView = nil
    }
    
}
