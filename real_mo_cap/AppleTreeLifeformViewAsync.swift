import SwiftUI
import SceneKit

struct AppleTreeLifeformViewAsync: UIViewRepresentable {
    var isActive: Bool = false
    var isPaused: Binding<Bool>
    var isDisplayLockPressed: Binding<Bool>
    let config: LifeformViewConfig

    init(isActive: Bool = false, isPaused: Binding<Bool>, isDisplayLockPressed: Binding<Bool>, config: LifeformViewConfig = LifeformViewConfig()) {
        self.isActive = isActive
        self.isPaused = isPaused
        self.isDisplayLockPressed = isDisplayLockPressed
        self.config = config
    }

    // Coordinator holds SceneKit objects across SwiftUI updates
    class Coordinator {
        let scene: SCNScene
        let scnView: SCNView
        let sim: AppleTreeSimulationAsync

        init(config: LifeformViewConfig) {
            scene = SCNScene()
            scnView = SCNView(frame: .zero)
            sim = AppleTreeSimulationAsync(scene: scene, config: config, scnView: scnView)

            scnView.scene = scene
            scnView.backgroundColor = .black
            scnView.allowsCameraControl = true
            scnView.autoenablesDefaultLighting = true
            scnView.isPlaying = true

            // Ensure a camera exists so the tree is visible
            if scene.rootNode.childNode(withName: "AppleTree_Camera", recursively: false) == nil {
                let camera = SCNCamera()
                camera.zNear = 0.1
                camera.zFar = 1000
                let cameraNode = SCNNode()
                cameraNode.name = "AppleTree_Camera"
                cameraNode.camera = camera
                cameraNode.position = SCNVector3(x: 0, y: 2.5, z: 6)
                cameraNode.eulerAngles = SCNVector3(x: -0.3, y: 0, z: 0)
                scene.rootNode.addChildNode(cameraNode)
                scnView.pointOfView = cameraNode
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(config: config) }

    func makeUIView(context: Context) -> SCNView {
        let c = context.coordinator
        c.sim.scnView = c.scnView
        c.scnView.isPlaying = true

        if isActive {
            c.sim.startAsyncSimulation()
        } else {
            c.sim.stopAsyncSimulation()
        }
        c.sim.setPaused(isPaused.wrappedValue)
        return c.scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let c = context.coordinator
        c.sim.setPaused(isPaused.wrappedValue)
        if isActive {
            c.sim.startAsyncSimulation()
        } else {
            c.sim.stopAsyncSimulation()
        }
    }
}
