import SwiftUI
import SceneKit
import QuartzCore


// Custom camera state that initializes with a pan offset
class PannedCameraState: CameraOrbitState {
    init(panX: Float = 0, panY: Float = 0, panZ: Float = 0) {
        super.init()
        self.panOffset = SIMD3<Float>(panX, panY, panZ)
    }
}
/// Holds the state for orbital camera
class CameraOrbitState: ObservableObject {
    @Published var azimuth: Float = 0 // horizontal angle
    @Published var elevation: Float = .pi / 6 // vertical angle
    @Published var radius: Float = 25 // distance from center
    @Published var lastDragValue: CGSize = .zero
    
    // Panning offset from the default center position
    @Published var panOffset: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    
    // Scene constants that can be accessed by other components
    static let maxCoord: Int = 127
    static let sceneScale: Float = 0.09
    
    var visualBounds: Float {
        return Float(Self.maxCoord) * Self.sceneScale
    }
    
    func centerPoint() -> SIMD3<Float> {
        // Center the camera on the origin instead of an offset
        let defaultCenter = SIMD3<Float>(0, 0, 0)
        return defaultCenter + panOffset
    }
    
    func cameraPosition() -> SCNVector3 {
        let center = centerPoint()
        let x = center.x + radius * cos(elevation) * cos(azimuth)
        let y = center.y + radius * sin(elevation)
        let z = center.z + radius * cos(elevation) * sin(azimuth)
        return SCNVector3(x, y, z)
    }
    
    // New properties for rotation constraints and sensitivity
    @Published var enableHorizontalRotation: Bool = true
    @Published var enableVerticalRotation: Bool = true
    var rotationSensitivity: Float = 0.01
    
    // New properties for zoom constraints
    var minRadius: Float = 10
    var maxRadius: Float = 50
    
    // New properties for panning
    @Published var enablePanning: Bool = true
    var panSensitivity: Float = 0.02
    
    // Methods to set initial camera position
    func setInitialPosition(azimuth: Float, elevation: Float, radius: Float) {
        self.azimuth = azimuth
        self.elevation = elevation
        self.radius = min(max(radius, minRadius), maxRadius)
    }
    
    // Set initial position using degrees which may be more intuitive than radians
    func setInitialPositionInDegrees(azimuth: Float, elevation: Float, radius: Float) {
        self.azimuth = azimuth * .pi / 180
        self.elevation = elevation * .pi / 180
        self.radius = min(max(radius, minRadius), maxRadius)
    }
    
    // Methods to control panning
    func setPanOffset(x: Float, y: Float, z: Float) {
        self.panOffset = SIMD3<Float>(x, y, z)
    }
    
    func resetPanOffset() {
        self.panOffset = SIMD3<Float>(0, 0, 0)
    }
    
    // Calculate pan direction vectors in camera space
    func panDirectionVectors() -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        // Right vector (perpendicular to viewing direction in horizontal plane)
        let rightX = -sin(azimuth)
        let rightZ = cos(azimuth)
        let right = SIMD3<Float>(rightX, 0, rightZ)
        
        // Up vector (world up since we want to pan horizontally)
        let up = SIMD3<Float>(0, 1, 0)
        
        return (right, up)
    }
}

// MARK: - Wireframe Cube Scene

/// A reusable 3D scene with a wireframe cube that can be used in different views
struct WireframeCubeSceneView: UIViewRepresentable {
    @ObservedObject var cameraState: CameraOrbitState
    var sceneSetupHandler: ((SCNScene) -> Void)?
    var onSCNViewReady: ((SCNView) -> Void)? = nil // Added callback property
    
    class Coordinator {
        var lastCameraPosition: SCNVector3?
        var lastLookCenter: SCNVector3?
        var lookTargetNode: SCNNode? // reused target for look-at constraint
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    func makeUIView(context: Context) -> SCNView {
        let scnView: SCNView
        if DebugToggles.enableFocusLogging {
            scnView = LoggingSCNView()
        } else {
            scnView = SCNView()
        }
        if DebugToggles.enableFocusLogging {
            #if targetEnvironment(macCatalyst)
            print("[FocusDiag] makeUIView -> class=\(type(of: scnView)) (Mac Catalyst)")
            #else
            print("[FocusDiag] makeUIView -> class=\(type(of: scnView))")
            #endif
        }
        let scene = SCNScene()
        scnView.scene = scene
        scnView.backgroundColor = .black
        scnView.allowsCameraControl = false // Use our own camera controls
        // Catalyst: try to become first responder after a short delay (UIFocus APIs largely no-op here)
        #if targetEnvironment(macCatalyst)
        if DebugToggles.enableFocusLogging {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak scnView] in
                guard let v = scnView else { return }
                let became = v.becomeFirstResponder()
                print("[FocusDiag] Catalyst forced becomeFirstResponder => \(became)")
            }
        }
        #endif
        // Create cube scene
        setupCubeScene(scene: scene)
        
        // Setup camera
        setupCamera(scene: scene)
        
        // Ensure the SCNView uses our camera for rendering and projection
        if let cameraNode = scene.rootNode.childNodes.first(where: { $0.camera != nil }) {
            scnView.pointOfView = cameraNode
            // Seed coordinator cache and optionally create look-at target
            let centerSIMD = cameraState.centerPoint()
            let center = SCNVector3(centerSIMD.x, centerSIMD.y, centerSIMD.z)
            context.coordinator.lastCameraPosition = cameraNode.position
            context.coordinator.lastLookCenter = center
            if DebugToggles.useLookAtConstraint {
                let target = SCNNode()
                target.position = center
                scene.rootNode.addChildNode(target)
                context.coordinator.lookTargetNode = target
                let constraint = SCNLookAtConstraint(target: target)
                constraint.isGimbalLockEnabled = true
                cameraNode.constraints = [constraint]
            } else {
                cameraNode.constraints = nil
                cameraNode.look(at: center)
            }
        }
        
        // Allow custom scene setup by caller
        sceneSetupHandler?(scene)
        
        // Call the callback with the SCNView
        onSCNViewReady?(scnView)
        
        return scnView
    }
    
    private func setupCubeScene(scene: SCNScene) {
        // This method is intentionally left empty. No wireframe cube or geometry is added.
    }
    
    private func setupCamera(scene: SCNScene) {
        let center = cameraState.centerPoint()
        
        // Create camera node
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        
        // Position based on current state
        let position = cameraState.cameraPosition()
        cameraNode.position = position
        cameraNode.camera?.fieldOfView = 75
        if !DebugToggles.useLookAtConstraint {
            cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
        }
        
        scene.rootNode.addChildNode(cameraNode)
    }
    
    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let scene = uiView.scene,
              let cameraNode = scene.rootNode.childNodes.first(where: { $0.camera != nil }) else { return }
        
        let updateBlock = {
            if DebugToggles.disableImplicitAnimations {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0
                CATransaction.setDisableActions(true)
            }
            defer { if DebugToggles.disableImplicitAnimations { SCNTransaction.commit() } }
            
            // Runtime switch: keep constraint usage in sync with toggle
            if DebugToggles.useLookAtConstraint {
                if context.coordinator.lookTargetNode == nil {
                    let target = SCNNode()
                    // seed with last or current center
                    let seedSIMD = self.cameraState.centerPoint()
                    target.position = SCNVector3(seedSIMD.x, seedSIMD.y, seedSIMD.z)
                    scene.rootNode.addChildNode(target)
                    context.coordinator.lookTargetNode = target
                    let constraint = SCNLookAtConstraint(target: target)
                    constraint.isGimbalLockEnabled = true
                    cameraNode.constraints = [constraint]
                    // Force next center update to run
                    context.coordinator.lastLookCenter = nil
                }
            } else {
                if context.coordinator.lookTargetNode != nil || (cameraNode.constraints?.isEmpty == false) {
                    cameraNode.constraints = nil
                    context.coordinator.lookTargetNode?.removeFromParentNode()
                    context.coordinator.lookTargetNode = nil
                    // Force next center update to run
                    context.coordinator.lastLookCenter = nil
                }
            }
            
            let centerSIMD = cameraState.centerPoint()
            let center = SCNVector3(centerSIMD.x, centerSIMD.y, centerSIMD.z)
            let position = cameraState.cameraPosition()
            
            let eps: Float = 1e-4
            var didChange = false
            if DebugToggles.onlyUpdateWhenChanged {
                if let lastPos = context.coordinator.lastCameraPosition {
                    if !lastPos.almostEquals(position, epsilon: eps) {
                        didChange = true
                        if DebugToggles.enableCameraChangeLogging { print("[Camera] position changed -> \(position)") }
                    }
                } else { didChange = true }
                if let lastCenter = context.coordinator.lastLookCenter {
                    if !lastCenter.almostEquals(center, epsilon: eps) {
                        didChange = true
                        if DebugToggles.enableCameraChangeLogging { print("[Camera] center changed -> \(center)") }
                    }
                } else { didChange = true }
            } else { didChange = true }
            
            if didChange || !DebugToggles.onlyUpdateWhenChanged {
                cameraNode.position = position
                if DebugToggles.useLookAtConstraint {
                    if let target = context.coordinator.lookTargetNode { target.position = center }
                } else {
                    cameraNode.look(at: center)
                }
                context.coordinator.lastCameraPosition = position
                context.coordinator.lastLookCenter = center
                if DebugToggles.enableCameraChangeLogging { print("[Camera] applied update (pos=\(position), center=\(center))") }
            }
            
            if didChange, uiView.pointOfView !== cameraNode {
                uiView.pointOfView = cameraNode
            }
        }
        
        if DebugToggles.useAutoreleasePoolPerFrame {
            autoreleasepool { updateBlock() }
        } else {
            updateBlock()
        }
    }
    
    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        guard DebugToggles.cleanTeardown else { return }
        if let scene = uiView.scene,
           let cameraNode = scene.rootNode.childNodes.first(where: { $0.camera != nil }) {
            cameraNode.constraints = nil
        }
        coordinator.lookTargetNode?.removeFromParentNode()
        coordinator.lookTargetNode = nil
        uiView.isPlaying = false
        uiView.pointOfView = nil
        uiView.scene = nil
        uiView.delegate = nil
    }
}

// MARK: - Camera Control View

/// A view that provides camera orbit controls
struct CameraOrbitControlsView: View {
    @ObservedObject var cameraState: CameraOrbitState
    
    var body: some View {
        VStack {
            HStack {
                Spacer()
                // Right rotation
                Button(action: {
                    cameraState.azimuth += .pi/8
                    if cameraState.azimuth > .pi * 2 { cameraState.azimuth -= .pi * 2 }
                }) {
                    Image(systemName: "arrow.right.circle")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .padding(4)
                }
                
                // Left rotation
                Button(action: {
                    cameraState.azimuth -= .pi/8
                    if cameraState.azimuth < 0 { cameraState.azimuth += .pi * 2 }
                }) {
                    Image(systemName: "arrow.left.circle")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .padding(4)
                }
                
                // Up rotation
                Button(action: {
                    cameraState.elevation = min(cameraState.elevation + .pi/8, .pi/2 - 0.01)
                }) {
                    Image(systemName: "arrow.up.circle")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .padding(4)
                }
                
                // Down rotation
                Button(action: {
                    cameraState.elevation = max(cameraState.elevation - .pi/8, -.pi/2 + 0.01)
                }) {
                    Image(systemName: "arrow.down.circle")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .padding(4)
                }
                
                // Optional: Zoom controls
                Button(action: { cameraState.radius = max(cameraState.radius - 5, 10) }) {
                    Image(systemName: "plus.circle")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .padding(4)
                }
                Button(action: { cameraState.radius = min(cameraState.radius + 5, 50) }) {
                    Image(systemName: "minus.circle")
                        .resizable()
                        .frame(width: 32, height: 32)
                        .padding(4)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Gesture Extension

extension View {
    /// Add orbit camera controls to the view
    func orbitGesture(cameraState: CameraOrbitState) -> some View {
        self.gesture(
            // Combine drag gesture (for rotation) with magnification gesture (for zoom)
            SimultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        let delta = CGSize(
                            width: value.translation.width - cameraState.lastDragValue.width,
                            height: value.translation.height - cameraState.lastDragValue.height
                        )
                        
                        // Update azimuth (horizontal rotation) if enabled
                        /*
                        if cameraState.enableHorizontalRotation {
                            cameraState.azimuth += Float(delta.width) * cameraState.rotationSensitivity
                            // Normalize azimuth to keep it in a reasonable range
                            if cameraState.azimuth > .pi * 2 { cameraState.azimuth -= .pi * 2 }
                            if cameraState.azimuth < 0 { cameraState.azimuth += .pi * 2 }
                        }*/
                        
                        // Update elevation (vertical rotation) if enabled
                        if cameraState.enableVerticalRotation {
                            cameraState.elevation -= Float(delta.height) * cameraState.rotationSensitivity
                            
                            // Limit elevation to avoid gimbal lock
                            cameraState.elevation = min(max(cameraState.elevation, -.pi/2 + 0.01), .pi/2 - 0.01)
                        }
                        
                        cameraState.lastDragValue = value.translation
                    }
                    .onEnded { _ in
                        cameraState.lastDragValue = .zero
                    },
                MagnificationGesture()
                    .onChanged { scale in
                        // Calculate new radius based on pinch scale
                        // Decrease radius (zoom in) when scale > 1
                        // Increase radius (zoom out) when scale < 1
                        let zoomFactor = 1 / Float(scale)
                        let newRadius = cameraState.radius * zoomFactor
                        
                        // Respect min and max radius constraints
                        cameraState.radius = min(max(newRadius, cameraState.minRadius), cameraState.maxRadius)
                    }
            )
        )
    }
    
    /// Add axis-constrained orbit controls - specify which axis can be rotated
    func constrainedOrbitGesture(cameraState: CameraOrbitState,
                                 horizontalEnabled: Bool = true,
                                 verticalEnabled: Bool = true) -> some View {
        // Set constraints in the camera state
        let _ = cameraState.enableHorizontalRotation = horizontalEnabled
        let _ = cameraState.enableVerticalRotation = verticalEnabled
        
        // Use the standard orbit gesture which will respect these constraints
        return self.orbitGesture(cameraState: cameraState)
    }
    
    /// Add pan gesture to the view
    func panGesture(cameraState: CameraOrbitState) -> some View {
        self.simultaneousGesture(
            // On iOS, use a gesture that works with two fingers
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard cameraState.enablePanning else { return }
                    
                    let delta = CGSize(
                        width: value.translation.width - cameraState.lastDragValue.width,
                        height: value.translation.height - cameraState.lastDragValue.height
                    )
                    
                    // Get camera space direction vectors
                    let (right, up) = cameraState.panDirectionVectors()
                    
                    // Calculate pan offset change
                    let panDelta = right * Float(-delta.width) * cameraState.panSensitivity +
                                   up * Float(delta.height) * cameraState.panSensitivity
                    
                    // Apply pan offset
                    cameraState.panOffset += panDelta
                    
                    cameraState.lastDragValue = value.translation
                }
                .onEnded { _ in
                    cameraState.lastDragValue = .zero
                }
        )
    }
    
    /// Add zoom gesture to the view
    func zoomGesture(cameraState: CameraOrbitState) -> some View {
        self.simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    let zoomFactor = 1 / Float(scale)
                    let newRadius = cameraState.radius * zoomFactor
                    
                    // Respect min and max radius constraints
                    cameraState.radius = min(max(newRadius, cameraState.minRadius), cameraState.maxRadius)
                }
        )
    }
    
    /// Add all camera controls (orbit, zoom, and pan) to the view
    func fullCameraControls(cameraState: CameraOrbitState) -> some View {
        #if os(iOS)
        // On iOS, combine with a two-finger drag gesture for panning
        return self.orbitGesture(cameraState: cameraState)
            .simultaneousGesture(
                // Use two-finger drag for panning on iOS
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard cameraState.enablePanning else { return }
                        
                        let delta = CGSize(
                            width: value.translation.width - cameraState.lastDragValue.width,
                            height: value.translation.height - cameraState.lastDragValue.height
                        )
                        
                        // Get camera space direction vectors
                        let (right, up) = cameraState.panDirectionVectors()
                        
                        // Calculate pan offset change
                        let panDelta = right * Float(-delta.width) * cameraState.panSensitivity +
                                      up * Float(delta.height) * cameraState.panSensitivity
                        
                        // Apply pan offset
                        cameraState.panOffset += panDelta
                        
                        cameraState.lastDragValue = value.translation
                    }
                    .onEnded { _ in
                        cameraState.lastDragValue = .zero
                    }
            )
        #else
        // On macOS, use the existing panGesture
        return self.orbitGesture(cameraState: cameraState)
            .panGesture(cameraState: cameraState)
        #endif
    }
}
