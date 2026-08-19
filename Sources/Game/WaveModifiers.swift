import Foundation

/// Endless-mode wave modifiers — rolled once per wave (see GameScene.rollWaveModifier), on top of
/// GameRules.survivalDifficulty's numeric scaling, so a run doesn't just become "the same fight
/// with bigger numbers." Unlike Perk (player-chosen, stacking, permanent for the run), a modifier
/// is imposed, exclusive (only one active at a time), and lasts exactly one wave.
enum WaveModifier: String, CaseIterable, Identifiable {
    case fog
    case blackout
    case rushHour
    case heavyweights
    case explodersOnly
    case graveTimeDisabled
    case doubleBoss

    var id: String { rawValue }

    /// Full banner text shown alongside the wave/boss announcement.
    var title: String {
        switch self {
        case .fog: "FOG ROLLING IN"
        case .blackout: "BLACKOUT"
        case .rushHour: "RUSH HOUR"
        case .heavyweights: "HEAVYWEIGHTS ONLY"
        case .explodersOnly: "EXPLODERS ONLY"
        case .graveTimeDisabled: "GRAVE TIME OFFLINE"
        case .doubleBoss: "DOUBLE BOSS"
        }
    }

    /// Short form for the persistent wave-status HUD strip, which has much less room than the banner.
    var badge: String {
        switch self {
        case .fog: "FOG"
        case .blackout: "BLACKOUT"
        case .rushHour: "RUSH HOUR"
        case .heavyweights: "HEAVYWEIGHTS"
        case .explodersOnly: "EXPLODERS ONLY"
        case .graveTimeDisabled: "NO GRAVE TIME"
        case .doubleBoss: "DOUBLE BOSS"
        }
    }

    /// `.doubleBoss` only means anything on a boss wave (spawns a second boss); the spawn-pool
    /// filters (`.heavyweights`/`.explodersOnly`) and `.rushHour`'s spawn-rate bump would be inert
    /// on one, since a boss wave's spawn logic replaces the regular pool with just the boss (see
    /// GameScene.update). `.fog`/`.blackout`/`.graveTimeDisabled` work regardless.
    static func eligible(forBossWave isBossWave: Bool) -> [WaveModifier] {
        if isBossWave {
            return [.doubleBoss, .blackout, .fog, .graveTimeDisabled]
        }
        return [.fog, .blackout, .rushHour, .heavyweights, .explodersOnly, .graveTimeDisabled]
    }
}
