import SpriteKit

@MainActor
protocol SpawnDirectorHost: AnyObject {
    var world: SKNode { get }
    var size: CGSize { get }
    var settings: GameSettings { get }
    var level: GameLevel { get }
    var elapsedTime: TimeInterval { get }
    var health: Int { get }
    var startingHealth: Int { get }
    var gameOver: Bool { get }
    var activeZombies: [ZombieNode] { get }
    var houseFrame: CGRect { get }
    var perkSystem: PerkSystem { get }
    var highestCompletedCampaignLevel: Int { get }

    func run(_ action: SKAction)
    func announce(text: String, color: SKColor, subtitle: String?, subtitleColor: SKColor)
    func spawnZombie(forceWalker: Bool, bossKind: ZombieKind?, forcedKind: ZombieKind?)
    func resolvedBossKind(forWave wave: Int) -> ZombieKind?
    func otherBossKind(than kind: ZombieKind) -> ZombieKind
    func finish(won: Bool)
}

/// Wave timing/progression (both endless and campaign) and the WaveModifier runtime it drives —
/// the WaveModifier-equivalent of PerkSystem (see WaveModifiers.swift for the `WaveModifier` enum
/// itself). Owned by GameScene via `spawnDirector`. Does not own the actual spawn mechanics
/// (`spawnZombie`, boss hookup) — those stay on GameScene since they're entangled with boss setup
/// that hasn't been extracted yet; this only decides *when* and *how many* to ask for.
///
/// @MainActor because GameScene (its sole host/caller) is implicitly main-actor-isolated via
/// SKScene, and the wave-transition functions call SoundManager (also @MainActor) directly.
@MainActor
final class SpawnDirector {
    weak var host: SpawnDirectorHost?

    private(set) var wave = 1
    /// Settable from outside (GameScene sets it to "SANDBOX" for sandbox levels, which never call
    /// `updateEndlessWave`/`updateCampaignWave`) as well as internally during wave transitions.
    var waveStatus = "WAVE 1"
    var waveStatusHighlighted = false
    var spawnedInWave = 0
    var currentWaveTarget = 0
    private var intermissionRemaining: TimeInterval = 0
    private var spawningFinished = false
    private var timeSinceSpawn: TimeInterval = 0
    private var spawnedBossWaves: Set<Int> = []
    /// Endless-only, re-rolled once per wave (see `rollWaveModifier`) — unlike a perk pick,
    /// exclusive (only one at a time) and lasts exactly one wave rather than accumulating.
    private(set) var activeModifier: WaveModifier?
    private var modifierOverlayNode: SKNode?
    private var rolledModifierWaves: Set<Int> = []
    var sandboxSpeed: CGFloat = 1
    var sandboxSpawnBurst = 1

    func updateEndlessWave(deltaTime: TimeInterval) {
        guard let host else { return }
        timeSinceSpawn += deltaTime
        let newWave = Int(host.elapsedTime / host.level.waveDuration) + 1
        if newWave != wave {
            wave = newWave
            SoundManager.shared.updateGameplayMix(wave: wave, healthFraction: CGFloat(host.health) / CGFloat(max(1, host.startingHealth)))
            let incomingBoss = host.resolvedBossKind(forWave: wave)
            rollWaveModifier()
            if let activeModifier {
                host.announce(
                    text: incomingBoss.map { "\($0.displayName) INCOMING" } ?? "WAVE \(wave)", color: .white,
                    subtitle: activeModifier.title, subtitleColor: modifierColor(activeModifier)
                )
            } else {
                host.announce(text: incomingBoss.map { "\($0.displayName) INCOMING" } ?? "WAVE \(wave)", color: .white, subtitle: nil, subtitleColor: .white)
            }
            // Same cadence as the boss wave check just above — every 5th wave doubles as both
            // a boss intro and a "level up before the fight" perk pick.
            host.perkSystem.offerChoices(forWave: wave)
        }
        waveStatus = activeModifier.map { "SURVIVE — \($0.badge)" } ?? "SURVIVE"
        waveStatusHighlighted = activeModifier != nil
        let difficulty = GameRules.survivalDifficulty(wave: wave, baseSpawnInterval: host.level.baseSpawnInterval)
        // RUSH HOUR: noticeably faster and denser than the wave's own numeric ramp alone would
        // ever get, for exactly one wave — meant to spike, not to be the new normal.
        let interval = activeModifier == .rushHour ? difficulty.spawnInterval * 0.55 : difficulty.spawnInterval
        if timeSinceSpawn >= interval {
            timeSinceSpawn = 0
            let bossKind = host.resolvedBossKind(forWave: wave)
            if let bossKind, !spawnedBossWaves.contains(wave) {
                spawnedBossWaves.insert(wave)
                host.spawnZombie(forceWalker: false, bossKind: bossKind, forcedKind: nil)
                // DOUBLE BOSS: the wave's other boss kind joins a couple seconds later, once
                // the first has had a moment to make its entrance.
                if activeModifier == .doubleBoss {
                    let second = host.otherBossKind(than: bossKind)
                    host.run(.sequence([.wait(forDuration: 2), .run { [weak host] in
                        guard let host, !host.gameOver else { return }
                        host.spawnZombie(forceWalker: false, bossKind: second, forcedKind: nil)
                    }]))
                }
            } else if bossKind == nil {
                let spawnCount = activeModifier == .rushHour ? difficulty.spawnCount + 1 : difficulty.spawnCount
                for _ in 0..<spawnCount {
                    host.spawnZombie(forceWalker: false, bossKind: nil, forcedKind: modifierForcedSpawnKind())
                }
            }
        }
    }

    func updateCampaignWave(deltaTime: TimeInterval) {
        guard let host else { return }
        timeSinceSpawn += deltaTime
        if intermissionRemaining > 0 {
            intermissionRemaining -= deltaTime
            if intermissionRemaining <= 0 {
                if spawningFinished {
                    host.finish(won: true)
                } else {
                    wave += 1
                    spawnedInWave = 0
                    timeSinceSpawn = 99
                    waveStatus = "WAVE \(wave)"
                    waveStatusHighlighted = false
                    SoundManager.shared.updateGameplayMix(wave: wave, healthFraction: CGFloat(host.health) / CGFloat(max(1, host.startingHealth)))
                    let boss = GameRules.storyBossKind(levelID: host.level.id, wave: wave, totalWaves: host.level.totalWaves)
                    host.announce(text: boss.map { "\($0.displayName) INCOMING" } ?? "WAVE \(wave)", color: .white, subtitle: nil, subtitleColor: .white)
                }
            }
            return
        }

        let bossKind = GameRules.storyBossKind(levelID: host.level.id, wave: wave, totalWaves: host.level.totalWaves)
        let target = bossKind == nil
            ? GameRules.campaignSpawnCount(wave: wave, waveDuration: host.level.waveDuration, baseSpawnInterval: host.level.baseSpawnInterval)
            : 1
        currentWaveTarget = target
        let interval = max(0.48, (host.level.baseSpawnInterval - Double(wave - 1) * 0.09) * host.settings.difficulty.spawnRate)
        if spawnedInWave < target, timeSinceSpawn >= interval {
            timeSinceSpawn = 0
            if let bossKind {
                if !spawnedBossWaves.contains(wave) {
                    spawnedBossWaves.insert(wave)
                    host.spawnZombie(forceWalker: false, bossKind: bossKind, forcedKind: nil)
                    spawnedInWave += 1
                }
            } else {
                host.spawnZombie(forceWalker: false, bossKind: nil, forcedKind: nil)
                spawnedInWave += 1
            }
        }

        let livingCount = host.activeZombies.filter { !$0.isDefeated }.count
        if spawnedInWave >= target, livingCount == 0 {
            spawningFinished = wave >= host.level.totalWaves
            intermissionRemaining = 1.25
            waveStatus = spawningFinished ? "NIGHT CLEARED" : "WAVE \(wave) CLEAR"
            waveStatusHighlighted = true
            host.announce(text: waveStatus, color: SKColor(red: 1, green: 0.77, blue: 0.24, alpha: 1), subtitle: nil, subtitleColor: .white)
            SoundManager.shared.play(.waveClear)
        } else {
            let unspawned = max(0, target - spawnedInWave)
            waveStatus = "\(livingCount + unspawned) LEFT"
            waveStatusHighlighted = false
        }
    }

    /// Rolls (or clears) this wave's WaveModifier — called once per endless wave transition, right
    /// before the wave/boss announcement so the two can render as one combined banner. Doesn't
    /// re-roll if already rolled for this exact wave number, so resuming from the perk-choice
    /// pause on a boss wave can't double-roll.
    private func rollWaveModifier() {
        modifierOverlayNode?.removeFromParent()
        modifierOverlayNode = nil
        guard !rolledModifierWaves.contains(wave) else { return }
        rolledModifierWaves.insert(wave)
        let isBossWave = GameRules.bossKind(forWave: wave) != nil
        guard wave > 2, Double.random(in: 0..<1) < GameRules.waveModifierChance(wave: wave) else {
            activeModifier = nil
            return
        }
        // Campaign progress gates the wilder modifiers (see WaveModifier.requiredCampaignLevel) —
        // fog/rush hour stay available from the start, but e.g. GRAVE TIME OFFLINE only shows up
        // once the player has actually finished the campaign that taught them to rely on it.
        let unlockedModifiers = WaveModifier.eligible(forBossWave: isBossWave)
            .filter { $0.requiredCampaignLevel <= (host?.highestCompletedCampaignLevel ?? 0) }
        let modifier = unlockedModifiers.randomElement()
        activeModifier = modifier
        guard let modifier else { return }
        if modifier == .fog || modifier == .blackout { showModifierOverlay(modifier) }
    }

    private func modifierColor(_ modifier: WaveModifier) -> SKColor {
        switch modifier {
        case .fog: SKColor(white: 0.82, alpha: 1)
        case .blackout: SKColor(red: 0.55, green: 0.42, blue: 0.95, alpha: 1)
        case .rushHour: .orange
        case .heavyweights: SKColor(red: 0.95, green: 0.42, blue: 0.30, alpha: 1)
        case .explodersOnly: SKColor(red: 0.34, green: 0.90, blue: 0.42, alpha: 1)
        case .graveTimeDisabled: .cyan
        case .doubleBoss: SKColor(red: 1, green: 0.24, blue: 0.24, alpha: 1)
        }
    }

    /// A translucent full-screen wash — grayish for FOG, near-black for BLACKOUT — layered above
    /// the environment art but below the HUD/combat VFX zPositions, torn down by the next
    /// `rollWaveModifier()` call whether or not a new overlay replaces it.
    private func showModifierOverlay(_ modifier: WaveModifier) {
        guard let host, !host.settings.reducedMotion else { return }
        let overlay = SKShapeNode(rectOf: CGSize(width: host.size.width + 40, height: host.size.height + 40))
        overlay.fillColor = modifier == .blackout ? .black : SKColor(white: 0.7, alpha: 1)
        overlay.strokeColor = .clear
        overlay.position = CGPoint(x: host.size.width / 2, y: host.size.height / 2)
        overlay.zPosition = 60
        overlay.alpha = 0
        overlay.isUserInteractionEnabled = false
        host.world.addChild(overlay)
        overlay.run(.fadeAlpha(to: modifier == .blackout ? 0.55 : 0.32, duration: 0.6))
        modifierOverlayNode = overlay
    }

    /// FOG/BLACKOUT: an approaching zombie fades in from near-invisible as it closes in on the
    /// diner instead of being clearly visible the moment it spawns off-screen. Only applies while
    /// a zombie is plainly walking — grabbed/thrown/otherwise-engaged zombies stay fully visible,
    /// since the player is already actively dealing with them.
    func applyVisibilityModifier(to zombie: ZombieNode) {
        guard let host, let activeModifier, activeModifier == .fog || activeModifier == .blackout,
              zombie.currentAnimationState == .walking else {
            zombie.alpha = 1
            return
        }
        let distanceToHouse = abs(zombie.position.x - host.houseFrame.midX)
        let revealDistance: CGFloat = activeModifier == .blackout ? 220 : 340
        let baseAlpha: CGFloat = activeModifier == .blackout ? 0.10 : 0.28
        let proximity = 1 - min(1, max(0, distanceToHouse / revealDistance))
        zombie.alpha = baseAlpha + (1 - baseAlpha) * proximity
    }

    /// HEAVYWEIGHTS/EXPLODERS ONLY: constrains the random pick a plain (non-boss) endless spawn
    /// would otherwise make from the level's full roster. nil (the default spawn pool) otherwise.
    private func modifierForcedSpawnKind() -> ZombieKind? {
        switch activeModifier {
        case .heavyweights: [.brute, .armored, .riot, .groundskeeper].randomElement()
        case .explodersOnly: .volatile
        default: nil
        }
    }
}
