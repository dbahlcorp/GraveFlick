import Foundation

/// Endless-mode roguelite perks — offered three at a time every 5th wave (see
/// GameScene.offerPerkChoices), picked once per offer, never persisted past the run (unlike
/// PlayerProgress's permanent upgrades). Each can be chosen again on a later offer; GameScene
/// tracks how many times via `activePerks: [Perk: Int]` and every mechanical hook scales with
/// that stack count, so two runs that pick differently actually play differently.
enum Perk: String, CaseIterable, Codable, Identifiable {
    case flickVelocity
    case volatileBlastRadius
    case explosiveWeaponRadius
    case bowlingRicochet
    case graveTimeExtended
    case shockwaveSlams
    case chargeRush
    case nightShiftBonus
    case fortifiedDiner
    case longerFuse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flickVelocity: "GREASED LIGHTNING"
        case .volatileBlastRadius: "WALKING TIME BOMBS"
        case .explosiveWeaponRadius: "DEMOLITION EXPERT"
        case .bowlingRicochet: "GUTTER? NEVER HEARD OF HER"
        case .graveTimeExtended: "OVERTIME PAY"
        case .shockwaveSlams: "GROUND ZERO"
        case .chargeRush: "ADRENALINE JUNKIE"
        case .nightShiftBonus: "TIPS ARE POOLED"
        case .fortifiedDiner: "STORM SHUTTERS"
        case .longerFuse: "SECOND WIND"
        }
    }

    var subtitle: String {
        switch self {
        case .flickVelocity: "Flick velocity +20%"
        case .volatileBlastRadius: "Exploding zombies: blast radius +35%"
        case .explosiveWeaponRadius: "Explosive weapons: blast radius +30%"
        case .bowlingRicochet: "Bowling ball ricochets off the edges instead of rolling off"
        case .graveTimeExtended: "Grave Time lasts +2 sec"
        case .shockwaveSlams: "A hard slam knocks back every zombie nearby"
        case .chargeRush: "Grave Time charges 25% faster"
        case .nightShiftBonus: "+20% coins earned this run"
        case .fortifiedDiner: "Diner takes 15% less bite damage"
        case .longerFuse: "Combo window +0.4 sec — chain kills more forgivingly"
        }
    }

    var icon: String {
        switch self {
        case .flickVelocity: "bolt.fill"
        case .volatileBlastRadius: "flame.fill"
        case .explosiveWeaponRadius: "circle.hexagongrid.fill"
        case .bowlingRicochet: "arrow.triangle.2.circlepath"
        case .graveTimeExtended: "clock.fill"
        case .shockwaveSlams: "waveform.path"
        case .chargeRush: "hare.fill"
        case .nightShiftBonus: "dollarsign.circle.fill"
        case .fortifiedDiner: "shield.fill"
        case .longerFuse: "timer"
        }
    }
}
