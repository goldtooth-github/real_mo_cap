import SwiftUI
import SceneKit
import UIKit
import UniformTypeIdentifiers

// Wrapper to hold a generic simulation instance without @State timing issues
final class SimulationRef<S>: ObservableObject { @Published var value: S? = nil }

// Simple raw-data FileDocument for exporting/importing settings
private struct RawDataDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { self.data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ModifiedSimulationView<SimulationType: LifeformSimulation>: View {
    // MARK: - Inputs
    var config: LifeformViewConfig
    @ObservedObject var customCameraState: CameraOrbitState
    var createSimulation: (SCNScene) -> SimulationType
    var controlsBuilder: ((Binding<SimulationType?>, Binding<Bool>) -> AnyView)?
    var panelBuilder: ((Binding<SimulationType?>, LifeformViewConfig) -> AnyView)? = nil
    var onViewReady: ((Binding<SimulationType?>, SCNView) -> Void)? = nil
    var isActive: Bool = true              // From pager (true only for selected page)
    var systemScaleGetter: (() -> Float)? = nil
    var systemScaleSetter: ((Float) -> Void)? = nil
    var systemScaleRange: ClosedRange<Float> = 0.5...3.0
    var simulationDragHandler: ((CGSize) -> Void)? = nil
    var enableParallaxPan: Bool = true
    var onSimulationUpdated: ((SimulationType?) -> Void)? = nil
    var driveWithSimulationManager: Bool = false
    var pauseHandler: ((Bool, SimulationType?) -> Void)? = nil
    var sceneOverlayBuilder: (() -> AnyView)? = nil
    var panelAutoHideEnabled: Bool = true
    var externalPaused: Binding<Bool>? = nil
    var isDisplayLockPressed: Binding<Bool> = .constant(false)
    var onPageLeft: (() -> Void)? = nil // Pagination left
    var onPageRight: (() -> Void)? = nil // Pagination right
    // New: generic settings persistence hooks
    var getSettingsData: (() -> Data)? = nil
    var applySettingsData: ((Data) -> Void)? = nil

    // MARK: - State
    @StateObject private var simRef = SimulationRef<SimulationType>()
    @EnvironmentObject private var settingsIO: SettingsIOActions
    @State private var sceneViewReady = false          // SCNView established
    @State private var hasStarted = false              // Async loop started
    @State private var internalPaused = false
    @State private var startStopReentrancy = false    // Prevents reentrant start/stop
    private var isPausedBinding: Binding<Bool> { externalPaused ?? Binding(get: { internalPaused }, set: { internalPaused = $0 }) }
    private var isPausedValue: Bool { isPausedBinding.wrappedValue }
    @AppStorage("keepScreenAwake") private var keepScreenAwake: Bool = false

    // Control panel state
    private enum PanelState { case expanded, hidden }
    @State private var panelState: PanelState = .expanded
    @State private var autoHideWorkItem: DispatchWorkItem?
    private let swipeRevealZoneHeight: CGFloat = 100

    // Scene references
    @State private var scnViewRef: SCNView? = nil // fallback reference

    // One-time prewarm for first interaction heavy subsystems
    @State private var didPrewarmFirstInteraction = false

    // LFO overlay frame (in "simulationRoot" coord space)
    @State private var lfoOverlayFrame: CGRect = .null
    // First-time edit smoothing
    @State private var hasClosedPanelForEditingOnce = false

    // New: settings exporter/importer state
    @State private var showExporter: Bool = false
    @State private var showImporter: Bool = false
    @State private var exportData: Data? = nil
    @State private var lastLoadedSettingsData: Data? = nil
    @State private var initialSettingsData: Data? = nil

    // MARK: - Init
    init(
        config: LifeformViewConfig,
        customCameraState: CameraOrbitState,
        createSimulation: @escaping (SCNScene) -> SimulationType,
        controlsBuilder: ((Binding<SimulationType?>, Binding<Bool>) -> AnyView)? = nil,
        panelBuilder: ((Binding<SimulationType?>, LifeformViewConfig) -> AnyView)? = nil,
        onViewReady: ((Binding<SimulationType?>, SCNView) -> Void)? = nil,
        isActive: Bool = true,
        systemScaleGetter: (() -> Float)? = nil,
        systemScaleSetter: ((Float) -> Void)? = nil,
        systemScaleRange: ClosedRange<Float> = 0.5...3.0,
        simulationDragHandler: ((CGSize) -> Void)? = nil,
        enableParallaxPan: Bool = true,
        onSimulationUpdated: ((SimulationType?) -> Void)? = nil,
        driveWithSimulationManager: Bool = false,
        pauseHandler: ((Bool, SimulationType?) -> Void)? = nil,
        sceneOverlayBuilder: (() -> AnyView)? = nil,
        panelAutoHideEnabled: Bool = true,
        externalPaused: Binding<Bool>? = nil,
        isDisplayLockPressed: Binding<Bool> = .constant(false),
        onPageLeft: (() -> Void)? = nil,
        onPageRight: (() -> Void)? = nil,
        getSettingsData: (() -> Data)? = nil,
        applySettingsData: ((Data) -> Void)? = nil
    ) {
        self.config = config
        self.createSimulation = createSimulation
        self.controlsBuilder = controlsBuilder
        self.panelBuilder = panelBuilder
        self.onViewReady = onViewReady
        self.isActive = isActive
        self.systemScaleGetter = systemScaleGetter
        self.systemScaleSetter = systemScaleSetter
        self.systemScaleRange = systemScaleRange
        self.simulationDragHandler = simulationDragHandler
        self.enableParallaxPan = enableParallaxPan
        self.onSimulationUpdated = onSimulationUpdated
        self.driveWithSimulationManager = driveWithSimulationManager
        self.pauseHandler = pauseHandler
        self.sceneOverlayBuilder = sceneOverlayBuilder
        self.panelAutoHideEnabled = panelAutoHideEnabled
        self.externalPaused = externalPaused
        self.isDisplayLockPressed = isDisplayLockPressed
        self.onPageLeft = onPageLeft
        self.onPageRight = onPageRight
        self.getSettingsData = getSettingsData
        self.applySettingsData = applySettingsData
        _customCameraState = ObservedObject(initialValue: customCameraState)
    }

    // MARK: - Body
    var body: some View {
        ZStack {
            sceneStack()
                .contentShape(Rectangle())
                // Define coordinate space and consume overlay frame preference
                .coordinateSpace(name: "simulationRoot")
                .onPreferenceChange(LFOOverlayFrameKey.self) { frame in
                    lfoOverlayFrame = frame
                }
                // Close panel when overlay note editing becomes active
             
                // Replace tap toggle with guarded 0-distance drag
                .simultaneousGesture(
                    panelAutoHideEnabled ? DragGesture(minimumDistance: 0).onEnded { value in
                       // dismissKeyboard()
                        let point = value.location
                        let move = hypot(value.translation.width, value.translation.height)
                        if move < 8 { // treat as tap only if minimal movement
                            if !lfoOverlayFrame.contains(point) { togglePanelVisibility() }
                        }
                    } : nil
                )
                .edgesIgnoringSafeArea(.all)
            VStack(spacing: 0) {
                Spacer()
                controlPanel()
                if panelAutoHideEnabled && panelState == .hidden {
                    Color.clear
                        .frame(height: swipeRevealZoneHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { showPanelAndScheduleAutoHide() }
                }
            }
        }
        // Exporter
        .sheet(isPresented: Binding(get: { showExporter && exportData != nil }, set: { showExporter = $0 })) {
            if let data = exportData {
                let filename = "\(config.title) Settings.json"
                DataExportPicker(
                    data: data,
                    defaultFilename: filename,
                    onComplete: { showExporter = false }
                )
            }
        }
        .fileImporter(isPresented: Binding(get: { showImporter }, set: { showImporter = $0 }), allowedContentTypes: [.json]) { importResult in
            switch importResult {
            case .success(let url):
                let fname = url.lastPathComponent
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var coordError: NSError?
                var loaded: Data?
                let coordinator = NSFileCoordinator(filePresenter: nil)
                coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readableURL in
                    do {
                        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
                        if FileManager.default.fileExists(atPath: tmp.path) { try? FileManager.default.removeItem(at: tmp) }
                        try FileManager.default.copyItem(at: readableURL, to: tmp)
                        loaded = try Data(contentsOf: tmp, options: .mappedIfSafe)
                        try? FileManager.default.removeItem(at: tmp)
                    } catch {
                        print("[Settings] Import: coordinate copy/read failed for \(fname): \(error)")
                    }
                }
                if let ce = coordError { print("[Settings] Import: NSFileCoordinator error for \(fname): \(ce)") }
                if let data = loaded {
                    let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                    print("[Settings] Import: loaded \(fname) (\(data.count) bytes) preview=\(preview)")
                    DispatchQueue.main.async {
                        lastLoadedSettingsData = data
                        applySettingsData?(data)
                    }
                } else {
                    print("[Settings] Import: failed to read file at URL \(url)")
                }
            case .failure(let err):
                print("[Settings] Import: picker error: \(err.localizedDescription)")
            }
        }
        // Expose settings I/O actions to descendants (provided from root)
        .preference(key: ControlPanelVisibilityPreferenceKey.self, value: panelState == .expanded)
        .preference(key: ControlPanelBottomInsetPreferenceKey.self, value: panelState == .expanded ? config.controlPanelBottomInset : 0)
        .onChange(of: isActive) { _, newVal in
            print("isActive -> \(newVal)")
            if newVal { attemptStart(origin: "isActive change") } else { ensureStopped(reason: "became inactive") }
        }
        .onChange(of: isPausedValue) { _, p in
            print("paused -> \(p)")
            pauseHandler?(p, simRef.value)
            if p { ensureStopped(reason: "paused") } else { attemptStart(origin: "pause cleared") }
        }
        .onAppear {
            print("onAppear active=\(isActive)")
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
            if panelAutoHideEnabled { scheduleAutoHide() }
            // Wire SettingsIOActions handlers
            settingsIO.requestExport = {
                if let snap = getSettingsData?() { exportData = snap; showExporter = true }
            }
            settingsIO.requestImport = { showImporter = true }
            settingsIO.requestReset = {
                if let data = lastLoadedSettingsData ?? initialSettingsData, let apply = applySettingsData { apply(data) }
            }
            if initialSettingsData == nil, let snap = getSettingsData?() { initialSettingsData = snap }
          
            attemptStart(origin: "onAppear")
        }
        .onDisappear {
            print("onDisappear")
            ensureStopped(reason: "disappear")
            cancelAutoHide()
        }
    }

    // MARK: - Scene / Simulation stack
    @ViewBuilder private func sceneStack() -> some View {
        ZStack(alignment: .top) {
            WireframeCubeSceneView(
                cameraState: customCameraState,
                sceneSetupHandler: { scene in
                    customCameraState.setInitialPositionInDegrees(
                        azimuth: Float(config.initialAzimuth),
                        elevation: Float(config.initialElevation),
                        radius: Float(config.initialRadius)
                    )
                    customCameraState.minRadius = Float(config.minRadius)
                    customCameraState.maxRadius = Float(config.maxRadius)
                    setupLighting(in: scene)
                    let sim = createSimulation(scene)
                    log("Created simulation id=\(ObjectIdentifier(sim as AnyObject)) active=\(isActive) (deferring state publish)")
                    DispatchQueue.main.async {
                        hasStarted = false
                        simRef.value = sim
                        onSimulationUpdated?(sim)
                        log("Published simulation (simRef.value != nil)=\(simRef.value != nil)")
                        attemptStart(origin: "post-publish")
                    }
                },
                onSCNViewReady: { scnView in
                    scnViewRef = scnView
                    DispatchQueue.main.async {
                        sceneViewReady = true
                        log("SCNView ready active=\(isActive) paused=\(isPausedValue) hasSim=\(simRef.value != nil) started=\(hasStarted)")
                        if let cb = onViewReady { cb(Binding(get: { simRef.value }, set: { simRef.value = $0 }), scnView) }
                        if !hasStarted { attemptStart(origin: "scn ready") }
                    }
                }
            )
            .modifier(CameraControlModifier(
                cameraState: customCameraState,
                cameraControlMode: config.cameraControlMode,
                systemScaleGetter: systemScaleGetter,
                systemScaleSetter: systemScaleSetter,
                systemScaleRange: systemScaleRange,
                simulationDragHandler: simulationDragHandler,
                enableParallaxPan: enableParallaxPan
            ))
            if let overlay = sceneOverlayBuilder?() { overlay }
        }
    }

    // MARK: - Control Panel
    @ViewBuilder private func controlPanel() -> some View {
        if panelState == .expanded { expandedPanel() }
    }

    @ViewBuilder private func expandedPanel() -> some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let panelWidth = isLandscape ? geometry.size.width * 0.8 : geometry.size.width
            Group {
                if let panelBuilder { panelBuilder(Binding(get: { simRef.value }, set: { simRef.value = $0 }), config) }
                else {
                    VStack(spacing: 12) {
                        headerRow()
                        if let controlsBuilder { controlsBuilder(Binding(get: { simRef.value }, set: { simRef.value = $0 }), isPausedBinding) }
                    }
                    .padding()
                    .frame(width: panelWidth)
                    .background(config.controlPanelColor)
                    .cornerRadius(10)
                }
            }
            .frame(maxWidth: geometry.size.width, maxHeight: .infinity, alignment: .bottom)
            .onTapGesture { if panelAutoHideEnabled { showPanelAndScheduleAutoHide() } }
            .padding(.bottom, config.controlPanelBottomInset)
        }
    }

    @ViewBuilder private func headerRow() -> some View {
        HStack(alignment: .top) {
            Button { isPausedBinding.wrappedValue.toggle() } label: {
                Image(systemName: isPausedBinding.wrappedValue ? "play.fill" : "pause.fill")
                    .foregroundColor(config.controlTextColor)
                    .frame(width: 15, height: 15)
                    .animation(nil, value: isPausedBinding.wrappedValue)
            }
            .frame(width: 40)
            .buttonStyle(PressableButtonStyle(
                onPress: {  isDisplayLockPressed.wrappedValue = true; },
                onRelease: { isDisplayLockPressed.wrappedValue = false;  }
            ))
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(config.title)
                    .font(.headline)
                    .foregroundColor(config.controlTextColor)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            // Save/Load/Reset icons
            Button {
                keepScreenAwake.toggle()
                UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
            } label: {
                Image(systemName: keepScreenAwake ? "lock.display" : "lock.open.display")
                    .font(.title2)
                    .foregroundColor(keepScreenAwake ? .orange : config.controlTextColor)
            }
            .frame(width: 40)
            .buttonStyle(PressableButtonStyle(
                onPress: { isDisplayLockPressed.wrappedValue = true;  },
                onRelease: { isDisplayLockPressed.wrappedValue = false;  }
            ))
        }
    }

    // MARK: - Start / Stop Logic
    @MainActor private func attemptStart(origin: String) {
        if startStopReentrancy { return }
        startStopReentrancy = true
        defer { startStopReentrancy = false }
        print("attemptStart(origin: \(origin)) hasStarted=\(hasStarted) isActive=\(isActive) isPausedValue=\(isPausedValue) simRef.value=\(simRef.value != nil)")
        guard !hasStarted else { return }
        guard isActive else { return }
        guard !isPausedValue else { return }
        guard let sim = simRef.value else { return }
        #if targetEnvironment(macCatalyst)
        // Reattach delegate if previously detached
        if let v = scnViewRef, v.delegate == nil {
            v.delegate = sim as? SCNSceneRendererDelegate
        }
        scnViewRef?.isPlaying = true
        #endif
        startAsyncIfKnown(sim) // <-- Start async simulation if applicable
        print("[Lifecycle] START (origin=\(origin))")
        hasStarted = true
    }

    @MainActor private func ensureStopped(reason: String) {
        if startStopReentrancy { return }
        startStopReentrancy = true
        defer { startStopReentrancy = false }
        print("ensureStopped(reason: \(reason)) hasStarted=\(hasStarted) simRef.value=\(simRef.value != nil)")
        guard hasStarted, let sim = simRef.value else { return }
        print("[Lifecycle] STOP (reason=\(reason))")
        // Stop async driver if applicable so adjacent (inactive) pages are idle but still resident
        stopAsyncIfKnown(sim)
        #if targetEnvironment(macCatalyst)
        if let v = scnViewRef {
            v.isPlaying = false
            v.delegate = nil
        }
        #endif
        hasStarted = false
    }

    // MARK: - Simulation Type Dispatch
    @MainActor private func startAsyncIfKnown(_ sim: LifeformSimulation) {
        log("startAsyncIfKnown type=\(type(of: sim))")
        switch sim {
        case let s as JellyfishSimulationAsync:
            print("[Lifecycle] START Jellyfish id=\(ObjectIdentifier(s))"); s.startAsyncSimulation()
        case let s as MeshBirdSimulationAsync:
            print("[Lifecycle] START MeshBird id=\(ObjectIdentifier(s))"); s.startAsyncSimulation()
        case let s as BarleySimulationAsync:
            print("[Lifecycle] START Barley id=\(ObjectIdentifier(s))"); s.startAsyncSimulation()
        case let s as BoidsSimulationAsync:
            print("[Lifecycle] START Boids id=\(ObjectIdentifier(s))"); s.startAsyncSimulation()
        case let s as SimplePlantLadybirdsSimulationAsync:
            print("[Lifecycle] START SimplePlantLadybirdsSimulationAsync id=\(ObjectIdentifier(s))"); s.startAsyncSimulation()
        case let s as FlowerClusterSimulationAsync:
            print("[Lifecycle] START FlowerClusterSimulationAsync id=\(ObjectIdentifier(s))"); s.startAsyncSimulation()
        case let s as PlanetsSimulationAsync:
            print("[Lifecycle] START PlanetsSimulationAsync id=\(ObjectIdentifier(s))"); s.startAsyncSimulation()
        case let s as WaveAndLeavesSimulationAsync:
            print("[Lifecycle] START WaveAndLeavesSimulationAsync id=\(ObjectIdentifier(s))"); s.startAsyncSimulation()
        default:
            print("[Lifecycle] Unknown sim type \(type(of: sim))")
        }
    }

    @MainActor private func stopAsyncIfKnown(_ sim: LifeformSimulation) {
        log("stopAsyncIfKnown type=\(type(of: sim))")
        switch sim {
        case let s as JellyfishSimulationAsync:
            print("[Lifecycle] STOP Jellyfish id=\(ObjectIdentifier(s))"); s.stopAsyncSimulation()
        case let s as MeshBirdSimulationAsync:
            print("[Lifecycle] STOP MeshBird id=\(ObjectIdentifier(s))"); s.stopAsyncSimulation()
        case let s as BarleySimulationAsync:
            print("[Lifecycle] STOP Barley id=\(ObjectIdentifier(s))"); s.stopAsyncSimulation()
        case let s as AntColonySimulationAsync:
            print("[Lifecycle] STOP AntColony id=\(ObjectIdentifier(s))"); s.stopAsyncSimulation()
        case let s as BoidsSimulationAsync:
            print("[Lifecycle] STOP Boids id=\(ObjectIdentifier(s))"); s.stopAsyncSimulation()
        case let s as SimplePlantLadybirdsSimulationAsync:
            print("[Lifecycle] STOP SimplePlantLadybirdsSimulationAsync id=\(ObjectIdentifier(s))"); s.stopAsyncSimulation()
        case let s as FlowerClusterSimulationAsync:
            print("[Lifecycle] STOP FlowerCluster SimulationAsync id=\(ObjectIdentifier(s))"); s.stopAsyncSimulation()
        case let s as PlanetsSimulationAsync:
            print("[Lifecycle] STOP PlanetsClusterSimulationAsync id=\(ObjectIdentifier(s))"); s.stopAsyncSimulation()
        case let s as WaveAndLeavesSimulationAsync:
            print("[Lifecycle] STOP WaveAndLeavesSimulationAsync id=\(ObjectIdentifier(s))"); s.stopAsyncSimulation()
        default:
            print("[Lifecycle] Unknown sim type \(type(of: sim))")
        }
    }

    // MARK: - Lighting
    private func setupLighting(in scene: SCNScene) {
        if config.title == "Jellyfish" {
            let d = SCNNode()
            d.light = SCNLight()
            d.light?.type = .directional
            d.light?.intensity = 1200
            d.light?.color = UIColor.white
            d.eulerAngles = SCNVector3(-Float.pi/3, Float.pi/4, 0)
            scene.rootNode.addChildNode(d)
            return
        }
     
            let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
            ambient.light?.color = UIColor(white: CGFloat(config.ambientLightIntensity), alpha: 1)
            scene.rootNode.addChildNode(ambient)
            let dir = SCNNode(); dir.light = SCNLight(); dir.light?.type = .directional
            dir.light?.color = UIColor(white: CGFloat(config.directionalLightIntensity), alpha: 1)
            dir.eulerAngles = config.directionalLightAngles
            scene.rootNode.addChildNode(dir)
        
    }

    // MARK: - Panel Auto Hide
    private func togglePanelVisibility() {
        guard panelAutoHideEnabled else { return }
        if panelState == .expanded { panelState = .hidden } else { showPanelAndScheduleAutoHide() }
    }
    private func scheduleAutoHide() {
        cancelAutoHide()
        let work = DispatchWorkItem { withAnimation(.easeInOut(duration: 0.35)) { panelState = .hidden } }
        autoHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }
    private func cancelAutoHide() { autoHideWorkItem?.cancel(); autoHideWorkItem = nil }
    private func showPanelAndScheduleAutoHide() { withAnimation(.easeInOut(duration: 0.25)) { panelState = .expanded }; scheduleAutoHide() }

   
    // MARK: - Logging
    private func log(_ msg: String) { print("[ModifiedSimulationView][" + config.title + "] " + msg) }
}

struct PressableButtonStyle: ButtonStyle {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed { onPress?() }
                else { onRelease?() }
            }
    }
}

#if canImport(UIKit)
private struct DataExportPicker: UIViewControllerRepresentable {
    let data: Data
    let defaultFilename: String
    let onComplete: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(defaultFilename)
        try? data.write(to: tmpURL, options: .atomic)
        let picker = UIDocumentPickerViewController(forExporting: [tmpURL], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: () -> Void
        init(onComplete: @escaping () -> Void) { self.onComplete = onComplete }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onComplete() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onComplete() }
    }
}
#endif
