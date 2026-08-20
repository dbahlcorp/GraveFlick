import SpriteKit

@MainActor
protocol CombatVFXSystemHost: AnyObject {
    var world: SKNode { get }
    var size: CGSize { get }
    var groundY: CGFloat { get }
    var houseFrame: CGRect { get }
    var settings: GameSettings { get }
}

/// Every purely-decorative combat payoff: gore splatter/debris/stains, hit-flash sprite effects
/// (CombatVFX), directional debris shards, pavement cracks, and diner siding damage. None of this
/// reads or mutates gameplay state (health/score/combo/etc.) — it only spawns nodes into `world`
/// and lets them animate themselves out. Owned by GameScene via `combatVFXSystem`.
///
/// Several methods here (`burst`, `playCombatVFX`, `playDirectionalDebris`,
/// `spawnPhysicsDebris(from:reason:)`) are required by host protocols that predate this
/// extraction (ComboSystemHost, WeaponSystemHost, BossDirectorHost) — GameScene keeps thin
/// same-named forwarders to this system to satisfy those.
///
/// @MainActor for consistency with every other owned system, even though this one doesn't call
/// SoundManager directly — GameScene (its sole host) is implicitly main-actor-isolated via
/// SKScene, so accessing `host.world`/`host.settings`/etc. through a non-@MainActor protocol
/// would fail to typecheck.
@MainActor
final class CombatVFXSystem {
    weak var host: CombatVFXSystemHost?

    private var goreStains: [SKNode] = []
    private var activeGoreDroplets = 0
    private var sceneryDamage = 0

    func spawnPhysicsDebris(from zombie: ZombieNode, reason: DefeatReason) {
        guard let host else { return }
        let impulseScale: CGFloat = reason == .explosion ? 1.8 : (zombie.kind.isBoss ? 0.75 : 1)
        if !host.settings.reducedMotion {
            let pieces = zombie.makePhysicsDebris()
            for (index, debris) in pieces.enumerated() {
                debris.position = zombie.position
                debris.zPosition = 28
                host.world.addChild(debris)
                let spread = CGFloat(index - 2) * 42 + CGFloat.random(in: -26...26)
                debris.physicsBody?.applyImpulse(CGVector(dx: spread * impulseScale, dy: CGFloat.random(in: 90...180) * impulseScale))
                debris.physicsBody?.angularVelocity = CGFloat.random(in: -7...7)
                debris.run(.sequence([.wait(forDuration: 2.4), .fadeOut(withDuration: 0.5), .removeFromParent()]))
            }
        }
        let splatterScale = (zombie.kind.isBoss ? 1.7 : 1) * (reason == .explosion ? 1.5 : 1)
        spawnGoreSplatter(
            at: zombie.position,
            scale: splatterScale,
            direction: zombie.approachesFromLeft ? -1 : 1,
            reason: reason
        )
    }

    /// Layered cartoon gore: a fast airborne burst followed by streaks, satellite drops, and a
    /// long-lived ground stain. Explosions throw gore radially while impacts preserve momentum.
    private func spawnGoreSplatter(at point: CGPoint, scale: CGFloat, direction: CGFloat, reason: DefeatReason) {
        guard let host else { return }
        let baseColor = SKColor(red: 0.34, green: 0.58, blue: 0.08, alpha: 1)
        if !host.settings.reducedMotion {
            spawnAirborneGore(at: point, scale: scale, direction: direction, radial: reason == .explosion)
        }

        let container = SKNode()
        container.position = CGPoint(x: point.x, y: host.groundY + 2)
        container.zPosition = 2
        host.world.addChild(container)

        let pool = SKShapeNode(path: splatterBlobPath(radius: 35 * scale, verticalScale: 0.32))
        pool.fillColor = baseColor.withAlphaComponent(0.66)
        pool.strokeColor = .clear
        container.addChild(pool)

        let core = SKShapeNode(path: splatterBlobPath(radius: 20 * scale, points: 8, verticalScale: 0.28))
        core.fillColor = SKColor(red: 0.16, green: 0.33, blue: 0.04, alpha: 0.62)
        core.strokeColor = .clear
        core.position = CGPoint(x: direction * 5 * scale, y: 0)
        container.addChild(core)

        let streakCount = reason == .explosion ? 8 : 5
        for index in 0..<streakCount {
            let angle: CGFloat = reason == .explosion
                ? CGFloat(index) / CGFloat(streakCount) * .pi * 2 + CGFloat.random(in: -0.18...0.18)
                : CGFloat.random(in: -0.42...0.42) + (direction < 0 ? .pi : 0)
            let length = CGFloat.random(in: 30...88) * scale
            let width = CGFloat.random(in: 3...7) * scale
            let streak = SKShapeNode(path: splatterStreakPath(length: length, width: width))
            streak.fillColor = baseColor.withAlphaComponent(CGFloat.random(in: 0.34...0.58))
            streak.strokeColor = .clear
            streak.zRotation = angle
            container.addChild(streak)
        }

        let dropletCount = Int((reason == .explosion ? 13 : 9) * scale)
        for _ in 0..<dropletCount {
            let droplet = SKShapeNode(path: splatterBlobPath(radius: CGFloat.random(in: 3...10) * scale, points: 7, verticalScale: CGFloat.random(in: 0.28...0.58)))
            droplet.fillColor = Bool.random()
                ? baseColor.withAlphaComponent(CGFloat.random(in: 0.42...0.68))
                : SKColor(red: 0.54, green: 0.76, blue: 0.12, alpha: CGFloat.random(in: 0.38...0.60))
            droplet.strokeColor = .clear
            let angle = reason == .explosion ? CGFloat.random(in: 0...(.pi * 2)) : CGFloat.random(in: -0.48...0.48) + (direction < 0 ? .pi : 0)
            let travel = CGFloat.random(in: 24...116) * scale
            droplet.position = CGPoint(x: cos(angle) * travel, y: sin(angle) * travel * 0.18)
            container.addChild(droplet)
        }

        container.alpha = 0
        container.setScale(0.6)
        container.run(.sequence([
            .group([.fadeAlpha(to: 1, duration: 0.06), .scale(to: 1.08, duration: 0.09)]),
            .scale(to: 1, duration: 0.08),
            .wait(forDuration: Double.random(in: 17...25)),
            .fadeOut(withDuration: 3.5),
            .removeFromParent()
        ]))
        retainGoreStain(container)
    }

    private func spawnAirborneGore(at point: CGPoint, scale: CGFloat, direction: CGFloat, radial: Bool) {
        guard let host else { return }
        let count = min(34, Int((radial ? 24 : 16) * scale))
        for index in 0..<count {
            guard activeGoreDroplets < 90 else { break }
            let angle = radial
                ? CGFloat(index) / CGFloat(count) * .pi * 2 + CGFloat.random(in: -0.22...0.22)
                : CGFloat.random(in: -0.72...0.34) + (direction < 0 ? .pi : 0)
            let distance = CGFloat.random(in: 48...155) * scale
            let landing = CGPoint(
                x: max(8, min(host.size.width - 8, point.x + cos(angle) * distance)),
                y: host.groundY + CGFloat.random(in: 2...10)
            )
            let peak = CGPoint(
                x: point.x + (landing.x - point.x) * 0.42,
                y: min(host.size.height - 20, point.y + CGFloat.random(in: 35...105) * scale)
            )
            let radius = CGFloat.random(in: 2.5...7.5) * min(1.5, scale)
            let droplet = SKShapeNode(path: splatterBlobPath(radius: radius, points: 6, verticalScale: CGFloat.random(in: 0.7...1.35)))
            droplet.fillColor = index.isMultiple(of: 4)
                ? SKColor(red: 0.62, green: 0.82, blue: 0.14, alpha: 0.88)
                : SKColor(red: 0.28, green: 0.54, blue: 0.06, alpha: 0.92)
            droplet.strokeColor = .clear
            droplet.position = point
            droplet.zPosition = 130 + CGFloat(index % 3)
            host.world.addChild(droplet)
            activeGoreDroplets += 1
            droplet.run(.sequence([
                .group([.move(to: peak, duration: Double.random(in: 0.10...0.18)), .rotate(byAngle: CGFloat.random(in: -1.8...1.8), duration: 0.14)]),
                .group([.move(to: landing, duration: Double.random(in: 0.18...0.30)), .scaleY(to: 0.28, duration: 0.24)]),
                .wait(forDuration: Double.random(in: 1.0...2.1)),
                .fadeOut(withDuration: 0.7),
                .run { [weak self] in
                    guard let self else { return }
                    self.activeGoreDroplets = max(0, self.activeGoreDroplets - 1)
                },
                .removeFromParent()
            ]))
        }
    }

    private func retainGoreStain(_ stain: SKNode) {
        goreStains.removeAll { $0.parent == nil }
        goreStains.append(stain)
        while goreStains.count > 28 {
            let oldest = goreStains.removeFirst()
            oldest.removeAllActions()
            oldest.run(.sequence([.fadeOut(withDuration: 0.35), .removeFromParent()]))
        }
    }

    private func splatterBlobPath(radius: CGFloat, points: Int = 9, verticalScale: CGFloat = 0.5) -> CGPath {
        let path = CGMutablePath()
        for index in 0..<points {
            let angle = (CGFloat(index) / CGFloat(points)) * .pi * 2
            let jittered = radius * CGFloat.random(in: 0.7...1.15)
            let vertex = CGPoint(x: cos(angle) * jittered, y: sin(angle) * jittered * verticalScale)
            if index == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
        }
        path.closeSubpath()
        return path
    }

    private func splatterStreakPath(length: CGFloat, width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: -width))
        path.addCurve(to: CGPoint(x: length, y: 0), control1: CGPoint(x: length * 0.35, y: -width * 0.75), control2: CGPoint(x: length * 0.82, y: -width * 0.18))
        path.addCurve(to: CGPoint(x: 0, y: width), control1: CGPoint(x: length * 0.78, y: width * 0.20), control2: CGPoint(x: length * 0.28, y: width * 0.72))
        path.closeSubpath()
        return path
    }

    func burst(at point: CGPoint, color: SKColor) {
        guard let host else { return }
        let count = host.settings.reducedMotion ? 5 : 12
        for index in 0..<count {
            let particle = SKShapeNode(circleOfRadius: CGFloat.random(in: 3...8))
            particle.fillColor = color
            particle.strokeColor = .clear
            particle.position = point
            particle.zPosition = 90
            host.world.addChild(particle)
            let angle = CGFloat(index) / CGFloat(count) * .pi * 2
            let distance = host.settings.reducedMotion ? CGFloat(35) : CGFloat.random(in: 45...110)
            let destination = CGPoint(x: point.x + cos(angle) * distance, y: point.y + sin(angle) * distance)
            particle.run(.sequence([.group([.move(to: destination, duration: 0.32), .fadeOut(withDuration: 0.34)]), .removeFromParent()]))
        }
    }

    func playCombatVFX(_ effect: CombatVFX, at point: CGPoint, size: CGFloat, direction: CGFloat, tint: SKColor? = nil) {
        guard let host else { return }
        let frameIndices = GameRules.animationFrameIndices(totalFrames: effect.frames.count, reducedMotion: host.settings.reducedMotion, emphasizedFrame: 2)
        let presentationFrames = frameIndices.map { effect.frames[$0] }
        let sprite = SKSpriteNode(texture: presentationFrames[0], size: CGSize(width: size, height: size))
        sprite.position = point
        sprite.zPosition = 132
        sprite.xScale = direction < 0 ? (host.settings.reducedMotion ? -1 : -0.22) : (host.settings.reducedMotion ? 1 : 0.22)
        sprite.yScale = host.settings.reducedMotion ? 1 : 0.22
        sprite.alpha = host.settings.reducedMotion ? 1 : 0
        if let tint {
            sprite.color = tint
            sprite.colorBlendFactor = 0.25
        }
        host.world.addChild(sprite)
        if !host.settings.reducedMotion {
            sprite.run(.animate(with: presentationFrames, timePerFrame: 0.065, resize: false, restore: false), withKey: "artFrames")
        }

        if host.settings.reducedMotion {
            sprite.run(.sequence([.wait(forDuration: 0.12), .fadeOut(withDuration: 0.12), .removeFromParent()]))
        } else {
            let targetX: CGFloat = direction < 0 ? -1 : 1
            let arrival = SKAction.group([
                .scaleX(to: targetX * 1.12, duration: 0.07),
                .scaleY(to: 1.12, duration: 0.07),
                .fadeIn(withDuration: 0.03)
            ])
            let settle = SKAction.group([.scaleX(to: targetX, duration: 0.10), .scaleY(to: 1, duration: 0.10)])
            sprite.run(.sequence([arrival, settle, .wait(forDuration: 0.13), .group([.scale(to: 1.18, duration: 0.18), .fadeOut(withDuration: 0.18)]), .removeFromParent()]))
        }

        let debrisColor: SKColor = switch effect {
        case .pavementImpact: .darkGray
        case .zombieSplatter: SKColor(red: 0.48, green: 0.76, blue: 0.16, alpha: 1)
        case .explosion: .orange
        // Brighter/more acidic than zombieSplatter's green — matches the toxic ooze in the
        // vfx_volatile_burst art rather than reusing the shared explosion's plain orange.
        case .volatileBurst: SKColor(red: 0.68, green: 0.95, blue: 0.22, alpha: 1)
        case .freezerBurst: .cyan
        }
        if !host.settings.reducedMotion {
            playDirectionalDebris(at: point, color: debrisColor, direction: direction, count: effect == .explosion || effect == .volatileBurst ? 14 : 8)
        }
    }

    func playDirectionalDebris(at point: CGPoint, color: SKColor, direction: CGFloat, count: Int) {
        guard let host else { return }
        let particleCount = host.settings.reducedMotion ? min(4, count) : count
        for index in 0..<particleCount {
            let shard = SKShapeNode(rectOf: CGSize(width: CGFloat.random(in: 3...8), height: CGFloat.random(in: 2...5)), cornerRadius: 1)
            shard.fillColor = index.isMultiple(of: 3) ? .white.withAlphaComponent(0.82) : color
            shard.strokeColor = .clear
            shard.position = point
            shard.zPosition = 134
            host.world.addChild(shard)
            let spread = CGFloat(index) / CGFloat(max(1, particleCount - 1)) - 0.5
            let dx = direction * CGFloat.random(in: 34...105) + spread * 46
            let dy = CGFloat.random(in: 24...92) - abs(spread) * 18
            shard.run(.sequence([.group([.moveBy(x: dx, y: dy, duration: 0.28), .rotate(byAngle: spread * .pi * 4, duration: 0.28), .fadeOut(withDuration: 0.31)]), .removeFromParent()]))
        }
    }

    /// Small persistent crack marks in the pavement at a hard flick-impact point — distinct from
    /// `damageScenery` (which is specific to the diner's siding), purely a floor-level payoff for
    /// a satisfying slam. Gated to real impacts (see GameScene.resolveImpact) so a tiny stumble
    /// stays quiet.
    func spawnPavementCracks(at point: CGPoint, power: CGFloat) {
        guard let host, !host.settings.reducedMotion else { return }
        let count = power < 0.45 ? 0 : (power < 0.85 ? 2 : 4)
        guard count > 0 else { return }
        for _ in 0..<count {
            let length = CGFloat.random(in: 14...26) * (0.85 + power * 0.4)
            let crack = SKShapeNode(rectOf: CGSize(width: length, height: 2.4), cornerRadius: 1.2)
            crack.fillColor = .black.withAlphaComponent(0.34)
            crack.strokeColor = .clear
            crack.zRotation = CGFloat.random(in: 0...(.pi))
            crack.position = CGPoint(x: point.x + CGFloat.random(in: -24...24), y: host.groundY + CGFloat.random(in: -3...5))
            crack.zPosition = 6
            crack.alpha = 0
            host.world.addChild(crack)
            crack.run(.sequence([.fadeAlpha(to: 0.85, duration: 0.05), .wait(forDuration: 3.2), .fadeOut(withDuration: 0.8), .removeFromParent()]))
        }
    }

    func damageScenery(near point: CGPoint) {
        guard let host else { return }
        sceneryDamage += 1
        let shard = SKShapeNode(rectOf: CGSize(width: 34, height: 9), cornerRadius: 2)
        shard.fillColor = sceneryDamage.isMultiple(of: 2) ? .darkGray : SKColor(red: 0.42, green: 0.17, blue: 0.11, alpha: 1)
        shard.strokeColor = .orange.withAlphaComponent(0.45)
        shard.position = CGPoint(x: point.x < host.size.width / 2 ? host.houseFrame.minX : host.houseFrame.maxX, y: host.groundY + CGFloat(35 + (sceneryDamage % 4) * 18))
        shard.zRotation = CGFloat.random(in: -0.35...0.35)
        shard.zPosition = 15
        host.world.addChild(shard)
        shard.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 34, height: 9))
        shard.physicsBody?.collisionBitMask = PhysicsCategory.ground
        shard.physicsBody?.applyImpulse(CGVector(dx: point.x < host.size.width / 2 ? -65 : 65, dy: 90))
        shard.run(.sequence([.wait(forDuration: 4), .fadeOut(withDuration: 0.5), .removeFromParent()]))
    }
}
