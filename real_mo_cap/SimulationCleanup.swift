//
//  SimulationCleanup.swift
//  universa
//
//  Created by Nick Packer on 25/09/2025.
//

// swift
import SceneKit

protocol SimulationDisposable: AnyObject {
    func stopAsyncSimulation()
    func dispose()          // custom node/resource cleanup
}

enum SimulationTeardown {
    static func teardown<S: SimulationDisposable>(sim: inout S?, scnView: inout SCNView?) {
        sim?.stopAsyncSimulation()
        sim?.dispose()
        sim = nil
        if let view = scnView {
            view.isPlaying = false
            view.delegate = nil
            if let scene = view.scene {
                scene.rootNode.enumerateChildNodes { node, _ in
                    node.removeAllActions()
                    node.geometry = nil
                    node.removeFromParentNode()
                }
            }
            view.scene = nil
        }
        scnView = nil
    }
}
