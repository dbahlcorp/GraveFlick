import SpriteKit

enum CombatVFX: String, CaseIterable {
    case pavementImpact = "vfx_pavement_impact"
    case zombieSplatter = "vfx_zombie_splatter"
    case explosion = "vfx_explosion"
    case grenadeExplosion = "vfx_grenade_explosion"
    case propaneExplosion = "vfx_propane_explosion"
    case airstrikeExplosion = "vfx_airstrike_explosion"
    case greaseFireExplosion = "vfx_grease_fire_explosion"
    case deliveryTruckImpact = "vfx_delivery_truck_impact"
    case freezerBurst = "vfx_freezer_burst"
    /// The Volatile zombie's own death animation, distinct from every weapon-specific blast so its
    /// burst looks and feels like the creature itself popping.
    case volatileBurst = "vfx_volatile_burst"

    var texture: SKTexture {
        let texture = SKTexture(imageNamed: rawValue)
        texture.filteringMode = .linear
        return texture
    }

    var frames: [SKTexture] {
        (1...4).map { index in
            let texture = SKTexture(imageNamed: "\(rawValue)_\(index)")
            texture.filteringMode = .linear
            return texture
        }
    }

    static var hasCompleteSet: Bool {
        allCases.allSatisfy { effect in effect.frames.count == 4 && effect.frames.allSatisfy { $0.size().width > 1 && $0.size().height > 1 } }
    }
}
