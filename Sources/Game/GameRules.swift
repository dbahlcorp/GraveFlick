import CoreGraphics
import Foundation

enum GameRules {
    static let startingHealth = 5
    static let maximumFlickSpeed: CGFloat = 2_200

    static func score(for kind: ZombieKind, combo: Int) -> Int {
        kind.scoreValue + max(0, combo - 1) * 25
    }

    static func stars(score: Int, health: Int, startingHealth: Int, won: Bool) -> Int {
        guard won else { return 0 }
        if health == startingHealth && score >= 2_000 { return 3 }
        if health >= max(1, startingHealth / 2) { return 2 }
        return 1
    }

    static func cooldown(base: TimeInterval, rapidGearLevel: Int) -> TimeInterval {
        base * max(0.68, 1 - Double(rapidGearLevel) * 0.08)
    }

    /// Endless mode always ends in a loss (there's no wave count to "clear"), so its coin payout
    /// is scored from performance instead of the win-gated per-level reward. Capped so a very
    /// long single run can't inflate the economy faster than clearing several story levels.
    static func survivalReward(score: Int) -> Int {
        min(2_000, 80 + score / 12)
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
