import SpriteKit

enum CombatVFX: String, CaseIterable {
    case pavementImpact = "vfx_pavement_impact"
    case zombieSplatter = "vfx_zombie_splatter"
    case explosion = "vfx_explosion"
    case freezerBurst = "vfx_freezer_burst"
    /// The Volatile zombie's own death animation — distinct from the shared `.explosion` used by
    /// grenades/propane tanks/airstrikes/grease fire, so its burst can look and feel like *it*
    /// popping rather than a generic weapon fireball.
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
