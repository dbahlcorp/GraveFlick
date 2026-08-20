import SpriteKit
import UIKit

@MainActor
protocol BossDirectorHost: AnyObject {
    var wave: Int { get }
    var health: Int { get }
    var startingHealth: Int { get }
    var highestCompletedCampaignLevel: Int { get }

    func announce(text: String, color: SKColor, subtitle: String?, subtitleColor: SKColor)
    func shakeCamera(intensity: CGFloat)
    func runHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle)
    func audioPan(for zombie: ZombieNode) -> Float
    func playCombatVFX(_ effect: CombatVFX, at point: CGPoint, size: CGFloat, direction: CGFloat, tint: SKColor?)
}

/// Boss HUD, boss-kind resolution, and the boss-only hooks a spawned zombie needs (armor/phase
/// callbacks, the Bouncer's armor-strip rule). Owned by GameScene via `bossDirector`. Does not own
/// spawning itself — `spawnZombie()` stays on GameScene and calls `configureBossHooks(on:)` right
/// after adding a zombie to the world, since spawning is entangled with roster/weapon/sandbox
/// concerns that aren't extracted.
///
/// @MainActor because GameScene (its sole host/caller) is implicitly main-actor-isolated via
/// SKScene, and several methods here call SoundManager (also @MainActor) directly.
@MainActor
final class BossDirector {
    weak var host: BossDirectorHost?

    let bossHUD = SKNode()
    private let bossHealthFill = SKShapeNode(rectOf: CGSize(width: 260, height: 12), cornerRadius: 6)
    private let bossNameLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")

    /// Builds the HUD node tree; the caller still has to `addChild(bossDirector.bossHUD)` onto the
    /// scene itself (not `world`) so it doesn't shake/scroll with combat VFX.
    func build(sceneSize: CGSize) {
        bossHUD.zPosition = 190
        bossHUD.position = CGPoint(x: sceneSize.width / 2, y: sceneSize.height - 48)
        bossHUD.isHidden = true

        let backing = SKShapeNode(rectOf: CGSize(width: 276, height: 28), cornerRadius: 8)
        backing.fillColor = .black.withAlphaComponent(0.78)
        backing.strokeColor = SKColor(red: 0.92, green: 0.22, blue: 0.16, alpha: 1)
        backing.lineWidth = 2
        bossHUD.addChild(backing)

        bossHealthFill.fillColor = SKColor(red: 0.92, green: 0.16, blue: 0.11, alpha: 1)
        bossHealthFill.strokeColor = .clear
        bossHealthFill.position.y = -4
        bossHUD.addChild(bossHealthFill)

        bossNameLabel.fontSize = 12
        bossNameLabel.fontColor = .white
        bossNameLabel.verticalAlignmentMode = .center
        bossNameLabel.position.y = 11
        bossHUD.addChild(bossNameLabel)
    }

    private func showHUD(for zombie: ZombieNode) {
        bossNameLabel.text = zombie.kind.displayName
        bossHealthFill.xScale = 1
        bossHUD.isHidden = false
        zombie.onHealthChanged = { [weak self] fraction in
            self?.bossHealthFill.xScale = max(0.001, fraction)
        }
    }

    /// The wave's naturally-rotated boss (see GameRules.bossKind), downgraded to `.butcher` if
    /// campaign hasn't unlocked it yet (see GameRules.unlockedBossKinds) — so Colossus/Bouncer
    /// showing up in an endless run means the player actually beat the campaign level that
    /// introduces them, not just that the wave number happened to line up.
    func resolvedBossKind(forWave wave: Int) -> ZombieKind? {
        guard let natural = GameRules.bossKind(forWave: wave) else { return nil }
        let unlocked = GameRules.unlockedBossKinds(highestCompletedLevel: host?.highestCompletedCampaignLevel ?? 0)
        return unlocked.contains(natural) ? natural : .butcher
    }

    /// Picks a random boss kind other than `kind` for DOUBLE BOSS — a list rather than a hardcoded
    /// pair so it automatically includes whatever boss kinds exist as more get added. Restricted
    /// to bosses this campaign progress has actually unlocked, same as `resolvedBossKind`, so
    /// DOUBLE BOSS can't hand a player a boss they haven't earned yet just because it rolled
    /// alongside one they have.
    func otherBossKind(than kind: ZombieKind) -> ZombieKind {
        GameRules.unlockedBossKinds(highestCompletedLevel: host?.highestCompletedCampaignLevel ?? 0)
            .filter { $0 != kind }.randomElement() ?? .butcher
    }

    /// Called right after a zombie is added to `world` — wires the armor/phase callbacks every
    /// zombie carries (harmless no-ops for non-armored/non-boss kinds) and, for an actual boss,
    /// shows the HUD and plays its spawn stinger.
    func configureBossHooks(on zombie: ZombieNode) {
        zombie.onArmorBroken = { SoundManager.shared.play(.armorBreak) }
        zombie.onArmorFullyStripped = { [weak host, weak zombie] in
            guard let host, let zombie else { return }
            host.announce(text: "\(zombie.kind.displayName) IS EXPOSED!", color: .cyan, subtitle: nil, subtitleColor: .white)
            SoundManager.shared.play(.armorBreak)
            host.shakeCamera(intensity: 0.6)
            host.runHaptic(.heavy)
        }
        zombie.onBossPhaseChanged = { [weak host, weak zombie] phase in
            guard let host, let zombie else { return }
            SoundManager.shared.playBossPhase(phase, pan: host.audioPan(for: zombie))
            SoundManager.shared.updateGameplayMix(
                wave: host.wave,
                healthFraction: CGFloat(host.health) / CGFloat(max(1, host.startingHealth)),
                bossPhase: phase
            )
        }
        if zombie.kind.isBoss {
            showHUD(for: zombie)
            SoundManager.shared.playZombieVoice(for: zombie.kind, moment: .spawn, pan: host?.audioPan(for: zombie) ?? 0)
            SoundManager.shared.playBossLayer(phase: 1)
        } else if Int.random(in: 0..<4) == 0 {
            SoundManager.shared.playZombieVoice(for: zombie.kind, moment: .spawn, pan: host?.audioPan(for: zombie) ?? 0)
        }
    }

    /// THE BOUNCER: armor only comes off when another zombie is genuinely thrown or knocked into
    /// it (`isThrown`), not just incidental crowd-pressure contact — weapons and traps never strip
    /// it either, only this. That's deliberate: the whole point is a boss that makes the player
    /// actually use the flick/knockback systems on other zombies instead of just pouring more
    /// weapon damage into a health bar. No-ops for every other kind.
    func handleBouncerArmorStrip(_ zombie: ZombieNode, thrownInto otherZombie: ZombieNode?, at contactPoint: CGPoint) {
        guard zombie.kind == .bouncer, zombie.isArmored, let otherZombie, otherZombie.isThrown else { return }
        zombie.knockArmorPlate()
        host?.playCombatVFX(.zombieSplatter, at: contactPoint, size: 64, direction: 1, tint: nil)
        SoundManager.shared.play(.armorBreak)
        host?.shakeCamera(intensity: 0.4)
    }
}
