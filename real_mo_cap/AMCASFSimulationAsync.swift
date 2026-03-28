import Foundation
import SceneKit
import UIKit

// MARK: - Async wrapper similar to MeshBirdSimulationAsync
final class AMCASFSimulationAsync: NSObject, LifeformSimulation, SCNSceneRendererDelegate {
    public let inner: AMCASFSimulation
    weak var scnView: SCNView? { didSet { inner.scnView = scnView; attachRendererIfPossible() } }
    var sceneReference: SCNScene? { get { inner.sceneRef } set { inner.sceneRef = newValue } }
    var visualBounds: Float { inner.visualBounds }

    // Timing state
    private var lastTime: TimeInterval = 0
    private var isPaused: Bool = false
    private var requestedStart: Bool = false
    private var externallyStopped: Bool = false
    private var dtClamp: Float = 1.0/30.0

    // Playback callback (UI tick)
    var perFrameCallback: (() -> Void)?
    private var callbackPending = false

    // Init
    init(scene: SCNScene, scnView: SCNView?) {
        self.inner = AMCASFSimulation(scene: scene, scnView: scnView)
        self.scnView = scnView
        super.init()
        attachRendererIfPossible()
    }

    // MARK: - LifeformSimulation passthrough
    func update(deltaTime: Float) { inner.update(deltaTime: deltaTime) }
    func reset() { inner.reset() }
    func trackerNames() -> [String] { inner.trackerNames() }
    @MainActor func jointWorldPosition(_ name: String) -> SCNVector3? { inner.jointWorldPosition(name) }
    @MainActor func projectedJointXY127(jointName: String) -> (x: Int, y: Int)? { inner.projectedJointXY127(jointName: jointName) }

    // MARK: - Start/Stop
    @MainActor func startAsyncSimulation() {
        requestedStart = true
        externallyStopped = false
        lastTime = 0
        attachRendererIfPossible()
        scnView?.isPlaying = true
    }
    @MainActor func stopAsyncSimulation() { externallyStopped = true }

    @MainActor func setPaused(_ paused: Bool) { isPaused = paused; scnView?.isPlaying = !paused }

    private func attachRendererIfPossible() {
        guard let v = scnView else { return }
        if v.delegate !== self { v.delegate = self }
        if requestedStart && !externallyStopped { v.isPlaying = true }
        if #available(iOS 13.0, *) { v.rendersContinuously = true }
    }

    // MARK: - Loading
    enum LoadState { case idle, loading, ready, failed(Error) }
    @Published private(set) var loadState: LoadState = .idle

    func loadFiles(asfName: String = "09", amcName: String = "09_03") {
        if inner.clip != nil { loadState = .ready; return }
        loadState = .loading
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.inner.loadFromBundle(asfName: asfName, amcName: amcName)
                DispatchQueue.main.async { self.loadState = .ready }
            } catch {
                DispatchQueue.main.async { self.loadState = .failed(error) }
            }
        }
    }

    // MARK: - Renderer Delegate
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if externallyStopped || isPaused || !requestedStart { lastTime = time; return }
        if lastTime == 0 { lastTime = time; return }
        
        // Acquire semaphore to limit concurrent render updates
        RenderCoordinator.shared.renderSemaphore.wait()
        defer { RenderCoordinator.shared.renderSemaphore.signal() }
        
        var dt = Float(time - lastTime); lastTime = time
        if dt > dtClamp { dt = dtClamp }

        inner.update(deltaTime: dt)
        if let cb = perFrameCallback, !callbackPending {
            callbackPending = true
            DispatchQueue.main.async { [weak self] in
                cb(); self?.callbackPending = false
            }
        }
    }

    // MARK: - Public playback controls
    func setPlaying(_ play: Bool) { inner.setPlaying(play) }
    func setSpeed(_ s: Float) { inner.setSpeed(s) }
    func setLooping(_ l: Bool) { inner.setLooping(l) }
    func scrubToFrame(_ f: Int) { inner.scrubToFrame(f) }
    var currentFrameIndex: Int { inner.currentFrameIndex }
    var totalFrames: Int { inner.clip?.frames.count ?? 0 }
    var frameTime: Float { inner.clip?.frameTime ?? 1.0/30.0 }

    // MARK: - Translation for screen bounds constraint
   // func translate(dx: Float, dy: Float, dz: Float) { inner.translate(dx: dx, dy: dy, dz: dz) }
    
    @MainActor func rootBoneScreenXY127Raw() -> (x: Int, y: Int)? {
        inner.projectedJointXY127(jointName: inner.rootBoneName)
    }

    /// Returns the projected Z depth of the root bone (0 = near clip, 1 = far clip).
    @MainActor func rootBoneProjectedZ() -> Float? {
        inner.projectedJointZ(jointName: inner.rootBoneName)
    }

    // MARK: - Root / loop controls passthrough
    func setRooted(_ r: Bool) { inner.setRooted(r) }
    func setRootedX(_ r: Bool) { inner.setRootedX(r) }
    func setRootedY(_ r: Bool) { inner.setRootedY(r) }
    var isRooted: Bool { inner.isRooted }
    var isRootedX: Bool { inner.isRootedX }
    var isRootedY: Bool { inner.isRootedY }
    func setLoopStartFrame(_ f: Int?) { inner.setLoopStartFrame(f) }
    var currentLoopStartFrame: Int { inner.currentLoopStartFrame }
    func setLoopEndFrame(_ f: Int?) { inner.setLoopEndFrame(f) }
    var currentLoopEndFrame: Int? { inner.currentLoopEndFrame }
    func setLoopCrossfadeFrames(_ n: Int) { inner.setLoopCrossfadeFrames(n) }
    func centerRootVertically(screenFraction: Float = 0.65, orthoScale: Float = 30) { inner.centerRootVertically(screenFraction: screenFraction, orthoScale: orthoScale) }
    
    // MARK: - Teardown
    deinit {
        teardownAndDispose()
    }
    
    // MARK: - Teardown
    func teardownAndDispose() {
        perFrameCallback = nil
        scnView?.delegate = nil
        scnView = nil
        sceneReference = nil
        inner.teardownAndDispose()
    }
}
