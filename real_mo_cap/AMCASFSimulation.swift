import Foundation
import SceneKit
import UIKit
import simd // Added for quaternion math

// MARK: - AMC/ASF Data Structures
struct ASFBone {
    let name: String
    let direction: SIMD3<Float>
    let length: Float
    let axisPreRotation: SIMD3<Float> // Euler degrees
    let axisOrder: String             // Rotation order for axis (e.g., "XYZ")
    let dofChannels: [String]
    var children: [String] = []
}

struct AMSFramePose { var channels: [String: [Float]] = [:] }
struct MotionClip { let frameTime: Float; let frames: [AMSFramePose] }

// Parsed model container used by the in-memory cache
struct ParsedAMCASFModel {
    let bones: [String: ASFBone]
    let rootBoneName: String
    let rootBasePosition: SIMD3<Float>
    let parsedRootOrderChannels: [String]?
    let parsedRootAxisOrder: String?
    let parsedRootOrientation: SIMD3<Float>?
    let clip: MotionClip
}

// Simple thread-safe in-memory cache for parsed models keyed by a string identifier
final class AMCASFModelCache {
    static let shared = AMCASFModelCache()
    private var storage: [String: ParsedAMCASFModel] = [:]
    private let queue = DispatchQueue(label: "AMCASFModelCache.queue", attributes: .concurrent)

    func get(_ key: String) -> ParsedAMCASFModel? {
        var r: ParsedAMCASFModel?
        queue.sync { r = storage[key] }
        return r
    }

    func set(_ key: String, _ model: ParsedAMCASFModel) {
        queue.async(flags: .barrier) { self.storage[key] = model }
    }

    func remove(_ key: String) {
        queue.async(flags: .barrier) { self.storage.removeValue(forKey: key) }
    }

    func clear() {
        queue.async(flags: .barrier) { self.storage.removeAll() }
    }
}

import Combine

// Observable holder which loads (once) and publishes a parsed model for use by UI.
final class AMCASFModelHolder: ObservableObject {
    @Published public private(set) var parsedModel: ParsedAMCASFModel? = nil
    @Published public private(set) var isLoading: Bool = false
    private var loadTask: Task<Void, Never>? = nil

    deinit {
        loadTask?.cancel()
    }

    // Load ASF/AMC from bundle (uses cache internally)
    func loadBundle(asfName: String = "09", amcName: String = "09_03") {
        let key = "bundle:\(asfName)|\(amcName)"
        if let cached = AMCASFModelCache.shared.get(key) {
            DispatchQueue.main.async { self.parsedModel = cached }
            return
        }
        isLoading = true
        // Cancel any in-flight task to avoid parallel loads
        loadTask?.cancel()
        loadTask = Task.detached {
            do {
                let scene = SCNScene()
                let sim = AMCASFSimulation(scene: scene, scnView: nil)
                try sim.loadFromBundle(asfName: asfName, amcName: amcName)
                
                if let clip = sim.clip {
                    let parsed = ParsedAMCASFModel(
                        bones: sim.bones,
                        rootBoneName: sim.rootBoneName,
                        rootBasePosition: sim.rootBasePosition,
                        parsedRootOrderChannels: sim.parsedRootOrderChannels,
                        parsedRootAxisOrder: sim.parsedRootAxisOrder,
                        parsedRootOrientation: sim.parsedRootOrientation,
                        clip: clip
                    )
                    AMCASFModelCache.shared.set(key, parsed)
                    
                    await MainActor.run { [weak self] in
                        self?.parsedModel = parsed
                        self?.isLoading = false
                    }
                } else {
                    await MainActor.run { [weak self] in
                        self?.isLoading = false
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isLoading = false
                }
            }
        }
    }

    // Load ASF/AMC from file paths (uses cache)
    func loadFromPaths(asfPath: String, amcPath: String) {
        let key = "path:\(asfPath)|\(amcPath)"
        if let cached = AMCASFModelCache.shared.get(key) {
            DispatchQueue.main.async { self.parsedModel = cached }
            return
        }
        isLoading = true
        // Cancel any in-flight task to avoid parallel loads
        loadTask?.cancel()
        loadTask = Task.detached {
            do {
                let scene = SCNScene()
                let sim = AMCASFSimulation(scene: scene, scnView: nil)
                try sim.load(asfPath: asfPath, amcPath: amcPath)
                
                if let clip = sim.clip {
                    let parsed = ParsedAMCASFModel(
                        bones: sim.bones,
                        rootBoneName: sim.rootBoneName,
                        rootBasePosition: sim.rootBasePosition,
                        parsedRootOrderChannels: sim.parsedRootOrderChannels,
                        parsedRootAxisOrder: sim.parsedRootAxisOrder,
                        parsedRootOrientation: sim.parsedRootOrientation,
                        clip: clip
                    )
                    AMCASFModelCache.shared.set(key, parsed)
                    
                    await MainActor.run { [weak self] in
                        self?.parsedModel = parsed
                        self?.isLoading = false
                    }
                } else {
                    await MainActor.run { [weak self] in
                        self?.isLoading = false
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isLoading = false
                }
            }
        }
    }

    func cancelLoad() { loadTask?.cancel(); loadTask = nil; Task { await MainActor.run { self.isLoading = false } } }
}

// MARK: - Errors
enum AMCASFError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case parseError(String)
    case hierarchyMissing
    case noFrames
    var description: String {
        switch self {
        case .fileNotFound(let f): return "File not found: \(f)"
        case .parseError(let m): return "Parse error: \(m)"
        case .hierarchyMissing: return "Hierarchy section missing"
        case .noFrames: return "No frames parsed"
        }
    }
}

// MARK: - Core Simulation
final class AMCASFSimulation: LifeformSimulation {
    // Scene references
    weak var sceneRef: SCNScene?
    weak var scnView: SCNView?
    let rootNode = SCNNode()

    // Data
    private(set) var bones: [String: ASFBone] = [:]
    var rootBoneName: String = "root"
    private(set) var clip: MotionClip? = nil
    // Root base params from :root
    var rootBasePosition: SIMD3<Float> = .zero
    var parsedRootOrderChannels: [String]? = nil
    var parsedRootAxisOrder: String? = nil
    var parsedRootOrientation: SIMD3<Float>? = nil

    // Nodes
    private var boneNodes: [String: SCNNode] = [:]
    private var linkNodes: [String: SCNNode] = [:]

    // Playback state
    private var currentTime: Float = 0
    private(set) var currentFrameIndex: Int = 0
    private var isPlaying: Bool = true
    private var playbackSpeed: Float = 1.0
    private var looping: Bool = true
    
    // Root anchoring flags (keeps root fixed per-axis when enabled)
    private var rootedX: Bool = true
    private var rootedY: Bool = true
    public var isRootedX: Bool { rootedX }
    public var isRootedY: Bool { rootedY }
    public var isRooted: Bool { rootedX && rootedY }
    public func setRooted(_ r: Bool) { rootedX = r; rootedY = r; applyFrame(currentFrameIndex) }
    public func setRootedX(_ r: Bool) { rootedX = r; applyFrame(currentFrameIndex) }
    public func setRootedY(_ r: Bool) { rootedY = r; applyFrame(currentFrameIndex) }
    
    // Optional loop start frame (inclusive). Defaults to 0 (first frame).
    private var loopStartFrame: Int = 0
    public var currentLoopStartFrame: Int { loopStartFrame }
    public func setLoopStartFrame(_ f: Int?) {
        if let f = f, f >= 0 {
            let maxFrame = (clip?.frames.count ?? 1) - 1
            loopStartFrame = min(f, maxFrame)
        } else {
            loopStartFrame = 0
        }
    }

    // Optional loop end frame (exclusive). If set, animation loops before reaching full length.
    // nil = play the entire clip.
    private var loopEndFrame: Int? = nil
    public var currentLoopEndFrame: Int? { loopEndFrame }
    public func setLoopEndFrame(_ f: Int?) {
        if let clip = clip, let f = f, f > 0 {
            loopEndFrame = min(f, clip.frames.count)
        } else {
            loopEndFrame = nil
        }
    }

    /// Number of frames over which to crossfade from the end of the loop back into the start,
    /// eliminating the visible "jump" at the seam. 0 = no crossfade (hard cut).
    private var loopCrossfadeFrames: Int = 30
    public func setLoopCrossfadeFrames(_ n: Int) { loopCrossfadeFrames = max(0, n) }
    
    // Head joint radius customization
    private var headRadiusScale: Float = 3.0 // multiplier applied only to head joint base sphere radius
    public func setHeadRadiusScale(_ s: Float) {
        headRadiusScale = max(0.01, s)
        // If head node already exists, update its geometry without rebuilding whole skeleton
        if let headNode = boneNodes["head"] {
            let newSphere = SCNSphere(radius: CGFloat(0.5 * boneSphereScale * headRadiusScale))
            newSphere.firstMaterial = makeMaterial(colorForBone("head"))
            headNode.geometry = newSphere
        }
    }

    // Root joint radius customization
    private var rootRadiusScale: Float = 1.5
    public func setRootRadiusScale(_ s: Float) {
        rootRadiusScale = max(0.01, s)
        if let rootNodeGeom = boneNodes[rootBoneName] {
            let newSphere = SCNSphere(radius: CGFloat(0.5 * boneSphereScale * rootRadiusScale))
            newSphere.firstMaterial = makeMaterial(colorForBone(rootBoneName))
            rootNodeGeom.geometry = newSphere
        }
    }

    // Finger/Thumb joint radius customization
    // Heuristics: bone name containing "thumb" -> thumb; containing "finger" or "phal" -> finger
    private var fingerRadiusScale: Float = 1.0
    private var thumbRadiusScale: Float = 0.6

    // Lower-neck joint radius customization (slightly larger by default)
    private var lowerNeckRadiusScale: Float = 1.3

    public func setLowerNeckRadiusScale(_ s: Float) {
        lowerNeckRadiusScale = max(0.01, s)
        for (name, node) in boneNodes where name.lowercased().contains("thorax") {
            let newSphere = SCNSphere(radius: CGFloat(0.5 * boneSphereScale * lowerNeckRadiusScale))
            newSphere.firstMaterial = makeMaterial(colorForBone(name))
            node.geometry = newSphere
        }
    }

    public func setFingerRadiusScale(_ s: Float) {
        fingerRadiusScale = max(0.01, s)
        // Update existing finger nodes live
        for (name, node) in boneNodes where name.lowercased().contains("finger") || name.lowercased().contains("phal") {
            let newSphere = SCNSphere(radius: CGFloat(0.5 * boneSphereScale * fingerRadiusScale))
            newSphere.firstMaterial = makeMaterial(colorForBone(name))
            node.geometry = newSphere
        }
    }

    public func setThumbRadiusScale(_ s: Float) {
        thumbRadiusScale = max(0.01, s)
        for (name, node) in boneNodes where name.lowercased().contains("thumb") {
            let newSphere = SCNSphere(radius: CGFloat(0.5 * boneSphereScale * thumbRadiusScale))
            newSphere.firstMaterial = makeMaterial(colorForBone(name))
            node.geometry = newSphere
        }
    }

    // Visual params
    var visualBounds: Float { 200.0 }
    private let boneSphereScale: Float = 1.0
    private let baseScale: Float = 1.0

    private let directionEpsilon: Float = 1e-6
    private let useParentOffsetRule = true // toggles offset algorithm
    private let maxUserOffset: Float = 60 // cap translation drift
    private var userOffset: SIMD3<Float> = .zero
    private var isDisposed = false

    init(scene: SCNScene, scnView: SCNView?) {
        self.sceneRef = scene
        self.scnView = scnView
        scene.rootNode.addChildNode(rootNode)
    }

    // MARK: Playback control
    func setPlaying(_ play: Bool) { isPlaying = play }
    func setSpeed(_ s: Float) { playbackSpeed = max(0, s) }
    func setLooping(_ l: Bool) { looping = l }
    func scrubToFrame(_ f: Int) {
        guard let clip = clip else { return }
        let clamped = max(0, min(f, clip.frames.count - 1))
        currentFrameIndex = clamped
        currentTime = Float(clamped) * clip.frameTime
        applyFrame(clamped)
    }

    // MARK: Load bundle files (02.asf / 02_03.amc)
    func loadFromBundle(asfName: String = "09", amcName: String = "09_03") throws {
        let cacheKey = "bundle:\(asfName)|\(amcName)"
        if let cached = AMCASFModelCache.shared.get(cacheKey) {
            // restore parsed state from cache
            bones = cached.bones
            rootBoneName = cached.rootBoneName
            rootBasePosition = cached.rootBasePosition
            parsedRootOrderChannels = cached.parsedRootOrderChannels
            parsedRootAxisOrder = cached.parsedRootAxisOrder
            parsedRootOrientation = cached.parsedRootOrientation
            clip = cached.clip
            rebuildScene()
            centerRootVertically()
            applyFrame(0)
            return
        }
        guard let asfURL = Bundle.main.url(forResource: asfName, withExtension: "asf") else { throw AMCASFError.fileNotFound("\(asfName).asf") }
        guard let amcURL = Bundle.main.url(forResource: amcName, withExtension: "amc") else { throw AMCASFError.fileNotFound("\(amcName).amc") }
        let asfData = try String(contentsOf: asfURL)
        let amcData = try String(contentsOf: amcURL)
        try parseASF(asfData)
        try parseAMC(amcData)
        // Prepare gravity range data once clip is available
        computeJointMinMax()
        // cache parsed result if available
        if let parsedClip = clip {
            let parsed = ParsedAMCASFModel(bones: bones, rootBoneName: rootBoneName, rootBasePosition: rootBasePosition, parsedRootOrderChannels: parsedRootOrderChannels, parsedRootAxisOrder: parsedRootAxisOrder, parsedRootOrientation: parsedRootOrientation, clip: parsedClip)
            AMCASFModelCache.shared.set(cacheKey, parsed)
        }
        rebuildScene()
        centerRootVertically()
        applyFrame(0)
    }
    
    // MARK: Load from file paths
    func load(asfPath: String, amcPath: String) throws {
        let cacheKey = "path:\(asfPath)|\(amcPath)"
        if let cached = AMCASFModelCache.shared.get(cacheKey) {
            bones = cached.bones
            rootBoneName = cached.rootBoneName
            rootBasePosition = cached.rootBasePosition
            parsedRootOrderChannels = cached.parsedRootOrderChannels
            parsedRootAxisOrder = cached.parsedRootAxisOrder
            parsedRootOrientation = cached.parsedRootOrientation
            clip = cached.clip
            rebuildScene()
            centerRootVertically()
            applyFrame(0)
            return
        }
        let asfURL = URL(fileURLWithPath: asfPath)
        let amcURL = URL(fileURLWithPath: amcPath)
        let asfData = try String(contentsOf: asfURL)
        let amcData = try String(contentsOf: amcURL)
        try parseASF(asfData)
        try parseAMC(amcData)
        // Prepare gravity range data once clip is available
        computeJointMinMax()
        if let parsedClip = clip {
            let parsed = ParsedAMCASFModel(bones: bones, rootBoneName: rootBoneName, rootBasePosition: rootBasePosition, parsedRootOrderChannels: parsedRootOrderChannels, parsedRootAxisOrder: parsedRootAxisOrder, parsedRootOrientation: parsedRootOrientation, clip: parsedClip)
            AMCASFModelCache.shared.set(cacheKey, parsed)
        }
        rebuildScene()
        centerRootVertically()
        applyFrame(0)
    }

    // MARK: Parsing ASF (robust)
    private func parseASF(_ text: String) throws {
        bones.removeAll()
        var inBoneData = false
        var inHierarchy = false
        var inRoot = false
        var preRotForBone: [String: SIMD3<Float>] = [:]
        var axisOrderForBone: [String: String] = [:]
        var dirForBone: [String: SIMD3<Float>] = [:]
        var lengthForBone: [String: Float] = [:]
        var dofForBone: [String: [String]] = [:]
        var childrenMap: [String: [String]] = [:]
        var encounteredHierarchy = false
        let lines = text.components(separatedBy: .newlines)
        var currentBone: String? = nil
        // Reset root data
        rootBasePosition = .zero
        parsedRootOrderChannels = nil
        parsedRootAxisOrder = nil
        parsedRootOrientation = nil
        for (idx, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix(":") {
                let lower = line.lowercased()
                inRoot = lower.contains(":root")
                inBoneData = lower.contains("bonedata")
                inHierarchy = lower.contains("hierarchy")
                continue
            }
            if inRoot {
                let parts = line.split(separator: " ")
                if parts.isEmpty { continue }
                let key = parts[0].lowercased()
                switch key {
                case "axis":
                    if parts.count >= 2 { parsedRootAxisOrder = String(parts[1]).uppercased() }
                case "order":
                    if parts.count >= 2 { parsedRootOrderChannels = parts.dropFirst().map { String($0).lowercased() } }
                case "position":
                    if parts.count >= 4 {
                        rootBasePosition = SIMD3<Float>(Float(parts[1]) ?? 0, Float(parts[2]) ?? 0, Float(parts[3]) ?? 0)
                    }
                case "orientation":
                    if parts.count >= 4 {
                        parsedRootOrientation = SIMD3<Float>(Float(parts[1]) ?? 0, Float(parts[2]) ?? 0, Float(parts[3]) ?? 0)
                    }
                default: break
                }
                continue
            }
            if inBoneData {
                if line.lowercased() == "begin" { currentBone = nil; continue }
                if line.lowercased() == "end" { currentBone = nil; continue }
                if line.lowercased().hasPrefix("name") {
                    let parts = line.split(separator: " ")
                    guard parts.count >= 2 else { throw AMCASFError.parseError("Malformed bone name at line \(idx): \(line)") }
                    currentBone = String(parts[1]); continue
                }
                guard let bone = currentBone else { continue }
                if line.lowercased().hasPrefix("direction") {
                    let rawParts = line.split(separator: " ")
                    if rawParts.count >= 4 {
                        var vx = Float(rawParts[1]) ?? 0
                        var vy = Float(rawParts[2]) ?? 0
                        var vz = Float(rawParts[3]) ?? 0
                        if abs(vx) < directionEpsilon { vx = 0 }
                        if abs(vy) < directionEpsilon { vy = 0 }
                        if abs(vz) < directionEpsilon { vz = 0 }
                        let vec = SIMD3<Float>(vx, vy, vz)
                        dirForBone[bone] = vec
                    } else { continue }
                } else if line.lowercased().hasPrefix("length") {
                    let parts = line.split(separator: " ")
                    guard parts.count >= 2 else { throw AMCASFError.parseError("Malformed length for bone \(bone) line \(idx): \(line)") }
                    lengthForBone[bone] = Float(parts[1]) ?? 0
                } else if line.lowercased().hasPrefix("axis") {
                    let parts = line.split(separator: " ")
                    // Format: axis x y z ORDER (values are for X,Y,Z; order is used for composition only)
                    if parts.count >= 5 {
                        let x = Float(parts[1]) ?? 0
                        let y = Float(parts[2]) ?? 0
                        let z = Float(parts[3]) ?? 0
                        let order = String(parts[4]).uppercased()
                        axisOrderForBone[bone] = order
                        preRotForBone[bone] = SIMD3<Float>(x, y, z)
                    }
                } else if line.lowercased().hasPrefix("dof") {
                    let parts = line.split(separator: " ").dropFirst(); dofForBone[bone] = parts.map { String($0) }
                }
            } else if inHierarchy {
                encounteredHierarchy = true
                if line.lowercased() == "begin" || line.lowercased() == "end" { continue }
                let parts = line.split(separator: " ")
                guard parts.count >= 2 else { throw AMCASFError.parseError("Malformed hierarchy line \(idx): \(line)") }
                let parent = String(parts[0])
                let children = parts.dropFirst().map { String($0) }
                childrenMap[parent, default: []].append(contentsOf: children)
            }
        }
        if !encounteredHierarchy { throw AMCASFError.hierarchyMissing }
        // Build bones
        for (boneName, dir) in dirForBone {
            let len = lengthForBone[boneName] ?? 0
            var axis = preRotForBone[boneName] ?? .zero
            var axisOrder = axisOrderForBone[boneName] ?? "XYZ"
            var dofs = dofForBone[boneName] ?? []
            if boneName == rootBoneName {
                // Root axis uses :root orientation and axis order
                axis = parsedRootOrientation ?? axis
                axisOrder = parsedRootAxisOrder ?? axisOrder
                if let rootOrder = parsedRootOrderChannels { dofs = rootOrder }
                else {
                    for t in ["tx","ty","tz"] where !dofs.contains(t) { dofs.insert(t, at: 0) }
                    for r in ["rx","ry","rz"] where !dofs.contains(r) { dofs.append(r) }
                }
            }
            bones[boneName] = ASFBone(name: boneName, direction: dir, length: len, axisPreRotation: axis, axisOrder: axisOrder, dofChannels: dofs, children: childrenMap[boneName] ?? [])
        }
        // If root was not part of bonedata, ensure it exists using :root values
        if bones[rootBoneName] == nil {
            let dofs = parsedRootOrderChannels ?? ["tx","ty","tz","rx","ry","rz"]
            bones[rootBoneName] = ASFBone(name: rootBoneName, direction: .zero, length: 0, axisPreRotation: parsedRootOrientation ?? .zero, axisOrder: parsedRootAxisOrder ?? "XYZ", dofChannels: dofs, children: childrenMap[rootBoneName] ?? [])
        }
        // Add parents missing from bone list
        for (parent, kids) in childrenMap where bones[parent] == nil {
            bones[parent] = ASFBone(name: parent, direction: SIMD3<Float>(0,0,0), length: 0, axisPreRotation: .zero, axisOrder: "XYZ", dofChannels: [], children: kids)
        }
        // Ensure children arrays are updated for existing parents
        for (parent, kids) in childrenMap { if var b = bones[parent] { b.children = kids; bones[parent] = b } }
    }

    // MARK: Parsing AMC
    private func parseAMC(_ text: String) throws {
        var frames: [AMSFramePose] = []
        var currentFrame: AMSFramePose? = nil
        let lines = text.components(separatedBy: .newlines)
        var frameTime: Float = 1.0/30.0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.lowercased().hasPrefix("frametime") {
                let parts = line.split(separator: " ")
                if parts.count >= 2 { frameTime = Float(parts[1]) ?? frameTime }
                continue
            }
            if let _ = Int(line) { // new frame index line
                if let f = currentFrame { frames.append(f) }
                currentFrame = AMSFramePose(); continue
            }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { continue }
            let boneName = String(parts[0])
            let values = parts.dropFirst().map { Float($0) ?? 0 }
            currentFrame?.channels[boneName] = values
        }
        if let f = currentFrame { frames.append(f) }
        guard !frames.isEmpty else { throw AMCASFError.noFrames }
        clip = MotionClip(frameTime: frameTime, frames: frames)
        currentTime = 0; currentFrameIndex = 0
    }

    // MARK: Scene Build
    private func rebuildScene() {
        rootNode.enumerateChildNodes { n,_ in n.removeFromParentNode() }
        boneNodes.removeAll(); linkNodes.removeAll()
        rootNode.position = .zero
        addLightsIfNeeded()
        guard bones[rootBoneName] != nil else { return }
        buildBoneNodeRecursive(rootBoneName)
    }

    // Returns true if this bone should be ignored (not built/updated or exposed)
    private func isIgnoredBone(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("finger") || n.contains("thumb") //|| n.contains("toe") //|| n.contains("phal")
    }

    private func buildBoneNodeRecursive(_ name: String) {
        guard let bone = bones[name] else { return }
        // Skip fingers/thumbs/toes (and their sub-branches)
        if isIgnoredBone(name) { return }
        let node = SCNNode()
        // Determine base radius per-bone. Special cases: head, thumb, fingers
        let lname = name.lowercased()
        let baseRadiusScale: Float = {
            // Root joint special size
            if name == rootBoneName { return 0.5 * boneSphereScale * rootRadiusScale }
            // Lower neck slightly larger
            if lname.contains("lowerneck") { return 0.5 * boneSphereScale * lowerNeckRadiusScale }
            if lname.contains("head") { return 0.5 * boneSphereScale * headRadiusScale }
            if lname.contains("thumb") { return 0.5 * boneSphereScale * thumbRadiusScale }
            if lname.contains("finger") || lname.contains("phal") { return 0.5 * boneSphereScale * fingerRadiusScale }
            return 0.5 * boneSphereScale
        }()
         let sphere = SCNSphere(radius: CGFloat(baseRadiusScale))
         sphere.firstMaterial = makeMaterial(colorForBone(name))
         node.geometry = sphere
        boneNodes[name] = node
        if name == rootBoneName {
            rootNode.addChildNode(node)
        } else if let parentName = findParent(of: name), let parentNode = boneNodes[parentName], let parentBone = bones[parentName] {
            // Offset rule: use parent bone's direction * parent length (common ASF usage) else fallback to child's own direction
            var offsetDir = useParentOffsetRule ? parentBone.direction : bone.direction
            let magSq = lengthSquared(offsetDir)
            if magSq < directionEpsilon || parentBone.length == 0 { offsetDir = SIMD3<Float>(0,0,0) } // leave at pivot without artificial raise
            let offset = offsetDir * parentBone.length * baseScale
            node.position = SCNVector3(offset.x, offset.y, offset.z)
            parentNode.addChildNode(node)
            if magSq >= directionEpsilon && parentBone.length > 0 {
                let cylNode = cylinderBetween(.zero, SCNVector3(offset.x, offset.y, offset.z), radius: 0.35)
                parentNode.addChildNode(cylNode); linkNodes[parentName+"->"+name] = cylNode
            }
        } else {
            rootNode.addChildNode(node)
        }
        for child in bone.children { buildBoneNodeRecursive(child) }
    }

    private func findParent(of child: String) -> String? { for (n,b) in bones where b.children.contains(child) { return n }; return nil }

    private func colorForBone(_ name: String) -> UIColor {
        BoneColor.uiColor(for: name)
    }
    private func makeMaterial(_ color: UIColor) -> SCNMaterial { let m = SCNMaterial(); m.diffuse.contents = color; m.lightingModel = .blinn; return m }

    private func cylinderBetween(_ a: SCNVector3, _ b: SCNVector3, radius: Float) -> SCNNode {
        let dir = b - a; let h = dir.length(); let cyl = SCNCylinder(radius: CGFloat(radius), height: CGFloat(h))
        cyl.firstMaterial = makeMaterial(.white.withAlphaComponent(0.8))
        let node = SCNNode(geometry: cyl); node.position = a; node.pivot = SCNMatrix4MakeTranslation(0, -Float(h/2.0), 0)
        let direction = dir.normalized(); if !direction.isZeroVector {
            let yAxis = SCNVector3(0,1,0); let axis = SCNVector3.cross(yAxis, direction)
            let angle = acos(max(-1, min(1, SCNVector3.dot(yAxis, direction))))
            if !axis.isZeroVector { node.rotation = SCNVector4(axis.x, axis.y, axis.z, angle) }
        }
        return node
    }

    private func addLightsIfNeeded() {
        guard let scene = sceneRef else { return }
        if scene.rootNode.childNodes.contains(where: { $0.light?.type == .ambient }) { return }
        let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient; amb.light?.color = UIColor(white: 0.3, alpha: 1); scene.rootNode.addChildNode(amb)
        let dir = SCNNode(); dir.light = SCNLight(); dir.light?.type = .directional; dir.light?.color = UIColor(white: 0.8, alpha: 1); dir.position = SCNVector3(10,10,10); dir.eulerAngles = SCNVector3(-Float.pi/4, Float.pi/4, 0); scene.rootNode.addChildNode(dir)
    }

    // MARK: Frame stepping
    func update(deltaTime dt: Float) {
        guard !isDisposed else { return }
        guard let clip = clip else { return }
        if isPlaying {
            currentTime += dt * playbackSpeed
            let frameTime = clip.frameTime
            if frameTime > 0 {
                var frameIdx = Int(floor(currentTime / frameTime))
                let start = loopStartFrame
                let end = loopEndFrame ?? clip.frames.count
                if frameIdx >= end {
                    if looping {
                        let range = max(end - start, 1)
                        frameIdx = start + ((frameIdx - start) % range)
                        currentTime = Float(frameIdx) * frameTime
                    } else {
                        frameIdx = end - 1
                        isPlaying = false
                    }
                }
                if frameIdx != currentFrameIndex { currentFrameIndex = frameIdx; applyFrame(frameIdx) }
            }
        }
    }

    func reset() { let start = loopStartFrame; currentTime = Float(start) * (clip?.frameTime ?? 0); currentFrameIndex = start; userOffset = .zero; if clip != nil { applyFrame(start) } }

    /// Adjusts rootBasePosition.y so the root bone sits at the given vertical screen fraction
    /// (0 = bottom of view, 0.5 = centre, 1 = top) based on the ty value of the current loop start frame.
    /// `orthoScale` is the camera's orthographicScale (half the visible vertical extent in world units).
    func centerRootVertically(screenFraction: Float = 0.65, orthoScale: Float = 30) {
        guard let clip = clip else { return }
        let startFrame = loopStartFrame
        guard startFrame < clip.frames.count else { return }
        guard let bone = bones[rootBoneName] else { return }
        let pose = clip.frames[startFrame]
        guard let values = pose.channels[rootBoneName] else { return }
        // Extract ty from the start frame
        var ty: Float = 0
        for (i, ch) in bone.dofChannels.enumerated() where i < values.count {
            if ch == "ty" { ty = values[i]; break }
        }
        // screenFraction 0.5 = centre (Y=0), 0 = bottom (-orthoScale), 1 = top (+orthoScale)
        // targetY = (screenFraction * 2 - 1) * orthoScale  →  e.g. 0.65 → 0.3 * orthoScale
        let targetY = (screenFraction * 2.0 - 1.0) * orthoScale
        rootBasePosition.y = targetY - ty
    }
    private func quatFromEuler(anglesDeg: SIMD3<Float>, order: String) -> simd_quatf {
        let angles = anglesDeg * (.pi/180)
        var q = simd_quatf(angle: 0, axis: SIMD3<Float>(1,0,0)) // identity
        for ch in order.uppercased() {
            switch ch {
            case "X": q = simd_quatf(angle: angles.x, axis: SIMD3<Float>(1,0,0)) * q
            case "Y": q = simd_quatf(angle: angles.y, axis: SIMD3<Float>(0,1,0)) * q
            case "Z": q = simd_quatf(angle: angles.z, axis: SIMD3<Float>(0,0,1)) * q
            default: break
            }
        }
        return simd_normalize(q)
    }

    private func quatFromDOF(channels: [String], valuesDeg: [Float]) -> simd_quatf {
        var q = simd_quatf(angle: 0, axis: SIMD3<Float>(1,0,0)) // identity
        for (i, ch) in channels.enumerated() where i < valuesDeg.count {
            let vRad = valuesDeg[i] * (.pi/180)
            switch ch {
            case "rx": q = simd_quatf(angle: vRad, axis: SIMD3<Float>(1,0,0)) * q
            case "ry": q = simd_quatf(angle: vRad, axis: SIMD3<Float>(0,1,0)) * q
            case "rz": q = simd_quatf(angle: vRad, axis: SIMD3<Float>(0,0,1)) * q
            default: continue // ignore translations here
            }
        }
        return simd_normalize(q)
    }

    // Gravity/weight effect parameters
    private var gravityLow: Float = 0.8
    private var gravityHigh: Float = 1.2
    public var gravityEnabled: Bool = true
    private var jointMinMax: [String: (min: Float, max: Float)] = [:]
    // New: per-channel min/max for each joint (e.g., ["knee"]["rx"]) = (min,max)
    private var jointChannelMinMax: [String: [String: (min: Float, max: Float)]] = [:]
    // Only apply gravity scaling to these channel names by default. Choose rotation X (pitch) for bobbing effect.
    private var gravityAllowedChannels: Set<String> = ["rx"]
    public func setGravityAllowedChannels(_ channels: [String]) { gravityAllowedChannels = Set(channels.map { $0.lowercased() }) }

    // Slider-driven gravity control: amount in [0,5] step 0.5. Each 0.5 step widens the window by 0.25 on each side.
    public func setGravity(amount: Float) {
        // Round to nearest 0.5 step
        let stepped = (amount * 2).rounded() / 2.0
        // Compute number of half-steps
        let steps = max(0.0, min(10.0, stepped / 0.5)) // 0..10 for 0..5
        let delta = 0.05 * steps
        // Center around 1.0 (no effect) and widen with steps
        var low = 1.0 - delta
        var high = 1.0 + delta
        // Clamp to safe bounds to avoid sign inversions and extreme amplification
        if low < 0.1 { low = 0.1 }
        if high > 1.3 { high = 1.3 }
        gravityLow = Float(low)
        gravityHigh = Float(high)
        gravityEnabled = stepped > 0
        // Ensure ranges available when enabling
        if gravityEnabled && jointMinMax.isEmpty { computeJointMinMax() }
        // Reapply current frame to reflect changes immediately
        applyFrame(currentFrameIndex)
    }

    // Call this after loading the clip
    public func computeJointMinMax() {
        jointMinMax.removeAll()
        jointChannelMinMax.removeAll()
        guard let clip = clip else { return }
        for (name, _) in bones {
            var minV: Float = .greatestFiniteMagnitude
            var maxV: Float = -.greatestFiniteMagnitude
            var channelDict: [String: (min: Float, max: Float)] = [:]
            for frame in clip.frames {
                if let values = frame.channels[name] {
                    // Update overall joint min/max
                    for v in values { minV = min(minV, v); maxV = max(maxV, v) }
                    // Update per-channel min/max using bone's channel labels
                    if let bone = bones[name] {
                        let count = min(values.count, bone.dofChannels.count)
                        for i in 0..<count {
                            let ch = bone.dofChannels[i]
                            let v = values[i]
                            if let mm = channelDict[ch] {
                                channelDict[ch] = (min(mm.min, v), max(mm.max, v))
                            } else {
                                channelDict[ch] = (v, v)
                            }
                        }
                    }
                }
            }
            if minV < maxV {
                jointMinMax[name] = (minV, maxV)
            }
            if !channelDict.isEmpty {
                jointChannelMinMax[name] = channelDict
            }
        }
    }

    private func applyFrame(_ frame: Int) {
        guard let clip = clip, frame >= 0, frame < clip.frames.count else { return }
        guard !isDisposed else { return }
        // Lazily compute ranges if gravity is enabled and not yet computed
        if gravityEnabled && jointChannelMinMax.isEmpty { computeJointMinMax() }
        let pose = clip.frames[frame]

        // --- Loop crossfade blending ---
        // If we're within the last `loopCrossfadeFrames` before the loop end,
        // blend this frame's channel values toward the loop-start frame to eliminate the seam.
        let endFrame = loopEndFrame ?? clip.frames.count
        let startFrame = loopStartFrame
        let crossfadeRegionStart = endFrame - loopCrossfadeFrames
        let blendFactor: Float  // 0 = use current frame as-is, 1 = fully at start frame
        let startPose: AMSFramePose?
        if looping && loopCrossfadeFrames > 0 && frame >= crossfadeRegionStart && frame < endFrame && startFrame < clip.frames.count {
            // t goes from 0.0 (at crossfadeRegionStart) to 1.0 (at endFrame-1)
            let framesIntoFade = frame - crossfadeRegionStart
            blendFactor = Float(framesIntoFade + 1) / Float(loopCrossfadeFrames)
            startPose = clip.frames[startFrame]
        } else {
            blendFactor = 0
            startPose = nil
        }

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }

        for name in Array(bones.keys) {
            guard let bone = bones[name] else { continue }
            guard let node = boneNodes[name] else { continue }
            guard var values = pose.channels[name] else { continue }
            // --- Apply crossfade blend toward start frame ---
            // For rotation channels, use shortest-path angle interpolation (wrap ±180°)
            // to prevent wild spinning when accumulated angles differ by large amounts.
            if blendFactor > 0, let sp = startPose, let startValues = sp.channels[name] {
                let count = min(values.count, startValues.count)
                let channelCount = bone.dofChannels.count
                for i in 0..<count {
                    let ch = i < channelCount ? bone.dofChannels[i] : ""
                    let isRotation = ch == "rx" || ch == "ry" || ch == "rz"
                    if isRotation {
                        // Shortest-path angle interpolation:
                        // Wrap the difference to ±180° so we always take the short way around
                        var diff = startValues[i] - values[i]
                        diff = diff.truncatingRemainder(dividingBy: 360)
                        if diff > 180 { diff -= 360 }
                        else if diff < -180 { diff += 360 }
                        values[i] = values[i] + diff * blendFactor
                    } else {
                        // Translation and other channels: direct linear interpolation
                        values[i] = values[i] + (startValues[i] - values[i]) * blendFactor
                    }
                }
            }
            var scaledValues = values
            if gravityEnabled {
                // Scale per channel using its own min/max for this joint
                if let chDict = jointChannelMinMax[name] {
                    let count = min(values.count, bone.dofChannels.count)
                    for i in 0..<count {
                        let ch = bone.dofChannels[i]
                        let v = values[i]
                        // Apply only to allowed channels (default: rx) and never to root bone to avoid whole-body steering
                        if name != rootBoneName, gravityAllowedChannels.contains(ch), let mm = chDict[ch], (mm.max - mm.min) > 0 {
                             let t = (v - mm.min) / (mm.max - mm.min)
                             let scale = gravityLow + (gravityHigh - gravityLow) * t
                             scaledValues[i] = v * scale
                         } else {
                             // Fallback: neutral scaling
                             scaledValues[i] = v
                         }
                    }
                }
            }
            let qC = quatFromEuler(anglesDeg: bone.axisPreRotation, order: bone.axisOrder)
            let qM = quatFromDOF(channels: bone.dofChannels, valuesDeg: scaledValues)
            let qR = name == rootBoneName
                ? simd_normalize(simd_inverse(qC) * qM * qC)
                : simd_normalize(qC * qM * simd_inverse(qC))
            if name == rootBoneName {
                var t = SIMD3<Float>(0,0,0)
                for (i,ch) in bone.dofChannels.enumerated() where i < scaledValues.count {
                    let v = scaledValues[i]
                    switch ch { case "tx": t.x = v; case "ty": t.y = v; case "tz": t.z = v; default: break }
                }
                let base = SIMD3<Float>(
                    rootedX ? 0 : t.x,
                    rootedY ? 0 : t.y,
                    rootedX ? 0 : t.z   // Z follows X (horizontal plane)
                ) + rootBasePosition
                node.simdPosition = base
            }
            node.simdOrientation = qR
        }
    }

    // MARK: Tracker API
    // MARK: LifeformSimulation extras
    func trackerNames() -> [String] {
        guard !isDisposed else { return ["frame.index"] }
        var arr: [String] = boneNodes.keys.flatMap { ["\($0).x","\($0).y"] }
        arr.append("frame.index")
        return arr.sorted()
    }
    func jointWorldPosition(_ name: String) -> SCNVector3? {
        guard !isDisposed else { return nil }
        if name == "frame.index" { return nil }
        let bone = name.split(separator: ".").first.map(String.init) ?? ""
        return boneNodes[bone]?.worldPosition
    }
    func projectedJointXY127(jointName: String) -> (x: Int, y: Int)? {
        guard !isDisposed else { return nil }
        guard let scnView = scnView, let node = boneNodes[jointName] else { return nil }
        let p = scnView.projectPoint(node.worldPosition); let w = max(scnView.bounds.width,1); let h = max(scnView.bounds.height,1)
        let nx = max(0,min(1,CGFloat(p.x)/w)); let ny = max(0,min(1,1 - CGFloat(p.y)/h))
        return (Int(round(nx*127)), Int(round(ny*127)))
    }

    /// Returns the projected-space Z depth of a joint (0 = near clip, 1 = far clip).
    /// Values <= 0 mean the joint is behind / at the near clip plane (clipped).
    func projectedJointZ(jointName: String) -> Float? {
        guard !isDisposed else { return nil }
        guard let scnView = scnView, let node = boneNodes[jointName] else { return nil }
        let p = scnView.projectPoint(node.worldPosition)
        return p.z
    }

    // MARK: Teardown
    func teardownAndDispose() {
        isDisposed = true
        rootNode.removeAllActions(); rootNode.enumerateChildNodes { n,_ in
            n.removeAllActions()
            n.geometry = nil
            n.removeFromParentNode()
        }
        boneNodes.removeAll(); linkNodes.removeAll(); bones.removeAll(); clip = nil
        jointMinMax.removeAll()
            jointChannelMinMax.removeAll()
            userOffset = .zero
            // Break scene references
            rootNode.removeFromParentNode()
        sceneRef = nil; scnView = nil
    }
}

// MARK: - Vector helpers
// Removed duplicate SCNVector3 operators (defined globally in SCNVector3Extensions.swift)
extension SIMD3 where Scalar == Float { static func *(lhs: SIMD3<Float>, rhs: Float) -> SIMD3<Float> { SIMD3<Float>(lhs.x*rhs, lhs.y*rhs, lhs.z*rhs) } }

extension AMCASFSimulation {
    private func lengthSquared(_ v: SIMD3<Float>) -> Float { v.x*v.x + v.y*v.y + v.z*v.z }
    private func length(_ v: SIMD3<Float>) -> Float { sqrt(lengthSquared(v)) }
}
