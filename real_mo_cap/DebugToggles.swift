import Foundation

// Global runtime flags for A/B testing optimizations across SceneKit updates.
// Flip these at runtime via the Debug flags panel in MeshBirdLifeformViewAsync.
struct DebugToggles {
    // SceneKit/Core Animation
    static var disableImplicitAnimations: Bool = true
    static var useAutoreleasePoolPerFrame: Bool = true
    
    // Update churn
    static var onlyUpdateWhenChanged: Bool = true
    
    // Spline geometry strategy
    static var useUnitHeightScalingForSplines: Bool = true // true: scale node.y; false: mutate SCNCylinder.height
    
    // Camera strategy
    static var useLookAtConstraint: Bool = true // true: look-at target node; false: call look(at:) each update
    
    // Teardown hygiene
    static var cleanTeardown: Bool = true // true: aggressively clear SceneKit resources on dismantle
    
    // Focus & camera debug logging
    static var enableFocusLogging: Bool = false
    static var enableCameraChangeLogging: Bool = false
    
    // Mac Catalyst window focus logging (NSWindowDidBecomeMain / key notifications)
    static var enableWindowFocusLogging: Bool = true
}
