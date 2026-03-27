import SceneKit

extension SCNVector3 {
    static func + (left: SCNVector3, right: SCNVector3) -> SCNVector3 {
        return SCNVector3(left.x + right.x, left.y + right.y, left.z + right.z)
    }
    
    static func - (left: SCNVector3, right: SCNVector3) -> SCNVector3 {
        return SCNVector3(left.x - right.x, left.y - right.y, left.z - right.z)
    }
    
    static func * (vector: SCNVector3, scalar: Float) -> SCNVector3 {
        return SCNVector3(vector.x * scalar, vector.y * scalar, vector.z * scalar)
    }
    
    static func / (vector: SCNVector3, scalar: Float) -> SCNVector3 {
        return SCNVector3(vector.x / scalar, vector.y / scalar, vector.z / scalar)
    }
    
    static func * (scalar: Float, vector: SCNVector3) -> SCNVector3 {
        return vector * scalar
    }
    
    func length() -> Float {
        return sqrt(x*x + y*y + z*z)
    }
    
    func normalized() -> SCNVector3 {
        let len = length()
        if len == 0 {
            return SCNVector3Zero
        }
        return SCNVector3(x / len, y / len, z / len)
    }
    
    // Renamed to avoid conflicts
    var isZeroVector: Bool {
        return (x == 0 && y == 0 && z == 0)
    }
    
    static func cross(_ left: SCNVector3, _ right: SCNVector3) -> SCNVector3 {
        return SCNVector3(
            left.y * right.z - left.z * right.y,
            left.z * right.x - left.x * right.z,
            left.x * right.y - left.y * right.x
        )
    }
    
    static func dot(_ left: SCNVector3, _ right: SCNVector3) -> Float {
        return left.x * right.x + left.y * right.y + left.z * right.z
    }
    // Unary minus operator for SCNVector3
    static prefix func - (vector: SCNVector3) -> SCNVector3 {
        return SCNVector3(-vector.x, -vector.y, -vector.z)
    }
    
    // Renamed to avoid conflicts
    func applyingMatrix(_ matrix: SCNMatrix4) -> SCNVector3 {
        let v = SCNVector3Make(
            x * matrix.m11 + y * matrix.m21 + z * matrix.m31 + matrix.m41,
            x * matrix.m12 + y * matrix.m22 + z * matrix.m32 + matrix.m42,
            x * matrix.m13 + y * matrix.m23 + z * matrix.m33 + matrix.m43
        )
        return v
    }
    
    static func distance(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        return (b - a).length()
    }
    
    static func += (left: inout SCNVector3, right: SCNVector3) { left = left + right }
    static func -= (left: inout SCNVector3, right: SCNVector3) { left = left - right }
    
    static var zero: SCNVector3 { SCNVector3Zero }
}

// MARK: - Equatable Conformance & Helpers
extension SCNVector3: Equatable {
    public static func == (lhs: SCNVector3, rhs: SCNVector3) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z
    }
    /// Approximate floating comparison convenience
    public func almostEquals(_ other: SCNVector3, epsilon: Float = 1e-4) -> Bool {
        abs(x - other.x) <= epsilon && abs(y - other.y) <= epsilon && abs(z - other.z) <= epsilon
    }
}
