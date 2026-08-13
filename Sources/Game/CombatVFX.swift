import SpriteKit

enum CombatVFX: String, CaseIterable {
    case pavementImpact = "vfx_pavement_impact"
    case zombieSplatter = "vfx_zombie_splatter"
    case explosion = "vfx_explosion"
    case freezerBurst = "vfx_freezer_burst"

    var texture: SKTexture {
        let texture = SKTexture(imageNamed: rawValue)
        texture.filteringMode = .linear
        return texture
    }

    static var hasCompleteSet: Bool {
        allCases.allSatisfy {
            let size = $0.texture.size()
            return size.width > 1 && size.height > 1
        }
    }
}
