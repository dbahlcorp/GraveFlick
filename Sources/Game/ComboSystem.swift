import SpriteKit

/// Why a zombie was defeated — drives which death animation plays (see `defeatStyle`), which
/// combo-event checks apply, and gore/VFX intensity/style (see GameScene.spawnPhysicsDebris).
enum DefeatReason { case impact, collision, weapon, trap, thrownOut, explosion }

@MainActor
protocol ComboSystemHost: AnyObject {
    var world: SKNode { get }
    var size: CGSize { get }
    var settings: GameSettings { get }
    var level: GameLevel { get }
    var elapsedTime: TimeInterval { get }
    var health: Int { get }
    var startingHealth: Int { get }
    var wave: Int { get }
    var spawnedInWave: Int { get }
    var currentWaveTarget: Int { get }
    var activeZombies: [ZombieNode] { get }
    var specialCharge: Double { get set }
    var sandboxDefeats: Int { get set }
    var finishingReplayUsed: Bool { get set }
    var bossHUD: SKNode { get }
    var perkSystem: PerkSystem { get }

    func run(_ action: SKAction, withKey key: String)
    func audioPan(for zombie: ZombieNode) -> Float
    func spawnPhysicsDebris(from zombie: ZombieNode, reason: DefeatReason)
    func playCombatVFX(_ effect: CombatVFX, at point: CGPoint, size: CGFloat, direction: CGFloat, tint: SKColor?)
    func burst(at point: CGPoint, color: SKColor)
    func runHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle)
    func impactHapticStyle(for power: CGFloat) -> UIImpactFeedbackGenerator.FeedbackStyle
    func shakeCamera(intensity: CGFloat)
    func hitStop(duration: TimeInterval, slowFactor: CGFloat)
    func spawnPickup(at point: CGPoint)
    func explodeVolatile(at point: CGPoint)
}

/// Kill scoring, combo tracking, and the on-kill feedback (combo/event/score popups) it triggers.
/// Owned by GameScene via `comboSystem`. `defeat(_:reason:...)` is the single entry point every
/// weapon/trap/collision/impact/thrown-out death routes through.
///
/// @MainActor because GameScene (its sole host/caller) is implicitly main-actor-isolated via
/// SKScene, and defeat() calls SoundManager (also @MainActor) directly.
@MainActor
final class ComboSystem {
    weak var host: ComboSystemHost?

    private(set) var score = 0
    private(set) var combo = 0
    private(set) var maxCombo = 0
    private(set) var defeats = 0
    private var lastDefeatTime: TimeInterval = -10

    /// Reset on any diner bite (see GameScene.resolveDinerAttack) — taking damage breaks the chain.
    func resetCombo() { combo = 0 }

    /// Non-kill scoring (coin pickups) still gets the same "+score" popup as a kill does, so
    /// picking one up feels rewarding even without a combo attached.
    func awardPickupScore(_ amount: Int, at point: CGPoint) {
        score += amount
        showScorePopup(at: point, score: amount)
    }

    func defeat(_ zombie: ZombieNode, reason: DefeatReason, multiKillTally: Int = 1, weaponKind: WeaponKind? = nil) {
        guard zombie.parent != nil, !zombie.isDefeated else { return }
        guard let host else { return }
        let gapSincePreviousKill = host.elapsedTime - lastDefeatTime
        if gapSincePreviousKill <= 1.8 + host.perkSystem.comboWindowBonus { combo += 1 } else { combo = 1 }
        maxCombo = max(maxCombo, combo)
        defeats += 1
        if host.level.isSandbox { host.sandboxDefeats += 1 }
        lastDefeatTime = host.elapsedTime
        // 0 unless this kill was the direct result of a flick/knockback landing or slamming into
        // something (see ZombieNode.lastImpactPower) — a weapon/trap/collision kill with no throw
        // of its own keeps the previous fixed feel below.
        let power = zombie.lastImpactPower
        // Read before playDefeat() below overwrites it to .defeated — DINER SPECIAL needs to know
        // whether this zombie was actively latched onto the diner at the moment it died.
        let preDefeatState = zombie.currentAnimationState
        let event = comboEvent(
            reason: reason, combo: combo, gapSincePreviousKill: gapSincePreviousKill,
            multiKillTally: multiKillTally, weaponKind: weaponKind, impactPower: power, preDefeatState: preDefeatState
        )
        let killScore = GameRules.score(for: zombie.kind, combo: combo, event: event)
        score += killScore
        let chargeGain = (zombie.kind.isBoss ? 0.5 : (zombie.kind == .brute ? 0.22 : 0.12)) * Double(host.perkSystem.chargeRushBonus)
        host.specialCharge = min(1, host.specialCharge + chargeGain)
        let point = zombie.position
        let volatile = zombie.kind == .volatile
        if host.settings.goreEnabled {
            host.spawnPhysicsDebris(from: zombie, reason: reason)
        }
        zombie.playDefeat(style: defeatStyle(for: reason), reducedMotion: host.settings.reducedMotion) {}
        if zombie.kind.isBoss {
            host.bossHUD.isHidden = true
            SoundManager.shared.updateGameplayMix(wave: host.wave, healthFraction: CGFloat(host.health) / CGFloat(max(1, host.startingHealth)))
        }
        // Computed fresh here rather than trusting `spawningFinished`: that flag only updates once
        // per frame in updateCampaignWave, which runs before this frame's physics contacts resolve,
        // so it's always one kill behind the zombie that's actually dying right now.
        let isFinalCampaignKill = !host.level.isEndless && !host.level.isSandbox
            && host.wave >= host.level.totalWaves
            && host.spawnedInWave >= host.currentWaveTarget
            && host.activeZombies.allSatisfy { $0.isDefeated }
        if !host.finishingReplayUsed, !host.settings.reducedMotion, (zombie.kind.isBoss || isFinalCampaignKill) {
            host.finishingReplayUsed = true
            host.world.speed = 0.22
            host.run(.sequence([.wait(forDuration: 0.5), .run { [weak host] in host?.world.speed = 1 }]), withKey: "finisherReplay")
        }
        if reason == .thrownOut {
            host.burst(at: point, color: .cyan)
        } else if reason != .explosion {
            let baseSplatterSize: CGFloat = zombie.kind.isBoss ? 210 : (zombie.kind == .brute ? 156 : 118)
            host.playCombatVFX(.zombieSplatter, at: point, size: baseSplatterSize + power * 48, direction: zombie.approachesFromLeft ? -1 : 1, tint: nil)
        }
        SoundManager.shared.play(.defeat, comboScale: combo, intensity: 0.8 + power * 0.75)
        if zombie.kind.isBoss || zombie.kind.alwaysVocalizesOnDefeat || Int.random(in: 0..<3) == 0 {
            SoundManager.shared.playZombieVoice(for: zombie.kind, moment: .defeat, pan: host.audioPan(for: zombie))
        }
        // A flick/knockback-driven kill scales its haptic and screen shake with how hard it was
        // actually hit instead of every kill feeling identically "medium" — a bare stumble kill
        // reads lighter, a monster-flick slam kill hits noticeably harder.
        host.runHaptic(power > 0 ? host.impactHapticStyle(for: power) : .medium)
        if power > 0.3 { host.shakeCamera(intensity: 0.2 + power * 1.1) }
        showScorePopup(at: point, score: killScore)
        if let event {
            showComboEvent(event, at: point, power: power)
        } else {
            showCombo(at: point)
        }
        host.hitStop(duration: min(0.13, 0.045 + Double(combo) * 0.004 + Double(power) * 0.05), slowFactor: 0.04)
        if Int.random(in: 0..<5) == 0 { host.spawnPickup(at: point) }
        if volatile, reason != .explosion { host.explodeVolatile(at: point) }
    }

    /// Picks the single highest-priority named event this kill qualifies for (see ComboEvent's
    /// case docs), or nil for an ordinary kill. Order matters: a rarer, more specific feat (e.g. a
    /// bowling multi-kill) wins over a merely-coincidental one (two unrelated kills that happened
    /// to land within a fraction of a second of each other).
    private func comboEvent(
        reason: DefeatReason,
        combo: Int,
        gapSincePreviousKill: TimeInterval,
        multiKillTally: Int,
        weaponKind: WeaponKind?,
        impactPower: CGFloat,
        preDefeatState: ZombieAnimationState
    ) -> ComboEvent? {
        if reason == .thrownOut { return .airMail }
        if reason == .collision { return .friendlyFire }
        if reason == .weapon, weaponKind == .bowlingBall, multiKillTally >= 2 { return .zombieBowling }
        if reason == .explosion, multiKillTally >= 2 { return .chainReaction }
        if preDefeatState == .attacking || preDefeatState == .holdingAtDiner { return .dinerSpecial }
        if reason == .impact, impactPower > 0.85 { return .headOverHeels }
        if combo >= 6 { return .graveyardShift }
        if combo >= 2, gapSincePreviousKill < 0.35 { return .doubleTap }
        return nil
    }

    private func defeatStyle(for reason: DefeatReason) -> ZombieDefeatStyle {
        switch reason {
        case .impact: .pavement
        case .collision: .collision
        case .weapon: .weapon
        case .trap: .trap
        case .thrownOut: .thrownOut
        case .explosion: .explosion
        }
    }

    private func showCombo(at point: CGPoint) {
        guard combo >= 2, let host else { return }
        let label = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        label.text = "×\(combo) COMBO"
        label.fontSize = min(42, 22 + CGFloat(combo))
        label.fontColor = SKColor(hue: max(0, 0.14 - CGFloat(combo) * 0.01), saturation: 1, brightness: 1, alpha: 1)
        label.position = CGPoint(x: point.x, y: min(host.size.height - 60, point.y + 52))
        label.zPosition = 120
        label.setScale(0.6)
        host.world.addChild(label)
        label.run(.sequence([
            .group([.scale(to: 1, duration: 0.12), .moveBy(x: 0, y: 8, duration: 0.12)]),
            .group([.moveBy(x: 0, y: 26, duration: 0.5), .fadeOut(withDuration: 0.5)]),
            .removeFromParent()
        ]))
    }

    /// The named-event banner (see ComboEvent) — the top of the on-kill feedback hierarchy: it
    /// must always read as bigger and land faster than the score/combo popups underneath it and
    /// the delayed achievement toast above it (see GameScene.showFeatToast), since it's calling
    /// out *how* the kill happened rather than just a running count or a longer-term unlock.
    private func showComboEvent(_ event: ComboEvent, at point: CGPoint, power: CGFloat) {
        guard let host else { return }
        let label = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        label.text = event.displayName
        label.fontSize = 32 + power * 12
        label.fontColor = comboEventColor(event)
        label.horizontalAlignmentMode = .center
        label.position = CGPoint(x: point.x, y: min(host.size.height - 64, point.y + 56))
        label.zPosition = 121
        label.setScale(0.4)
        label.zRotation = CGFloat.random(in: -0.05...0.05)
        host.world.addChild(label)
        label.run(.sequence([
            .group([.scale(to: 1.22, duration: 0.06), .moveBy(x: 0, y: 10, duration: 0.06)]),
            .scale(to: 1, duration: 0.05),
            .wait(forDuration: 0.32),
            .group([.moveBy(x: 0, y: 24, duration: 0.42), .fadeOut(withDuration: 0.42), .scale(to: 0.85, duration: 0.42)]),
            .removeFromParent()
        ]))
    }

    private func comboEventColor(_ event: ComboEvent) -> SKColor {
        switch event {
        case .airMail: SKColor(red: 0.42, green: 0.78, blue: 1.0, alpha: 1)
        case .friendlyFire: SKColor(red: 1.0, green: 0.55, blue: 0.18, alpha: 1)
        case .zombieBowling: SKColor(red: 0.95, green: 0.92, blue: 0.55, alpha: 1)
        case .chainReaction: SKColor(red: 1.0, green: 0.42, blue: 0.24, alpha: 1)
        case .dinerSpecial: SKColor(red: 0.55, green: 1.0, blue: 0.62, alpha: 1)
        case .headOverHeels: SKColor(red: 1.0, green: 0.32, blue: 0.68, alpha: 1)
        case .graveyardShift: SKColor(red: 0.72, green: 0.58, blue: 1.0, alpha: 1)
        case .doubleTap: SKColor(red: 1.0, green: 0.86, blue: 0.32, alpha: 1)
        }
    }

    /// A floating "+score" popup on every kill, not just combo chains, so single defeats still feel rewarding.
    private func showScorePopup(at point: CGPoint, score: Int) {
        guard let host else { return }
        let label = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        label.text = "+\(score)"
        label.fontSize = 17
        label.fontColor = .white.withAlphaComponent(0.85)
        label.position = CGPoint(x: point.x, y: min(host.size.height - 40, point.y + 18))
        label.zPosition = 118
        host.world.addChild(label)
        label.run(.sequence([.group([.moveBy(x: 0, y: 22, duration: 0.45), .fadeOut(withDuration: 0.45)]), .removeFromParent()]))
    }
}
