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
    let waveStatus: String
    let waveStatusHighlighted: Bool
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
    private var selectedZombies: [ObjectIdentifier: ZombieNode] = [:]
    private var touchSamples: [ObjectIdentifier: [(point: CGPoint, time: TimeInterval)]] = [:]
    private var dualTouchBaseline: (distance: CGFloat, angle: CGFloat)?
    private var lastUpdateTime: TimeInterval = 0
    private var elapsedTime: TimeInterval = 0
    private var timeSinceSpawn: TimeInterval = 0
    private var movementAudioRemaining: TimeInterval = 0.7
    private var score = 0
    private var health: Int
    private var wave = 1
    private var waveStatus = "WAVE 1"
    private var waveStatusHighlighted = false
    private var spawnedInWave = 0
    private var currentWaveTarget = 0
    private var intermissionRemaining: TimeInterval = 0
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
    private var spawnedBossWaves: Set<Int> = []
    private var sandboxSpeed: CGFloat = 1
    private var sandboxSpawnBurst = 1
    private var sandboxDefeats = 0
    private var finishingReplayUsed = false
    private var sceneryDamage = 0
    private var goreStains: [SKNode] = []
    private var activeGoreDroplets = 0
    /// .doubleSided alternates strictly left/right/left/right rather than trusting Bool.random(),
    /// which could otherwise streak several spawns from the same side and read as a standard mission.
    private var nextDoubleSidedFromLeft = true
    private let bossHUD = SKNode()
    private let bossHealthFill = SKShapeNode(rectOf: CGSize(width: 260, height: 12), cornerRadius: 6)
    private let bossNameLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")

    private var startingHealth: Int { level.isSandbox ? 99 : (level.modifier == .suddenDeath ? 1 : GameRules.startingHealth + progress.upgradeLevel(.reinforcedDiner)) }
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
        health = level.isSandbox ? 99 : (level.modifier == .suddenDeath ? 1 : GameRules.startingHealth + progress.upgradeLevel(.reinforcedDiner))
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
        physicsWorld.gravity = CGVector(dx: 0, dy: level.modifier == .lowGravity ? -3.8 : -8.8)
        physicsWorld.contactDelegate = self
        addChild(world)
        buildEnvironment()
        buildBossHUD()
        SoundManager.shared.updateGameplayMix(wave: wave, healthFraction: 1)
        if level.isSandbox { waveStatus = "SANDBOX" }
        notifyDelegate()
        announce(text: level.title.uppercased(), color: .white)
        if !level.isSandbox {
            // Skip the forced tutorial walker when wave 1 is itself the boss wave, so its spawn
            // doesn't silently consume the boss wave's spawn quota before the boss ever appears.
            let opensOnBoss = !level.isEndless && GameRules.storyBossKind(levelID: level.id, wave: wave, totalWaves: level.totalWaves) != nil
            if !opensOnBoss {
                spawnZombie(forceWalker: true)
                if !level.isEndless { spawnedInWave = 1 }
            }
        }
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
        movementAudioRemaining -= deltaTime

        if level.isSandbox {
            // Sandbox spawns only through explicit player controls.
        } else if level.isEndless {
            let newWave = Int(elapsedTime / level.waveDuration) + 1
            if newWave != wave {
                wave = newWave
                SoundManager.shared.updateGameplayMix(wave: wave, healthFraction: CGFloat(health) / CGFloat(max(1, startingHealth)))
                let incomingBoss = GameRules.bossKind(forWave: wave)
                announce(text: incomingBoss.map { "\($0.displayName) INCOMING" } ?? "WAVE \(wave)", color: .white)
            }
            waveStatus = "SURVIVE"
            waveStatusHighlighted = false
            let difficulty = GameRules.survivalDifficulty(wave: wave, baseSpawnInterval: level.baseSpawnInterval)
            let interval = difficulty.spawnInterval
            if timeSinceSpawn >= interval {
                timeSinceSpawn = 0
                let bossKind = GameRules.bossKind(forWave: wave)
                if let bossKind, !spawnedBossWaves.contains(wave) {
                    spawnedBossWaves.insert(wave)
                    spawnZombie(forceWalker: false, bossKind: bossKind)
                } else if bossKind == nil {
                    for _ in 0..<difficulty.spawnCount {
                        spawnZombie(forceWalker: false)
                    }
                }
            }
        } else {
            updateCampaignWave(deltaTime: deltaTime)
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
        if movementAudioRemaining <= 0,
           let walker = zombies.filter({ !$0.isDefeated && !$0.isGrabbed && !$0.isThrown }).randomElement() {
            SoundManager.shared.playMovement(for: walker.kind, pan: audioPan(for: walker))
            movementAudioRemaining = max(0.42, 1.25 - Double(min(8, zombies.count)) * 0.07)
        }

        notifyDelegate()
    }

    private func updateCampaignWave(deltaTime: TimeInterval) {
        if intermissionRemaining > 0 {
            intermissionRemaining -= deltaTime
            if intermissionRemaining <= 0 {
                if spawningFinished {
                    finish(won: true)
                } else {
                    wave += 1
                    spawnedInWave = 0
                    timeSinceSpawn = 99
                    waveStatus = "WAVE \(wave)"
                    waveStatusHighlighted = false
                    SoundManager.shared.updateGameplayMix(wave: wave, healthFraction: CGFloat(health) / CGFloat(max(1, startingHealth)))
                    let boss = GameRules.storyBossKind(levelID: level.id, wave: wave, totalWaves: level.totalWaves)
                    announce(text: boss.map { "\($0.displayName) INCOMING" } ?? "WAVE \(wave)", color: .white)
                }
            }
            return
        }

        let bossKind = GameRules.storyBossKind(levelID: level.id, wave: wave, totalWaves: level.totalWaves)
        let target = bossKind == nil
            ? GameRules.campaignSpawnCount(wave: wave, waveDuration: level.waveDuration, baseSpawnInterval: level.baseSpawnInterval)
            : 1
        currentWaveTarget = target
        let interval = max(0.48, (level.baseSpawnInterval - Double(wave - 1) * 0.09) * settings.difficulty.spawnRate)
        if spawnedInWave < target, timeSinceSpawn >= interval {
            timeSinceSpawn = 0
            if let bossKind {
                if !spawnedBossWaves.contains(wave) {
                    spawnedBossWaves.insert(wave)
                    spawnZombie(forceWalker: false, bossKind: bossKind)
                    spawnedInWave += 1
                }
            } else {
                spawnZombie(forceWalker: false)
                spawnedInWave += 1
            }
        }

        let livingCount = activeZombies.filter { !$0.isDefeated }.count
        if spawnedInWave >= target, livingCount == 0 {
            spawningFinished = wave >= level.totalWaves
            intermissionRemaining = 1.25
            waveStatus = spawningFinished ? "NIGHT CLEARED" : "WAVE \(wave) CLEAR"
            waveStatusHighlighted = true
            announce(text: waveStatus, color: SKColor(red: 1, green: 0.77, blue: 0.24, alpha: 1))
            SoundManager.shared.play(.waveClear)
        } else {
            let unspawned = max(0, target - spawnedInWave)
            waveStatus = "\(livingCount + unspawned) LEFT"
            waveStatusHighlighted = false
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isGameplayPaused, !gameOver else { return }
        for touch in touches {
            let key = ObjectIdentifier(touch)
            let location = touch.location(in: self)
            if collectPickup(at: location) { continue }
            guard level.modifier != .noGrab, let zombie = zombie(at: location), zombie.canBeGrabbed else { continue }
            let existingTouches = selectedZombies.values.filter { $0 === zombie }.count
            guard existingTouches < 2 else { continue }
            selectedZombies[key] = zombie
            touchSamples[key] = [(location, touch.timestamp)]
            if existingTouches == 0 { zombie.beginGrab(reducedMotion: settings.reducedMotion) }
            zombie.zPosition = 100
            SoundManager.shared.play(.grab)
            runHaptic(.light)
        }
        updateDualTouchGesture()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let key = ObjectIdentifier(touch)
            guard let zombie = selectedZombies[key] else { continue }
            let location = touch.location(in: self)
            zombie.position = CGPoint(x: min(size.width - 20, max(20, location.x)), y: min(size.height - 25, max(groundY + zombie.kind.size.height * 0.39 + 4, location.y)))
            touchSamples[key, default: []].append((location, touch.timestamp))
            touchSamples[key] = Array(touchSamples[key, default: []].suffix(8))
        }
        updateDualTouchGesture()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.forEach(releaseZombie)
        if selectedZombies.count < 2 { dualTouchBaseline = nil }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touches.forEach(releaseZombie)
        if selectedZombies.count < 2 { dualTouchBaseline = nil }
    }

    func useWeapon(_ kind: WeaponKind) {
        guard (level.isSandbox || progress.isUnlocked(kind)), weaponCooldowns[kind, default: 0] <= 0, !gameOver else { return }
        let weaponLevel = progress.upgradeLevel(kind)
        weaponCooldowns[kind] = level.isSandbox ? 0 : GameRules.cooldown(base: kind.cooldown, rapidGearLevel: rapidGearLevel + weaponLevel)
        SoundManager.shared.playWeapon(kind)
        switch kind {
        case .bowlingBall: launchBowlingBall()
        case .shotgun: fireScatterblast()
        case .airstrike: launchAirstrike()
        case .anvil: dropAnvils()
        case .grenade: throwExplosive(radius: 150, damage: 4.5, color: .orange)
        case .propaneTank: launchPropaneTank()
        case .wreckingBall: swingWreckingBall()
        case .sniper: fireSniper()
        case .greaseFire: igniteGreaseFire()
        case .transformer: chainLightning()
        case .deliveryTruck: launchDeliveryTruck()
        case .meteor: launchMeteor()
        }
        notifyDelegate()
    }

    func useTrap(_ kind: TrapKind) {
        guard progress.isUnlocked(kind), trapCooldowns[kind, default: 0] <= 0, !gameOver else { return }
        trapCooldowns[kind] = GameRules.cooldown(base: kind.cooldown, rapidGearLevel: rapidGearLevel)
        SoundManager.shared.playTrap(kind)
        switch kind {
        case .spikeStrip: placeSpikeStrips()
        case .freezer: triggerFreezer()
        }
        notifyDelegate()
    }

    func useSpecial() {
        guard specialCharge >= 1, !gameOver else { return }
        specialCharge = 0
        SoundManager.shared.play(.special)
        SoundManager.shared.duckMusic(strength: 0.34, duration: 0.55)
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
            if let weaponKind = bodies.lazy.compactMap({ body -> WeaponKind? in
                guard body.categoryBitMask == PhysicsCategory.weapon, let name = body.node?.name else { return nil }
                return WeaponKind(rawValue: name)
            }).first, let sound = impactSound(for: weaponKind) {
                SoundManager.shared.play(sound)
            }
            playCombatVFX(.zombieSplatter, at: contact.contactPoint, size: 92, direction: zombie.approachesFromLeft ? -1 : 1)
            let baseDamage: CGFloat = zombie.kind == .brute ? 1.8 : 4
            if zombie.damageAt(contact.contactPoint, amount: baseDamage * zombie.kind.weaponDamageMultiplier) { defeat(zombie, reason: .weapon) }
            return
        }

        if let zombie = zombieBody(in: bodies), bodies.contains(where: { $0.categoryBitMask == PhysicsCategory.trap }) {
            playCombatVFX(.zombieSplatter, at: contact.contactPoint, size: 76, direction: zombie.approachesFromLeft ? -1 : 1)
            let baseDamage: CGFloat = zombie.kind == .armored ? 0.7 : 1.5
            if zombie.damage(baseDamage * zombie.kind.trapDamageMultiplier) { defeat(zombie, reason: .trap) }
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

    /// Central place for weapon-specific impact sounds, keyed by the WeaponKind name every weapon
    /// node is now tagged with, so a new weapon needing a unique impact sound is one case here
    /// instead of another hardcoded node-name branch in didBegin.
    private func impactSound(for weaponKind: WeaponKind) -> SoundManager.Effect? {
        weaponKind == .bowlingBall ? .bowlingImpact : nil
    }

    private func resolveImpact(on zombie: ZombieNode, damage: CGFloat) {
        SoundManager.shared.play(.impact)
        zombie.playImpact(reducedMotion: settings.reducedMotion)
        let impactPoint = CGPoint(x: zombie.position.x, y: groundY + 8)
        playCombatVFX(.pavementImpact, at: impactPoint, size: min(210, 120 + damage * 36), direction: zombie.physicsBody?.velocity.dx.sign == .minus ? -1 : 1)
        if zombie.damage(damage) {
            defeat(zombie, reason: .impact)
        } else {
            if Int.random(in: 0..<3) == 0 {
                SoundManager.shared.playZombieVoice(for: zombie.kind, moment: .hurt, pan: audioPan(for: zombie))
            }
            zombie.run(.sequence([
                .wait(forDuration: 0.34),
                .run { [weak self, weak zombie] in
                    guard let self else { return }
                    zombie?.resumeWalking(on: self.groundY)
                }
            ]))
        }
    }

    private func releaseZombie(_ touch: UITouch) {
        let key = ObjectIdentifier(touch)
        guard let zombie = selectedZombies.removeValue(forKey: key) else { return }
        let location = touch.location(in: self)
        touchSamples[key, default: []].append((location, touch.timestamp))
        let samples = touchSamples.removeValue(forKey: key) ?? []
        guard !selectedZombies.values.contains(where: { $0 === zombie }) else {
            // A second touch is still holding this zombie (dual-touch pinch) — only stop
            // tracking this finger; the remaining touch keeps driving it via touchesMoved.
            return
        }
        zombie.position = CGPoint(x: location.x, y: max(groundY + zombie.kind.size.height * 0.39 + 4, location.y))
        var velocity = FlickMath.velocity(from: samples)
        if hypot(velocity.dx, velocity.dy) < 140 { velocity.dy = 180 }
        zombie.release(with: velocity, powerMultiplier: flickMultiplier)
        if hypot(velocity.dx, velocity.dy) > 1_850 {
            hitStop(duration: 0.16, slowFactor: 0.35)
        }
        zombie.zPosition = 20
    }

    private func updateDualTouchGesture() {
        let entries = touchSamples.compactMap { key, samples -> (ZombieNode, CGPoint)? in
            guard let zombie = selectedZombies[key], let point = samples.last?.point else { return nil }
            return (zombie, point)
        }
        guard entries.count == 2, entries[0].0 === entries[1].0 else { dualTouchBaseline = nil; return }
        let dx = entries[1].1.x - entries[0].1.x
        let dy = entries[1].1.y - entries[0].1.y
        let distance = max(1, hypot(dx, dy))
        let angle = atan2(dy, dx)
        if let baseline = dualTouchBaseline {
            entries[0].0.applyPinch(scale: distance / baseline.distance, rotation: angle - baseline.angle)
        } else { dualTouchBaseline = (distance, angle) }
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

    func sandboxSpawn(_ kind: ZombieKind) {
        guard level.isSandbox else { return }
        for _ in 0..<sandboxSpawnBurst { spawnZombie(forceWalker: false, bossKind: kind.isBoss ? kind : nil, forcedKind: kind) }
    }

    func sandboxClear() {
        guard level.isSandbox else { return }
        activeZombies.forEach { $0.removeFromParent() }
        bossHUD.isHidden = true
    }

    func sandboxSetSpeed(_ speed: CGFloat) {
        guard level.isSandbox else { return }
        sandboxSpeed = min(2.5, max(0.35, speed))
    }

    func sandboxSetGravity(_ gravity: CGFloat) {
        guard level.isSandbox else { return }
        physicsWorld.gravity = CGVector(dx: 0, dy: min(-1, max(-18, gravity)))
    }

    func sandboxSetBurst(_ count: Int) { sandboxSpawnBurst = min(12, max(1, count)) }

    var sandboxStats: String { "ACTIVE \(activeZombies.count) • DEFEATS \(sandboxDefeats) • SPEED \(String(format: "%.1f", sandboxSpeed))×" }

    private func buildBossHUD() {
        bossHUD.zPosition = 190
        bossHUD.position = CGPoint(x: size.width / 2, y: size.height - 48)
        bossHUD.isHidden = true

        let backing = SKShapeNode(rectOf: CGSize(width: 276, height: 28), cornerRadius: 8)
        backing.fillColor = .black.withAlphaComponent(0.78)
        backing.strokeColor = SKColor(red: 0.92, green: 0.22, blue: 0.16, alpha: 1)
        backing.lineWidth = 2
        bossHUD.addChild(backing)

        bossHealthFill.fillColor = SKColor(red: 0.92, green: 0.16, blue: 0.11, alpha: 1)
        bossHealthFill.strokeColor = .clear
        bossHealthFill.position.y = -4
        bossHUD.addChild(bossHealthFill)

        bossNameLabel.fontSize = 12
        bossNameLabel.fontColor = .white
        bossNameLabel.verticalAlignmentMode = .center
        bossNameLabel.position.y = 11
        bossHUD.addChild(bossNameLabel)
        addChild(bossHUD)
    }

    private func showBossHUD(for zombie: ZombieNode) {
        bossNameLabel.text = zombie.kind.displayName
        bossHealthFill.xScale = 1
        bossHUD.isHidden = false
        zombie.onHealthChanged = { [weak self] fraction in
            self?.bossHealthFill.xScale = max(0.001, fraction)
        }
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

    private func spawnZombie(forceWalker: Bool, bossKind: ZombieKind? = nil, forcedKind: ZombieKind? = nil) {
        let unlockedCount = min(level.enemyRoster.count, max(1, 1 + wave))
        let roster = Array(level.enemyRoster.prefix(unlockedCount))
        let kind = forcedKind ?? bossKind ?? (level.modifier == .volatileRush ? .volatile : (level.modifier == .waitressRush ? .waitress : (forceWalker ? (roster.contains(.walker) ? ZombieKind.walker : roster[0]) : roster.randomElement()!)))
        let fromLeft: Bool
        switch level.modifier {
        case .leftOnly: fromLeft = true
        case .rightOnly: fromLeft = false
        case .doubleSided:
            fromLeft = nextDoubleSidedFromLeft
            nextDoubleSidedFromLeft.toggle()
        default: fromLeft = Bool.random()
        }
        let difficulty = level.isEndless ? GameRules.survivalDifficulty(wave: wave, baseSpawnInterval: level.baseSpawnInterval) : nil
        let zombie = ZombieNode(
            kind: kind,
            approachesFromLeft: fromLeft,
            movementMultiplier: (difficulty?.speedMultiplier ?? 1) * settings.difficulty.enemySpeed * (level.isSandbox ? sandboxSpeed : 1),
            healthMultiplier: (difficulty?.healthMultiplier ?? 1) * settings.difficulty.enemyHealth
        )
        zombie.position = CGPoint(
            x: fromLeft ? -kind.size.width : size.width + kind.size.width,
            y: groundY + kind.size.height * 0.39 + 2
        )
        zombie.zPosition = 10
        world.addChild(zombie)
        zombie.onArmorBroken = { SoundManager.shared.play(.armorBreak) }
        zombie.onBossPhaseChanged = { [weak self, weak zombie] phase in
            guard let self, let zombie else { return }
            SoundManager.shared.playBossPhase(phase, pan: self.audioPan(for: zombie))
            SoundManager.shared.updateGameplayMix(
                wave: self.wave,
                healthFraction: CGFloat(self.health) / CGFloat(max(1, self.startingHealth)),
                bossPhase: phase
            )
        }
        if kind.isBoss {
            showBossHUD(for: zombie)
            SoundManager.shared.playZombieVoice(for: kind, moment: .spawn, pan: audioPan(for: zombie))
            SoundManager.shared.playBossLayer(phase: 1)
        } else if Int.random(in: 0..<4) == 0 {
            SoundManager.shared.playZombieVoice(for: kind, moment: .spawn, pan: audioPan(for: zombie))
        }
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
        SoundManager.shared.playZombieVoice(for: zombie.kind, moment: .attack, pan: audioPan(for: zombie))
        health = level.isSandbox ? health : max(0, health - zombie.kind.dinerDamage)
        combo = 0
        dinerNode?.takeHit(remainingHealth: health, maximumHealth: startingHealth)
        damageScenery(near: zombie.position)
        let strikeX = zombie.position.x < size.width / 2 ? houseFrame.minX + 28 : houseFrame.maxX - 28
        playCombatVFX(.pavementImpact, at: CGPoint(x: strikeX, y: groundY + 72), size: 138, direction: zombie.approachesFromLeft ? 1 : -1, tint: .red)
        shakeCamera(intensity: 1.4)
        SoundManager.shared.play(.dinerHit)
        SoundManager.shared.duckMusic(strength: 0.52, duration: 0.46)
        SoundManager.shared.updateGameplayMix(
            wave: wave,
            healthFraction: CGFloat(health) / CGFloat(max(1, startingHealth)),
            bossPhase: zombie.kind.isBoss ? zombie.bossPhase : 0
        )
        runHaptic(.heavy)
        zombie.playDefeat(style: .dinerAttack, reducedMotion: settings.reducedMotion) {}
        if zombie.kind.isBoss {
            bossHUD.isHidden = true
            SoundManager.shared.updateGameplayMix(wave: wave, healthFraction: CGFloat(health) / CGFloat(max(1, startingHealth)))
        }
        if health == 0 { finish(won: false) }
    }

    private func defeat(_ zombie: ZombieNode, reason: DefeatReason) {
        guard zombie.parent != nil, !zombie.isDefeated else { return }
        if elapsedTime - lastDefeatTime <= 1.8 { combo += 1 } else { combo = 1 }
        maxCombo = max(maxCombo, combo)
        defeats += 1
        if level.isSandbox { sandboxDefeats += 1 }
        lastDefeatTime = elapsedTime
        let killScore = GameRules.score(for: zombie.kind, combo: combo)
        score += killScore
        specialCharge = min(1, specialCharge + (zombie.kind.isBoss ? 0.5 : (zombie.kind == .brute ? 0.22 : 0.12)))
        let point = zombie.position
        let volatile = zombie.kind == .volatile
        if settings.goreEnabled {
            spawnPhysicsDebris(from: zombie, reason: reason)
        }
        zombie.playDefeat(style: defeatStyle(for: reason), reducedMotion: settings.reducedMotion) {}
        if zombie.kind.isBoss {
            bossHUD.isHidden = true
            SoundManager.shared.updateGameplayMix(wave: wave, healthFraction: CGFloat(health) / CGFloat(max(1, startingHealth)))
        }
        // Computed fresh here rather than trusting `spawningFinished`: that flag only updates once
        // per frame in updateCampaignWave, which runs before this frame's physics contacts resolve,
        // so it's always one kill behind the zombie that's actually dying right now.
        let isFinalCampaignKill = !level.isEndless && !level.isSandbox
            && wave >= level.totalWaves
            && spawnedInWave >= currentWaveTarget
            && activeZombies.allSatisfy { $0.isDefeated }
        if !finishingReplayUsed, !settings.reducedMotion, (zombie.kind.isBoss || isFinalCampaignKill) {
            finishingReplayUsed = true
            world.speed = 0.22
            run(.sequence([.wait(forDuration: 0.5), .run { [weak self] in self?.world.speed = 1 }]), withKey: "finisherReplay")
        }
        if reason == .thrownOut {
            burst(at: point, color: .cyan)
        } else if reason != .explosion {
            playCombatVFX(.zombieSplatter, at: point, size: zombie.kind.isBoss ? 210 : (zombie.kind == .brute ? 156 : 118), direction: zombie.approachesFromLeft ? -1 : 1)
        }
        SoundManager.shared.play(.defeat, comboScale: combo)
        if zombie.kind.isBoss || zombie.kind.alwaysVocalizesOnDefeat || Int.random(in: 0..<3) == 0 {
            SoundManager.shared.playZombieVoice(for: zombie.kind, moment: .defeat, pan: audioPan(for: zombie))
        }
        runHaptic(.medium)
        showScorePopup(at: point, score: killScore)
        showCombo(at: point)
        hitStop(duration: min(0.09, 0.045 + Double(combo) * 0.004))
        if Int.random(in: 0..<5) == 0 { spawnPickup(at: point) }
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

    private func audioPan(for zombie: ZombieNode) -> Float {
        let normalized = (zombie.position.x / max(1, size.width)) * 2 - 1
        return Float(max(-0.9, min(0.9, normalized)))
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
        SoundManager.shared.play(.explosion)
        SoundManager.shared.duckMusic(strength: 0.48, duration: 0.42)
        shakeCamera(intensity: 1.2)
    }

    private func launchBowlingBall() {
        let ball = SKSpriteNode(texture: EquipmentArt.bowlingBall.texture)
        ball.size = EquipmentArt.bowlingBall.fittedSize(inside: CGSize(width: 82, height: 82))
        ball.name = WeaponKind.bowlingBall.rawValue
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
        SoundManager.shared.play(.bowlingRoll)
        if !settings.reducedMotion {
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
        if settings.reducedMotion { scattergun.texture = EquipmentArt.scatterblast.actionFrames[1] }
        else { scattergun.run(.animate(with: EquipmentArt.scatterblast.actionFrames, timePerFrame: 0.075, resize: false, restore: false), withKey: "artFrames") }
        if settings.reducedMotion {
            scattergun.run(.sequence([.wait(forDuration: 0.12), .fadeOut(withDuration: 0.10), .removeFromParent()]))
        } else {
            let recoil: CGFloat = 18
            scattergun.run(.sequence([
                .moveBy(x: -recoil, y: -recoil * 0.25, duration: 0.045),
                .moveBy(x: recoil, y: recoil * 0.25, duration: 0.11),
                .fadeOut(withDuration: 0.12),
                .removeFromParent()
            ]))
        }
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
        if settings.reducedMotion { beacon.texture = EquipmentArt.airstrikeBeacon.actionFrames[1] }
        else { beacon.run(.repeatForever(.animate(with: EquipmentArt.airstrikeBeacon.actionFrames, timePerFrame: 0.16, resize: false, restore: true)), withKey: "artFrames") }
        if settings.reducedMotion {
            beacon.setScale(1)
            beacon.run(.sequence([.wait(forDuration: 1.2), .fadeOut(withDuration: 0.12), .removeFromParent()]))
        } else {
            let pulse = SKAction.sequence([.fadeAlpha(to: 0.38, duration: 0.14), .fadeAlpha(to: 1, duration: 0.14)])
            beacon.run(.sequence([
                .scale(to: 1, duration: 0.18),
                .repeat(pulse, count: 4),
                .wait(forDuration: 0.45),
                .fadeOut(withDuration: 0.2),
                .removeFromParent()
            ]))
        }
        let xs = [size.width * 0.18, size.width * 0.5, size.width * 0.82]
        for (index, x) in xs.enumerated() {
            world.run(.sequence([
                .wait(forDuration: Double(index) * 0.24),
                .run { [weak self] in self?.airstrikeImpact(x: x) }
            ]))
        }
    }

    private func dropAnvils() {
        for zombie in activeZombies.filter({ !$0.isDefeated }).prefix(3) {
            let anvil = SKSpriteNode(texture: WeaponKind.anvil.authoredTexture, size: CGSize(width: 82, height: 68))
            anvil.name = WeaponKind.anvil.rawValue
            anvil.position = CGPoint(x: zombie.position.x, y: size.height + 45)
            anvil.zPosition = 40
            anvil.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 58, height: 42))
            anvil.physicsBody?.mass = 5
            anvil.physicsBody?.categoryBitMask = PhysicsCategory.weapon
            anvil.physicsBody?.collisionBitMask = PhysicsCategory.zombie | PhysicsCategory.ground
            anvil.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
            world.addChild(anvil)
            anvil.run(.sequence([.wait(forDuration: 4), .removeFromParent()]))
        }
    }

    private func throwExplosive(radius: CGFloat, damage: CGFloat, color: SKColor) {
        let point = CGPoint(x: size.width / 2, y: groundY + 42)
        for zombie in activeZombies where !zombie.isDefeated && abs(zombie.position.x - point.x) < radius {
            if zombie.damage(damage * zombie.kind.weaponDamageMultiplier) { defeat(zombie, reason: .explosion) }
            else { zombie.launch(with: CGVector(dx: (zombie.position.x < point.x ? -1 : 1) * 260, dy: 300)) }
        }
        playCombatVFX(.explosion, at: point, size: radius * 1.7, direction: 1, tint: color)
        SoundManager.shared.play(.explosion)
        SoundManager.shared.duckMusic(strength: 0.48, duration: 0.42)
        shakeCamera(intensity: 1)
    }

    private func launchPropaneTank() {
        let tank = SKSpriteNode(texture: WeaponKind.propaneTank.authoredTexture, size: CGSize(width: 86, height: 58))
        tank.name = WeaponKind.propaneTank.rawValue
        tank.position = CGPoint(x: -50, y: groundY + 34)
        tank.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 82, height: 34))
        tank.physicsBody?.mass = 3
        tank.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        tank.physicsBody?.collisionBitMask = PhysicsCategory.zombie | PhysicsCategory.ground
        tank.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        tank.physicsBody?.velocity = CGVector(dx: 680, dy: 110)
        world.addChild(tank)
        tank.run(.sequence([.wait(forDuration: 2.2), .run { [weak self, weak tank] in
            guard let self, let tank else { return }
            self.throwExplosive(at: tank.position, radius: 175, damage: 5.5)
            tank.removeFromParent()
        }]))
    }

    private func throwExplosive(at point: CGPoint, radius: CGFloat, damage: CGFloat) {
        for zombie in activeZombies where !zombie.isDefeated && hypot(zombie.position.x - point.x, zombie.position.y - point.y) < radius {
            if zombie.damage(damage * zombie.kind.weaponDamageMultiplier) { defeat(zombie, reason: .explosion) }
        }
        playCombatVFX(.explosion, at: point, size: radius * 1.7, direction: 1)
        SoundManager.shared.play(.explosion)
        SoundManager.shared.duckMusic(strength: 0.48, duration: 0.42)
    }

    private func swingWreckingBall() {
        let ball = SKSpriteNode(texture: WeaponKind.wreckingBall.authoredTexture, size: CGSize(width: 118, height: 118))
        ball.name = WeaponKind.wreckingBall.rawValue
        ball.position = CGPoint(x: -70, y: size.height * 0.56)
        ball.physicsBody = SKPhysicsBody(circleOfRadius: 50)
        ball.physicsBody?.isDynamic = false
        ball.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        ball.physicsBody?.collisionBitMask = PhysicsCategory.none
        ball.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        world.addChild(ball)
        ball.run(.sequence([.moveTo(x: size.width + 70, duration: 0.78), .moveTo(x: -70, duration: 0.78), .removeFromParent()]))
    }

    private func fireSniper() {
        guard let target = activeZombies.filter({ !$0.isDefeated }).max(by: { $0.kind.scoreValue < $1.kind.scoreValue }) else { return }
        let hitDamage = target.kind.isBoss ? target.kind.hitPoints * 0.14 : target.kind.hitPoints * 1.2
        if target.damage(hitDamage) { defeat(target, reason: .weapon) }
        playDirectionalDebris(at: target.position, color: .yellow, direction: target.approachesFromLeft ? -1 : 1, count: 6)
        hitStop(duration: 0.14)
    }

    private func igniteGreaseFire() {
        let center = CGPoint(x: size.width / 2, y: groundY + 20)
        for tick in 0..<5 {
            world.run(.sequence([.wait(forDuration: Double(tick) * 0.5), .run { [weak self] in
                guard let self else { return }
                for zombie in self.activeZombies where !zombie.isDefeated && abs(zombie.position.x - center.x) < 210 {
                    if zombie.damage(0.85 * zombie.kind.weaponDamageMultiplier) { self.defeat(zombie, reason: .weapon) }
                }
                self.playCombatVFX(.explosion, at: center, size: 220, direction: 1, tint: .orange)
            }]))
        }
    }

    private func chainLightning() {
        for (index, zombie) in activeZombies.filter({ !$0.isDefeated }).prefix(6).enumerated() {
            world.run(.sequence([.wait(forDuration: Double(index) * 0.09), .run { [weak self, weak zombie] in
                guard let self, let zombie else { return }
                if zombie.damage(2.4 * zombie.kind.weaponDamageMultiplier) { self.defeat(zombie, reason: .weapon) }
                self.radialFlash(at: zombie.position, color: .cyan)
            }]))
        }
    }

    private func launchDeliveryTruck() {
        let truck = SKSpriteNode(texture: WeaponKind.deliveryTruck.authoredTexture, size: CGSize(width: 190, height: 104))
        truck.name = WeaponKind.deliveryTruck.rawValue
        truck.position = CGPoint(x: -120, y: groundY + 48)
        truck.zPosition = 35
        truck.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 175, height: 80))
        truck.physicsBody?.isDynamic = false
        truck.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        truck.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        truck.run(.sequence([.moveTo(x: size.width + 130, duration: 1.05), .removeFromParent()]))
        world.addChild(truck)
    }

    private func launchMeteor() {
        let target = activeZombies.randomElement()?.position ?? CGPoint(x: size.width / 2, y: groundY + 25)
        let meteor = SKSpriteNode(texture: WeaponKind.anvil.authoredTexture, size: CGSize(width: 110, height: 92))
        meteor.color = .orange; meteor.colorBlendFactor = 0.55
        meteor.position = CGPoint(x: target.x + 160, y: size.height + 80)
        meteor.zPosition = 140
        world.addChild(meteor)
        meteor.run(.sequence([.move(to: target, duration: 0.48), .run { [weak self] in self?.throwExplosive(at: target, radius: 260, damage: 10) }, .removeFromParent()]))
    }

    private func spawnPhysicsDebris(from zombie: ZombieNode, reason: DefeatReason) {
        let impulseScale: CGFloat = reason == .explosion ? 1.8 : (zombie.kind.isBoss ? 0.75 : 1)
        if !settings.reducedMotion {
            let pieces = zombie.makePhysicsDebris()
            for (index, debris) in pieces.enumerated() {
                debris.position = zombie.position
                debris.zPosition = 28
                world.addChild(debris)
                let spread = CGFloat(index - 2) * 34 + CGFloat.random(in: -22...22)
                debris.physicsBody?.applyImpulse(CGVector(dx: spread * impulseScale, dy: CGFloat.random(in: 70...150) * impulseScale))
                debris.physicsBody?.angularVelocity = CGFloat.random(in: -5...5)
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
        let baseColor = SKColor(red: 0.34, green: 0.58, blue: 0.08, alpha: 1)
        if !settings.reducedMotion {
            spawnAirborneGore(at: point, scale: scale, direction: direction, radial: reason == .explosion)
        }

        let container = SKNode()
        container.position = CGPoint(x: point.x, y: groundY + 2)
        container.zPosition = 2
        world.addChild(container)

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
        let count = min(34, Int((radial ? 24 : 16) * scale))
        for index in 0..<count {
            guard activeGoreDroplets < 90 else { break }
            let angle = radial
                ? CGFloat(index) / CGFloat(count) * .pi * 2 + CGFloat.random(in: -0.22...0.22)
                : CGFloat.random(in: -0.72...0.34) + (direction < 0 ? .pi : 0)
            let distance = CGFloat.random(in: 48...155) * scale
            let landing = CGPoint(
                x: max(8, min(size.width - 8, point.x + cos(angle) * distance)),
                y: groundY + CGFloat.random(in: 2...10)
            )
            let peak = CGPoint(
                x: point.x + (landing.x - point.x) * 0.42,
                y: min(size.height - 20, point.y + CGFloat.random(in: 35...105) * scale)
            )
            let radius = CGFloat.random(in: 2.5...7.5) * min(1.5, scale)
            let droplet = SKShapeNode(path: splatterBlobPath(radius: radius, points: 6, verticalScale: CGFloat.random(in: 0.7...1.35)))
            droplet.fillColor = index.isMultiple(of: 4)
                ? SKColor(red: 0.62, green: 0.82, blue: 0.14, alpha: 0.88)
                : SKColor(red: 0.28, green: 0.54, blue: 0.06, alpha: 0.92)
            droplet.strokeColor = .clear
            droplet.position = point
            droplet.zPosition = 130 + CGFloat(index % 3)
            world.addChild(droplet)
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

    private func airstrikeImpact(x: CGFloat) {
        let point = CGPoint(x: x, y: groundY + 35)
        for zombie in activeZombies where !zombie.isDefeated && abs(zombie.position.x - x) < size.width * 0.22 {
            if zombie.damage(5) { defeat(zombie, reason: .weapon) }
        }
        playCombatVFX(.explosion, at: point, size: 238, direction: indexDirection(for: x))
        SoundManager.shared.play(.explosion)
        SoundManager.shared.duckMusic(strength: 0.44, duration: 0.36)
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
            if settings.reducedMotion { strip.texture = EquipmentArt.spikeStrip.actionFrames[2] }
            else { strip.run(.animate(with: EquipmentArt.spikeStrip.actionFrames, timePerFrame: 0.09, resize: false, restore: false), withKey: "artFrames") }
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
        if settings.reducedMotion { freezer.texture = EquipmentArt.flashFreezer.actionFrames[2] }
        else { freezer.run(.animate(with: EquipmentArt.flashFreezer.actionFrames, timePerFrame: 0.10, resize: false, restore: false), withKey: "artFrames") }
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
        selectedZombies.removeAll()
        touchSamples.removeAll()
        activeZombies.forEach { $0.physicsBody?.isDynamic = false }
        SoundManager.shared.play(won ? .victory : .loss)
        SoundManager.shared.duckMusic(strength: won ? 0.36 : 0.60, duration: 0.9)
        // Endless never "wins" (there's no wave count to clear), so its payout is scored from
        // performance instead of the win-gated per-level reward, and stars don't apply.
        let earnedStars = level.isEndless ? 0 : GameRules.stars(score: score, health: health, startingHealth: startingHealth, won: won)
        let baseReward = level.isEndless ? GameRules.survivalReward(score: score) : (won ? level.reward + earnedStars * 40 : 0)
        let reward = level.isSandbox ? 0 : Int(Double(baseReward) * settings.difficulty.rewardMultiplier)
        let result = LevelResult(levelID: level.id, score: score, stars: earnedStars, reward: reward, won: won, defeats: defeats, maxCombo: maxCombo, wave: wave)
        gameDelegate?.gameScene(self, didFinish: result)
    }

    private func spawnPickup(at point: CGPoint) {
        let roll = Int.random(in: 0..<10)
        let choices = WeaponKind.allCases.filter { progress.isUnlocked($0) }
        guard let weapon = choices.randomElement() else { return }
        let pickup = SKShapeNode(circleOfRadius: 25)
        pickup.name = roll < 2 ? "pickup-repair" : (roll < 6 ? "pickup-coin" : "pickup-\(weapon.rawValue)")
        pickup.fillColor = roll < 2 ? .red : (roll < 6 ? .yellow : .orange)
        pickup.strokeColor = .white
        pickup.lineWidth = 4
        pickup.position = point
        pickup.zPosition = 115
        let icon = SKSpriteNode(texture: weapon.authoredTexture, size: weapon.authoredFittedSize(inside: CGSize(width: 40, height: 40)))
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
                } else if current.name == "pickup-coin" {
                    score += 75
                    current.removeFromParent()
                    SoundManager.shared.play(.pickup)
                    showScorePopup(at: location, score: 75)
                    return true
                } else if current.name == "pickup-repair" {
                    health = min(startingHealth, health + 1)
                    SoundManager.shared.updateGameplayMix(wave: wave, healthFraction: CGFloat(health) / CGFloat(max(1, startingHealth)))
                    current.removeFromParent()
                    SoundManager.shared.play(.pickup)
                    announce(text: "DINER REPAIRED", color: .green)
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
            waveStatus: waveStatus,
            waveStatusHighlighted: waveStatusHighlighted,
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

    private func damageScenery(near point: CGPoint) {
        sceneryDamage += 1
        let shard = SKShapeNode(rectOf: CGSize(width: 34, height: 9), cornerRadius: 2)
        shard.fillColor = sceneryDamage.isMultiple(of: 2) ? .darkGray : SKColor(red: 0.42, green: 0.17, blue: 0.11, alpha: 1)
        shard.strokeColor = .orange.withAlphaComponent(0.45)
        shard.position = CGPoint(x: point.x < size.width / 2 ? houseFrame.minX : houseFrame.maxX, y: groundY + CGFloat(35 + (sceneryDamage % 4) * 18))
        shard.zRotation = CGFloat.random(in: -0.35...0.35)
        shard.zPosition = 15
        world.addChild(shard)
        shard.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 34, height: 9))
        shard.physicsBody?.collisionBitMask = PhysicsCategory.ground
        shard.physicsBody?.applyImpulse(CGVector(dx: point.x < size.width / 2 ? -65 : 65, dy: 90))
        shard.run(.sequence([.wait(forDuration: 4), .fadeOut(withDuration: 0.5), .removeFromParent()]))
    }

    private func buildSky() {
        // EnvironmentNode derives its art filename straight from levelID; endless reuses Last
        // Light's backdrop (there's no dedicated "environment_00" asset for the id-0 placeholder).
        let environmentID = level.environmentID ?? ((level.isEndless || level.isSandbox) ? 5 : level.id)
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
        let frameIndices = GameRules.animationFrameIndices(totalFrames: effect.frames.count, reducedMotion: settings.reducedMotion, emphasizedFrame: 2)
        let presentationFrames = frameIndices.map { effect.frames[$0] }
        let sprite = SKSpriteNode(texture: presentationFrames[0], size: CGSize(width: size, height: size))
        sprite.position = point
        sprite.zPosition = 132
        sprite.xScale = direction < 0 ? (settings.reducedMotion ? -1 : -0.22) : (settings.reducedMotion ? 1 : 0.22)
        sprite.yScale = settings.reducedMotion ? 1 : 0.22
        sprite.alpha = settings.reducedMotion ? 1 : 0
        if let tint {
            sprite.color = tint
            sprite.colorBlendFactor = 0.25
        }
        world.addChild(sprite)
        if !settings.reducedMotion {
            sprite.run(.animate(with: presentationFrames, timePerFrame: 0.065, resize: false, restore: false), withKey: "artFrames")
        }

        if settings.reducedMotion {
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
        case .freezerBurst: .cyan
        }
        if !settings.reducedMotion {
            playDirectionalDebris(at: point, color: debrisColor, direction: direction, count: effect == .explosion ? 14 : 8)
        }
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
        guard settings.flashesEnabled else { return }
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
        guard !settings.reducedMotion, settings.screenShakeEnabled else { return }
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
