import SceneKit
import UIKit



class SimplePlantLadybirdsSimulation: LifeformSimulation {
    // --- Scene references (move to top, like MeshBirdSimulation) ---
    weak var sceneReference: SCNScene?
    weak var scnView: SCNView?
    private let rootNode = SCNNode()

    // Provide visual bounds similar to other sims (for world->CC fallback)
    var visualBounds: Float {
        if let scene = sceneReference,
           let cameraState = (scene as? NSObject)?.value(forKey: "cameraState") as? CameraOrbitState {
            return cameraState.visualBounds
        }
        return 30.0
    }

    // --- Config struct and config/globalConfig properties ---
    struct Config {
        var leafCount: Int = 14
        var leafCols: Int = 8
        var leafRows: Int = 5
        var cellSize: Float = 0.16
        var leafLengthRange: ClosedRange<Float> = 0.2...0.5
        var leafWidthFactorRange: ClosedRange<Float> = 0.02...0.25
        var stemRadius: Float = 0.12
        var branchCount: Int = 5
        var branchLengthRange: ClosedRange<Float> = 1.2...2.8
        var branchRadiusFactor: Float = 0.5 // NEW thinner branches
        var ladybirdCount: Int = 5
        var ladybirdSpeed: Float = 0.12
        var ladybirdEatRate: Float = 3.0
        var separationRadius: Float = 0.12
        var maxLeavesPerLadybirdSearch: Int = 6
        var dynamicLeafSpawnInterval: ClosedRange<Float> = 2.5...4.5
        var dynamicLeafSpawnBatch: ClosedRange<Int> = 1...2
        var maxTotalLeaves: Int = 14
        var mainLateralAmplitude: Float = 0.8 // toned-down angle amplitude
        var mainBendNoise: Float = 0.18 // amplitude for random bend injection
        var leafFallDistance: Float = 1.2 // NEW fall distance
        var leafFallDuration: TimeInterval = 1.8 // NEW fall animation duration
        var stemClearanceMargin: Float = 0.01 // NEW extra radial margin to keep ladybirds off stem surface
        var normalizeToUnitHeight: Bool = false // If true, normalize stems to unit height and rescale to original height
        var leafCellLightingConstant: Bool = true // Use constant lighting for leaf cells to reduce shading cost
        var reduceVeinSegments: Bool = true // Lower radial segment count for vein cylinders
        // var useBatchedLeafCells: Bool = false // Always batched now
    }
    private let config: Config
    private let globalConfig: LifeformViewConfig?

    // --- State variables (grouped together) ---
    private var stems: [StemPath] = []
    private var leaves: [Leaf] = []
    private var ladybirds: [Ladybird] = []
    private var nextLeafID = 0
    private var scaleMultiplier: Float = 1.0
    private var speedMultiplier: Float = 1.0
    private var leafSpawnTimer: Float = 0
    private var nextLeafSpawnInterval: Float = 0
    private let leafMoveBaseSpeed: Float = 0.30
    private let leafMoveMinDuration: Float = 0.22
    private let leafMoveMaxDuration: Float = 0.95
    private let leafMoveArcAmplitude: Float = 0.006
    private let leafBobAmplitude: Float = 0.0035
    private let floorY: Float = 0.0
    private var stemsPendingFade: Set<Int> = []
    private var frameCounter: Int = 0
    private var trackerCenterWorld: SCNVector3 = SCNVector3Zero
    private var trackerRadius: Float = 1.0
    private var branchAttachSCache: [Int: Float] = [:]
    private var originalPlantHeight: Float = 1.0 // capture pre-normalization height for restoration
    private var leavesNeedingRebuild: [Leaf] = [] // Track leaves needing geometry rebuild
    private var fallingLeafNodes: Set<SCNNode> = [] // Track nodes that should be removed after fall animation
    private var hasConfiguredView: Bool = false // Track if scnView was already configured to avoid re-enabling stats
    
    // MARK: - Action Pooling for Performance
    private struct ActionPool {
        // Reusable actions to reduce allocation overhead
        static let cellEatFadeOut: SCNAction = {
            .sequence([
                .group([
                    .scale(to: 0.05, duration: 0.15),
                    .fadeOut(duration: 0.15)
                ]),
                .removeFromParentNode()
            ])
        }()
        
        static func leafFallAction(driftX: Float, driftZ: Float, fallDist: Float, duration: TimeInterval) -> SCNAction {
            let move = SCNAction.moveBy(x: CGFloat(driftX), y: CGFloat(-fallDist), z: CGFloat(driftZ), duration: duration)
            move.timingMode = .easeIn
            let rot = SCNAction.rotateBy(x: CGFloat.random(in: -1.2...1.2), y: CGFloat.random(in: -2.0...2.0), z: CGFloat.random(in: -1.2...1.2), duration: duration)
            let fade = SCNAction.fadeOut(duration: duration * 0.6)
            return .sequence([.group([move, rot, fade]), .removeFromParentNode()])
        }
        
        static func stemFadeAction() -> SCNAction {
            .sequence([.fadeOut(duration: 1.2), .removeFromParentNode()])
        }
    }
    
    // Pooled materials & textures to reduce draw calls
    private struct MaterialPool {
        // Stem material with flat shading - shows true hexagonal geometry
        static let stemMaterial: SCNMaterial = {
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(red:0.25, green:0.45, blue:0.20, alpha:1.0) // darker green-brown
            m.lightingModel = .lambert // most efficient - no lighting calculations, flat shading
            m.isDoubleSided = false
            m.transparency = 1.0
            return m
        }()
        
        // Stem joint material - slightly yellower than main stem
        static let stemJointMaterial: SCNMaterial = {
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(red:0.32, green:0.48, blue:0.18, alpha:1.0) // yellower than stem
            m.lightingModel = .lambert // most efficient - no lighting calculations, flat shading
            m.isDoubleSided = false
            m.transparency = 1.0
            return m
        }()
        
        // Leaf material with procedural texture - flat shading for performance
        static let leafMaterial: SCNMaterial = {
            let m = SCNMaterial()
            // Create procedural leaf texture with veins
            let leafTexture = createLeafTexture()
            m.diffuse.contents = leafTexture
            m.lightingModel = .constant // most efficient - no lighting calculations
            m.isDoubleSided = true // leaves visible from both sides
            m.transparency = 0.95 // slight translucency for organic feel
            return m
        }()
        
        // Generate procedural leaf texture with veins and color variation
        private static func createLeafTexture() -> UIImage {
            let size = CGSize(width: 256, height: 256)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { context in
                let ctx = context.cgContext
                
                // Base leaf color with gradient from tip to base
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: [
                                            UIColor(red:0.22, green:0.68, blue:0.22, alpha:1.0).cgColor, // darker tip
                                            UIColor(red:0.32, green:0.76, blue:0.28, alpha:1.0).cgColor  // brighter base
                                         ] as CFArray,
                                         locations: [0.0, 1.0])!
                ctx.drawLinearGradient(gradient,
                                      start: CGPoint(x: 0, y: 0),
                                      end: CGPoint(x: size.width, y: 0),
                                      options: [])
                
                // Draw central vein
                ctx.setStrokeColor(UIColor(red:0.18, green:0.50, blue:0.18, alpha:0.6).cgColor)
                ctx.setLineWidth(3.0)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: 0, y: size.height/2))
                ctx.addLine(to: CGPoint(x: size.width, y: size.height/2))
                ctx.strokePath()
                
                // Draw branching veins
                ctx.setLineWidth(1.5)
                let veinCount = 8
                for i in 0..<veinCount {
                    let x = size.width * CGFloat(i + 1) / CGFloat(veinCount + 1)
                    let yOffset = size.height * 0.25
                    // Upper vein
                    ctx.move(to: CGPoint(x: x, y: size.height/2))
                    ctx.addLine(to: CGPoint(x: x + 20, y: size.height/2 - yOffset))
                    // Lower vein
                    ctx.move(to: CGPoint(x: x, y: size.height/2))
                    ctx.addLine(to: CGPoint(x: x + 20, y: size.height/2 + yOffset))
                }
                ctx.strokePath()
                
                // Add subtle texture noise for organic feel
                ctx.setBlendMode(.overlay)
                for _ in 0..<200 {
                    let x = CGFloat.random(in: 0...size.width)
                    let y = CGFloat.random(in: 0...size.height)
                    let size = CGFloat.random(in: 1...3)
                    let alpha = CGFloat.random(in: 0.05...0.15)
                    ctx.setFillColor(UIColor(white: 0.0, alpha: alpha).cgColor)
                    ctx.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
                }
            }
        }
    }

    // --- Nested types (move after state/config, like MeshBirdSimulation) ---
    // MARK: - Leaf Cell
    final class LeafCell {
        let node: SCNNode
        var eaten = false
        let rNorm: Float // radial distance normalized (for perimeter ordering)
        init(node: SCNNode, rNorm: Float) { self.node = node; self.rNorm = rNorm }
    }
    // MARK: - Leaf
    final class Leaf {
        let id: Int
        let stemIndex: Int // NEW: which stem this leaf is attached to
        let anchorS: Float      // position along stem
        let outwardDir: SCNVector3
        let container: SCNNode
        var cells: [LeafCell] = []
        // Axis orderings for eating
        var cellsSortedByX: [LeafCell] = []
        var cellsSortedByZ: [LeafCell] = []
        var perimeterSorted: [LeafCell] = [] // NEW perimeter -> inward ordering (legacy)
        var tipToBaseSorted: [LeafCell] = [] // NEW tip (max x) -> base (min x) order for linear eating
        var uneatenCount: Int = 0
        var isFalling: Bool = false // NEW falls when fully eaten
        // Removed batchedGeometryNode and related properties
        init(id: Int, stemIndex: Int, anchorS: Float, outwardDir: SCNVector3, container: SCNNode) {
            self.id = id; self.stemIndex = stemIndex; self.anchorS = anchorS; self.outwardDir = outwardDir; self.container = container
        }
    }
    // MARK: - Stem
    private struct StemSegment { let start: SCNVector3; let end: SCNVector3; let length: Float }
    private final class StemPath {
        var control: [SCNVector3] = []
        var segments: [StemSegment] = []
        var totalLength: Float = 0
        let radius: Float
        init(points: [SCNVector3], radius: Float) {
            self.control = points; self.radius = radius; rebuild()
        }
        private func rebuild() {
            segments.removeAll(); totalLength = 0
            for i in 1..<control.count { let a = control[i-1]; let b = control[i]; let len = (b-a).length(); segments.append(.init(start: a,end: b,length: len)); totalLength += len }
        }
    }
    // MARK: - Ladybird
    private enum LadybirdState { case wander, toLeaf, eating }
    private struct Ladybird {
        let node: SCNNode
        let bodyNode: SCNNode
        var state: LadybirdState = .wander
        var stemIndex: Int
        var stemS: Float
        var wrapAngle: Float
        var speed: Float
        var targetLeaf: Leaf?
        var latchedLeaf: Leaf?
        var munchTimer: Float = 0
        var eatIndex: Int = 0
        var activeCell: LeafCell? = nil
        // Smooth interpolation state (NEW)
        var leafMoveStart: SCNVector3 = SCNVector3Zero
        var leafMoveEnd: SCNVector3 = SCNVector3Zero
        var leafMoveT: Float = 0
        var leafMoveDuration: Float = 0
        var leafLateralDir: SCNVector3 = SCNVector3Zero
        // Route (sequence of (stemIndex, targetS) waypoints along stems)
        var route: [(Int, Float)] = []
    }

    // MARK: - Init
    init(scene: SCNScene, scnView: SCNView?, config: Config = Config(), globalConfig: LifeformViewConfig? = nil) {
        self.sceneReference = scene
        self.scnView = scnView
        self.config = config
        self.globalConfig = globalConfig
        setup()
    }

    // MARK: - Setup
    private func setup() {
        if rootNode.parent == nil { sceneReference?.rootNode.addChildNode(rootNode) }
        rootNode.enumerateChildNodes { n,_ in n.removeFromParentNode() }

        leaves.removeAll(); ladybirds.removeAll(); nextLeafID = 0; stems.removeAll()
        fallingLeafNodes.removeAll() // Clear falling nodes tracking
        
        buildStems()
        // Capture original vertical extent prior to optional normalization
        if let minY = stems.flatMap({ $0.control.map { $0.y } }).min(),
           let maxY = stems.flatMap({ $0.control.map { $0.y } }).max() {
            originalPlantHeight = max(0.0001, maxY - minY)
        }
        if config.normalizeToUnitHeight {
            normalizeStemsToUnitHeight()
        }
        buildStemGeometry()
        // If normalized, rescale root to original height to preserve visual scale
        if config.normalizeToUnitHeight {
            rootNode.scale = SCNVector3(originalPlantHeight, originalPlantHeight, originalPlantHeight)
        } else {
            rootNode.scale = SCNVector3(1,1,1)
        }
        seedInitialLeaves()
        spawnLadybirds()
        scheduleNextLeafSpawn()
        // Center pivot & tracker sizing
        let (minVec, maxVec) = rootNode.boundingBox
        let center = SCNVector3(
            (minVec.x + maxVec.x) / 2,
            (minVec.y + maxVec.y) / 2,
            (minVec.z + maxVec.z) / 2
        )
        rootNode.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)
        // After pivot recenters local space, compute dynamic bounds for tracker normalization
        let extents = SCNVector3((maxVec.x - minVec.x)/2, (maxVec.y - minVec.y)/2, (maxVec.z - minVec.z)/2)
        trackerRadius = max(0.001, max(extents.x, extents.z))
        trackerCenterWorld = rootNode.presentation.worldPosition
        frameCounter = 0
        ensureSingleAmbientLight()
        
        // GPU Performance: Enable instancing hints for repeated geometry
        configurePerformanceOptimizations()
    }
    
    // MARK: - Performance Optimizations
    private func configurePerformanceOptimizations() {
        // Only configure view settings once, not on every reset
        // This prevents showsStatistics from flickering when low power mode changes
        guard !hasConfiguredView else { return }
        hasConfiguredView = true
        
        // Enable Metal optimizations if available
        if let scnView = scnView {
            // Reduce antialiasing for better performance
            scnView.antialiasingMode = .none // Changed from .multisampling2X for max performance
            
            // Disable expensive rendering features
            scnView.showsStatistics = false // Disable stats overlay
            scnView.allowsCameraControl = false // Already handled by custom controls
            
            #if DEBUG
            // Only show stats in debug builds
            scnView.showsStatistics = true
            #endif
        }
        
        // Hint to Metal that stems use repeated geometry for instancing
        rootNode.enumerateChildNodes { node, _ in
            if let name = node.name {
                if name.hasPrefix("sp_stem_") {
                    // Enable automatic instancing for stem cylinders/spheres
                    node.categoryBitMask = 1 // Group similar geometry
                }
            }
        }
    }

    // Build main stem + branches (static)
    private func buildStems() {
        // Main stem with moderated lateral variation / angularity
        var pts: [SCNVector3] = []
        var y: Float = 0
        let mainSegments = 18
        for i in 0...mainSegments {
            y += 0.30 + Float.random(in: -0.05...0.05)
            let t = Float(i)/Float(mainSegments)
            let angle = t * 3.5 + Float.random(in: -0.4...0.4)
            let rad = config.mainLateralAmplitude * t * 0.5 + Float.random(in: -0.08...0.08)
            let x = cos(angle) * rad
            let z = sin(angle) * rad
            let base = SCNVector3(x,y,z)
            if let prev = pts.last {
                var dir = (base - prev).normalized()
                dir = (dir + randomLateral() * config.mainBendNoise).normalized()
                pts.append(prev + dir * (base - prev).length())
            } else { pts.append(base) }
        }
        let main = StemPath(points: pts, radius: config.stemRadius)
        stems.append(main)
        // Branches
        let attachableIndices = (2..<main.control.count-2).map { $0 }
        for idx in attachableIndices.shuffled().prefix(config.branchCount) {
            let anchor = main.control[idx]
            var outward = SCNVector3(anchor.x, 0, anchor.z)
            if outward.length() < 0.05 { outward = SCNVector3(1,0,0) }
            outward = (outward.normalized() + randomLateral() * 0.4).normalized()
            let length = Float.random(in: config.branchLengthRange)
            let steps = 5
            var bPts: [SCNVector3] = [anchor]
            var current = anchor
            var dir = (outward + SCNVector3(0, Float.random(in: 0.05...0.22), 0)).normalized()
            for i in 1...steps {
                let stepLen = length / Float(steps)
                current = current + dir * stepLen
                current.y += -Float(i)/Float(steps) * Float.random(in: 0.0...0.06)
                dir = (dir + randomLateral() * 0.25).normalized()
                bPts.append(current)
            }
            let branch = StemPath(points: bPts, radius: config.stemRadius * config.branchRadiusFactor)
            stems.append(branch)
        }
        // NOTE: Removed buildStemGeometry() call here so geometry is only built AFTER normalization.
    }

    private func buildStemGeometry() {
        for (sIndex, stem) in stems.enumerated() {
            for (idx, seg) in stem.segments.enumerated() {
                let len = seg.length; guard len > 0.0001 else { continue }
                // Use shared material
                let dir = (seg.end - seg.start).normalized()
                let up = SCNVector3(0,1,0)
                var axis = SCNVector3.cross(up, dir)
                var angle = acos(max(-1,min(1, SCNVector3.dot(up, dir))))
                if axis.length() < 1e-4 { axis = SCNVector3(1,0,0); if abs(dir.y - 1) < 1e-4 { angle = 0 } }
                let cyl = SCNCylinder(radius: CGFloat(stem.radius), height: CGFloat(len))
                cyl.radialSegmentCount = 6 // Reduced from 10 for better performance
                cyl.materials = [MaterialPool.stemMaterial]
                // GPU Performance: Enable adaptive subdivision
                if #available(iOS 13.0, *) {
                    cyl.wantsAdaptiveSubdivision = true
                }
                let node = SCNNode(geometry: cyl)
                node.name = "sp_stem_\(sIndex)_\(idx)"
                node.rotation = SCNVector4(axis.x, axis.y, axis.z, angle)
                node.position = (seg.start + seg.end) * 0.5
                node.categoryBitMask = 1 // Instancing hint
                rootNode.addChildNode(node)
                // Joint sphere uses slightly yellower material for visual distinction
                if idx > 0 {
                    let sphere = SCNSphere(radius: CGFloat(stem.radius * 1.06))
                    sphere.segmentCount = 8 // Reduced from default 48 for performance
                    sphere.materials = [MaterialPool.stemJointMaterial]
                    // GPU Performance: Enable adaptive subdivision
                    if #available(iOS 13.0, *) {
                        sphere.wantsAdaptiveSubdivision = true
                    }
                    let jNode = SCNNode(geometry: sphere)
                    jNode.position = seg.start
                    jNode.categoryBitMask = 1 // Instancing hint
                    rootNode.addChildNode(jNode)
                }
            }
        }
    }

    private func seedInitialLeaves() {
        guard !stems.isEmpty else { return }
        // Distribute initial leaves roughly proportionally across stems
        let perStemBase = max(1, config.leafCount / max(1, stems.count))
        for (sIndex, _) in stems.enumerated() { // '_' avoids unused variable warning
            let count = min(perStemBase + Int.random(in: 0...2),  max(1, config.leafCount - leaves.count))
            for _ in 0..<count { spawnLeaf(onStem: sIndex) }
            if leaves.count >= config.leafCount { break }
        }
        // If still short (due to rounding), spawn remainder anywhere
        while leaves.count < config.leafCount { spawnLeaf(onStem: Int.random(in: 0..<stems.count)) }
    }

    private func spawnLeaf(onStem stemIndex: Int) {
        guard stemIndex < stems.count else { return }
        let stem = stems[stemIndex]
        guard stem.totalLength > 0 else { return }
        let s = Float.random(in: stem.totalLength * 0.05 ... stem.totalLength * 0.95)
        let (pos, tan) = pointAndTangent(stemIndex: stemIndex, atS: s)
        var horizTangent = SCNVector3(tan.x, 0, tan.z)
        if horizTangent.length() < 0.001 { horizTangent = SCNVector3(0,0,1) }
        var outward = SCNVector3(-horizTangent.z, 0, horizTangent.x).normalized()
        let yaw = Float.random(in: -0.6...0.6)
        let c = cos(yaw), si = sin(yaw)
        outward = SCNVector3(outward.x * c - outward.z * si, 0, outward.x * si + outward.z * c).normalized()
        let length = Float.random(in: config.leafLengthRange)
        let width = length * Float.random(in: config.leafWidthFactorRange)
        let leafNode = SCNNode(); leafNode.name = "sp_leaf_\(nextLeafID)"; leafNode.position = pos
        let rot = rotationAligning(from: SCNVector3(1,0,0), to: outward)
        leafNode.rotation = rot
        rootNode.addChildNode(leafNode)
        let leaf = Leaf(id: nextLeafID, stemIndex: stemIndex, anchorS: s, outwardDir: outward, container: leafNode)
        nextLeafID += 1
        buildLeafCells(for: leaf, length: length, width: width)
        leaves.append(leaf)
    }

    // --- OPTIMIZED LEAF GEOMETRY: Custom leaf shape with triangular tip ---
    private func buildLeafCells(for leaf: Leaf, length: Float, width: Float) {
        // Create custom leaf geometry with pointed tip
        let leafGeometry = createLeafGeometry(length: length, width: width)
        leafGeometry.materials = [MaterialPool.leafMaterial]
        // GPU Performance: Enable adaptive subdivision
        if #available(iOS 13.0, *) {
            leafGeometry.wantsAdaptiveSubdivision = true
        }
        
        let node = SCNNode(geometry: leafGeometry)
        // Rotate 90 degrees around Z to align leaf with stem direction
        node.eulerAngles.x = .pi/4
        node.position = SCNVector3(length * 0.5, 0, 0)
        
        // Add natural leaf curvature and variation
        // Slight droop (gravity effect)
        node.eulerAngles.x += Float.random(in: -0.52...0.25)
        // Random twist for natural variation
        node.eulerAngles.z += Float.random(in: -0.25...0.25)
        // Slight lateral bend
        node.eulerAngles.y += Float.random(in: -0.28...0.28)
        
        leaf.container.addChildNode(node)
        
        // Single cell for eating logic
        let cell = LeafCell(node: node, rNorm: 0)
        leaf.cells = [cell]
        leaf.uneatenCount = 1
        leaf.cellsSortedByX = [cell]
        leaf.cellsSortedByZ = [cell]
        leaf.perimeterSorted = [cell]
        leaf.tipToBaseSorted = [cell]
    }
    
    // Create custom leaf-shaped geometry with triangular tip
    private func createLeafGeometry(length: Float, width: Float) -> SCNGeometry {
        // Leaf shape: wider at base, tapers to pointed tip
        // Using simple quad mesh with custom vertices
        
        let halfWidth = width * 0.5
        let tipWidth = width * 0.15 // Narrow tip (15% of max width)
        
        // Define 6 vertices for leaf outline:
        // Base (wide): left and right
        // Middle (widest): left and right  
        // Tip (narrow): point
        
        let vertices: [SCNVector3] = [
            // Base row (at x=0, wider)
            SCNVector3(0, -halfWidth * 0.8, 0),        // 0: base left
            SCNVector3(0, halfWidth * 0.8, 0),         // 1: base right
            
            // Middle row (at x=length*0.4, widest point)
            SCNVector3(length * 0.4, -halfWidth, 0),   // 2: middle left
            SCNVector3(length * 0.4, halfWidth, 0),    // 3: middle right
            
            // Tip row (at x=length, narrow point)
            SCNVector3(length, -tipWidth, 0),          // 4: tip left
            SCNVector3(length, tipWidth, 0)            // 5: tip right
        ]
        
        // Texture coordinates (UV mapping)
        let texCoords: [CGPoint] = [
            CGPoint(x: 0, y: 0),      // 0
            CGPoint(x: 0, y: 1),      // 1
            CGPoint(x: 0.4, y: 0),    // 2
            CGPoint(x: 0.4, y: 1),    // 3
            CGPoint(x: 1, y: 0.35),   // 4 (tip narrows)
            CGPoint(x: 1, y: 0.65)    // 5 (tip narrows)
        ]
        
        // Normals (all pointing up in Z direction)
        let normals: [SCNVector3] = Array(repeating: SCNVector3(0, 0, 1), count: 6)
        
        // Triangle indices (two triangles per quad section)
        // Section 1: base to middle
        // Section 2: middle to tip
        let indices: [Int32] = [
            // Base to middle quad
            0, 2, 1,  // triangle 1
            1, 2, 3,  // triangle 2
            
            // Middle to tip quad
            2, 4, 3,  // triangle 3
            3, 4, 5   // triangle 4
        ]
        
        // Create geometry sources
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let texCoordSource = SCNGeometrySource(textureCoordinates: texCoords)
        
        // Create geometry element
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: 4, // 4 triangles
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        
        // Create and return geometry
        return SCNGeometry(sources: [vertexSource, normalSource, texCoordSource], elements: [element])
    }

    private func scheduleNextLeafSpawn(){
        nextLeafSpawnInterval = Float.random(in: config.dynamicLeafSpawnInterval)
        leafSpawnTimer = 0
    }

    private func dynamicLeafSpawnUpdate(_ dt: Float){
        guard leaves.count < config.maxTotalLeaves else { return }
        leafSpawnTimer += dt
        if leafSpawnTimer >= nextLeafSpawnInterval {
            let batch = Int.random(in: config.dynamicLeafSpawnBatch)
            for _ in 0..<batch { spawnLeaf(onStem: Int.random(in: 0..<stems.count)) }
            scheduleNextLeafSpawn()
        }
    }

    // Adjust ladybird spawning for multiple stems
    private func spawnLadybirds() {
        for i in 0..<config.ladybirdCount {
            let node = SCNNode(); node.name = "sp_ladybird_\(i)"
            let body = SCNSphere(radius: 0.045 * CGFloat(scaleMultiplier))
            body.segmentCount = 16 // Reduced from default 48 for performance
            // GPU Performance: Enable adaptive subdivision
            if #available(iOS 13.0, *) {
                body.wantsAdaptiveSubdivision = true
            }
            let bm = SCNMaterial()
            bm.diffuse.contents = ladybirdColor(index: i)
            bm.lightingModel = .lambert // Changed from .physicallyBased for better performance
            body.materials=[bm]
            let bodyNode = SCNNode(geometry: body); bodyNode.name = "body"; node.addChildNode(bodyNode)
            
            let head = SCNSphere(radius: 0.022 * CGFloat(scaleMultiplier))
            head.segmentCount = 12 // Reduced from default 48 for performance
            // GPU Performance: Enable adaptive subdivision
            if #available(iOS 13.0, *) {
                head.wantsAdaptiveSubdivision = true
            }
            let hm = SCNMaterial()
            hm.diffuse.contents = UIColor.black
            hm.lightingModel = .lambert // Changed from default for consistency and performance
            head.materials=[hm]
            let headNode = SCNNode(geometry: head)
            headNode.position = SCNVector3(0, -0.03 * scaleMultiplier, 0.032 * scaleMultiplier)
            node.addChildNode(headNode)
            
            let sIndex = Int.random(in: 0..<stems.count)
            let stem = stems[sIndex]
            let s = Float.random(in: 0.02 ... max(0.02, stem.totalLength * 0.98))
            let wrap = Float.random(in: 0 ..< 2*Float.pi)
            let (center, tan) = pointAndTangent(stemIndex: sIndex, atS: s)
            node.position = surfacePosition(center: center, tangent: tan, wrapAngle: wrap, radius: stem.radius)
            rootNode.addChildNode(node)
            // Append fully initialized ladybird
            let speed = config.ladybirdSpeed * (0.75 + Float.random(in:0...0.5))
            let lb = Ladybird(node: node, bodyNode: bodyNode, stemIndex: sIndex, stemS: s, wrapAngle: wrap, speed: speed, targetLeaf: nil, latchedLeaf: nil)
            ladybirds.append(lb)
        }
    }

    // MARK: - Cleanup
    private func cleanupOrphanedNodes() {
        // Remove any leaf nodes that are no longer in the leaves array
        let validLeafIDs = Set(leaves.map { $0.id })
        var removedCount = 0
        rootNode.enumerateChildNodes { node, _ in
            if let name = node.name, name.hasPrefix("sp_leaf_") {
                // Extract leaf ID from name
                if let idStr = name.split(separator: "_").last,
                   let id = Int(idStr) {
                    if !validLeafIDs.contains(id) {
                        // This is an orphaned leaf node - remove it immediately
                        node.removeFromParentNode()
                        removedCount += 1
                    }
                }
            }
        }
        
        // Remove falling leaf nodes that are too far below the floor
        fallingLeafNodes = fallingLeafNodes.filter { node in
            if node.presentation.worldPosition.y < floorY - 3.0 {
                node.removeFromParentNode()
                return false
            }
            return true
        }
        
        #if DEBUG
        if removedCount > 0 {
            print("[SimplePlant] Cleaned up \(removedCount) orphaned leaf nodes")
        }
        #endif
    }
    
    // MARK: - Update
    func update(deltaTime dt: Float) {
        frameCounter += 1
        
        // Periodic cleanup every 300 frames (~5 seconds at 60fps) to remove orphaned nodes
        if frameCounter % 300 == 0 {
            DispatchQueue.main.async { [weak self] in
                self?.cleanupOrphanedNodes()
            }
        }
        
        // Run simulation directly on render thread (no background queue)
        // This matches Barley's architecture for better UI responsiveness
        stepSimulation(dt)
        
        // Stem fade updates can happen on render thread too
        updateStemFadeOut()
    }
        
        
    private func stepSimulation(_ dt: Float) {
        // Apply speed multiplier directly to dt
        let adjustedDt = dt * speedMultiplier
        dynamicLeafSpawnUpdate(adjustedDt)
        updateLadybirds(dt: adjustedDt)
    }

    // Check if any stems pending fade-out have reached the floor
    private func updateStemFadeOut() {
        for stemIdx in stemsPendingFade {
            guard stemIdx < stems.count else { continue }
            let stem = stems[stemIdx]
            // Find the lowest segment y
            let minY = stem.segments.map { min($0.start.y, $0.end.y) }.min() ?? 0.0
            if minY <= floorY {
                fadeOutStem(stemIndex: stemIdx)
            }
        }
        // Remove faded stems from pending set
        stemsPendingFade = stemsPendingFade.filter { stemIdx in
            guard stemIdx < stems.count else { return false }
            let stem = stems[stemIdx]
            let minY = stem.segments.map { min($0.start.y, $0.end.y) }.min() ?? 0.0
            return minY > floorY
        }
    }

    private func updateLadybirds(dt: Float) {
        guard !stems.isEmpty else { return }
        let count = ladybirds.count
        var separation: [SCNVector3] = count > 1 ? Array(repeating: SCNVector3Zero, count: count) : []
        // Removed leg animation code
        var leavesToCull: [Leaf] = []
        for idx in 0..<count {
            var lb = ladybirds[idx]
            // Removed cached leg animation (avoid child lookups)
            switch lb.state {
            case .wander:
                if Float.random(in:0...1) < 0.02 { lb.targetLeaf = pickLeaf(from: lb) }
                if let target = lb.targetLeaf, !target.isFalling, target.uneatenCount > 0 {
                    planRoute(for: &lb, to: target)
                    lb.state = .toLeaf
                } else {
                    let dir: Float = (sin(lb.wrapAngle * 0.5) > 0) ? 1 : -1
                    let stem = stems[lb.stemIndex]
                    lb.stemS = clamp(lb.stemS + dir * lb.speed * dt, 0, stem.totalLength)
                    lb.wrapAngle += dt * 0.8
                    let (center, tan) = pointAndTangent(stemIndex: lb.stemIndex, atS: lb.stemS)
                    lb.node.position = surfacePosition(center: center, tangent: tan, wrapAngle: lb.wrapAngle, radius: stem.radius) + separation[idx]
                    keepLadybirdOutside(idx)
                }
            case .toLeaf:
                if let target = lb.targetLeaf, target.uneatenCount > 0 && !target.isFalling {
                    // Re-plan occasionally if leaf changes (e.g., eaten by others) or route invalid
                    if lb.route.isEmpty { planRoute(for: &lb, to: target) }
                    if !lb.route.isEmpty {
                        // Ensure we are on the correct stem for current waypoint
                        if lb.stemIndex != lb.route[0].0 {
                            // Smooth stem transition: keep world position, project onto new stem instead of teleporting S
                            let oldPos = lb.node.position
                            lb.stemIndex = lb.route[0].0
                            let (_, _, projS) = closestPointOnStem(stemIndex: lb.stemIndex, to: oldPos)
                            lb.stemS = projS
                            // (We intentionally do NOT modify wrapAngle here; keeping it preserves local radial continuity better than re-deriving from new frame)
                        }
                        let stem = stems[lb.stemIndex]
                        let targetS = lb.route[0].1
                        let delta = targetS - lb.stemS
                        let step = lb.speed * dt
                        if abs(delta) <= step { lb.stemS = targetS } else { lb.stemS += (delta > 0 ? step : -step) }
                        lb.wrapAngle += dt * 1.0
                        let (center, tan) = pointAndTangent(stemIndex: lb.stemIndex, atS: lb.stemS)
                        lb.node.position = surfacePosition(center: center, tangent: tan, wrapAngle: lb.wrapAngle, radius: stem.radius) + separation[idx]
                        keepLadybirdOutside(idx)
                        if abs(targetS - lb.stemS) < 0.0005 {
                            lb.route.removeFirst()
                        }
                    }
                    // If route finished and on same stem as leaf, latch when close (no hard snap of stemS)
                    if lb.route.isEmpty && lb.stemIndex == target.stemIndex {
                        let delta = target.anchorS - lb.stemS
                        // (Removed immediate snapping of stemS to anchorS to avoid micro-jump)
                        if abs(delta) < 0.02 {
                            lb.latchedLeaf = target; lb.state = .eating; lb.munchTimer = 0; lb.eatIndex = 0
                            if let firstCell = target.tipToBaseSorted.first(where: { !$0.eaten }) {
                                lb.activeCell = firstCell
                                let worldCell = target.container.convertPosition(firstCell.node.position, to: rootNode) + target.outwardDir * 0.015
                                lb.leafMoveStart = lb.node.position
                                lb.leafMoveEnd = worldCell
                                let dist = (lb.leafMoveEnd - lb.leafMoveStart).length()
                                let rawDur = dist / max(0.0001, leafMoveBaseSpeed * (0.85 + Float.random(in:0...0.25)))
                                lb.leafMoveDuration = min(leafMoveMaxDuration, max(leafMoveMinDuration, rawDur))
                                lb.leafMoveT = 0
                                var side = SCNVector3.cross(target.outwardDir, SCNVector3(0,1,0)).normalized(); if side.length() < 0.001 { side = SCNVector3(1,0,0) }; if Bool.random() { side = side * -1 }; lb.leafLateralDir = side
                            }
                        }
                    }
                } else { lb.state = .wander; lb.targetLeaf = nil; lb.route.removeAll() }
            case .eating:
                if let leaf = lb.latchedLeaf, leaf.uneatenCount > 0 {
                    if let cell = lb.activeCell {
                        let desiredEnd = leaf.container.convertPosition(cell.node.position, to: rootNode) + leaf.outwardDir * 0.015
                        // If target changed notably mid-move, retarget smoothly
                        if (desiredEnd - lb.leafMoveEnd).length() > 0.005 && lb.leafMoveT > lb.leafMoveDuration * 0.4 {
                            lb.leafMoveStart = lb.node.position
                            lb.leafMoveEnd = desiredEnd
                            let dist = (lb.leafMoveEnd - lb.leafMoveStart).length()
                            let rawDur = dist / max(0.0001, leafMoveBaseSpeed * (0.9 + Float.random(in:0...0.2)))
                            lb.leafMoveDuration = min(leafMoveMaxDuration * 0.7, max(leafMoveMinDuration * 0.5, rawDur))
                            lb.leafMoveT = 0
                        }
                        // Interpolate
                        if lb.leafMoveDuration > 0.0001 {
                            lb.leafMoveT += dt
                            let tNorm = min(1, lb.leafMoveT / lb.leafMoveDuration)
                            let smooth = tNorm * tNorm * (3 - 2 * tNorm)
                            let basePos = lb.leafMoveStart + (lb.leafMoveEnd - lb.leafMoveStart) * smooth
                            let arc = sin(Float.pi * smooth) * leafMoveArcAmplitude * lb.leafLateralDir
                            let bob = sin(lb.wrapAngle * 3 + smooth * Float.pi) * leafBobAmplitude * leaf.outwardDir
                            lb.node.position = basePos + arc + bob
                        } else {
                            lb.node.position = lb.leafMoveEnd
                        }
                    }
                    lb.wrapAngle += dt * 0.55
                    lb.munchTimer += dt * config.ladybirdEatRate
                    if lb.munchTimer >= 1.0 {
                        lb.munchTimer -= 1.0
                        var consumed = false
                        if let cell = lb.activeCell, !cell.eaten {
                            cell.eaten = true; leaf.uneatenCount -= 1
                            // Use pooled action for better performance
                            cell.node.runAction(ActionPool.cellEatFadeOut)
                            consumed = true
                        }
                        // Advance tip -> base
                        while lb.eatIndex < leaf.tipToBaseSorted.count {
                            let c = leaf.tipToBaseSorted[lb.eatIndex]; lb.eatIndex += 1
                            if !c.eaten { lb.activeCell = c
                                lb.leafMoveStart = lb.node.position
                                lb.leafMoveEnd = leaf.container.convertPosition(c.node.position, to: rootNode) + leaf.outwardDir * 0.015
                                let dist = (lb.leafMoveEnd - lb.leafMoveStart).length()
                                let rawDur = dist / max(0.0001, leafMoveBaseSpeed * (0.85 + Float.random(in:0...0.25)))
                                lb.leafMoveDuration = min(leafMoveMaxDuration, max(leafMoveMinDuration, rawDur))
                                lb.leafMoveT = 0
                                var side = SCNVector3.cross(leaf.outwardDir, SCNVector3(0,1,0)).normalized(); if side.length() < 0.001 { side = SCNVector3(1,0,0) }; if Bool.random() { side = side * -1 }; lb.leafLateralDir = side
                                break }
                        }
                        if leaf.uneatenCount <= 0 {
                            if !leaf.isFalling { leafFall(leaf); leavesToCull.append(leaf) }
                            lb.state = .wander; lb.latchedLeaf = nil; lb.targetLeaf = nil; lb.activeCell = nil
                        } else if !consumed && (lb.activeCell == nil || lb.activeCell?.eaten == true) {
                            lb.activeCell = leaf.tipToBaseSorted.first(where: { !$0.eaten })
                            if let cell = lb.activeCell {
                                lb.leafMoveStart = lb.node.position
                                lb.leafMoveEnd = leaf.container.convertPosition(cell.node.position, to: rootNode) + leaf.outwardDir * 0.015
                                let dist = (lb.leafMoveEnd - lb.leafMoveStart).length()
                                let rawDur = dist / max(0.0001, leafMoveBaseSpeed)
                                lb.leafMoveDuration = min(leafMoveMaxDuration, max(leafMoveMinDuration, rawDur))
                                lb.leafMoveT = 0
                                var side = SCNVector3.cross(leaf.outwardDir, SCNVector3(0,1,0)).normalized(); if side.length() < 0.001 { side = SCNVector3(1,0,0) }; if Bool.random() { side = side * -1 }; lb.leafLateralDir = side
                            } else {
                                if !leaf.isFalling { leafFall(leaf); leavesToCull.append(leaf) }
                                lb.state = .wander; lb.latchedLeaf = nil; lb.targetLeaf = nil
                            }
                        }
                    }
                } else { lb.state = .wander; if let leaf = lb.latchedLeaf, !leaf.isFalling { if leaf.uneatenCount <= 0 { leafFall(leaf); leavesToCull.append(leaf) } }; lb.latchedLeaf = nil; lb.targetLeaf = nil; lb.activeCell = nil; lb.route.removeAll() }
            }
            ladybirds[idx] = lb
        }
        // Remove fully eaten falling leaves from selection pool after processing ladybirds
        if !leavesToCull.isEmpty {
            let ids = Set(leavesToCull.map { $0.id })
            // Track which stems lost all leaves
            for leaf in leavesToCull {
                let stemIdx = leaf.stemIndex
                let stillHasLeaves = leaves.contains { $0.stemIndex == stemIdx && !$0.isFalling }
                if !stillHasLeaves { stemsPendingFade.insert(stemIdx) }
            }
            leaves.removeAll { ids.contains($0.id) }
        }
        // Defer geometry rebuilds: process up to 2 per frame
        let maxRebuildsPerFrame = 1
        var rebuilt = 0
        leavesNeedingRebuild.removeAll { leaf in
            if rebuilt >= maxRebuildsPerFrame || leaf.isFalling { return false }
            rebuilt += 1
            return true
        }
    }

    private func pickLeaf(from lb: Ladybird) -> Leaf? {
        if leaves.isEmpty { return nil }
        // exclude falling leaves
        let candidates = leaves.filter { !$0.isFalling && $0.uneatenCount > 0 }
        if candidates.isEmpty { return nil }
        var best: Leaf? = nil; var bestScore: Float = -Float.infinity
        let sampleSize = min(config.maxLeavesPerLadybirdSearch, candidates.count)
        var sampled = Set<Int>(); while sampled.count < sampleSize { sampled.insert(Int.random(in:0..<candidates.count)) }
        let pos = lb.node.position
        for idx in sampled { let leaf = candidates[idx]; let (anchorPos, _) = pointAndTangent(stemIndex: leaf.stemIndex, atS: leaf.anchorS); let d = (anchorPos - pos).length(); let score = Float(leaf.uneatenCount)*0.6 - d*0.4 + Float.random(in:-0.2...0.2); if score > bestScore { bestScore = score; best = leaf } }
        return best
    }

    private func pointAndTangent(stemIndex: Int, atS s: Float) -> (SCNVector3, SCNVector3) { var remaining = s; let stem = stems[stemIndex]; for seg in stem.segments { if remaining <= seg.length { let t = max(0,min(1,remaining/seg.length)); let pos = seg.start + (seg.end - seg.start)*t; return (pos,(seg.end - seg.start).normalized()) }; remaining -= seg.length }; if let last = stem.segments.last { return (last.end,(last.end - last.start).normalized()) }; return (SCNVector3Zero, SCNVector3(0,1,0)) }

    private func surfacePosition(center: SCNVector3, tangent: SCNVector3, wrapAngle: Float, radius: Float) -> SCNVector3 {
        let t = tangent.normalized()
        var ref = SCNVector3(0,1,0)
        if abs(SCNVector3.dot(ref, t)) > 0.92 { ref = SCNVector3(1,0,0) }
        var ortho = SCNVector3.cross(t, ref).normalized(); if ortho.length() < 1e-4 { ortho = SCNVector3(1,0,0) }
        let bin = SCNVector3.cross(t, ortho).normalized()
        let radial = ortho * cos(wrapAngle) + bin * sin(wrapAngle)
        let bodyRadius: Float = 0.045 * scaleMultiplier
        let clearance = radius + bodyRadius + config.stemClearanceMargin
        return center + radial * clearance
    }

    // remove old single-stem versions of pointAndTangent/surfacePosition (kept names updated above)

    private func randomLateral() -> SCNVector3 { let a = Float.random(in:0..<2*Float.pi); return SCNVector3(cos(a),0,sin(a)) }

    // MARK: - Helpers (restored)
    private func ladybirdColor(index: Int) -> UIColor {
        let base: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemIndigo, .systemPurple]
        return base[index % base.count]
    }
    private func rotationAligning(from: SCNVector3, to: SCNVector3) -> SCNVector4 {
        let f = from.normalized(); let t = to.normalized(); var d = SCNVector3.dot(f,t); d = max(-1,min(1,d)); if d > 0.999 { return SCNVector4(0,1,0,0) }; if d < -0.999 { return SCNVector4(0,1,0,Float.pi) }; let axis = SCNVector3.cross(f,t).normalized(); let angle = acos(d); return SCNVector4(axis.x,axis.y,axis.z,angle)
    }
    private func clamp(_ v: Float, _ a: Float, _ b: Float) -> Float { v < a ? a : (v > b ? b : v) }
    private var leafsByID: [Int: Leaf] { Dictionary(uniqueKeysWithValues: leaves.map { ($0.id, $0) }) }

    // MARK: - LifeformSimulation
    func reset() { setup() }

    // MARK: - Public tracking API (mirrors expected caterpillar interface)
    func segmentCount(caterpillar index: Int) -> Int { index == 0 ? ladybirds.count : 0 }
    func projectedFirstCaterpillarSegmentXY127(segment: Int) -> (x: Int, y: Int)? {
        guard segment >= 0, segment < ladybirds.count else { return nil }
        let ladybird = ladybirds[segment]
        // Preferred: screen-space projection like Jellyfish/MeshBird
        if let scnView = scnView {
            let worldPos = ladybird.node.presentation.worldPosition
            let proj = scnView.projectPoint(worldPos)
            let w = max(scnView.bounds.width, 1)
            let h = max(scnView.bounds.height, 1)
            // Guard against NaN/inf
            if proj.x.isFinite && proj.y.isFinite {
                let xView = CGFloat(proj.x)
                let yView = h - CGFloat(proj.y) // top-left origin
                let x127 = Int(round(min(max(xView, 0), w) / w * 127))
                let y127 = Int(round(min(max(yView, 0), h) / h * 127))
                return (x127, y127)
            }
        }
        // Fallback: world-normalized mapping using dynamic tracker bounds
        let worldPos = ladybird.node.presentation.worldPosition
        let radius = trackerRadius > 0.0001 ? trackerRadius : 6.0
        let rel = worldPos - trackerCenterWorld
        let normalizedX = max(-1, min(1, rel.x / radius))
        let normalizedZ = max(-1, min(1, rel.z / radius))
        let x = Int(round((normalizedX + 1) * 0.5 * 127))
        let y = Int(round((normalizedZ + 1) * 0.5 * 127))
        return (x, y)
    }

    // MARK: - Dynamic controls
    func setScaleMultiplier(_ v: Float) {
        let clamped = clamp(v, 0.3, 3.0)
        guard abs(clamped - scaleMultiplier) > 0.0001 else { return }
        scaleMultiplier = clamped
        // Optimized: batch update ladybird scales instead of searching through child nodes
        for lb in ladybirds {
            if let body = lb.node.childNodes.first,
               let sph = body.geometry as? SCNSphere {
                sph.radius = CGFloat(0.045 * scaleMultiplier)
            }
        }
    }
    func setSpeedMultiplier(_ v: Float) { speedMultiplier = clamp(v, 0.1, 5.0) }
    func currentScaleMultiplier() -> Float { scaleMultiplier }
    func currentSpeedMultiplier() -> Float { speedMultiplier }
    func translate(dx: Float, dy: Float, dz: Float) { rootNode.position.x += dx; rootNode.position.y += dy; rootNode.position.z += dz }
    func setGlobalScale(_ s: Float) { let c = clamp(s, 0.1, 5.0); rootNode.scale = SCNVector3(c,c,c) }
    func currentGlobalScale() -> Float { Float(rootNode.scale.x) }
    func setRotationAngle(_ angleDegrees: Float) { rootNode.eulerAngles.y = angleDegrees * .pi / 180 }

    // MARK: - Low Power Mode
    private var isLowPowerMode: Bool = false
    func setLowPowerMode(_ enabled: Bool) {
        guard enabled != isLowPowerMode else { return }
           isLowPowerMode = enabled
           reset() // rebuild plant
           updatePlantMaterialsForLowPowerMode() // apply low power materials
 //   ()
    }

    private func updatePlantMaterialsForLowPowerMode() {
        // All geometry already uses the simple material, so nothing to do
    }

    
    
    
    // MARK: - Leaf fall animation
    private func leafFall(_ leaf: Leaf) {
        guard !leaf.isFalling else { return }
        leaf.isFalling = true
        
        // Track node for cleanup
        fallingLeafNodes.insert(leaf.container)
        
        // Use pooled action factory
        let dur = config.leafFallDuration
        let fallDist = config.leafFallDistance + Float.random(in: -0.2...0.2)
        let driftX = Float.random(in: -0.4...0.4)
        let driftZ = Float.random(in: -0.4...0.4)
        
        leaf.container.runAction(ActionPool.leafFallAction(driftX: driftX, driftZ: driftZ, fallDist: fallDist, duration: dur))
    }

    // Helper: Fade out all stem nodes for a given stemIndex
    private func fadeOutStem(stemIndex: Int) {
        let fadeAction = ActionPool.stemFadeAction()
        rootNode.enumerateChildNodes { node, _ in
            if let name = node.name, name.hasPrefix("sp_stem_\(stemIndex)_") {
                node.runAction(fadeAction)
            }
        }
    }

    
    // MARK: - Fixed-height spline computation (unit height normalization) ---
    private func normalizeStemsToUnitHeight() {
        guard !stems.isEmpty else { return }
        // Find current height
        let allY = stems.flatMap { $0.control.map { $0.y } }
        guard let minY = allY.min(), let maxY = allY.max(), maxY > minY else { return }
        let height = maxY - minY
        let scale = 1.0 / height
        for stem in stems {
            for i in 0..<stem.control.count {
                stem.control[i].y = (stem.control[i].y - minY) * scale
            }
            // Rebuild segments after normalization
            stem.segments.removeAll()
            stem.totalLength = 0
            for i in 1..<stem.control.count {
                let a = stem.control[i-1]
                let b = stem.control[i]
                let len = (b-a).length()
                stem.segments.append(.init(start: a,end: b,length: len))
                stem.totalLength += len
            }
        }
    }

    // MARK: - Tracker normalization (aligned with Jellyfish)
    private func recalibrateTrackerBounds() {
        if !ladybirds.isEmpty {
            var minX: Float = .infinity, maxX: Float = -.infinity
            var minZ: Float = .infinity, maxZ: Float = -.infinity
            for lb in ladybirds {
                let p = lb.node.presentation.worldPosition
                if p.x < minX { minX = p.x }; if p.x > maxX { maxX = p.x }
                if p.z < minZ { minZ = p.z }; if p.z > maxZ { maxZ = p.z }
            }
            if minX.isFinite, maxX.isFinite, minZ.isFinite, maxZ.isFinite {
                let cx = (minX + maxX) * 0.5
                let cz = (minZ + maxZ) * 0.5
                trackerCenterWorld = SCNVector3(cx, rootNode.presentation.worldPosition.y, cz)
                let radX = max(0.001, (maxX - minX) * 0.5)
                let radZ = max(0.001, (maxZ - minZ) * 0.5)
                trackerRadius = max(radX, radZ)
            }
        } else {
            trackerRadius = max(0.3, visualBounds * 0.5)
            trackerCenterWorld = rootNode.presentation.worldPosition
        }
    }

    func updateTrackerCalibration() {
        frameCounter += 1
        if frameCounter % 30 == 0 { recalibrateTrackerBounds() }
    }

    // MARK: - Route / Proximity Helpers (restored)
    private func branchAttachS(stemIndex: Int) -> Float {
        if stemIndex == 0 { return 0 }
        if let cached = branchAttachSCache[stemIndex] { return cached }
        guard stemIndex > 0, stemIndex < stems.count else { return 0 }
        guard let anchor = stems[stemIndex].control.first else { return 0 }
        let main = stems[0]
        var accum: Float = 0
        for seg in main.segments {
            if (seg.start - anchor).length() < 1e-4 { branchAttachSCache[stemIndex] = accum; return accum }
            let segVec = seg.end - seg.start
            let segLen = segVec.length()
            if segLen > 1e-5 {
                let toAnchor = anchor - seg.start
                let proj = SCNVector3.dot(toAnchor, segVec) / max(1e-5, segLen*segLen)
                if proj > 0 && proj < 1 {
                    let closest = seg.start + segVec * proj
                    if (closest - anchor).length() < 1e-3 {
                        let sVal = accum + segLen * proj
                        branchAttachSCache[stemIndex] = sVal
                        return sVal
                    }
                }
            }
            accum += seg.length
            if (seg.end - anchor).length() < 1e-4 { branchAttachSCache[stemIndex] = accum; return accum }
        }
        branchAttachSCache[stemIndex] = 0
        return 0
    }

    private func closestPointOnStem(stemIndex: Int, to p: SCNVector3) -> (center: SCNVector3, tangent: SCNVector3, s: Float) {
        guard stemIndex >= 0 && stemIndex < stems.count else { return (p, SCNVector3(0,1,0), 0) }
        let stem = stems[stemIndex]
        var bestDist2: Float = .infinity
        var bestPoint = p
        var bestTan = SCNVector3(0,1,0)
        var bestS: Float = 0
        var accum: Float = 0
        for seg in stem.segments {
            let ab = seg.end - seg.start
            let abLen2 = max(1e-6, SCNVector3.dot(ab, ab))
            let ap = p - seg.start
            var t = SCNVector3.dot(ap, ab) / abLen2
            t = max(0, min(1, t))
            let q = seg.start + ab * t
            let diff = q - p
            let d2 = SCNVector3.dot(diff, diff)
            if d2 < bestDist2 {
                bestDist2 = d2
                bestPoint = q
                bestTan = ab.normalized()
                bestS = accum + seg.length * t
            }
            accum += seg.length
        }
        return (bestPoint, bestTan, bestS)
    }

    private func keepLadybirdOutside(_ lbIndex: Int) {
        guard lbIndex >= 0 && lbIndex < ladybirds.count else { return }
        let lb = ladybirds[lbIndex]
        let bodyRadius: Float = 0.045 * scaleMultiplier
        let safety: Float = 0.008
        let stem = stems[lb.stemIndex]
        let (c, tan, _) = closestPointOnStem(stemIndex: lb.stemIndex, to: lb.node.position)
        var offset = lb.node.position - c
        let currentDist = offset.length()
        let minDist = stem.radius + bodyRadius + safety + config.stemClearanceMargin
        if currentDist < minDist || currentDist.isNaN || currentDist < 1e-5 {
            if currentDist < 1e-5 {
                var ref = SCNVector3(0,1,0)
                if abs(SCNVector3.dot(ref, tan)) > 0.9 { ref = SCNVector3(1,0,0) }
                offset = SCNVector3.cross(tan, ref).normalized()
            } else {
                offset = offset / max(1e-5, currentDist)
            }
            lb.node.position = c + offset * minDist
        }
    }

    private func planRoute(for lb: inout Ladybird, to leaf: Leaf) {
        lb.route.removeAll()
        if leaf.stemIndex == lb.stemIndex {
            lb.route.append((lb.stemIndex, leaf.anchorS))
        } else {
            let currentIsMain = (lb.stemIndex == 0)
            let targetIsMain = (leaf.stemIndex == 0)
            if currentIsMain && !targetIsMain {
                let attach = branchAttachS(stemIndex: leaf.stemIndex)
                lb.route.append((0, attach))
                lb.route.append((leaf.stemIndex, leaf.anchorS))
            } else if !currentIsMain && targetIsMain {
                _ = branchAttachS(stemIndex: lb.stemIndex)
                lb.route.append((lb.stemIndex, 0))
                lb.route.append((0, leaf.anchorS))
            } else if !currentIsMain && !targetIsMain {
                let currentAttach = branchAttachS(stemIndex: lb.stemIndex)
                let targetAttach = branchAttachS(stemIndex: leaf.stemIndex)
                lb.route.append((lb.stemIndex, 0))
                lb.route.append((0, currentAttach))
                lb.route.append((0, targetAttach))
                lb.route.append((leaf.stemIndex, leaf.anchorS))
            } else {
                lb.route.append((0, leaf.anchorS))
            }
        }
        var collapsed: [(Int, Float)] = []
        for (sIdx, sVal) in lb.route {
            if let last = collapsed.last, last.0 == sIdx {
                collapsed[collapsed.count - 1].1 = sVal
            } else { collapsed.append((sIdx, sVal)) }
        }
        lb.route = collapsed
    }

    private func ensureSingleAmbientLight() {
        guard let scene = sceneReference else { return }
        var ambientNodes: [SCNNode] = []
        scene.rootNode.enumerateChildNodes { node, _ in
            if let l = node.light, l.type == .ambient { ambientNodes.append(node) }
        }
        if ambientNodes.count == 0 {
            let amb = SCNNode()
            let light = SCNLight(); light.type = .ambient; light.color = UIColor(white:0.6, alpha:1) // Increased for better 3D visibility
            amb.light = light
            scene.rootNode.addChildNode(amb)
        } else if ambientNodes.count > 1 {
            // Keep first, remove extras
            for extra in ambientNodes.dropFirst() { extra.removeFromParentNode() }
            // Ensure first has reasonable intensity/color
            ambientNodes.first?.light?.color = UIColor(white:0.6, alpha:1) // Increased for better 3D visibility
        }
    }
} // end class SimplePlantLadybirdsSimulation
