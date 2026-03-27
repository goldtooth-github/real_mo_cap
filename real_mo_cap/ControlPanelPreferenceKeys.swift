import SwiftUI

// Shared preference keys for control panel state propagation
struct ControlPanelVisibilityPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

struct ControlPanelBottomInsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

public struct PinchActivePreferenceKey: PreferenceKey {
    public static var defaultValue: Bool = false
    public static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

// New: reports the rendered heights of workbench control panels by instance ID
struct WorkbenchPanelHeightsPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
