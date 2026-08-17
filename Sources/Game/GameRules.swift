import CoreGraphics
import Foundation

enum GameRules {
    // Numeric health pool, not hearts — with zombies attacking the diner repeatedly instead of
    // dying on contact (see ZombieNode.playDinerAttack), a handful of discrete hearts drained in
    // one bite each, doesn't leave enough resolution: one ignored zombie could end a run in a few
    // seconds. A bigger pool with proportionally small per-bite damage (ZombieKind.dinerDamage)
    // keeps a few seconds of inattention recoverable while sustained neglect still adds up fast.
    static let startingHealth = 100
    static let reinforcedDinerHealthPerLevel = 20
    static let repairPickupAmount = 20
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

    static func campaignSpawnCount(wave: Int, waveDuration: TimeInterval, baseSpawnInterval: TimeInterval) -> Int {
        // Nudged up from 0.55 to compensate for the slower global zombie walk speed
        // (GameScene.zombieSpeedScale) — each zombie now spends longer crossing the screen, so
        // spawning a bit more densely keeps overall wave pressure roughly where it was. This is
        // an estimate, not a measured value; revisit after a playtest pass.
        let baseline = Int((waveDuration / max(0.45, baseSpawnInterval)) * 0.60)
        return min(14, max(5, baseline + max(0, wave - 1)))
    }

    /// Endless mode always ends in a loss (there's no wave count to "clear"), so its coin payout
    /// is scored from performance instead of the win-gated per-level reward. Capped so a very
    /// long single run can't inflate the economy faster than clearing several story levels.
    static func survivalReward(score: Int) -> Int {
        min(2_000, 80 + score / 12)
    }

    struct SurvivalDifficulty: Equatable {
        let spawnInterval: TimeInterval
        let speedMultiplier: CGFloat
        let healthMultiplier: CGFloat
        let spawnCount: Int
        let isBossWave: Bool
    }

    static func survivalDifficulty(wave: Int, baseSpawnInterval: TimeInterval = 1.05) -> SurvivalDifficulty {
        let safeWave = max(1, wave)
        let tier = (safeWave - 1) / 5
        return SurvivalDifficulty(
            // *0.92 compensates for the slower global zombie walk speed (see
            // GameScene.zombieSpeedScale) — an estimate to revisit after playtesting, not a
            // measured value.
            spawnInterval: max(0.34, (baseSpawnInterval - Double(safeWave - 1) * 0.035) * 0.92),
            speedMultiplier: min(2.25, 1 + CGFloat(safeWave - 1) * 0.028),
            healthMultiplier: min(3.5, 1 + CGFloat(tier) * 0.18),
            spawnCount: min(3, 1 + tier / 3),
            isBossWave: safeWave.isMultiple(of: 5)
        )
    }

    static func bossKind(forWave wave: Int) -> ZombieKind? {
        guard max(1, wave).isMultiple(of: 5) else { return nil }
        return wave.isMultiple(of: 10) ? .colossus : .butcher
    }

    static func storyBossKind(levelID: Int, wave: Int, totalWaves: Int) -> ZombieKind? {
        guard wave == totalWaves else { return nil }
        return switch levelID {
        case 4: .butcher
        case 5: .colossus
        default: levelID > 5 && levelID.isMultiple(of: 5) ? (levelID.isMultiple(of: 10) ? .colossus : .butcher) : nil
        }
    }

    static func animationFrameIndices(totalFrames: Int, reducedMotion: Bool, emphasizedFrame: Int) -> [Int] {
        guard totalFrames > 0 else { return [] }
        if reducedMotion { return [min(max(0, emphasizedFrame), totalFrames - 1)] }
        return Array(0..<totalFrames)
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
