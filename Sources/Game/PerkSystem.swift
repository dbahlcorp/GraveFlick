import SpriteKit

@MainActor
protocol PerkSystemHost: AnyObject {
    var isGameplayPaused: Bool { get set }
    var gameOver: Bool { get }
    func notifyDelegate()
    func run(_ action: SKAction)
}

/// Endless-mode roguelite perk state and the mechanical bonuses every perk hook reads — see
/// `Perk` (Perks.swift) for the enum itself. Owned by GameScene via `perkSystem`; never persisted
/// past the run (unlike PlayerProgress's permanent upgrades).
///
/// @MainActor because GameScene (its sole host/caller) is implicitly main-actor-isolated via
/// SKScene, and this needs to match so cross-references type-check.
@MainActor
final class PerkSystem {
    weak var host: PerkSystemHost?

    /// Keyed by perk rather than a flat list so picking the same perk again on a later offer
    /// stacks its effect instead of being a no-op; every mechanical hook reads its count via
    /// `stacks(_:)`.
    private(set) var activePerks: [Perk: Int] = [:]
    private(set) var pendingPerkChoices: [Perk] = []
    private var offeredPerkWaves: Set<Int> = []

    func stacks(_ perk: Perk) -> Int { activePerks[perk] ?? 0 }

    var flickVelocityBonus: CGFloat { 1 + CGFloat(stacks(.flickVelocity)) * 0.20 }
    var volatileBlastRadiusBonus: CGFloat { 1 + CGFloat(stacks(.volatileBlastRadius)) * 0.35 }
    var explosiveWeaponRadiusBonus: CGFloat { 1 + CGFloat(stacks(.explosiveWeaponRadius)) * 0.30 }
    var graveTimeBonusDuration: TimeInterval { TimeInterval(stacks(.graveTimeExtended)) * 2 }
    var chargeRushBonus: CGFloat { 1 + CGFloat(stacks(.chargeRush)) * 0.25 }
    var nightShiftBonusMultiplier: CGFloat { 1 + CGFloat(stacks(.nightShiftBonus)) * 0.20 }
    /// Floored at 0.1 (never below 10% of normal damage) rather than letting enough stacks zero it
    /// out entirely — a maxed-out build should feel nearly invincible against bites, not literally
    /// immune; `resolveDinerAttack` also floors the final Int damage at 1 for the same reason.
    var fortifiedDinerReduction: CGFloat { max(0.1, 1 - CGFloat(stacks(.fortifiedDiner)) * 0.15) }
    var comboWindowBonus: TimeInterval { TimeInterval(stacks(.longerFuse)) * 0.4 }
    var hasBowlingRicochet: Bool { stacks(.bowlingRicochet) > 0 }
    var hasShockwaveSlams: Bool { stacks(.shockwaveSlams) > 0 }

    /// Every 5th endless wave, freeze gameplay and hand the player three random perks — reusing
    /// `isGameplayPaused` rather than any new pause mechanism, since it already stops physics/
    /// actions and cancels any in-progress weapon drag. Held back ~1s (run on the scene, not
    /// `world`, so it isn't affected by the pause it's about to cause) rather than firing in the
    /// same frame as the wave/boss `announce()` banner: pausing `world` immediately would
    /// otherwise freeze that banner visibly mid-fade underneath the perk picker the instant it
    /// appears — one more label fighting for the player's attention at the exact same moment.
    /// No-ops if `wave` isn't a due offer wave, or this exact wave was already offered — call
    /// unconditionally from the wave-transition check.
    func offerChoices(forWave wave: Int) {
        guard wave > 1, wave.isMultiple(of: 5), !offeredPerkWaves.contains(wave) else { return }
        offeredPerkWaves.insert(wave)
        host?.run(.sequence([.wait(forDuration: 1.0), .run { [weak self] in self?.presentChoices() }]))
    }

    private func presentChoices() {
        // The 1s delay above means the run can end before this fires (e.g. the player dies in
        // that window) — without this guard it would re-pause and re-open the picker on top of
        // an already-shown results screen.
        guard let host, !host.gameOver else { return }
        pendingPerkChoices = Array(Perk.allCases.shuffled().prefix(3))
        host.isGameplayPaused = true
        host.notifyDelegate()
    }

    /// Called by the SwiftUI perk picker (via GameSessionModel.choosePerk → GameScene.choosePerk)
    /// when the player taps one of the three offered cards.
    func choose(_ perk: Perk) {
        guard pendingPerkChoices.contains(perk) else { return }
        activePerks[perk, default: 0] += 1
        pendingPerkChoices = []
        host?.isGameplayPaused = false
        host?.notifyDelegate()
    }
}
