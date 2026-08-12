import CoreGraphics
import Foundation

enum GameRules {
    static let startingHealth = 5
    static let maximumFlickSpeed: CGFloat = 2_200

    static func score(for kind: ZombieKind, combo: Int) -> Int {
        let base = kind == .brute ? 250 : 100
        return base + max(0, combo - 1) * 25
    }
}

enum FlickMath {
    static func velocity(from samples: [(point: CGPoint, time: TimeInterval)]) -> CGVector {
        guard let last = samples.last else { return .zero }
        let cutoff = last.time - 0.11
        let first = samples.first(where: { $0.time >= cutoff }) ?? samples[0]
        let duration = max(0.016, last.time - first.time)
        let raw = CGVector(
            dx: (last.point.x - first.point.x) / duration,
            dy: (last.point.y - first.point.y) / duration
        )
        return clamped(raw, maximum: GameRules.maximumFlickSpeed)
    }

    static func clamped(_ vector: CGVector, maximum: CGFloat) -> CGVector {
        let magnitude = hypot(vector.dx, vector.dy)
        guard magnitude > maximum, magnitude > 0 else { return vector }
        let scale = maximum / magnitude
        return CGVector(dx: vector.dx * scale, dy: vector.dy * scale)
    }
}

