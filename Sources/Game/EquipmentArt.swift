import SpriteKit

enum EquipmentArt: String, CaseIterable {
    case bowlingBall = "weapon_bowling_ball"
    case scatterblast = "weapon_scatterblast"
    case airstrikeBeacon = "weapon_airstrike_beacon"
    case spikeStrip = "trap_spike_strip"
    case flashFreezer = "trap_flash_freezer"

    var texture: SKTexture {
        let texture = SKTexture(imageNamed: rawValue)
        texture.filteringMode = .linear
        return texture
    }

    func fittedSize(inside bounds: CGSize) -> CGSize {
        let source = texture.size()
        guard source.width > 0, source.height > 0 else { return bounds }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    static var hasCompleteSet: Bool {
        allCases.allSatisfy {
            let size = $0.texture.size()
            return size.width > 1 && size.height > 1
        }
    }
}

extension WeaponKind {
    var equipmentArt: EquipmentArt {
        switch self {
        case .bowlingBall: .bowlingBall
        case .shotgun: .scatterblast
        case .airstrike: .airstrikeBeacon
        }
    }
}

extension TrapKind {
    var equipmentArt: EquipmentArt {
        self == .spikeStrip ? .spikeStrip : .flashFreezer
    }
}
