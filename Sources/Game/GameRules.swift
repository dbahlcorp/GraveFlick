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

    /// `event`, when present, replaces the plain per-combo +25 bump with a flat multiplier on the
    /// zombie's base score — score for *how* a zombie died, not merely how many died in a row. See
    /// `ComboEvent` and GameScene.defeat(_:reason:...) for detection.
    static func score(for kind: ZombieKind, combo: Int, event: ComboEvent? = nil) -> Int {
        guard let event else { return kind.scoreValue + max(0, combo - 1) * 25 }
        return Int((CGFloat(kind.scoreValue) * event.multiplier).rounded())
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
        // Three-way rotation, not just two — checked in this order so every 15-wave block sees
        // all three once: 5→butcher, 10→colossus, 15→bouncer, 20→colossus, 25→butcher, 30→bouncer...
        if wave.isMultiple(of: 15) { return .bouncer }
        return wave.isMultiple(of: 10) ? .colossus : .butcher
    }

    /// Odds a wave rolls a WaveModifier at all (see GameScene.rollWaveModifier) — rare and mild
    /// early, common by the time a run is deep enough to already be numerically brutal, so
    /// escalation stops meaning "the same fight with bigger numbers" long before raw scaling
    /// alone would make that obvious. Reuses survivalDifficulty's tier grouping (every 5 waves).
    static func waveModifierChance(wave: Int) -> Double {
        let tier = (max(1, wave) - 1) / 5
        return min(0.65, 0.15 + Double(tier) * 0.10)
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

/// Named, skill-based kill events — the "personality" of a GraveFlick combo. Detected in
/// GameScene.defeat(_:reason:...) from *how* a zombie died (flicked clear off the screen, killed
/// by another zombie, chained through several targets with one throw, caught mid-bite at the
/// diner, ...) rather than purely how many kills happened in a row. Exactly one event (the
/// highest-priority match, see GameScene.comboEvent(for:...)) applies per kill; ordinary kills
/// with no qualifying event keep the plain per-combo score bump from `GameRules.score`.
enum ComboEvent: CaseIterable {
    /// A flicked/knocked-back zombie sent clean off the play area boundary without ever landing.
    case airMail
    /// A zombie killed by colliding with another zombie — turning one enemy into a weapon.
    case friendlyFire
    /// The bowling ball claims a second (or later) kill on the same roll.
    case zombieBowling
    /// An explosion claims a second (or later) kill in the same blast.
    case chainReaction
    /// A zombie killed while actively latched onto (or parked biting) the diner — a clutch save.
    case dinerSpecial
    /// A monster-power flick (see ZombieNode.lastImpactPower) kills its target on ground impact.
    case headOverHeels
    /// A long, unbroken combo streak.
    case graveyardShift
    /// Two kills within a fraction of a second of each other, by any means.
    case doubleTap

    var displayName: String {
        switch self {
        case .airMail: "AIR MAIL"
        case .friendlyFire: "FRIENDLY FIRE"
        case .zombieBowling: "ZOMBIE BOWLING"
        case .chainReaction: "CHAIN REACTION"
        case .dinerSpecial: "DINER SPECIAL"
        case .headOverHeels: "HEAD OVER HEELS"
        case .graveyardShift: "GRAVEYARD SHIFT"
        case .doubleTap: "DOUBLE TAP"
        }
    }

    var multiplier: CGFloat {
        switch self {
        case .doubleTap: 1.5
        case .airMail: 1.6
        case .friendlyFire: 1.8
        case .dinerSpecial: 1.9
        case .zombieBowling: 2.0
        case .chainReaction: 2.0
        case .headOverHeels: 2.2
        case .graveyardShift: 2.4
        }
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
