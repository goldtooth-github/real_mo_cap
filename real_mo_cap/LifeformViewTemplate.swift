// LifeformViewTemplate.swift
// Reusable template for all lifeform views with consistent parameters
import SwiftUI
import SceneKit

// Configuration structure for lifeform simulation parameters
struct LifeformViewConfig {
    // Camera parameters
    var initialAzimuth: Double = 0     // Initial horizontal angle in degrees
    var initialElevation: Double = 30   // Initial vertical angle in degrees
    var initialRadius: Double = 15      // Initial distance from center
    var minRadius: Double = 8           // Minimum zoom distance
    var maxRadius: Double = 30          // Maximum zoom distance
    
    // Camera control options
    enum CameraControlMode {
        case fixed              // No camera movement allowed
        case orbitOnly          // Only orbit around the center point (traditional rotation)
        case orbitWithPan       // Orbit with ability to pan the center point
        case fullControl        // Complete camera control (orbit, pan, zoom)
        case nicks_control    // Nick's custom control: horizontal-only rotation
       
        // Helper properties for individual control components
        var allowsHorizontalRotation: Bool { self != .fixed }
        var allowsVerticalRotation: Bool { self != .fixed }
        var allowsPanning: Bool { self == .orbitWithPan || self == .fullControl }
        var allowsZooming: Bool { self != .fixed }
    }
    
    var cameraControlMode: CameraControlMode = .nicks_control
    var rotationSensitivity: Double = 0.1   // How sensitive rotation is to gestures
    var panSensitivity: Double = 0.02        // How sensitive panning is to gestures
    
    // Legacy compatibility property
    @available(*, deprecated, message: "Use cameraControlMode instead")
    var allowFullRotation: Bool {
        get {
            return cameraControlMode != .orbitOnly && cameraControlMode != .fixed
        }
        set {
            cameraControlMode = newValue ? .fullControl : .orbitOnly
        }
    }
    
    // Lighting parameters
    var ambientLightIntensity: Double = 0.4
    var directionalLightIntensity: Double = 0.8
    var directionalLightAngles: SCNVector3 = SCNVector3(x: -.pi / 4, y: .pi / 4, z: 0)
    // New: disables ambient/directional lights if true
    var disableSceneLights: Bool = false
    
    // Simulation parameters
    var updateInterval: TimeInterval = 0.016 // ~60fps
    
    // UI parameters
    var title: String = "Lifeform Simulation"
    var description: String = ""
    var controlPanelColor: Color = Color.black.opacity(0.6)
    var controlTextColor: Color = .white
    var buttonBackgroundColor: Color = Color.blue.opacity(0.6)
    var controlPanelBottomInset: CGFloat = 10 // Bottom inset for control panel
    
    // App-wide initial offset for field/container
    var initialFieldOffset: SCNVector3 = SCNVector3(0, 0, 0)
}

// Protocol that all lifeform simulation classes should conform to
protocol LifeformSimulation {
    func update(deltaTime: Float)
    func reset()
}

// Generic lifeform view that can be used with any simulation type
struct GenericLifeformView<SimulationType: LifeformSimulation>: View {
    // Configuration for the view
    var config: LifeformViewConfig
    
    // Function to create the simulation
    var createSimulation: (SCNScene) -> SimulationType
    
    // Optional control view builder
    var controlsBuilder: ((Binding<SimulationType?>) -> AnyView)?
    
    // Camera state
    @StateObject private var cameraState = CameraOrbitState()
    
    // Store simulation reference
    @State private var simulation: SimulationType?
    
    // Store timer reference
    @State private var simulationTimer: Timer?
    
    var body: some View {
        ZStack {
            // Use the wireframe cube scene with our simulation
            WireframeCubeSceneView(
                cameraState: cameraState,
                sceneSetupHandler: { scene in
                    // Set initial camera position
                    cameraState.setInitialPositionInDegrees(
                        azimuth: Float(config.initialAzimuth),
                        elevation: Float(config.initialElevation),
                        radius: Float(config.initialRadius)
                    )
                    cameraState.minRadius = Float(config.minRadius)
                    cameraState.maxRadius = Float(config.maxRadius)
                    
                    // Set up lighting
                    setupLighting(in: scene)
                    
                    // Always create a new simulation when scene is set up
                    simulationTimer?.invalidate()
                    let newSimulation = createSimulation(scene)
                    self.simulation = newSimulation
                    
                    // Start simulation timer
                    startSimulationTimer()
                }
            )
            .edgesIgnoringSafeArea(.all)
            // Add camera control gestures based on configuration
            .modifier(CameraControlModifier(
                cameraState: cameraState,
                cameraControlMode: config.cameraControlMode
            ))
            
            VStack {
                Spacer()
                
                // Controls panel
                VStack(spacing: 12) {
                    Text(config.title)
                        .font(.headline)
                        .foregroundColor(config.controlTextColor)
                    
                    // Custom controls if provided
                    if let controlsBuilder = controlsBuilder {
                        controlsBuilder(Binding(
                            get: { simulation },
                            set: { simulation = $0 }
                        ))
                    }
                    
                    Text(config.description)
                        .font(.caption)
                        .foregroundColor(config.controlTextColor.opacity(0.8))
                    
                    Button(action: {
                        simulation?.reset()
                    }) {
                        Text("R")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(config.buttonBackgroundColor)
                            .cornerRadius(8)
                            .foregroundColor(config.controlTextColor)
                    }
                }
                .id("controlPanel")
                .transaction { tx in tx.disablesAnimations = true }
                .padding()
                .background(config.controlPanelColor)
                .cornerRadius(10)
                .padding(.bottom)
            }
        }
        .onAppear {
            // Make sure timer is started when view appears
            if simulationTimer == nil {
                startSimulationTimer()
            }
        }
        .onDisappear {
            // Stop and clean up the timer when view disappears
            simulationTimer?.invalidate()
            simulationTimer = nil
            simulation = nil
        }
    }
    
    // Function to start the simulation timer
    private func startSimulationTimer() {
        // Stop any existing timer first
        simulationTimer?.invalidate()
        
        // Create a new timer and store it
        guard let sim = simulation else { return }
        let timer = Timer(timeInterval: config.updateInterval, repeats: true) { _ in
            sim.update(deltaTime: Float(config.updateInterval))
        }
        
        // Store reference to timer
        simulationTimer = timer
        
        // Add to run loop
        RunLoop.main.add(timer, forMode: .common)
    }
    
    private func setupLighting(in scene: SCNScene) {
        // Ambient light for overall illumination
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.color = UIColor(white: CGFloat(config.ambientLightIntensity), alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)
        
        // Directional light for shadows and better definition
        let directionalLight = SCNNode()
        directionalLight.light = SCNLight()
        directionalLight.light?.type = .directional
        directionalLight.light?.color = UIColor(white: CGFloat(config.directionalLightIntensity), alpha: 1.0)
        directionalLight.eulerAngles = config.directionalLightAngles
        scene.rootNode.addChildNode(directionalLight)
    }
}

// Modifier for camera controls
struct CameraControlModifier: ViewModifier {
    var cameraState: CameraOrbitState
    var cameraControlMode: LifeformViewConfig.CameraControlMode
    // Optional system scale control
    var systemScaleGetter: (() -> Float)? = nil
    var systemScaleSetter: ((Float) -> Void)? = nil
    var systemScaleRange: ClosedRange<Float> = 0.5...3.0
    // Optional external drag handler (forward raw delta in points)
    var simulationDragHandler: ((CGSize) -> Void)? = nil
    // New: allow disabling camera parallax pan separately
    var enableParallaxPan: Bool = true
    // Internal pinch anchor
    @State private var pinchStartScale: Float? = nil
    @State private var pinchStartRadius: Float? = nil
    
    func body(content: Content) -> some View {
        // Pinch gesture
        let pinchGesture = MagnificationGesture()
            .onChanged { value in
                guard let get = systemScaleGetter, let set = systemScaleSetter else { return }
                if pinchStartScale == nil { pinchStartScale = get() }
                let base = pinchStartScale ?? get()
                let newScale = min(max(base * Float(value), systemScaleRange.lowerBound), systemScaleRange.upperBound)
                if abs(newScale - get()) > 0.0001 { set(newScale) }
            }
            .onEnded { _ in pinchStartScale = nil }
        // Drag gesture
        let dragGesture = DragGesture()
            .onChanged { value in
                guard cameraState.enablePanning else { return }
                let prev = cameraState.lastDragValue
                let translation = value.translation
                let delta = CGSize(width: translation.width - prev.width, height: translation.height - prev.height)
                if let handler = simulationDragHandler {
                    handler(delta)
                    if enableParallaxPan {
                        let (right, up) = cameraState.panDirectionVectors()
                        let parallaxFactor: Float = 0.5
                        let panX = right * Float(delta.width) * cameraState.panSensitivity * parallaxFactor
                        let panY = up * Float(delta.height) * cameraState.panSensitivity * parallaxFactor
                        cameraState.panOffset -= (panX + panY)
                    }
                } else if enableParallaxPan {
                    let (right, up) = cameraState.panDirectionVectors()
                    let panX = right * Float(delta.width) * cameraState.panSensitivity
                    let panY = up * Float(delta.height) * cameraState.panSensitivity
                    cameraState.panOffset += (panX + panY)
                }
                cameraState.lastDragValue = translation
            }
            .onEnded { _ in cameraState.lastDragValue = .zero }
        // Combined gesture for drag + pinch
        // Reference: https://developer.apple.com/documentation/swiftui/gesturepriority
        // By combining drag and pinch with .simultaneously and attaching with .gesture,
        // both gestures block parent gestures (e.g., TabView page swipes).
        let combinedGesture = dragGesture.simultaneously(with: pinchGesture)
        switch cameraControlMode {
        case .fixed:
            // Pinch only (highest priority)
            return AnyView(content.gesture(pinchGesture))
        case .orbitOnly:
            // Orbit gesture + pinch (pinch highest priority)
            let orbitWrapped = content.orbitGesture(cameraState: cameraState)
            return AnyView(orbitWrapped.gesture(pinchGesture))
        case .orbitWithPan:
            // Orbit gesture + pan drag + pinch (both block parent)
            let orbitWrapped = content.orbitGesture(cameraState: cameraState)
            return AnyView(orbitWrapped.gesture(combinedGesture))
        case .fullControl:
            // Full camera controls + drag + pinch (both block parent)
            let fullWrapped = content.fullCameraControls(cameraState: cameraState)
            return AnyView(fullWrapped.gesture(combinedGesture))
        case .nicks_control:
            // Drag + pinch (both block parent)
            let dragGesture = DragGesture()
                .onChanged { value in
                    guard cameraState.enablePanning else { return }
                    let prev = cameraState.lastDragValue
                    let translation = value.translation
                    let delta = CGSize(width: translation.width - prev.width, height: translation.height - prev.height)
                    if let handler = simulationDragHandler {
                        handler(delta)
                        if enableParallaxPan {
                            let (right, up) = cameraState.panDirectionVectors()
                            let parallaxFactor: Float = 0.5
                            let panX = right * Float(delta.width) * cameraState.panSensitivity * parallaxFactor
                            let panY = up * Float(delta.height) * cameraState.panSensitivity * parallaxFactor
                            cameraState.panOffset -= (panX + panY)
                        }
                    } else if enableParallaxPan {
                        let (right, up) = cameraState.panDirectionVectors()
                        let panX = right * Float(delta.width) * cameraState.panSensitivity
                        let panY = up * Float(delta.height) * cameraState.panSensitivity
                        cameraState.panOffset += (panX + panY)
                    }
                    cameraState.lastDragValue = translation
                }
                .onEnded { _ in cameraState.lastDragValue = .zero }
            
            // Create appropriate pinch gesture based on whether systemScale is provided
            if systemScaleGetter != nil && systemScaleSetter != nil {
                // Use systemScale only (bird size), don't adjust camera radius
                let systemScalePinch = MagnificationGesture()
                    .onChanged { value in
                        guard let get = systemScaleGetter, let set = systemScaleSetter else { return }
                        if pinchStartScale == nil { pinchStartScale = get() }
                        let base = pinchStartScale ?? get()
                        let newScale = min(max(base * Float(value), systemScaleRange.lowerBound), systemScaleRange.upperBound)
                        if abs(newScale - get()) > 0.0001 { set(newScale) }
                    }
                    .onEnded { _ in pinchStartScale = nil }
                let combinedGesture = dragGesture.simultaneously(with: systemScalePinch)
                return AnyView(content.gesture(combinedGesture))
            } else {
                // Use camera radius zoom only (original behavior)
                let unifiedPinch = MagnificationGesture()
                    .onChanged { value in
                        let scale = Float(value)
                        if pinchStartRadius == nil { pinchStartRadius = cameraState.radius }
                        let baseRadius = pinchStartRadius ?? cameraState.radius
                        let newRadius = (baseRadius / max(scale, 0.0001)) / 2.0
                        cameraState.radius = min(max(newRadius, cameraState.minRadius), cameraState.maxRadius)
                    }
                    .onEnded { _ in pinchStartRadius = nil }
                let combinedGesture = dragGesture.simultaneously(with: unifiedPinch)
                return AnyView(content.gesture(combinedGesture))
            }
        }
    }
}
