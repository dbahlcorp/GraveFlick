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

    var actionFrames: [SKTexture] {
        (1...3).map { index in
            let texture = SKTexture(imageNamed: "\(rawValue)_\(index)")
            texture.filteringMode = .linear
            return texture
        }
    }

    func fittedSize(inside bounds: CGSize) -> CGSize {
        let source = texture.size()
        guard source.width > 0, source.height > 0 else { return bounds }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    static var hasCompleteSet: Bool {
        allCases.allSatisfy { art in art.actionFrames.count == 3 && art.actionFrames.allSatisfy { $0.size().width > 1 && $0.size().height > 1 } }
    }
}

extension WeaponKind {
    var equipmentArt: EquipmentArt {
        switch self {
        case .bowlingBall: .bowlingBall
        case .shotgun: .scatterblast
        case .airstrike: .airstrikeBeacon
        case .anvil, .grenade, .propaneTank, .wreckingBall, .sniper, .greaseFire, .transformer, .deliveryTruck, .meteor: .bowlingBall
        }
    }

    var authoredTexture: SKTexture {
        let texture = SKTexture(imageNamed: icon)
        texture.filteringMode = .linear
        return texture
    }

    func authoredFittedSize(inside bounds: CGSize) -> CGSize {
        let source = authoredTexture.size()
        guard source.width > 0, source.height > 0 else { return bounds }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}

extension TrapKind {
    var equipmentArt: EquipmentArt {
        self == .spikeStrip ? .spikeStrip : .flashFreezer
    }
}
