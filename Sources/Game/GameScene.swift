import SpriteKit
import UIKit

enum PhysicsCategory {
    static let none: UInt32 = 0
    static let ground: UInt32 = 1 << 0
    static let boundary: UInt32 = 1 << 1
    static let zombie: UInt32 = 1 << 2
    static let weapon: UInt32 = 1 << 3
    static let trap: UInt32 = 1 << 4
}

struct GameHUDSnapshot {
    let score: Int
    let wave: Int
    let health: Int
    let specialCharge: Double
    let weaponCooldowns: [WeaponKind: TimeInterval]
    let trapCooldowns: [TrapKind: TimeInterval]
}

@MainActor
protocol GameSceneDelegate: AnyObject {
    func gameScene(_ scene: GameScene, didUpdate snapshot: GameHUDSnapshot)
    func gameScene(_ scene: GameScene, didFinish result: LevelResult)
}

final class GameScene: SKScene, SKPhysicsContactDelegate {
    weak var gameDelegate: GameSceneDelegate?

    let level: GameLevel
    private let settings: GameSettings
    private let progress: PlayerProgress

    var isGameplayPaused = false {
        didSet { world.isPaused = isGameplayPaused }
    }

    private let world = SKNode()
    private var dinerNode: DinerNode?
    private var selectedZombie: ZombieNode?
    private var touchSamples: [(point: CGPoint, time: TimeInterval)] = []
    private var lastUpdateTime: TimeInterval = 0
    private var elapsedTime: TimeInterval = 0
    private var timeSinceSpawn: TimeInterval = 0
    private var score = 0
    private var health: Int
    private var wave = 1
    private var combo = 0
    private var maxCombo = 0
    private var defeats = 0
    private var lastDefeatTime: TimeInterval = -10
    private var specialCharge = 0.0
    private var weaponCooldowns: [WeaponKind: TimeInterval] = [:]
    private var trapCooldowns: [TrapKind: TimeInterval] = [:]
    private var gameOver = false
    private var spawningFinished = false
    private var didBuildWorld = false

    private var startingHealth: Int { GameRules.startingHealth + progress.upgradeLevel(.reinforcedDiner) }
    private var flickMultiplier: CGFloat { 1 + CGFloat(progress.upgradeLevel(.flickTraining)) * 0.10 }
    private var rapidGearLevel: Int { progress.upgradeLevel(.rapidGear) }
    private var groundY: CGFloat { max(70, size.height * 0.13) }
    private var houseFrame: CGRect {
        let width = min(260, size.width * 0.24)
        return CGRect(x: size.width * 0.5 - width * 0.5, y: groundY, width: width, height: min(250, size.height * 0.34))
    }

    init(level: GameLevel, progress: PlayerProgress, settings: GameSettings, size: CGSize) {
        self.level = level
        self.progress = progress
        self.settings = settings
        health = GameRules.startingHealth + progress.upgradeLevel(.reinforcedDiner)
        super.init(size: size)
        scaleMode = .resizeFill
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMove(to view: SKView) {
        guard !didBuildWorld else { return }
        didBuildWorld = true
        backgroundColor = level.skyColor
        physicsWorld.gravity = CGVector(dx: 0, dy: -8.8)
        physicsWorld.contactDelegate = self
        addChild(world)
        buildEnvironment()
        notifyDelegate()
        announce(text: level.title.uppercased(), color: .white)
        spawnZombie(forceWalker: true)
    }

    override func update(_ currentTime: TimeInterval) {
        guard !isGameplayPaused, !gameOver else {
            lastUpdateTime = currentTime
            return
        }

        let deltaTime = lastUpdateTime == 0 ? 0 : min(1.0 / 20.0, currentTime - lastUpdateTime)
        lastUpdateTime = currentTime
        elapsedTime += deltaTime
        timeSinceSpawn += deltaTime
        tickCooldowns(deltaTime)

        let activeDuration = level.waveDuration * Double(level.totalWaves)
        if elapsedTime < activeDuration {
            let newWave = min(level.totalWaves, Int(elapsedTime / level.waveDuration) + 1)
            if newWave != wave {
                wave = newWave
                announce(text: "WAVE \(wave)", color: .white)
            }
            let interval = max(0.48, level.baseSpawnInterval - Double(wave - 1) * 0.09)
            if timeSinceSpawn >= interval {
                timeSinceSpawn = 0
                spawnZombie(forceWalker: false)
            }
        } else if !spawningFinished {
            spawningFinished = true
            announce(text: "CLEAR THE LOT", color: SKColor(red: 1, green: 0.77, blue: 0.24, alpha: 1))
        }

        let zombies = activeZombies
        for zombie in zombies {
            zombie.updateWalking(deltaTime: deltaTime, reducedMotion: settings.reducedMotion)
            if zombie.isDefeated { continue }
            if !zombie.isGrabbed, !zombie.isThrown, zombieHasReachedHouse(zombie) {
                zombieReachedHouse(zombie)
            } else if zombie.position.y < -170 || zombie.position.x < -220 || zombie.position.x > size.width + 220 {
                defeat(zombie, reason: .thrownOut)
            }
        }

        if spawningFinished, zombies.isEmpty {
            finish(won: true)
        }
        notifyDelegate()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isGameplayPaused, !gameOver, selectedZombie == nil, let touch = touches.first else { return }
        let location = touch.location(in: self)
        if collectPickup(at: location) { return }
        guard let zombie = zombie(at: location) else { return }
        selectedZombie = zombie
        touchSamples = [(location, touch.timestamp)]
        zombie.beginGrab(reducedMotion: settings.reducedMotion)
        zombie.zPosition = 100
        SoundManager.shared.play(.grab)
        runHaptic(.light)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let zombie = selectedZombie, let touch = touches.first else { return }
        let location = touch.location(in: self)
        zombie.position = CGPoint(
            x: min(size.width - 20, max(20, location.x)),
            y: min(size.height - 25, max(groundY + zombie.kind.size.height * 0.39 + 4, location.y))
        )
        touchSamples.append((location, touch.timestamp))
        touchSamples = Array(touchSamples.suffix(8))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        releaseSelectedZombie(with: touches.first)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        releaseSelectedZombie(with: touches.first)
    }

    func useWeapon(_ kind: WeaponKind) {
        guard progress.isUnlocked(kind), weaponCooldowns[kind, default: 0] <= 0, !gameOver else { return }
        weaponCooldowns[kind] = GameRules.cooldown(base: kind.cooldown, rapidGearLevel: rapidGearLevel)
        SoundManager.shared.play(.weapon)
        switch kind {
        case .bowlingBall: launchBowlingBall()
        case .shotgun: fireScatterblast()
        case .airstrike: launchAirstrike()
        }
        notifyDelegate()
    }

    func useTrap(_ kind: TrapKind) {
        guard progress.isUnlocked(kind), trapCooldowns[kind, default: 0] <= 0, !gameOver else { return }
        trapCooldowns[kind] = GameRules.cooldown(base: kind.cooldown, rapidGearLevel: rapidGearLevel)
        SoundManager.shared.play(.trap)
        switch kind {
        case .spikeStrip: placeSpikeStrips()
        case .freezer: triggerFreezer()
        }
        notifyDelegate()
    }

    func useSpecial() {
        guard specialCharge >= 1, !gameOver else { return }
        specialCharge = 0
        SoundManager.shared.play(.weapon)
        announce(text: "GRAVE TIME", color: .cyan)
        for zombie in activeZombies {
            zombie.slow(for: 8, reducedMotion: settings.reducedMotion)
            zombie.physicsBody?.velocity.dx *= 0.35
            zombie.physicsBody?.velocity.dy *= 0.35
        }
        if !settings.reducedMotion {
            let wash = SKShapeNode(rectOf: size)
            wash.fillColor = .cyan.withAlphaComponent(0.18)
            wash.strokeColor = .clear
            wash.position = CGPoint(x: size.width / 2, y: size.height / 2)
            wash.zPosition = 180
            world.addChild(wash)
            wash.run(.sequence([.fadeOut(withDuration: 0.8), .removeFromParent()]))
        }
        notifyDelegate()
    }

    func didBegin(_ contact: SKPhysicsContact) {
        guard !gameOver else { return }
        let bodies = [contact.bodyA, contact.bodyB]

        if let zombie = zombieBody(in: bodies), bodies.contains(where: { $0.categoryBitMask == PhysicsCategory.ground }), zombie.isThrown, !zombie.hasResolvedImpact {
            zombie.hasResolvedImpact = true
            let fallHeight = max(0, zombie.highestPoint - zombie.position.y)
            let heightDamage = min(2.2, fallHeight / 190)
            let impactDamage = contact.collisionImpulse / max(1, zombie.kind.defeatImpulse)
            resolveImpact(on: zombie, damage: max(heightDamage, impactDamage))
            return
        }

        if let zombie = zombieBody(in: bodies), bodies.contains(where: { $0.categoryBitMask == PhysicsCategory.weapon }) {
            playCombatVFX(.zombieSplatter, at: contact.contactPoint, size: 92, direction: zombie.approachesFromLeft ? -1 : 1)
            if zombie.damage(zombie.kind == .brute ? 1.8 : 4) { defeat(zombie, reason: .weapon) }
            return
        }

        if let zombie = zombieBody(in: bodies), bodies.contains(where: { $0.categoryBitMask == PhysicsCategory.trap }) {
            playCombatVFX(.zombieSplatter, at: contact.contactPoint, size: 76, direction: zombie.approachesFromLeft ? -1 : 1)
            if zombie.damage(zombie.kind == .armored ? 0.7 : 1.5) { defeat(zombie, reason: .trap) }
            return
        }

        if bodies.allSatisfy({ $0.categoryBitMask == PhysicsCategory.zombie }), contact.collisionImpulse > 18 {
            playCombatVFX(.zombieSplatter, at: contact.contactPoint, size: 82, direction: contact.contactNormal.dx >= 0 ? 1 : -1)
            for body in bodies {
                if let zombie = body.node as? ZombieNode, !zombie.isDefeated, zombie.damage(contact.collisionImpulse / 42) {
                    defeat(zombie, reason: .collision)
                }
            }
        }
    }

    private enum DefeatReason { case impact, collision, weapon, trap, thrownOut, explosion }

    private func resolveImpact(on zombie: ZombieNode, damage: CGFloat) {
        SoundManager.shared.play(.impact)
        zombie.playImpact(reducedMotion: settings.reducedMotion)
        let impactPoint = CGPoint(x: zombie.position.x, y: groundY + 8)
        playCombatVFX(.pavementImpact, at: impactPoint, size: min(210, 120 + damage * 36), direction: zombie.physicsBody?.velocity.dx.sign == .minus ? -1 : 1)
        if zombie.damage(damage) {
            defeat(zombie, reason: .impact)
        } else {
            zombie.run(.sequence([
                .wait(forDuration: 0.34),
                .run { [weak self, weak zombie] in
                    guard let self else { return }
                    zombie?.resumeWalking(on: self.groundY)
                }
            ]))
        }
    }

    private func releaseSelectedZombie(with touch: UITouch?) {
        guard let zombie = selectedZombie else { return }
        if let touch {
            let location = touch.location(in: self)
            touchSamples.append((location, touch.timestamp))
            zombie.position = CGPoint(x: location.x, y: max(groundY + zombie.kind.size.height * 0.39 + 4, location.y))
        }
        var velocity = FlickMath.velocity(from: touchSamples)
        if hypot(velocity.dx, velocity.dy) < 140 { velocity.dy = 180 }
        zombie.release(with: velocity, powerMultiplier: flickMultiplier)
        if hypot(velocity.dx, velocity.dy) > 1_850 {
            hitStop(duration: 0.16, slowFactor: 0.35)
        }
        zombie.zPosition = 20
        selectedZombie = nil
        touchSamples.removeAll()
    }

    private func zombie(at location: CGPoint) -> ZombieNode? {
        for node in nodes(at: location) {
            var candidate: SKNode? = node
            while let current = candidate {
                if let zombie = current as? ZombieNode, !zombie.isDefeated { return zombie }
                candidate = current.parent
            }
        }
        return nil
    }

    private func zombieBody(in bodies: [SKPhysicsBody]) -> ZombieNode? {
        guard let zombie = bodies.first(where: { $0.categoryBitMask == PhysicsCategory.zombie })?.node as? ZombieNode,
              !zombie.isDefeated else { return nil }
        return zombie
    }

    private var activeZombies: [ZombieNode] {
        world.children.compactMap { $0 as? ZombieNode }
    }

    /// Avoids SKNode.frame's accumulated-subtree walk by treating the zombie as a simple
    /// box around its position, since grounded zombies never need per-part precision here.
    private func zombieHasReachedHouse(_ zombie: ZombieNode) -> Bool {
        let frame = houseFrame.insetBy(dx: 18, dy: 0)
        let halfWidth = zombie.kind.size.width * 0.5
        let halfHeight = zombie.kind.size.height * 0.5
        guard zombie.position.x + halfWidth >= frame.minX, zombie.position.x - halfWidth <= frame.maxX else { return false }
        return zombie.position.y + halfHeight >= frame.minY && zombie.position.y - halfHeight <= frame.maxY
    }

    private func spawnZombie(forceWalker: Bool) {
        let unlockedCount = min(level.enemyRoster.count, max(1, 1 + wave))
        let roster = Array(level.enemyRoster.prefix(unlockedCount))
        let kind = forceWalker ? (roster.contains(.walker) ? ZombieKind.walker : roster[0]) : roster.randomElement()!
        let fromLeft = Bool.random()
        let zombie = ZombieNode(kind: kind, approachesFromLeft: fromLeft)
        zombie.position = CGPoint(
            x: fromLeft ? -kind.size.width : size.width + kind.size.width,
            y: groundY + kind.size.height * 0.39 + 2
        )
        zombie.zPosition = 10
        world.addChild(zombie)
        zombie.playSpawn(reducedMotion: settings.reducedMotion)
    }

    private func zombieReachedHouse(_ zombie: ZombieNode) {
        guard zombie.parent != nil else { return }
        guard zombie.playDinerAttack(reducedMotion: settings.reducedMotion, completion: { [weak self, weak zombie] in
            guard let self, let zombie, zombie.parent != nil else { return }
            self.resolveDinerAttack(from: zombie)
        }) else { return }
    }

    private func resolveDinerAttack(from zombie: ZombieNode) {
        health = max(0, health - zombie.kind.dinerDamage)
        combo = 0
        dinerNode?.takeHit(remainingHealth: health, maximumHealth: startingHealth)
        let strikeX = zombie.position.x < size.width / 2 ? houseFrame.minX + 28 : houseFrame.maxX - 28
        playCombatVFX(.pavementImpact, at: CGPoint(x: strikeX, y: groundY + 72), size: 138, direction: zombie.approachesFromLeft ? 1 : -1, tint: .red)
        shakeCamera(intensity: 1.4)
        SoundManager.shared.play(.dinerHit)
        runHaptic(.heavy)
        zombie.playDefeat(style: .dinerAttack, reducedMotion: settings.reducedMotion) {}
        if health == 0 { finish(won: false) }
    }

    private func defeat(_ zombie: ZombieNode, reason: DefeatReason) {
        guard zombie.parent != nil, !zombie.isDefeated else { return }
        if elapsedTime - lastDefeatTime <= 1.8 { combo += 1 } else { combo = 1 }
        maxCombo = max(maxCombo, combo)
        defeats += 1
        lastDefeatTime = elapsedTime
        let killScore = GameRules.score(for: zombie.kind, combo: combo)
        score += killScore
        specialCharge = min(1, specialCharge + (zombie.kind == .brute ? 0.22 : 0.12))
        let point = zombie.position
        let volatile = zombie.kind == .volatile
        zombie.playDefeat(style: defeatStyle(for: reason), reducedMotion: settings.reducedMotion) {}
        if reason == .thrownOut {
            burst(at: point, color: .cyan)
        } else if reason != .explosion {
            playCombatVFX(.zombieSplatter, at: point, size: zombie.kind == .brute ? 156 : 118, direction: zombie.approachesFromLeft ? -1 : 1)
        }
        SoundManager.shared.play(.defeat, comboScale: combo)
        runHaptic(.medium)
        showScorePopup(at: point, score: killScore)
        showCombo(at: point)
        hitStop(duration: min(0.09, 0.045 + Double(combo) * 0.004))
        if Int.random(in: 0..<9) == 0 { spawnPickup(at: point) }
        if volatile, reason != .explosion { explodeVolatile(at: point) }
    }

    private func defeatStyle(for reason: DefeatReason) -> ZombieDefeatStyle {
        switch reason {
        case .impact: .pavement
        case .collision: .collision
        case .weapon: .weapon
        case .trap: .trap
        case .thrownOut: .thrownOut
        case .explosion: .explosion
        }
    }

    private func explodeVolatile(at point: CGPoint) {
        let nearby = activeZombies.filter {
            !$0.isDefeated && hypot($0.position.x - point.x, $0.position.y - point.y) < 170
        }
        for zombie in nearby {
            if zombie.damage(1.6) { defeat(zombie, reason: .explosion) }
            else {
                let dx = zombie.position.x - point.x
                zombie.launch(with: CGVector(dx: dx.sign == .minus ? -220 : 220, dy: 280))
            }
        }
        playCombatVFX(.explosion, at: point, size: 270, direction: 1)
        shakeCamera(intensity: 1.2)
    }

    private func launchBowlingBall() {
        let ball = SKSpriteNode(texture: EquipmentArt.bowlingBall.actionFrames[0], size: CGSize(width: 72, height: 72))
        ball.name = "weapon"
        ball.position = CGPoint(x: -35, y: groundY + 34)
        ball.zPosition = 30
        ball.physicsBody = SKPhysicsBody(circleOfRadius: 27)
        ball.physicsBody?.mass = 3.5
        ball.physicsBody?.restitution = 0.32
        ball.physicsBody?.friction = 0.7
        ball.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        ball.physicsBody?.collisionBitMask = PhysicsCategory.zombie | PhysicsCategory.ground
        ball.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        ball.physicsBody?.velocity = CGVector(dx: 820, dy: 130)
        world.addChild(ball)
        if !settings.reducedMotion {
            ball.run(.repeatForever(.animate(with: EquipmentArt.bowlingBall.actionFrames, timePerFrame: 0.09, resize: false, restore: true)), withKey: "artFrames")
            ball.run(.repeatForever(.rotate(byAngle: -.pi * 2, duration: 0.38)), withKey: "roll")
        }
        ball.run(.sequence([.wait(forDuration: 5), .removeFromParent()]))
    }

    private func fireScatterblast() {
        let center = CGPoint(x: size.width / 2, y: groundY + 110)
        let scattergun = SKSpriteNode(texture: EquipmentArt.scatterblast.actionFrames[0], size: CGSize(width: 180, height: 180))
        scattergun.position = CGPoint(x: center.x, y: center.y + 16)
        scattergun.zPosition = 135
        world.addChild(scattergun)
        scattergun.run(.animate(with: EquipmentArt.scatterblast.actionFrames, timePerFrame: settings.reducedMotion ? 0.02 : 0.075, resize: false, restore: false), withKey: "artFrames")
        let recoil = settings.reducedMotion ? CGFloat(4) : CGFloat(18)
        scattergun.run(.sequence([
            .moveBy(x: -recoil, y: -recoil * 0.25, duration: 0.045),
            .moveBy(x: recoil, y: recoil * 0.25, duration: 0.11),
            .fadeOut(withDuration: 0.12),
            .removeFromParent()
        ]))
        let zombies = activeZombies.filter { !$0.isDefeated }
        for zombie in zombies {
            let dx = zombie.position.x - center.x
            let direction: CGFloat = dx < 0 ? -1 : 1
            zombie.launch(with: CGVector(dx: direction * 390, dy: 270))
            if zombie.damage(zombie.kind == .brute ? 0.8 : 1.25) { defeat(zombie, reason: .weapon) }
        }
        radialFlash(at: center, color: .yellow)
        playDirectionalDebris(at: center, color: .orange, direction: 1, count: 10)
        shakeCamera(intensity: 0.8)
    }

    private func launchAirstrike() {
        let beacon = SKSpriteNode(texture: EquipmentArt.airstrikeBeacon.actionFrames[0], size: CGSize(width: 108, height: 108))
        beacon.position = CGPoint(x: size.width / 2, y: groundY + 54)
        beacon.zPosition = 32
        beacon.setScale(0.05)
        world.addChild(beacon)
        beacon.run(.repeatForever(.animate(with: EquipmentArt.airstrikeBeacon.actionFrames, timePerFrame: 0.16, resize: false, restore: true)), withKey: "artFrames")
        let pulse = SKAction.sequence([.fadeAlpha(to: 0.38, duration: 0.14), .fadeAlpha(to: 1, duration: 0.14)])
        beacon.run(.sequence([
            .scale(to: 1, duration: settings.reducedMotion ? 0.01 : 0.18),
            .repeat(pulse, count: 4),
            .wait(forDuration: 0.45),
            .fadeOut(withDuration: 0.2),
            .removeFromParent()
        ]))
        let xs = [size.width * 0.18, size.width * 0.5, size.width * 0.82]
        for (index, x) in xs.enumerated() {
            world.run(.sequence([
                .wait(forDuration: Double(index) * 0.24),
                .run { [weak self] in self?.airstrikeImpact(x: x) }
            ]))
        }
    }

    private func airstrikeImpact(x: CGFloat) {
        let point = CGPoint(x: x, y: groundY + 35)
        for zombie in activeZombies where !zombie.isDefeated && abs(zombie.position.x - x) < size.width * 0.22 {
            if zombie.damage(5) { defeat(zombie, reason: .weapon) }
        }
        playCombatVFX(.explosion, at: point, size: 238, direction: indexDirection(for: x))
        shakeCamera(intensity: 1.1)
    }

    private func placeSpikeStrips() {
        for x in [houseFrame.minX - 115, houseFrame.maxX + 115] {
            let strip = SKSpriteNode(texture: EquipmentArt.spikeStrip.actionFrames[0], size: CGSize(width: 135, height: 54))
            strip.position = CGPoint(x: x, y: groundY + 10)
            strip.zPosition = 8
            strip.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 125, height: 30))
            strip.physicsBody?.isDynamic = false
            strip.physicsBody?.categoryBitMask = PhysicsCategory.trap
            strip.physicsBody?.collisionBitMask = PhysicsCategory.none
            strip.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
            world.addChild(strip)
            strip.run(.animate(with: EquipmentArt.spikeStrip.actionFrames, timePerFrame: settings.reducedMotion ? 0.02 : 0.09, resize: false, restore: false), withKey: "artFrames")
            if !settings.reducedMotion {
                strip.setScale(0.15)
                strip.run(.sequence([.scale(to: 1.12, duration: 0.12), .scale(to: 1, duration: 0.1)]))
            }
            strip.run(.sequence([.wait(forDuration: 9), .fadeOut(withDuration: 0.3), .removeFromParent()]))
        }
    }

    private func triggerFreezer() {
        let freezer = SKSpriteNode(texture: EquipmentArt.flashFreezer.actionFrames[0], size: CGSize(width: 150, height: 116))
        freezer.position = CGPoint(x: size.width / 2, y: groundY + 58)
        freezer.zPosition = 136
        world.addChild(freezer)
        freezer.run(.animate(with: EquipmentArt.flashFreezer.actionFrames, timePerFrame: settings.reducedMotion ? 0.02 : 0.10, resize: false, restore: false), withKey: "artFrames")
        if !settings.reducedMotion {
            freezer.run(.sequence([
                .group([.scale(to: 1.12, duration: 0.12), .rotate(byAngle: -0.04, duration: 0.12)]),
                .group([.scale(to: 1, duration: 0.16), .rotate(toAngle: 0, duration: 0.16)]),
                .wait(forDuration: 0.35),
                .fadeOut(withDuration: 0.24),
                .removeFromParent()
            ]))
        } else {
            freezer.run(.sequence([.wait(forDuration: 0.4), .removeFromParent()]))
        }
        for zombie in activeZombies { zombie.slow(for: 7, reducedMotion: settings.reducedMotion) }
        playCombatVFX(.freezerBurst, at: CGPoint(x: size.width / 2, y: groundY + 84), size: min(size.width * 0.72, 520), direction: 1)
        radialFlash(at: CGPoint(x: size.width / 2, y: size.height / 2), color: .cyan)
    }

    private func tickCooldowns(_ deltaTime: TimeInterval) {
        for key in weaponCooldowns.keys { weaponCooldowns[key] = max(0, weaponCooldowns[key, default: 0] - deltaTime) }
        for key in trapCooldowns.keys { trapCooldowns[key] = max(0, trapCooldowns[key, default: 0] - deltaTime) }
    }

    private func finish(won: Bool) {
        guard !gameOver else { return }
        gameOver = true
        selectedZombie = nil
        activeZombies.forEach { $0.physicsBody?.isDynamic = false }
        if won { SoundManager.shared.play(.victory) }
        // Endless never "wins" (there's no wave count to clear), so its payout is scored from
        // performance instead of the win-gated per-level reward, and stars don't apply.
        let earnedStars = level.isEndless ? 0 : GameRules.stars(score: score, health: health, startingHealth: startingHealth, won: won)
        let reward = level.isEndless ? GameRules.survivalReward(score: score) : (won ? level.reward + earnedStars * 40 : 0)
        let result = LevelResult(levelID: level.id, score: score, stars: earnedStars, reward: reward, won: won, defeats: defeats, maxCombo: maxCombo, wave: wave)
        gameDelegate?.gameScene(self, didFinish: result)
    }

    private func spawnPickup(at point: CGPoint) {
        let choices = WeaponKind.allCases.filter { progress.isUnlocked($0) }
        guard let weapon = choices.randomElement() else { return }
        let pickup = SKShapeNode(circleOfRadius: 25)
        pickup.name = "pickup-\(weapon.rawValue)"
        pickup.fillColor = .orange
        pickup.strokeColor = .white
        pickup.lineWidth = 4
        pickup.position = point
        pickup.zPosition = 115
        let art = weapon.equipmentArt
        let icon = SKSpriteNode(texture: art.texture, size: art.fittedSize(inside: CGSize(width: 40, height: 40)))
        pickup.addChild(icon)
        world.addChild(pickup)
        pickup.run(.repeatForever(.sequence([.scale(to: 1.13, duration: 0.45), .scale(to: 0.92, duration: 0.45)])))
        pickup.run(.sequence([.wait(forDuration: 6), .fadeOut(withDuration: 0.3), .removeFromParent()]), withKey: "expiry")
    }

    private func collectPickup(at location: CGPoint) -> Bool {
        for node in nodes(at: location) {
            var candidate: SKNode? = node
            while let current = candidate {
                if let name = current.name, name.hasPrefix("pickup-"), let weapon = WeaponKind(rawValue: String(name.dropFirst(7))) {
                    weaponCooldowns[weapon] = 0
                    specialCharge = min(1, specialCharge + 0.20)
                    current.removeFromParent()
                    SoundManager.shared.play(.pickup)
                    announce(text: "\(weapon.title.uppercased()) READY", color: .yellow)
                    notifyDelegate()
                    return true
                }
                candidate = current.parent
            }
        }
        return false
    }

    private func notifyDelegate() {
        gameDelegate?.gameScene(self, didUpdate: GameHUDSnapshot(
            score: score,
            wave: wave,
            health: health,
            specialCharge: specialCharge,
            weaponCooldowns: weaponCooldowns,
            trapCooldowns: trapCooldowns
        ))
    }

    private func buildEnvironment() {
        buildSky()
        buildGround()
        buildHouse()
    }

    private func buildSky() {
        // EnvironmentNode derives its art filename straight from levelID; endless reuses Last
        // Light's backdrop (there's no dedicated "environment_00" asset for the id-0 placeholder).
        let environmentID = level.isEndless ? 5 : level.id
        world.addChild(EnvironmentNode(levelID: environmentID, sceneSize: size, reducedMotion: settings.reducedMotion, highContrast: settings.highContrast))
    }

    private func buildGround() {
        let pavement = SKShapeNode(rectOf: CGSize(width: size.width + 80, height: groundY * 2))
        pavement.fillColor = (settings.highContrast ? SKColor.black : level.horizonColor).withAlphaComponent(settings.highContrast ? 0.78 : 0.18)
        pavement.strokeColor = .white.withAlphaComponent(settings.highContrast ? 0.7 : 0.18)
        pavement.lineWidth = 4
        pavement.position = CGPoint(x: size.width / 2, y: 0)
        world.addChild(pavement)

        let ground = SKNode()
        ground.position = CGPoint(x: 0, y: groundY)
        ground.physicsBody = SKPhysicsBody(edgeFrom: .zero, to: CGPoint(x: size.width, y: 0))
        ground.physicsBody?.categoryBitMask = PhysicsCategory.ground
        ground.physicsBody?.collisionBitMask = PhysicsCategory.zombie | PhysicsCategory.weapon
        ground.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        world.addChild(ground)

        let boundaries = SKNode()
        boundaries.physicsBody = SKPhysicsBody(edgeLoopFrom: CGRect(x: -120, y: -120, width: size.width + 240, height: size.height + 240))
        boundaries.physicsBody?.categoryBitMask = PhysicsCategory.boundary
        boundaries.physicsBody?.collisionBitMask = PhysicsCategory.zombie
        world.addChild(boundaries)
    }

    private func buildHouse() {
        let diner = DinerNode(frame: houseFrame, reducedMotion: settings.reducedMotion, highContrast: settings.highContrast)
        dinerNode = diner
        world.addChild(diner)
    }

    private func burst(at point: CGPoint, color: SKColor) {
        let count = settings.reducedMotion ? 5 : 12
        for index in 0..<count {
            let particle = SKShapeNode(circleOfRadius: CGFloat.random(in: 3...8))
            particle.fillColor = color
            particle.strokeColor = .clear
            particle.position = point
            particle.zPosition = 90
            world.addChild(particle)
            let angle = CGFloat(index) / CGFloat(count) * .pi * 2
            let distance = settings.reducedMotion ? CGFloat(35) : CGFloat.random(in: 45...110)
            let destination = CGPoint(x: point.x + cos(angle) * distance, y: point.y + sin(angle) * distance)
            particle.run(.sequence([.group([.move(to: destination, duration: 0.32), .fadeOut(withDuration: 0.34)]), .removeFromParent()]))
        }
    }

    private func playCombatVFX(_ effect: CombatVFX, at point: CGPoint, size: CGFloat, direction: CGFloat, tint: SKColor? = nil) {
        let sprite = SKSpriteNode(texture: effect.frames[0], size: CGSize(width: size, height: size))
        sprite.position = point
        sprite.zPosition = 132
        sprite.xScale = direction < 0 ? -0.22 : 0.22
        sprite.yScale = 0.22
        sprite.alpha = 0
        if let tint {
            sprite.color = tint
            sprite.colorBlendFactor = 0.25
        }
        world.addChild(sprite)
        sprite.run(.animate(with: effect.frames, timePerFrame: settings.reducedMotion ? 0.025 : 0.065, resize: false, restore: false), withKey: "artFrames")

        let targetX: CGFloat = direction < 0 ? -1 : 1
        let arrival = SKAction.group([
            .scaleX(to: targetX * (settings.reducedMotion ? 1 : 1.12), duration: settings.reducedMotion ? 0.03 : 0.07),
            .scaleY(to: settings.reducedMotion ? 1 : 1.12, duration: settings.reducedMotion ? 0.03 : 0.07),
            .fadeIn(withDuration: 0.03)
        ])
        let settle = SKAction.group([
            .scaleX(to: targetX, duration: 0.10),
            .scaleY(to: 1, duration: 0.10)
        ])
        sprite.run(.sequence([arrival, settle, .wait(forDuration: settings.reducedMotion ? 0.06 : 0.13), .group([.scale(to: 1.18, duration: 0.18), .fadeOut(withDuration: 0.18)]), .removeFromParent()]))

        let debrisColor: SKColor = switch effect {
        case .pavementImpact: .darkGray
        case .zombieSplatter: SKColor(red: 0.48, green: 0.76, blue: 0.16, alpha: 1)
        case .explosion: .orange
        case .freezerBurst: .cyan
        }
        playDirectionalDebris(at: point, color: debrisColor, direction: direction, count: effect == .explosion ? 14 : 8)
    }

    private func playDirectionalDebris(at point: CGPoint, color: SKColor, direction: CGFloat, count: Int) {
        let particleCount = settings.reducedMotion ? min(4, count) : count
        for index in 0..<particleCount {
            let shard = SKShapeNode(rectOf: CGSize(width: CGFloat.random(in: 3...8), height: CGFloat.random(in: 2...5)), cornerRadius: 1)
            shard.fillColor = index.isMultiple(of: 3) ? .white.withAlphaComponent(0.82) : color
            shard.strokeColor = .clear
            shard.position = point
            shard.zPosition = 134
            world.addChild(shard)
            let spread = CGFloat(index) / CGFloat(max(1, particleCount - 1)) - 0.5
            let dx = direction * CGFloat.random(in: 34...105) + spread * 46
            let dy = CGFloat.random(in: 24...92) - abs(spread) * 18
            shard.run(.sequence([.group([.moveBy(x: dx, y: dy, duration: 0.28), .rotate(byAngle: spread * .pi * 4, duration: 0.28), .fadeOut(withDuration: 0.31)]), .removeFromParent()]))
        }
    }

    private func indexDirection(for x: CGFloat) -> CGFloat {
        x < size.width / 2 ? -1 : 1
    }

    private func radialFlash(at point: CGPoint, color: SKColor) {
        let ring = SKShapeNode(circleOfRadius: 24)
        ring.fillColor = .clear
        ring.strokeColor = color
        ring.lineWidth = 12
        ring.position = point
        ring.zPosition = 130
        world.addChild(ring)
        ring.run(.sequence([.group([.scale(to: settings.reducedMotion ? 2 : 7, duration: 0.32), .fadeOut(withDuration: 0.34)]), .removeFromParent()]))
    }

    private func showCombo(at point: CGPoint) {
        guard combo >= 2 else { return }
        let label = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        label.text = "×\(combo) COMBO"
        label.fontSize = min(42, 22 + CGFloat(combo))
        label.fontColor = SKColor(hue: max(0, 0.14 - CGFloat(combo) * 0.01), saturation: 1, brightness: 1, alpha: 1)
        label.position = CGPoint(x: point.x, y: min(size.height - 60, point.y + 52))
        label.zPosition = 120
        label.setScale(0.6)
        world.addChild(label)
        label.run(.sequence([
            .group([.scale(to: 1, duration: 0.12), .moveBy(x: 0, y: 8, duration: 0.12)]),
            .group([.moveBy(x: 0, y: 26, duration: 0.5), .fadeOut(withDuration: 0.5)]),
            .removeFromParent()
        ]))
    }

    /// A floating "+score" popup on every kill, not just combo chains, so single defeats still feel rewarding.
    private func showScorePopup(at point: CGPoint, score: Int) {
        let label = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        label.text = "+\(score)"
        label.fontSize = 17
        label.fontColor = .white.withAlphaComponent(0.85)
        label.position = CGPoint(x: point.x, y: min(size.height - 40, point.y + 18))
        label.zPosition = 118
        world.addChild(label)
        label.run(.sequence([.group([.moveBy(x: 0, y: 22, duration: 0.45), .fadeOut(withDuration: 0.45)]), .removeFromParent()]))
    }

    private func announce(text: String, color: SKColor) {
        let label = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        label.text = text
        label.fontSize = 42
        label.fontColor = color
        label.position = CGPoint(x: size.width / 2, y: size.height * 0.67)
        label.alpha = 0
        label.zPosition = 150
        world.addChild(label)
        label.run(.sequence([.fadeIn(withDuration: 0.16), .wait(forDuration: 0.65), .fadeOut(withDuration: 0.28), .removeFromParent()]))
    }

    private func shakeCamera(intensity: CGFloat = 1) {
        guard !settings.reducedMotion else { return }
        world.removeAction(forKey: "shake")
        world.run(.sequence([
            .moveBy(x: -8 * intensity, y: 3 * intensity, duration: 0.035),
            .moveBy(x: 15 * intensity, y: -5 * intensity, duration: 0.045),
            .moveBy(x: -10 * intensity, y: 4 * intensity, duration: 0.04),
            .move(to: .zero, duration: 0.055)
        ]), withKey: "shake")
    }

    /// Freezes (or nearly freezes) the sim briefly on a satisfying hit, then resumes — a cheap
    /// "hit-stop" trick that reads as impact weight without any new art or animation states.
    private func hitStop(duration: TimeInterval, slowFactor: CGFloat = 0.04) {
        guard !settings.reducedMotion else { return }
        world.speed = slowFactor
        run(.sequence([.wait(forDuration: duration), .run { [weak self] in self?.world.speed = 1 }]), withKey: "hitStop")
    }

    private func runHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard settings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
