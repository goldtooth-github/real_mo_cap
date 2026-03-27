import UIKit

extension UIBezierPath {
    /// Returns a CGPoint at the given percent of the total path length (0...1).
    func point(atPercentOfLength percent: CGFloat) -> CGPoint {
        let steps = 100
        var points: [CGPoint] = []
        var lastPoint: CGPoint?
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let pt = self.point(at: t)
            points.append(pt)
            lastPoint = pt
        }
        // Calculate total length
        var totalLength: CGFloat = 0
        for i in 1..<points.count {
            totalLength += hypot(points[i].x - points[i-1].x, points[i].y - points[i-1].y)
        }
        // Find target length
        let targetLength = percent * totalLength
        var currentLength: CGFloat = 0
        for i in 1..<points.count {
            let segmentLength = hypot(points[i].x - points[i-1].x, points[i].y - points[i-1].y)
            if currentLength + segmentLength >= targetLength {
                let remaining = targetLength - currentLength
                let ratio = remaining / segmentLength
                let x = points[i-1].x + (points[i].x - points[i-1].x) * ratio
                let y = points[i-1].y + (points[i].y - points[i-1].y) * ratio
                return CGPoint(x: x, y: y)
            }
            currentLength += segmentLength
        }
        return points.last ?? CGPoint.zero
    }
    /// Returns a point at t (0...1) along the path, using linear interpolation of control points.
    func point(at t: CGFloat) -> CGPoint {
        // Only works for simple paths made of lines
        var start: CGPoint?
        var end: CGPoint?
        var found = false
        self.cgPath.applyWithBlock { element in
            let type = element.pointee.type
            let points = element.pointee.points
            if type == .moveToPoint {
                start = points[0]
            } else if type == .addLineToPoint {
                end = points[0]
                found = true
            }
        }
        if let start = start, let end = end, found {
            let x = start.x + (end.x - start.x) * t
            let y = start.y + (end.y - start.y) * t
            return CGPoint(x: x, y: y)
        }
        return CGPoint.zero
    }
}
