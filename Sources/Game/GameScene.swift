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
    let armedWeapon: WeaponKind?
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
        didSet {
            world.isPaused = isGameplayPaused
            // Pausing `world` stops actions/physics but not touchesMoved/Ended — an in-progress
            // drag could otherwise still resolve into a fired shot while the game visibly looks
            // frozen (e.g. a second finger hits the pause button mid-flick). Cancel any armed/
            // mid-gesture weapon the moment we pause so that can't happen.
            if isGameplayPaused { cancelArmedWeapon() }
        }
    }

    private let world = SKNode()
    private var dinerNode: DinerNode?
    private var selectedZombies: [ObjectIdentifier: ZombieNode] = [:]
    private var touchSamples: [ObjectIdentifier: [(point: CGPoint, time: TimeInterval)]] = [:]
    private var dualTouchBaseline: (distance: CGFloat, angle: CGFloat)?

    // MARK: - Weapon aiming
    private(set) var armedWeapon: WeaponKind?
    private var aimTouchKey: ObjectIdentifier?
    /// The touch-down point, held stable for the whole gesture — `aimSamples` is trimmed to a
    /// short rolling window for velocity math, so it can't be trusted to still hold this by the
    /// time a long drag ends.
    private var aimOrigin: CGPoint?
    private var aimSamples: [(point: CGPoint, time: TimeInterval)] = []
    private var aimPathPoints: [CGPoint] = []
    private var aimPreviewNode: SKNode?
    private struct Detonatable { let node: SKNode; let detonate: () -> Void }
    private var detonatables: [ObjectIdentifier: Detonatable] = [:]
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
        let width = min(310, size.width * 0.29)
        return CGRect(x: size.width * 0.5 - width * 0.5, y: groundY, width: width, height: min(280, size.height * 0.38))
    }
    /// The point defender-fired shots (sniper tracer, scatterblast pellets) visually originate from.
    private var defenderMuzzle: CGPoint {
        CGPoint(x: houseFrame.midX + houseFrame.width * 0.18, y: groundY + houseFrame.height * 0.43)
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
        let nearestThreat = zombies
            .filter { !$0.isDefeated && !$0.isGrabbed && !$0.isThrown }
            .min { abs($0.position.x - houseFrame.midX) < abs($1.position.x - houseFrame.midX) }
        dinerNode?.aimDefender(at: nearestThreat?.position)
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

    /// The gesture primitive a weapon's `touchesBegan`/`touchesMoved`/`touchesEnded` aim needs.
    private enum WeaponAimGesture {
        case tap
        case tapOnNode(named: String)
        case dragRelease
        case dragAimReleaseLine
        case pendulumDragRelease
        case paintPath
    }

    /// The resolved aim, handed to a fire function once its gesture completes.
    private enum WeaponAim {
        case point(CGPoint)
        case flick(origin: CGPoint, releasePoint: CGPoint, velocity: CGVector)
        case line(origin: CGPoint, through: CGPoint)
        case path([CGPoint])

        var resolvedPoint: CGPoint? {
            if case .point(let point) = self { return point }
            return nil
        }

        var resolvedFlick: (origin: CGPoint, releasePoint: CGPoint, velocity: CGVector)? {
            if case .flick(let origin, let releasePoint, let velocity) = self { return (origin, releasePoint, velocity) }
            return nil
        }

        var resolvedLine: (origin: CGPoint, through: CGPoint)? {
            if case .line(let origin, let through) = self { return (origin, through) }
            return nil
        }

        var resolvedPath: [CGPoint]? {
            if case .path(let points) = self { return points }
            return nil
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isGameplayPaused, !gameOver else { return }
        for touch in touches {
            let key = ObjectIdentifier(touch)
            let location = touch.location(in: self)
            if detonateIfHit(at: location) { continue }
            if let armedWeapon {
                guard aimTouchKey == nil else { continue }
                beginAim(weapon: armedWeapon, key: key, location: location, timestamp: touch.timestamp)
                continue
            }
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
            if key == aimTouchKey {
                updateAim(location: touch.location(in: self), timestamp: touch.timestamp)
                continue
            }
            guard let zombie = selectedZombies[key] else { continue }
            let location = touch.location(in: self)
            zombie.position = CGPoint(x: min(size.width - 20, max(20, location.x)), y: min(size.height - 25, max(groundY + zombie.kind.size.height * 0.39 + 4, location.y)))
            touchSamples[key, default: []].append((location, touch.timestamp))
            touchSamples[key] = Array(touchSamples[key, default: []].suffix(8))
        }
        updateDualTouchGesture()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if ObjectIdentifier(touch) == aimTouchKey {
                endAim(location: touch.location(in: self), timestamp: touch.timestamp)
            } else {
                releaseZombie(touch)
            }
        }
        if selectedZombies.count < 2 { dualTouchBaseline = nil }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if ObjectIdentifier(touch) == aimTouchKey {
                cancelAim()
            } else {
                releaseZombie(touch)
            }
        }
        if selectedZombies.count < 2 { dualTouchBaseline = nil }
    }

    /// Anvil/Meteor/Scatterblast are tap-targeted for good — the rest still resolve as `.tap`
    /// (fire immediately on touch-down, ignoring where they're aimed) until their drag/paint/
    /// pierce logic is built, one weapon at a time.
    private func aimGesture(for kind: WeaponKind) -> WeaponAimGesture {
        switch kind {
        case .anvil, .meteor, .shotgun: .tap
        case .bowlingBall, .grenade, .propaneTank, .deliveryTruck: .dragRelease
        case .sniper: .dragAimReleaseLine
        case .greaseFire, .airstrike: .paintPath
        case .transformer: .tapOnNode(named: "transformerPole")
        case .wreckingBall: .pendulumDragRelease
        }
    }

    /// Arming replaces the old instant-fire `useWeapon`: tapping a weapon's icon readies it
    /// instead of firing it immediately, and the actual shot comes from performing that weapon's
    /// gesture on the battlefield (resolved in `beginAim`/`endAim`). Cooldown only starts on an
    /// actual shot in `commitFire`, so arming or canceling costs nothing.
    func armWeapon(_ kind: WeaponKind) {
        guard !gameOver else { return }
        if armedWeapon == kind {
            cancelAim()
            notifyDelegate()
            return
        }
        guard (level.isSandbox || progress.isUnlocked(kind)), weaponCooldowns[kind, default: 0] <= 0 else { return }
        cancelAim()
        armedWeapon = kind
        spawnAimPreview(for: kind)
        notifyDelegate()
    }

    private func beginAim(weapon: WeaponKind, key: ObjectIdentifier, location: CGPoint, timestamp: TimeInterval) {
        switch aimGesture(for: weapon) {
        case .tap:
            commitFire(weapon, aim: .point(location))
        case .tapOnNode(let name):
            let hitProp = nodes(at: location).contains { node in
                var candidate: SKNode? = node
                while let current = candidate {
                    if current.name == name { return true }
                    candidate = current.parent
                }
                return false
            }
            if hitProp { commitFire(weapon, aim: .point(location)) }
        case .dragRelease, .dragAimReleaseLine, .pendulumDragRelease, .paintPath:
            aimTouchKey = key
            aimOrigin = location
            aimSamples = [(location, timestamp)]
            aimPathPoints = [location]
            updateAimPreview(weapon: weapon, location: location)
        }
    }

    private func updateAim(location: CGPoint, timestamp: TimeInterval) {
        guard let armedWeapon else { return }
        aimSamples.append((location, timestamp))
        aimSamples = Array(aimSamples.suffix(8))
        aimPathPoints.append(location)
        updateAimPreview(weapon: armedWeapon, location: location)
    }

    private func endAim(location: CGPoint, timestamp: TimeInterval) {
        aimTouchKey = nil
        guard let weapon = armedWeapon else { return }
        aimSamples.append((location, timestamp))
        switch aimGesture(for: weapon) {
        case .tap, .tapOnNode:
            break // already resolved on touch-down in beginAim
        case .dragRelease, .pendulumDragRelease:
            var velocity = FlickMath.velocity(from: aimSamples)
            // A too-weak release would otherwise just drop the object in place — match the floor
            // ZombieNode.release already applies to a weak zombie flick.
            if hypot(velocity.dx, velocity.dy) < 140 { velocity.dy = 180 }
            commitFire(weapon, aim: .flick(origin: aimOrigin ?? location, releasePoint: location, velocity: velocity))
        case .dragAimReleaseLine:
            commitFire(weapon, aim: .line(origin: defenderMuzzle, through: location))
        case .paintPath:
            commitFire(weapon, aim: .path(aimPathPoints))
        }
    }

    private func cancelAim() {
        armedWeapon = nil
        aimTouchKey = nil
        aimOrigin = nil
        aimSamples.removeAll()
        aimPathPoints.removeAll()
        aimPreviewNode?.removeFromParent()
        aimPreviewNode = nil
    }

    /// Public entry point for cleanup callers outside the touch-handling code (pausing,
    /// backgrounding, level finish) — a plain `cancelAim()` call skips the HUD refresh those
    /// sites need, since they're not already about to call `notifyDelegate()` themselves.
    func cancelArmedWeapon() {
        guard armedWeapon != nil else { return }
        cancelAim()
        notifyDelegate()
    }

    /// Hands the preview node off to the fire function (which turns it into the live projectile)
    /// without removing it from the scene, unlike `cancelAim` — an explicit cancel discards the
    /// preview, but a completed shot keeps it flying.
    @discardableResult
    private func releaseAimPreview() -> SKNode? {
        let node = aimPreviewNode
        armedWeapon = nil
        aimTouchKey = nil
        aimOrigin = nil
        aimSamples.removeAll()
        aimPathPoints.removeAll()
        aimPreviewNode = nil
        return node
    }

    /// Placeholder until each weapon's gesture is converted (see `aimGesture(for:)`) — nothing to
    /// preview for a `.tap`-resolved weapon since it fires on touch-down with no drag phase.
    private func spawnAimPreview(for kind: WeaponKind) {
        switch aimGesture(for: kind) {
        case .tap:
            break
        case .tapOnNode:
            aimPreviewNode = spawnTransformerPole()
        case .dragRelease:
            // Delivery Truck has no on-screen prop to drag — it starts off-screen and only
            // the drag's origin/direction matter, so it gets a live line preview instead
            // (drawn in updateAimPreview) rather than a ready sprite here.
            guard kind != .deliveryTruck, let node = makeDragReadyNode(for: kind) else { return }
            aimPreviewNode = node
            world.addChild(node)
        case .pendulumDragRelease:
            guard let node = makeDragReadyNode(for: kind) else { return }
            aimPreviewNode = node
            world.addChild(node)
        case .dragAimReleaseLine, .paintPath:
            break
        }
    }

    private var transformerPolePosition: CGPoint {
        CGPoint(x: houseFrame.minX - 90, y: groundY + 70)
    }

    /// A static pivot anchored near the top of the screen with the ball hanging below it at rest
    /// — the joint (built fresh in `swingWreckingBall` at release, not here) treats this as its
    /// rest arm length, so the ball's dragged-to position at release is what the pendulum swings
    /// from.
    private var wreckingBallPivotPosition: CGPoint {
        CGPoint(x: size.width * 0.5, y: size.height * 0.92)
    }
    private var wreckingBallArmLength: CGFloat {
        min(260, size.height * 0.42)
    }

    /// The tappable prop Transformer arms — expires after 6s if untapped so the player isn't
    /// stuck armed forever without spending the weapon's cooldown.
    private func spawnTransformerPole() -> SKNode {
        let pole = SKSpriteNode(texture: WeaponKind.transformer.authoredTexture, size: CGSize(width: 60, height: 108))
        pole.name = "transformerPole"
        pole.position = transformerPolePosition
        pole.zPosition = 34
        world.addChild(pole)
        if settings.reducedMotion {
            pole.setScale(1)
        } else {
            pole.setScale(0.2)
            pole.run(.sequence([
                .scale(to: 1.12, duration: 0.14),
                .scale(to: 1, duration: 0.10)
            ]))
            pole.run(.repeatForever(.sequence([
                .fadeAlpha(to: 0.55, duration: 0.35),
                .fadeAlpha(to: 1, duration: 0.35)
            ])), withKey: "poleGlow")
        }
        pole.run(.sequence([
            .wait(forDuration: 6),
            .run { [weak self, weak pole] in
                guard let self, let pole else { return }
                self.cancelTransformerPoleIfStillArmed(pole)
            }
        ]))
        return pole
    }

    private func cancelTransformerPoleIfStillArmed(_ pole: SKNode) {
        guard armedWeapon == .transformer, aimPreviewNode === pole else { return }
        cancelAim()
        notifyDelegate()
    }

    private func weaponReadySpot(for kind: WeaponKind) -> CGPoint {
        switch kind {
        case .grenade:
            // Close to the diner — this is a hand-thrown weapon, it should visibly come from
            // the player's position at the window, not materialize at mid-field.
            return CGPoint(x: houseFrame.midX + houseFrame.width * 0.1, y: groundY + houseFrame.height * 0.3)
        default:
            return CGPoint(x: size.width * 0.5, y: groundY + 40)
        }
    }

    /// The weapon-prop sprite a `dragRelease` weapon presents at its ready spot when armed —
    /// physics-less until `commitFire` hands it to that weapon's fire function.
    private func makeDragReadyNode(for kind: WeaponKind) -> SKSpriteNode? {
        switch kind {
        case .bowlingBall:
            let ball = SKSpriteNode(texture: EquipmentArt.bowlingBall.texture)
            ball.size = EquipmentArt.bowlingBall.fittedSize(inside: CGSize(width: 67, height: 67))
            ball.name = WeaponKind.bowlingBall.rawValue
            ball.position = weaponReadySpot(for: kind)
            ball.zPosition = 30
            return ball
        case .grenade:
            let grenade = SKSpriteNode(texture: WeaponKind.grenade.authoredTexture, size: CGSize(width: 44, height: 58))
            grenade.name = WeaponKind.grenade.rawValue
            grenade.position = weaponReadySpot(for: kind)
            grenade.zPosition = 30
            return grenade
        case .propaneTank:
            let tank = SKSpriteNode(texture: WeaponKind.propaneTank.authoredTexture, size: CGSize(width: 86, height: 58))
            tank.name = WeaponKind.propaneTank.rawValue
            tank.position = weaponReadySpot(for: kind)
            tank.zPosition = 30
            return tank
        case .wreckingBall:
            let ball = SKSpriteNode(texture: WeaponKind.wreckingBall.authoredTexture, size: CGSize(width: 118, height: 118))
            ball.name = WeaponKind.wreckingBall.rawValue
            ball.position = CGPoint(x: wreckingBallPivotPosition.x, y: wreckingBallPivotPosition.y - wreckingBallArmLength)
            ball.zPosition = 30
            return ball
        default:
            return nil
        }
    }

    private func updateAimPreview(weapon: WeaponKind, location: CGPoint) {
        switch aimGesture(for: weapon) {
        case .tap, .tapOnNode:
            break
        case .dragRelease:
            if weapon == .deliveryTruck {
                updateDirectionalPreview(from: aimOrigin ?? location, to: location, color: .yellow)
            } else {
                aimPreviewNode?.position = CGPoint(
                    x: min(size.width - 30, max(30, location.x)),
                    y: min(size.height - 30, max(groundY + 20, location.y))
                )
            }
        case .dragAimReleaseLine:
            updateDirectionalPreview(from: defenderMuzzle, to: location, color: SKColor(red: 1, green: 0.82, blue: 0.28, alpha: 0.7))
        case .paintPath:
            updatePaintPathPreview(weapon: weapon)
        case .pendulumDragRelease:
            // Cosmetic-only clamp while dragging — the ball has no physics body yet (added fresh
            // in swingWreckingBall at release), so nothing here fights a physics constraint.
            let pivot = wreckingBallPivotPosition
            let dx = location.x - pivot.x
            let dy = location.y - pivot.y
            let distance = max(1, hypot(dx, dy))
            let clamped = min(wreckingBallArmLength, distance)
            let angle = atan2(dy, dx)
            aimPreviewNode?.position = CGPoint(x: pivot.x + cos(angle) * clamped, y: pivot.y + sin(angle) * clamped)
        }
    }

    /// Live polyline reading back the zone/path the player is painting, tinted per-weapon.
    private func updatePaintPathPreview(weapon: WeaponKind) {
        aimPreviewNode?.removeFromParent()
        guard aimPathPoints.count > 1 else { return }
        let path = CGMutablePath()
        path.move(to: aimPathPoints[0])
        for point in aimPathPoints.dropFirst() { path.addLine(to: point) }
        let line = SKShapeNode(path: path)
        line.strokeColor = weapon == .greaseFire
            ? SKColor(red: 1, green: 0.55, blue: 0.12, alpha: 0.75)
            : SKColor(red: 1, green: 0.82, blue: 0.30, alpha: 0.7)
        line.lineWidth = 6
        line.glowWidth = settings.reducedMotion ? 0 : 4
        line.zPosition = 133
        world.addChild(line)
        aimPreviewNode = line
    }

    /// Live drag-direction indicator for gestures with no on-screen prop to drag (Delivery Truck,
    /// Sniper's aim line).
    private func updateDirectionalPreview(from origin: CGPoint, to location: CGPoint, color: SKColor) {
        aimPreviewNode?.removeFromParent()
        let path = CGMutablePath()
        path.move(to: origin)
        path.addLine(to: location)
        let line = SKShapeNode(path: path)
        line.strokeColor = color
        line.lineWidth = 3
        line.glowWidth = settings.reducedMotion ? 0 : 3
        line.zPosition = 133
        world.addChild(line)
        aimPreviewNode = line
    }

    private func detonateIfHit(at location: CGPoint) -> Bool {
        for node in nodes(at: location) {
            var candidate: SKNode? = node
            while let current = candidate {
                let key = ObjectIdentifier(current)
                if let detonatable = detonatables[key] {
                    detonatables.removeValue(forKey: key)
                    detonatable.detonate()
                    return true
                }
                candidate = current.parent
            }
        }
        return false
    }

    /// Weapons whose fire function takes ownership of the preview node, turning it into the live
    /// projectile — every other weapon's "preview" is purely cosmetic (a tracer/paint line) and
    /// must be discarded here, or it would linger in the scene after the shot resolves.
    private static let weaponsThatKeepPreview: Set<WeaponKind> = [.bowlingBall, .grenade, .propaneTank, .wreckingBall]

    private func commitFire(_ kind: WeaponKind, aim: WeaponAim) {
        let preview = releaseAimPreview()
        if !Self.weaponsThatKeepPreview.contains(kind) { preview?.removeFromParent() }
        let weaponLevel = progress.upgradeLevel(kind)
        weaponCooldowns[kind] = level.isSandbox ? 0 : GameRules.cooldown(base: kind.cooldown, rapidGearLevel: rapidGearLevel + weaponLevel)
        SoundManager.shared.playWeapon(kind)
        if kind == .shotgun || kind == .sniper { dinerNode?.fireDefender() }
        switch kind {
        case .bowlingBall:
            if let flick = aim.resolvedFlick { launchBowlingBall(preview: preview, velocity: flick.velocity) }
        case .shotgun: fireScatterblast(toward: aim.resolvedPoint ?? CGPoint(x: size.width / 2, y: groundY + 110))
        case .airstrike: launchAirstrike(along: aim.resolvedPath ?? [CGPoint(x: size.width / 2, y: groundY + 54)])
        case .anvil: dropAnvils(at: aim.resolvedPoint ?? CGPoint(x: size.width / 2, y: 0))
        case .grenade:
            if let flick = aim.resolvedFlick { throwGrenade(preview: preview, velocity: flick.velocity) }
        case .propaneTank:
            if let flick = aim.resolvedFlick { launchPropaneTank(preview: preview, velocity: flick.velocity) }
        case .wreckingBall:
            if let flick = aim.resolvedFlick { swingWreckingBall(preview: preview, velocity: flick.velocity) }
        case .sniper:
            if let line = aim.resolvedLine { fireSniper(through: line.through) }
        case .greaseFire: igniteGreaseFire(along: aim.resolvedPath ?? [CGPoint(x: size.width / 2, y: groundY + 20)])
        case .transformer: chainLightning()
        case .deliveryTruck:
            if let flick = aim.resolvedFlick { launchDeliveryTruck(from: flick.origin, velocity: flick.velocity) }
        case .meteor: launchMeteor(target: aim.resolvedPoint ?? CGPoint(x: size.width / 2, y: groundY + 25))
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
            // Frozen-solid zombies shatter for much higher weapon-contact damage (Flash Freezer),
            // and bypass the usual "survives its first ordinary hit" floor — that's the whole
            // point of brittleness — while a normal zombie's first hit is unaffected.
            if zombie.damageAt(contact.contactPoint, amount: baseDamage * zombie.kind.weaponDamageMultiplier * zombie.frozenImpactDamageMultiplier, canOverkill: zombie.isFrozenSolid) {
                defeat(zombie, reason: .weapon)
            } else {
                SoundManager.shared.playZombieVoice(for: zombie.kind, moment: .hurt, pan: audioPan(for: zombie))
            }
            return
        }

        if let zombie = zombieBody(in: bodies), bodies.contains(where: { $0.categoryBitMask == PhysicsCategory.trap }) {
            playCombatVFX(.zombieSplatter, at: contact.contactPoint, size: 76, direction: zombie.approachesFromLeft ? -1 : 1)
            let baseDamage: CGFloat = zombie.kind == .armored ? 0.7 : 1.5
            if zombie.damage(baseDamage * zombie.kind.trapDamageMultiplier) {
                defeat(zombie, reason: .trap)
            } else {
                SoundManager.shared.playZombieVoice(for: zombie.kind, moment: .hurt, pan: audioPan(for: zombie))
            }
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

    private func resolveImpact(on zombie: ZombieNode, damage rawDamage: CGFloat) {
        // Frozen-solid zombies shatter for much higher ground-impact damage (Flash Freezer), and
        // bypass the usual "survives its first ordinary hit" floor — that's the whole point of
        // brittleness — while a normal zombie's first hit is unaffected.
        let damage = rawDamage * zombie.frozenImpactDamageMultiplier
        SoundManager.shared.play(.impact)
        zombie.playImpact(reducedMotion: settings.reducedMotion)
        let impactPoint = CGPoint(x: zombie.position.x, y: groundY + 8)
        playCombatVFX(.pavementImpact, at: impactPoint, size: min(210, 120 + damage * 36), direction: zombie.physicsBody?.velocity.dx.sign == .minus ? -1 : 1)
        if zombie.damage(damage, canOverkill: zombie.isFrozenSolid) {
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
            healthMultiplier: (difficulty?.healthMultiplier ?? 1) * settings.difficulty.enemyHealth,
            dismembermentEnabled: settings.goreEnabled
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
        let radius: CGFloat = 170
        let nearby = activeZombies.filter {
            !$0.isDefeated && hypot($0.position.x - point.x, $0.position.y - point.y) < radius
        }
        for zombie in nearby {
            if zombie.damage(1.6) { defeat(zombie, reason: .explosion) }
            else {
                zombie.launch(with: radialImpulse(from: point, to: zombie.position, radius: radius, maxImpulse: 380, minImpulse: 140))
            }
        }
        playCombatVFX(.explosion, at: point, size: 270, direction: 1)
        SoundManager.shared.play(.explosion)
        SoundManager.shared.duckMusic(strength: 0.48, duration: 0.42)
        shakeCamera(intensity: 1.2)
    }

    /// `preview` is the ready sprite the player dragged (see `makeDragReadyNode`); falls back to
    /// spawning fresh only if a shot somehow arrives with no preview (defensive, shouldn't happen).
    private func launchBowlingBall(preview: SKNode?, velocity: CGVector) {
        let ball = (preview as? SKSpriteNode) ?? {
            let fallback = SKSpriteNode(texture: EquipmentArt.bowlingBall.texture)
            fallback.size = EquipmentArt.bowlingBall.fittedSize(inside: CGSize(width: 67, height: 67))
            fallback.position = CGPoint(x: size.width * 0.5, y: groundY + 34)
            world.addChild(fallback)
            return fallback
        }()
        ball.name = WeaponKind.bowlingBall.rawValue
        ball.zPosition = 30
        // Matches the ~82% shrink, then a further ~55% shrink, applied to ZombieKind.size — a
        // full-size ball rolling through the now-smaller zombies would be relatively chunkier
        // than intended, hitting more of each body than the original size ratio called for.
        ball.physicsBody = SKPhysicsBody(circleOfRadius: 12)
        ball.physicsBody?.mass = 3.5
        ball.physicsBody?.restitution = 0.32
        ball.physicsBody?.friction = 0.7
        ball.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        ball.physicsBody?.collisionBitMask = PhysicsCategory.zombie | PhysicsCategory.ground
        ball.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        ball.physicsBody?.velocity = velocity
        SoundManager.shared.play(.bowlingRoll)
        if !settings.reducedMotion {
            ball.run(.repeatForever(.rotate(byAngle: velocity.dx < 0 ? .pi * 2 : -.pi * 2, duration: 0.38)), withKey: "roll")
        }
        ball.run(.sequence([.wait(forDuration: 5), .removeFromParent()]))
    }

    /// Half-angle of the scatterblast cone, in radians (~22°).
    private let scatterblastHalfAngle: CGFloat = 0.38
    private var scatterblastRange: CGFloat { size.width * 0.62 }

    /// Knockback follows the real direction to each zombie (not a flattened left/right), and both
    /// damage and impulse taper with distance from the muzzle: a point-blank hit sends a zombie
    /// flying, a zombie at the edge of the cone's range barely staggers.
    private func fireScatterblast(toward aimPoint: CGPoint) {
        let origin = defenderMuzzle
        let aimAngle = atan2(aimPoint.y - origin.y, aimPoint.x - origin.x)
        let range = scatterblastRange
        let zombies = activeZombies.filter { !$0.isDefeated }
        for zombie in zombies {
            let dx = zombie.position.x - origin.x
            let dy = zombie.position.y - origin.y
            let distance = max(1, hypot(dx, dy))
            let angleToZombie = atan2(dy, dx)
            guard abs(shortestAngleDelta(from: aimAngle, to: angleToZombie)) <= scatterblastHalfAngle else { continue }

            let proximity = max(0, 1 - distance / range)
            let damage = (1.0 + proximity * 3.4) * zombie.kind.weaponDamageMultiplier
            let impulse = radialImpulse(from: origin, to: zombie.position, radius: range, maxImpulse: 760, minImpulse: 210)
            zombie.launch(with: impulse)
            if zombie.damage(damage) { defeat(zombie, reason: .weapon) }
        }
        fireBuckshotSpread(from: origin, angle: aimAngle)
        radialFlash(at: origin, color: .yellow)
        playDirectionalDebris(at: origin, color: .orange, direction: cos(aimAngle) < 0 ? -1 : 1, count: 10)
        shakeCamera(intensity: 0.8)
    }

    private func shortestAngleDelta(from a: CGFloat, to b: CGFloat) -> CGFloat {
        var delta = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return delta
    }

    /// Visible pellet fan reading as a shotgun blast out of the defender's window, fanned around
    /// the aimed direction so the shot itself is legible instead of looking like an unexplained
    /// shockwave.
    private func fireBuckshotSpread(from origin: CGPoint, angle: CGFloat) {
        guard settings.flashesEnabled else { return }
        let pelletCount = 9
        let range = scatterblastRange
        for index in 0..<pelletCount {
            let spread = (CGFloat(index) / CGFloat(pelletCount - 1)) - 0.5
            let pelletAngle = angle + spread * scatterblastHalfAngle * 2
            let distance = range * CGFloat.random(in: 0.72...1)
            let end = CGPoint(x: origin.x + cos(pelletAngle) * distance, y: origin.y + sin(pelletAngle) * distance)
            let path = CGMutablePath()
            path.move(to: origin)
            path.addLine(to: end)
            let pellet = SKShapeNode(path: path)
            pellet.strokeColor = SKColor(red: 1, green: 0.86, blue: 0.42, alpha: 0.82)
            pellet.lineWidth = settings.reducedMotion ? 1.5 : 2.5
            pellet.glowWidth = settings.reducedMotion ? 0 : 3
            pellet.zPosition = 133
            world.addChild(pellet)
            pellet.run(.sequence([
                .wait(forDuration: Double(index) * 0.006),
                .fadeOut(withDuration: 0.10),
                .removeFromParent()
            ]))
        }
    }

    /// Impact count/spacing scale with the painted swipe's length (2–5 impacts) instead of the
    /// old fixed 3-point pattern.
    private func launchAirstrike(along path: [CGPoint]) {
        let xs = path.map(\.x)
        let minX = xs.min() ?? size.width * 0.18
        let maxX = xs.max() ?? size.width * 0.82
        let span = maxX - minX
        let impactCount = span < 40 ? 2 : min(5, max(2, Int(span / 90) + 2))
        let targets: [CGFloat] = (0..<impactCount).map { index in
            impactCount == 1 ? (minX + maxX) / 2 : minX + span * CGFloat(index) / CGFloat(impactCount - 1)
        }

        let beacon = SKSpriteNode(texture: EquipmentArt.airstrikeBeacon.actionFrames[0], size: CGSize(width: 108, height: 108))
        beacon.position = CGPoint(x: (minX + maxX) / 2, y: groundY + 54)
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
        for (index, x) in targets.enumerated() {
            world.run(.sequence([
                .wait(forDuration: Double(index) * 0.24),
                .run { [weak self] in self?.airstrikeImpact(x: x) }
            ]))
        }
    }

    /// A single tap-targeted anvil, replacing the old auto-drop-on-up-to-3-nearest-zombies — a
    /// deliberate trade of total coverage for precision, since the player now aims it themselves.
    private func dropAnvils(at target: CGPoint) {
        let anvil = SKSpriteNode(texture: WeaponKind.anvil.authoredTexture, size: CGSize(width: 82, height: 68))
        anvil.name = WeaponKind.anvil.rawValue
        anvil.position = CGPoint(x: target.x, y: size.height + 45)
        anvil.zPosition = 40
        anvil.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 58, height: 42))
        anvil.physicsBody?.mass = 5
        anvil.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        anvil.physicsBody?.collisionBitMask = PhysicsCategory.zombie | PhysicsCategory.ground
        anvil.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        world.addChild(anvil)
        anvil.run(.sequence([.wait(forDuration: 4), .removeFromParent()]))
    }

    /// Drag-thrown, physics-bounced grenade with a fixed fuse — explodes wherever it's landed
    /// ~2.2s after release, via the same point-based `throwExplosive` propane/meteor use.
    private func throwGrenade(preview: SKNode?, velocity: CGVector) {
        let grenade = (preview as? SKSpriteNode) ?? {
            let fallback = SKSpriteNode(texture: WeaponKind.grenade.authoredTexture, size: CGSize(width: 44, height: 58))
            fallback.position = weaponReadySpot(for: .grenade)
            world.addChild(fallback)
            return fallback
        }()
        grenade.name = WeaponKind.grenade.rawValue
        grenade.zPosition = 30
        grenade.physicsBody = SKPhysicsBody(circleOfRadius: 20)
        grenade.physicsBody?.mass = 1.4
        grenade.physicsBody?.restitution = 0.55
        grenade.physicsBody?.friction = 0.6
        grenade.physicsBody?.linearDamping = 0.2
        grenade.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        grenade.physicsBody?.collisionBitMask = PhysicsCategory.zombie | PhysicsCategory.ground | PhysicsCategory.boundary
        // No contact-test damage — this weapon deals damage only through its timed explosion,
        // not by bumping into zombies as it bounces past them.
        grenade.physicsBody?.contactTestBitMask = PhysicsCategory.none
        grenade.physicsBody?.velocity = velocity
        grenade.physicsBody?.angularVelocity = max(-8, min(8, -velocity.dx / 140))
        attachFuseSpark(to: grenade)
        grenade.run(.sequence([
            .wait(forDuration: 2.2),
            .run { [weak self, weak grenade] in
                guard let self, let grenade else { return }
                self.throwExplosive(at: grenade.position, radius: 150, damage: 4.5)
                grenade.removeFromParent()
            }
        ]))
    }

    private func attachFuseSpark(to grenade: SKNode) {
        guard !settings.reducedMotion else { return }
        let spark = SKShapeNode(circleOfRadius: 3)
        spark.fillColor = .yellow
        spark.strokeColor = .orange
        spark.glowWidth = 3
        spark.position = CGPoint(x: 0, y: 18)
        spark.zPosition = 1
        grenade.addChild(spark)
        spark.run(.repeatForever(.sequence([
            .scale(to: 1.6, duration: 0.12),
            .scale(to: 0.8, duration: 0.12)
        ])))
    }

    private func launchPropaneTank(preview: SKNode?, velocity: CGVector) {
        let tank = (preview as? SKSpriteNode) ?? {
            let fallback = SKSpriteNode(texture: WeaponKind.propaneTank.authoredTexture, size: CGSize(width: 86, height: 58))
            fallback.position = CGPoint(x: size.width * 0.5, y: groundY + 34)
            world.addChild(fallback)
            return fallback
        }()
        tank.name = WeaponKind.propaneTank.rawValue
        tank.zPosition = 30
        tank.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 82, height: 34))
        tank.physicsBody?.mass = 3
        tank.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        tank.physicsBody?.collisionBitMask = PhysicsCategory.zombie | PhysicsCategory.ground
        tank.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        tank.physicsBody?.velocity = velocity

        var hasDetonated = false
        let key = ObjectIdentifier(tank)
        let detonate: () -> Void = { [weak self, weak tank] in
            guard let self, let tank, !hasDetonated else { return }
            hasDetonated = true
            self.throwExplosive(at: tank.position, radius: 175, damage: 5.5)
            tank.removeFromParent()
        }
        detonatables[key] = Detonatable(node: tank, detonate: detonate)
        world.addChild(tank)
        tank.run(.sequence([.wait(forDuration: 2.2), .run { [weak self] in
            self?.detonatables.removeValue(forKey: key)
            detonate()
        }]))
    }

    /// A genuinely radial, distance-proportional knockback — replaces flat left/right pushes so a
    /// point-blank hit sends a zombie flying while an edge-of-blast survivor barely staggers, and
    /// the resulting trajectory (real direction, real magnitude) can chain into other zombies or
    /// weapon props via ordinary physics collision, instead of every explosion looking the same.
    private func radialImpulse(from origin: CGPoint, to position: CGPoint, radius: CGFloat, maxImpulse: CGFloat, minImpulse: CGFloat) -> CGVector {
        let dx = position.x - origin.x
        // Floors the vertical component so a same-height hit still reads as a launch upward
        // rather than a shove straight along the ground.
        let dy = max(60, position.y - origin.y)
        let distance = max(1, hypot(dx, position.y - origin.y))
        let falloff = max(0, 1 - distance / radius)
        let magnitude = minImpulse + (maxImpulse - minImpulse) * falloff
        let angle = atan2(dy, dx)
        return CGVector(dx: cos(angle) * magnitude, dy: sin(angle) * magnitude)
    }

    private func throwExplosive(at point: CGPoint, radius: CGFloat, damage: CGFloat, maxImpulse: CGFloat = 460, minImpulse: CGFloat = 140) {
        for zombie in activeZombies where !zombie.isDefeated && hypot(zombie.position.x - point.x, zombie.position.y - point.y) < radius {
            if zombie.damage(damage * zombie.kind.weaponDamageMultiplier, canOverkill: true) {
                defeat(zombie, reason: .explosion)
            } else {
                zombie.launch(with: radialImpulse(from: point, to: zombie.position, radius: radius, maxImpulse: maxImpulse, minImpulse: minImpulse))
            }
        }
        playCombatVFX(.explosion, at: point, size: radius * 1.7, direction: 1)
        SoundManager.shared.play(.explosion)
        SoundManager.shared.duckMusic(strength: 0.48, duration: 0.42)
    }

    /// A real `SKPhysicsJointPin` pendulum instead of the old scripted (non-physics) sweep. The
    /// joint is built here, fresh, using wherever the ball was dragged to at release — not up
    /// front when armed — so its rest arm always matches the ball's actual release position
    /// instead of risking a snap back to a stale offset computed before the drag.
    private func swingWreckingBall(preview: SKNode?, velocity: CGVector) {
        let ball = (preview as? SKSpriteNode) ?? {
            let fallback = SKSpriteNode(texture: WeaponKind.wreckingBall.authoredTexture, size: CGSize(width: 118, height: 118))
            fallback.position = CGPoint(x: wreckingBallPivotPosition.x, y: wreckingBallPivotPosition.y - wreckingBallArmLength)
            world.addChild(fallback)
            return fallback
        }()
        ball.name = WeaponKind.wreckingBall.rawValue
        ball.zPosition = 30

        let anchor = SKNode()
        anchor.position = wreckingBallPivotPosition
        anchor.physicsBody = SKPhysicsBody(circleOfRadius: 4)
        anchor.physicsBody?.isDynamic = false
        anchor.physicsBody?.categoryBitMask = PhysicsCategory.none
        anchor.physicsBody?.collisionBitMask = PhysicsCategory.none
        anchor.physicsBody?.contactTestBitMask = PhysicsCategory.none
        world.addChild(anchor)

        ball.physicsBody = SKPhysicsBody(circleOfRadius: 50)
        ball.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        ball.physicsBody?.collisionBitMask = PhysicsCategory.none
        ball.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        ball.physicsBody?.mass = 4
        ball.physicsBody?.linearDamping = 0.25
        ball.physicsBody?.angularDamping = 0.4
        ball.physicsBody?.velocity = velocity

        let joint = SKPhysicsJointPin.joint(withBodyA: anchor.physicsBody!, bodyB: ball.physicsBody!, anchor: anchor.position)
        physicsWorld.add(joint)

        world.run(.sequence([
            .wait(forDuration: 6),
            .run { [weak self, weak anchor, weak ball] in
                guard let self else { return }
                self.physicsWorld.remove(joint)
                anchor?.removeFromParent()
                ball?.removeFromParent()
            }
        ]))
    }

    /// Drag-aimed piercing shot: everything within a body-width of the aimed line gets hit, full
    /// damage on the first zombie in the line with falloff per zombie behind it, capped at 4 —
    /// turns the old single-target near-guaranteed kill into a lane-clear tool.
    private func fireSniper(through releasePoint: CGPoint) {
        let origin = defenderMuzzle
        let raw = CGVector(dx: releasePoint.x - origin.x, dy: releasePoint.y - origin.y)
        let rawLength = max(1, hypot(raw.dx, raw.dy))
        let unit = CGVector(dx: raw.dx / rawLength, dy: raw.dy / rawLength)
        let lineEnd = CGPoint(x: origin.x + unit.dx * size.width * 1.6, y: origin.y + unit.dy * size.width * 1.6)
        // Matches the ~82% shrink, then a further ~55% shrink, applied to ZombieKind.size, so the
        // pierce band still tracks roughly one body-width instead of becoming relatively wider
        // than the zombies it's testing against.
        let tolerance: CGFloat = 12

        let pierced = activeZombies.filter { !$0.isDefeated }.compactMap { zombie -> (zombie: ZombieNode, along: CGFloat)? in
            let toZombie = CGVector(dx: zombie.position.x - origin.x, dy: zombie.position.y - origin.y)
            let along = toZombie.dx * unit.dx + toZombie.dy * unit.dy
            guard along > 0 else { return nil }
            let perpendicular = abs(toZombie.dx * unit.dy - toZombie.dy * unit.dx)
            guard perpendicular <= tolerance else { return nil }
            return (zombie, along)
        }.sorted { $0.along < $1.along }.prefix(4)

        let tracerPath = CGMutablePath()
        tracerPath.move(to: origin)
        tracerPath.addLine(to: lineEnd)
        let tracer = SKShapeNode(path: tracerPath)
        tracer.strokeColor = SKColor(red: 1, green: 0.82, blue: 0.28, alpha: 0.92)
        tracer.lineWidth = settings.reducedMotion ? 2 : 4
        tracer.glowWidth = settings.reducedMotion ? 0 : 5
        tracer.zPosition = 134
        world.addChild(tracer)
        tracer.run(.sequence([.wait(forDuration: 0.04), .fadeOut(withDuration: 0.10), .removeFromParent()]))

        for (index, entry) in pierced.enumerated() {
            let zombie = entry.zombie
            let falloff = pow(0.5, CGFloat(index))
            let hitDamage = (zombie.kind.isBoss ? zombie.kind.hitPoints * 0.14 : zombie.kind.hitPoints * 1.2) * falloff
            if zombie.damage(hitDamage) { defeat(zombie, reason: .weapon) }
            playDirectionalDebris(at: zombie.position, color: .yellow, direction: zombie.approachesFromLeft ? -1 : 1, count: max(2, 6 - index))
        }
        if !pierced.isEmpty { hitStop(duration: 0.14) }
    }

    /// The painted zone's x-range replaces the old fixed ~420px-wide band at screen center,
    /// clamped so a barely-there swipe and a full-screen swipe both stay reasonable.
    private func igniteGreaseFire(along path: [CGPoint]) {
        let xs = path.map(\.x)
        let minX = xs.min() ?? size.width / 2
        let maxX = xs.max() ?? size.width / 2
        let width = min(320, max(140, maxX - minX))
        let halfWidth = width / 2
        let center = CGPoint(x: (minX + maxX) / 2, y: groundY + 20)
        for tick in 0..<5 {
            world.run(.sequence([.wait(forDuration: Double(tick) * 0.5), .run { [weak self] in
                guard let self else { return }
                for zombie in self.activeZombies where !zombie.isDefeated && abs(zombie.position.x - center.x) < halfWidth {
                    if zombie.damage(0.85 * zombie.kind.weaponDamageMultiplier) { self.defeat(zombie, reason: .weapon) }
                }
                self.playCombatVFX(.explosion, at: center, size: halfWidth * 2.1, direction: 1, tint: .orange)
            }]))
        }
    }

    /// Chains outward from the tapped pole, nearest zombie first — previously chained through
    /// the first 6 zombies in spawn order, regardless of where they actually were.
    private func chainLightning() {
        let origin = transformerPolePosition
        let ordered = activeZombies
            .filter { !$0.isDefeated }
            .sorted { hypot($0.position.x - origin.x, $0.position.y - origin.y) < hypot($1.position.x - origin.x, $1.position.y - origin.y) }
            .prefix(6)
        for (index, zombie) in ordered.enumerated() {
            world.run(.sequence([.wait(forDuration: Double(index) * 0.09), .run { [weak self, weak zombie] in
                guard let self, let zombie else { return }
                if zombie.damage(2.4 * zombie.kind.weaponDamageMultiplier) { self.defeat(zombie, reason: .weapon) }
                self.radialFlash(at: zombie.position, color: .cyan)
            }]))
        }
        radialFlash(at: origin, color: .cyan)
    }

    /// The truck starts off-screen, so its swipe has no on-screen prop to drag (see
    /// `spawnAimPreview`) — only where the swipe started (which edge to launch from) and its
    /// direction (a little vertical drift) matter.
    private func launchDeliveryTruck(from origin: CGPoint, velocity: CGVector) {
        let fromLeft = origin.x < size.width / 2
        let truck = SKSpriteNode(texture: WeaponKind.deliveryTruck.authoredTexture, size: CGSize(width: 190, height: 104))
        truck.name = WeaponKind.deliveryTruck.rawValue
        truck.position = CGPoint(x: fromLeft ? -120 : size.width + 120, y: groundY + 48)
        truck.xScale = fromLeft ? 1 : -1
        truck.zPosition = 35
        truck.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 175, height: 80))
        truck.physicsBody?.affectedByGravity = false
        truck.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        truck.physicsBody?.collisionBitMask = PhysicsCategory.none
        truck.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        let travelDistance = size.width + 240
        let dx: CGFloat = (fromLeft ? 1 : -1) * travelDistance / 1.05
        let dy = max(-70, min(70, velocity.dy * 0.12))
        truck.physicsBody?.velocity = CGVector(dx: dx, dy: dy)
        world.addChild(truck)
        truck.run(.sequence([.wait(forDuration: 1.3), .removeFromParent()]))
    }

    private func launchMeteor(target rawTarget: CGPoint) {
        let target = CGPoint(x: rawTarget.x, y: groundY + 25)
        spawnMeteorWarning(at: target)
        world.run(.sequence([
            .wait(forDuration: 0.6),
            .run { [weak self] in self?.dropMeteor(at: target) }
        ]))
    }

    private func dropMeteor(at target: CGPoint) {
        let meteor = SKSpriteNode(texture: WeaponKind.anvil.authoredTexture, size: CGSize(width: 110, height: 92))
        meteor.color = .orange; meteor.colorBlendFactor = 0.55
        meteor.position = CGPoint(x: target.x + 160, y: size.height + 80)
        meteor.zPosition = 140
        world.addChild(meteor)
        meteor.run(.sequence([
            .move(to: target, duration: 0.48),
            .run { [weak self] in self?.resolveMeteorImpact(at: target) },
            .removeFromParent()
        ]))
    }

    /// Ground reticle telegraphing where the meteor will land before it drops, so the tap-aimed
    /// target reads clearly instead of the impact appearing without warning.
    private func spawnMeteorWarning(at target: CGPoint) {
        let reticle = SKShapeNode(ellipseOf: CGSize(width: 130, height: 40))
        reticle.strokeColor = SKColor(red: 1, green: 0.42, blue: 0.12, alpha: 0.85)
        reticle.lineWidth = 3
        reticle.glowWidth = settings.reducedMotion ? 0 : 4
        reticle.fillColor = SKColor(red: 1, green: 0.30, blue: 0.05, alpha: 0.16)
        reticle.position = CGPoint(x: target.x, y: groundY + 6)
        reticle.zPosition = 6
        world.addChild(reticle)
        reticle.run(.sequence([
            .repeat(.sequence([.fadeAlpha(to: 0.35, duration: 0.16), .fadeAlpha(to: 1, duration: 0.16)]), count: settings.reducedMotion ? 1 : 2),
            .wait(forDuration: 0.08),
            .removeFromParent()
        ]))
    }

    private func resolveMeteorImpact(at target: CGPoint) {
        // Bigger radial impulse than a grenade/propane blast, matching the "enormous physics
        // impulse" this weapon is meant for.
        throwExplosive(at: target, radius: 260, damage: 10, maxImpulse: 640, minImpulse: 220)
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
        for zombie in activeZombies where !zombie.isDefeated && !zombie.isGrabbed && !zombie.isThrown {
            zombie.freezeSolid(for: 7, reducedMotion: settings.reducedMotion)
        }
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
        // touchesMoved/Ended don't check `gameOver` (only touchesBegan does), so a weapon that
        // was mid-drag the instant the level ended could otherwise still fire after the result
        // modal appears.
        cancelArmedWeapon()
        if won { dinerNode?.celebrateDefender() }
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
            trapCooldowns: trapCooldowns,
            armedWeapon: armedWeapon
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

        // Must stay well outside the off-screen defeat thresholds below (±220 x / -170 y) plus the
        // largest zombie's half-width, or a hard-flicked zombie collides with this wall before ever
        // crossing the threshold — leaving it stuck bouncing off-camera instead of being defeated.
        let boundaries = SKNode()
        boundaries.physicsBody = SKPhysicsBody(edgeLoopFrom: CGRect(x: -320, y: -320, width: size.width + 640, height: size.height + 640))
        boundaries.physicsBody?.categoryBitMask = PhysicsCategory.boundary
        boundaries.physicsBody?.collisionBitMask = PhysicsCategory.zombie
        world.addChild(boundaries)
    }

    private func buildHouse() {
        let diner = DinerNode(frame: houseFrame, reducedMotion: settings.reducedMotion, highContrast: settings.highContrast)
        diner.configureDefender(weaponTier: progress.upgradeLevel(.shotgun))
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
