import SwiftUI
import UIKit

struct FlowerPalette {
    // Central palette for all flower colors
    static let colors: [Color] = [
        .red, .mint, .pink, .blue, .purple, .purple, .pink, .mint, .indigo, .teal
    ]
    static var uiColors: [UIColor] {
        colors.map { UIColor($0) }
    }
    // Helper to get a darkened UIColor for flower heads
    static func darkenedHeadColor(for index: Int, darkenFactor: CGFloat = 0.6) -> UIColor {
        let color = uiColors[index % uiColors.count]
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return UIColor(red: r * darkenFactor, green: g * darkenFactor, blue: b * darkenFactor, alpha: a)
        }
        return color // fallback if conversion fails
    }
    // Helper to get a Color for trackers
    static func trackerColor(for index: Int) -> Color {
        colors[index % colors.count]
    }
}
