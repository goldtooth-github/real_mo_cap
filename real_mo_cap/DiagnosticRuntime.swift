import Foundation
import SceneKit
import QuartzCore
import Darwin.Mach

struct SimulationDiagnostics {
    // Internal toggle (set true where needed)
    static var enabled: Bool = false
    struct SceneStats {
        let geometryCount: Int
        let materialCount: Int
        let lightCount: Int
        let cameraCount: Int
        let triangleCount: Int
        let uniqueGeometryCount: Int
        let uniqueMaterialCount: Int
    }
    private static var lastResident: UInt64? = nil
    private static var lastTriangleCount: Int? = nil
    
    // Public snapshot (can be called manually if needed)
    static func snapshot(label: String, scene: SCNScene?) { logEvent(label, scene: scene) }
    
    // MARK: - Memory
    static func currentResidentBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4 // dynamic instead of MACH_TASK_BASIC_INFO_COUNT
        let kerr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }
    static func bytesString(_ bytes: UInt64?) -> String {
        guard let b = bytes else { return "?" }
        if b > 1_000_000_000 { return String(format: "%.2f GB", Double(b)/1_000_000_000.0) }
        if b > 1_000_000 { return String(format: "%.2f MB", Double(b)/1_000_000.0) }
        if b > 1000 { return String(format: "%.2f KB", Double(b)/1000.0) }
        return "\(b) B"
    }
    
    // MARK: - Scene Traversal
    static func collect(scene: SCNScene?) -> SceneStats {
        guard let scene = scene else { return SceneStats(geometryCount: 0, materialCount: 0, lightCount: 0, cameraCount: 0, triangleCount: 0, uniqueGeometryCount: 0, uniqueMaterialCount: 0) }
        var geomCount = 0, matCount = 0, lightCount = 0, cameraCount = 0, triCount = 0
        var uniqueGeoms = Set<ObjectIdentifier>()
        var uniqueMats = Set<ObjectIdentifier>()
        func triCountFor(_ g: SCNGeometry) -> Int {
            var total = 0
            for elem in g.elements {
                if elem.primitiveType == .triangles {
                    total += elem.primitiveCount
                }
            }
            return total
        }
        func walk(_ n: SCNNode) {
            if let g = n.geometry {
                geomCount += 1
                triCount += triCountFor(g)
                uniqueGeoms.insert(ObjectIdentifier(g))
                for m in g.materials {
                    matCount += 1
                    uniqueMats.insert(ObjectIdentifier(m))
                }
            }
            if n.light != nil { lightCount += 1 }
            if n.camera != nil { cameraCount += 1 }
            for c in n.childNodes { walk(c) }
        }
        walk(scene.rootNode)
        return SceneStats(geometryCount: geomCount, materialCount: matCount, lightCount: lightCount, cameraCount: cameraCount, triangleCount: triCount, uniqueGeometryCount: uniqueGeoms.count, uniqueMaterialCount: uniqueMats.count)
    }
    
    // MARK: - Logging
    static func logEvent(_ label: String, scene: SCNScene?) {
        guard enabled else { return }
        let mem = currentResidentBytes()
        let stats = collect(scene: scene)
        let memDeltaStr: String = {
            guard let prev = lastResident, let cur = mem else { return "Δ=?" }
            let diff = Int64(cur) - Int64(prev)
            let sign = diff >= 0 ? "+" : ""; return "Δ=" + sign + bytesString(UInt64(abs(diff)))
        }()
        let triDeltaStr: String = {
            guard let prev = lastTriangleCount else { return "trisΔ=?" }
            let diff = stats.triangleCount - prev
            let sign = diff >= 0 ? "+" : ""; return "trisΔ=" + sign + String(diff)
        }()
        print("[Diag] \(label) mem=\(bytesString(mem)) \(memDeltaStr) tris=\(stats.triangleCount) \(triDeltaStr) geoms=\(stats.geometryCount)/uniq\(stats.uniqueGeometryCount) mats=\(stats.materialCount)/uniq\(stats.uniqueMaterialCount) lights=\(stats.lightCount) cams=\(stats.cameraCount)")
        lastResident = mem
        lastTriangleCount = stats.triangleCount
    }
    static func markCreation(name: String, scene: SCNScene?) { logEvent("Create: \(name)", scene: scene) }
    static func markPreTeardown(name: String, scene: SCNScene?) { logEvent("PreTeardown: \(name)", scene: scene) }
    static func markPostTeardown(name: String) { logEvent("PostTeardown: \(name)", scene: nil) }
}
