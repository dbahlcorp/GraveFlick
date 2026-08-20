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
    let maximumHealth: Int
    let specialCharge: Double
    let weaponCooldowns: [WeaponKind: TimeInterval]
    let trapCooldowns: [TrapKind: TimeInterval]
    let armedWeapon: WeaponKind?
    /// Non-empty only while a perk offer is awaiting the player's pick (see
    /// PerkSystem.offerChoices/choose) — SwiftUI shows the picker whenever this isn't empty.
    let perkChoices: [Perk]
}

@MainActor
protocol GameSceneDelegate: AnyObject {
    func gameScene(_ scene: GameScene, didUpdate snapshot: GameHUDSnapshot)
    func gameScene(_ scene: GameScene, didFinish result: LevelResult)
}

final class GameScene: SKScene, SKPhysicsContactDelegate {
    weak var gameDelegate: GameSceneDelegate?

    let level: GameLevel
    let settings: GameSettings
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

    let world = SKNode()
    private var dinerNode: DinerNode?
    private var selectedZombies: [ObjectIdentifier: ZombieNode] = [:]
    private var touchSamples: [ObjectIdentifier: [(point: CGPoint, time: TimeInterval)]] = [:]
    private var dualTouchBaseline: (distance: CGFloat, angle: CGFloat)?

    private var lastUpdateTime: TimeInterval = 0
    var elapsedTime: TimeInterval = 0
    private var movementAudioRemaining: TimeInterval = 0.7
    var health: Int
    /// Wave timing/progression and the WaveModifier runtime.
    private let spawnDirector = SpawnDirector()
    var wave: Int { spawnDirector.wave }
    var spawnedInWave: Int {
        get { spawnDirector.spawnedInWave }
        set { spawnDirector.spawnedInWave = newValue }
    }
    var currentWaveTarget: Int { spawnDirector.currentWaveTarget }
    /// Kill scoring, combo tracking, and their on-kill feedback popups.
    let comboSystem = ComboSystem()
    var specialCharge = 0.0
    /// Weapon/trap arming, aim-gesture state, cooldowns, and every fire function.
    private let weaponSystem = WeaponSystem()
    var gameOver = false
    private var didBuildWorld = false
    /// Roguelite perk state and mechanical bonuses — endless-only, in-memory for this run only
    /// (never touches ProgressStore/PlayerProgress, which is permanent cross-run progression).
    let perkSystem = PerkSystem()
    /// Skill-based feats performed this run ("how you played," not score/completion thresholds —
    /// see LevelResult.feats), folded into `finish(won:)`'s result and granted as ordinary
    /// achievements by ProgressStore.complete. Accumulates for the whole run; never cleared mid-run.
    private var achievedFeats: Set<String> = []
    /// Tracks the GRACEFUL_WAVE feat ("clear a wave without a grabbed zombie touching the
    /// ground") across whichever wave-transition path is active (SpawnDirector's
    /// updateEndlessWave or updateCampaignWave) — checked centrally in `update()` on any change
    /// to `wave` rather than duplicated in both branches. 0 is a sentinel for "not yet synced,"
    /// so the very first frame doesn't look like a completed wave.
    private var lastObservedWaveForFeats = 0
    private var playerThrewThisWave = false
    private var playerThrownZombieGroundedThisWave = false
    /// Achievement ids queued to display as the small delayed "unlocked" toast (see
    /// showFeatToast) — a run can earn several feats within the same second, and draining this
    /// one at a time keeps that from becoming another label stacked into the same instant as the
    /// combo-event banner and score popup.
    private var pendingFeatToasts: [String] = []
    private var isDrainingFeatToasts = false
    /// Global walk-speed tuning knob, layered under every other speed multiplier (difficulty,
    /// wave ramp, sandbox slider) so it scales zombies uniformly without touching their relative
    /// per-kind balance.
    private let zombieSpeedScale: CGFloat = 0.85
    var sandboxDefeats = 0
    var finishingReplayUsed = false
    private var sceneryDamage = 0
    private var goreStains: [SKNode] = []
    private var activeGoreDroplets = 0
    /// .doubleSided alternates strictly left/right/left/right rather than trusting Bool.random(),
    /// which could otherwise streak several spawns from the same side and read as a standard mission.
    private var nextDoubleSidedFromLeft = true
    /// Boss HUD, boss-kind resolution, and boss-only spawn hooks.
    private let bossDirector = BossDirector()
    var bossHUD: SKNode { bossDirector.bossHUD }

    // 9_999, not 99: with the numeric health pool a fully upgraded diner's real max (up to 160)
    // could otherwise exceed sandbox's old "effectively unlimited" value.
    var startingHealth: Int { level.isSandbox ? 9_999 : (level.modifier == .suddenDeath ? 1 : GameRules.startingHealth + progress.upgradeLevel(.reinforcedDiner) * GameRules.reinforcedDinerHealthPerLevel) }
    private var flickMultiplier: CGFloat { (1 + CGFloat(progress.upgradeLevel(.flickTraining)) * 0.10) * perkSystem.flickVelocityBonus }
    var rapidGearLevel: Int { progress.upgradeLevel(.rapidGear) }
    var groundY: CGFloat { max(70, size.height * 0.13) }
    var houseFrame: CGRect {
        let width = min(310, size.width * 0.29)
        return CGRect(x: size.width * 0.5 - width * 0.5, y: groundY, width: width, height: min(280, size.height * 0.38))
    }
    /// True while `WaveModifier.graveTimeDisabled` is this wave's active modifier.
    var isGraveTimeDisabled: Bool { spawnDirector.activeModifier == .graveTimeDisabled }

    init(level: GameLevel, progress: PlayerProgress, settings: GameSettings, size: CGSize) {
        self.level = level
        self.progress = progress
        self.settings = settings
        health = level.isSandbox ? 9_999 : (level.modifier == .suddenDeath ? 1 : GameRules.startingHealth + progress.upgradeLevel(.reinforcedDiner) * GameRules.reinforcedDinerHealthPerLevel)
        super.init(size: size)
        scaleMode = .resizeFill
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMove(to view: SKView) {
        guard !didBuildWorld else { return }
        didBuildWorld = true
        perkSystem.host = self
        comboSystem.host = self
        spawnDirector.host = self
        bossDirector.host = self
        weaponSystem.host = self
        backgroundColor = level.skyColor
        physicsWorld.gravity = CGVector(dx: 0, dy: level.modifier == .lowGravity ? -3.8 : -8.8)
        physicsWorld.contactDelegate = self
        addChild(world)
        buildEnvironment()
        bossDirector.build(sceneSize: size)
        addChild(bossDirector.bossHUD)
        SoundManager.shared.updateGameplayMix(wave: wave, healthFraction: 1)
        if level.isSandbox { spawnDirector.waveStatus = "SANDBOX" }
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
        weaponSystem.tickCooldowns(deltaTime)
        movementAudioRemaining -= deltaTime

        if level.isSandbox {
            // Sandbox spawns only through explicit player controls.
        } else if level.isEndless {
            spawnDirector.updateEndlessWave(deltaTime: deltaTime)
        } else {
            spawnDirector.updateCampaignWave(deltaTime: deltaTime)
        }

        // GRACEFUL_WAVE: works the same way regardless of which branch above actually moved
        // `wave` forward, so it doesn't need its own copy in both the endless and campaign paths.
        if wave != lastObservedWaveForFeats {
            if lastObservedWaveForFeats > 0, playerThrewThisWave, !playerThrownZombieGroundedThisWave {
                recordFeat("graceful_wave")
            }
            lastObservedWaveForFeats = wave
            playerThrewThisWave = false
            playerThrownZombieGroundedThisWave = false
        }

        let zombies = activeZombies
        let nearestThreat = zombies
            .filter { !$0.isDefeated && !$0.isGrabbed && !$0.isThrown }
            .min { abs($0.position.x - houseFrame.midX) < abs($1.position.x - houseFrame.midX) }
        dinerNode?.aimDefender(at: nearestThreat?.position)
        for zombie in zombies {
            zombie.updateWalking(deltaTime: deltaTime, reducedMotion: settings.reducedMotion)
            if zombie.isDefeated { continue }
            if level.isEndless { spawnDirector.applyVisibilityModifier(to: zombie) }
            // SKY_LAUNCH: checked every frame while airborne (not just on landing/defeat) so it's
            // caught regardless of what happens next — surviving the fall, landing, or exiting off
            // a side boundary without ever triggering a ground contact.
            if zombie.highestPoint > size.height { recordFeat("sky_launch") }
            if !zombie.isGrabbed, !zombie.isThrown, zombieHasReachedHouse(zombie) {
                zombieReachedHouse(zombie)
            } else if zombie.position.y < -170 || zombie.position.x < -220 || zombie.position.x > size.width + 220 {
                comboSystem.defeat(zombie, reason: .thrownOut)
            }
        }
        if movementAudioRemaining <= 0,
           let walker = zombies.filter({ !$0.isDefeated && !$0.isGrabbed && !$0.isThrown }).randomElement() {
            SoundManager.shared.playMovement(for: walker.kind, pan: audioPan(for: walker))
            movementAudioRemaining = max(0.42, 1.25 - Double(min(8, zombies.count)) * 0.07)
        }

        notifyDelegate()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isGameplayPaused, !gameOver else { return }
        for touch in touches {
            let key = ObjectIdentifier(touch)
            let location = touch.location(in: self)
            if weaponSystem.detonateIfHit(at: location) { continue }
            if let armedWeapon = weaponSystem.armedWeapon {
                guard weaponSystem.aimTouchKey == nil else { continue }
                weaponSystem.beginAim(weapon: armedWeapon, key: key, location: location, timestamp: touch.timestamp)
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
            if key == weaponSystem.aimTouchKey {
                weaponSystem.updateAim(location: touch.location(in: self), timestamp: touch.timestamp)
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
            if ObjectIdentifier(touch) == weaponSystem.aimTouchKey {
                weaponSystem.endAim(location: touch.location(in: self), timestamp: touch.timestamp)
            } else {
                releaseZombie(touch)
            }
        }
        if selectedZombies.count < 2 { dualTouchBaseline = nil }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if ObjectIdentifier(touch) == weaponSystem.aimTouchKey {
                weaponSystem.cancelAim()
            } else {
                releaseZombie(touch)
            }
        }
        if selectedZombies.count < 2 { dualTouchBaseline = nil }
    }

    /// Called by the SwiftUI weapon rack when the player taps a weapon icon.
    func armWeapon(_ kind: WeaponKind) { weaponSystem.armWeapon(kind) }

    /// Public entry point for cleanup callers outside the touch-handling code (pausing,
    /// backgrounding, level finish).
    func cancelArmedWeapon() { weaponSystem.cancelArmedWeapon() }

    func useTrap(_ kind: TrapKind) { weaponSystem.useTrap(kind) }

    func useSpecial() { weaponSystem.useSpecial() }

    func upgradeLevel(_ kind: WeaponKind) -> Int { progress.upgradeLevel(kind) }
    func isUnlocked(_ weapon: WeaponKind) -> Bool { progress.isUnlocked(weapon) }
    func isUnlocked(_ trap: TrapKind) -> Bool { progress.isUnlocked(trap) }
    func fireDefender() { dinerNode?.fireDefender() }

    /// Called by the SwiftUI perk picker (via GameSessionModel.choosePerk) when the player taps
    /// one of the three offered cards.
    func choosePerk(_ perk: Perk) { perkSystem.choose(perk) }

    /// Forwards to `bossDirector` — kept as a same-named GameScene member because SpawnDirectorHost
    /// (which predates BossDirector's extraction) still requires it.
    func otherBossKind(than kind: ZombieKind) -> ZombieKind { bossDirector.otherBossKind(than: kind) }

    /// `PlayerProgress.highestUnlockedLevel` advances to N+1 only once level N is actually won, so
    /// subtracting 1 recovers "levels actually beaten" — 0 for a player who's never won a campaign
    /// level. Shared by BossDirector's `resolvedBossKind`/`otherBossKind` and SpawnDirector's
    /// `rollWaveModifier` WaveModifier gate, so campaign progress means the same thing everywhere
    /// endless checks it.
    var highestCompletedCampaignLevel: Int { max(0, progress.highestUnlockedLevel - 1) }

    /// Forwards to `bossDirector` — kept as a same-named GameScene member because SpawnDirectorHost
    /// (which predates BossDirector's extraction) still requires it.
    func resolvedBossKind(forWave wave: Int) -> ZombieKind? { bossDirector.resolvedBossKind(forWave: wave) }

    func didBegin(_ contact: SKPhysicsContact) {
        guard !gameOver else { return }
        let bodies = [contact.bodyA, contact.bodyB]

        if let zombie = zombieBody(in: bodies), bodies.contains(where: { $0.categoryBitMask == PhysicsCategory.ground }), zombie.isThrown, !zombie.hasResolvedImpact {
            zombie.hasResolvedImpact = true
            // GRACEFUL_WAVE only cares about zombies the player actually grabbed and flicked, not
            // ones an explosion or another zombie knocked to the ground (see ZombieNode.wasPlayerThrown).
            if zombie.wasPlayerThrown { playerThrownZombieGroundedThisWave = true }
            let fallHeight = max(0, zombie.highestPoint - zombie.position.y)
            let heightDamage = min(2.2, fallHeight / 190)
            let impactDamage = contact.collisionImpulse / max(1, zombie.kind.defeatImpulse)
            resolveImpact(on: zombie, damage: max(heightDamage, impactDamage))
            return
        }

        if let zombie = zombieBody(in: bodies), let weaponBody = bodies.first(where: { $0.categoryBitMask == PhysicsCategory.weapon }) {
            let weaponKind = weaponBody.node?.name.flatMap(WeaponKind.init(rawValue:))
            if let weaponKind, let sound = weaponSystem.impactSound(for: weaponKind) {
                SoundManager.shared.play(sound)
            }
            playCombatVFX(.zombieSplatter, at: contact.contactPoint, size: 92, direction: zombie.approachesFromLeft ? -1 : 1)
            let baseDamage: CGFloat = zombie.kind == .brute ? 1.8 : 4
            // Frozen-solid zombies shatter for much higher weapon-contact damage (Flash Freezer),
            // and bypass the usual "survives its first ordinary hit" floor — that's the whole
            // point of brittleness — while a normal zombie's first hit is unaffected.
            if zombie.damageAt(contact.contactPoint, amount: baseDamage * zombie.kind.weaponDamageMultiplier * zombie.frozenImpactDamageMultiplier, canOverkill: zombie.isFrozenSolid) {
                // Tracked on the projectile itself (see incrementKillTally) so a bowling ball that
                // rolls through several zombies knows this is its 2nd+ kill — that's ZOMBIE BOWLING.
                let tally = weaponSystem.incrementKillTally(on: weaponBody.node)
                if weaponKind == .bowlingBall, tally >= 3 { recordFeat("bowling_triple") }
                comboSystem.defeat(zombie, reason: .weapon, multiKillTally: tally, weaponKind: weaponKind)
            } else {
                SoundManager.shared.playZombieVoice(for: zombie.kind, moment: .hurt, pan: audioPan(for: zombie))
                // A walking zombie's body is kinematic (isDynamic == false, see ZombieNode.init),
                // so without this a weapon that doesn't kill would just bounce off it and the
                // zombie would keep walking as if nothing happened. Launching it off the weapon's
                // own velocity instead sells the hit and can chain into further collisions. Signed
                // (not abs'd) dy so a weapon striking downward reads as a weaker pop than one
                // striking upward, instead of both looking identical.
                if zombie.canBeKnockedBack {
                    knockback(zombie, impulse: CGVector(dx: weaponBody.velocity.dx * 0.32, dy: weaponBody.velocity.dy * 0.22 + 90))
                }
            }
            return
        }

        if let zombie = zombieBody(in: bodies), bodies.contains(where: { $0.categoryBitMask == PhysicsCategory.trap }) {
            playCombatVFX(.zombieSplatter, at: contact.contactPoint, size: 76, direction: zombie.approachesFromLeft ? -1 : 1)
            let baseDamage: CGFloat = zombie.kind == .armored ? 0.7 : 1.5
            if zombie.damage(baseDamage * zombie.kind.trapDamageMultiplier) {
                comboSystem.defeat(zombie, reason: .trap)
            } else {
                SoundManager.shared.playZombieVoice(for: zombie.kind, moment: .hurt, pan: audioPan(for: zombie))
            }
            return
        }

        if bodies.allSatisfy({ $0.categoryBitMask == PhysicsCategory.zombie }), contact.collisionImpulse > 18 {
            playCombatVFX(.zombieSplatter, at: contact.contactPoint, size: 82, direction: contact.contactNormal.dx >= 0 ? 1 : -1)
            let zombieA = bodies[0].node as? ZombieNode
            let zombieB = bodies[1].node as? ZombieNode
            // A thrown zombie plowing into a walking one used to just tick damage on both — the
            // walking one is kinematic (see ZombieNode.init) so it never actually got pushed.
            // Launching the survivor away from whichever body it collided with turns this into a
            // real bowling-pin chain reaction instead of a stationary hitbox.
            for (zombie, otherZombie) in [(zombieA, zombieB), (zombieB, zombieA)] {
                guard let zombie, !zombie.isDefeated else { continue }
                bossDirector.handleBouncerArmorStrip(zombie, thrownInto: otherZombie, at: contact.contactPoint)
                if zombie.damage(contact.collisionImpulse / 42) {
                    // Matches the armor-strip check above: only counts as "colliding it with
                    // another zombie" when the other one was actually thrown/knocked in, not an
                    // ordinary crowd-pressure kill the boss happened to be standing in.
                    if zombie.kind.isBoss, let otherZombie, otherZombie.isThrown { recordFeat("boss_friendly_fire") }
                    comboSystem.defeat(zombie, reason: .collision)
                } else if zombie.canBeKnockedBack, let otherZombie {
                    knockback(zombie, awayFrom: otherZombie.position, magnitude: contact.collisionImpulse)
                }
            }
        }
    }

    /// Launches a currently-walking zombie into the same airborne/land/recover flow a player
    /// flick uses (see ZombieNode.launch), clamped to a readable stagger-hop rather than a full
    /// screen-length flight. `impulse` is a direct directional push (e.g. off a weapon's own
    /// velocity); the `awayFrom:` overload derives direction from another body's position.
    /// Divides by the zombie's own `throwResistance` here rather than inside `launch()` itself —
    /// `launch()` also backs explodeVolatile/fireScatterblast/throwExplosive, whose impulse
    /// constants are already tuned per-weapon assuming it applies them undivided, so scaling
    /// there would have quietly weakened every one of those against riot/butcher/colossus.
    private func knockback(_ zombie: ZombieNode, impulse: CGVector) {
        let dx = max(-360, min(360, impulse.dx)) / zombie.kind.throwResistance
        let dy = max(90, min(320, impulse.dy)) / zombie.kind.throwResistance
        zombie.launch(with: CGVector(dx: dx, dy: dy))
    }

    private func knockback(_ zombie: ZombieNode, awayFrom point: CGPoint, magnitude: CGFloat) {
        let dx = zombie.position.x - point.x
        let sign: CGFloat = dx == 0 ? (zombie.approachesFromLeft ? -1 : 1) : (dx > 0 ? 1 : -1)
        let power = min(300, max(90, magnitude * 3.2))
        knockback(zombie, impulse: CGVector(dx: sign * power, dy: power * 0.6))
    }

    private func resolveImpact(on zombie: ZombieNode, damage rawDamage: CGFloat) {
        // Frozen-solid zombies shatter for much higher ground-impact damage (Flash Freezer), and
        // bypass the usual "survives its first ordinary hit" floor — that's the whole point of
        // brittleness — while a normal zombie's first hit is unaffected.
        let damage = rawDamage * zombie.frozenImpactDamageMultiplier
        // 0...1.4, see ZombieNode.lastImpactPower — the whole point of the flick: a tiny toss
        // barely registers, a monster flick should feel violently, cartoonishly satisfying.
        let power = zombie.lastImpactPower
        SoundManager.shared.play(.impact, intensity: 0.7 + power * 0.9)
        zombie.playImpact(reducedMotion: settings.reducedMotion, power: power)
        let impactPoint = CGPoint(x: zombie.position.x, y: groundY + 8)
        playCombatVFX(.pavementImpact, at: impactPoint, size: min(230, 120 + damage * 30 + power * 70), direction: zombie.physicsBody?.velocity.dx.sign == .minus ? -1 : 1)
        spawnPavementCracks(at: impactPoint, power: power)
        if power > 0.3 {
            shakeCamera(intensity: 0.25 + power * 1.35)
            runHaptic(impactHapticStyle(for: power))
        }
        if power > 0.55 {
            // A second, landing-moment hit-stop — separate from releaseZombie's release-moment
            // "snap" — so a hard slam gets weight both at the throw and at the payoff.
            hitStop(duration: min(0.14, 0.05 + Double(power) * 0.09), slowFactor: max(0.12, 0.4 - power * 0.22))
            // GROUND ZERO: reuses the same knockback() a weapon/collision hit already sends a
            // walking zombie flying with (see didBegin) — a hard-enough slam radiates the same
            // effect outward to everyone standing nearby.
            if perkSystem.hasShockwaveSlams {
                let shockRadius: CGFloat = 140
                for other in activeZombies where other.canBeKnockedBack
                    && hypot(other.position.x - impactPoint.x, other.position.y - impactPoint.y) < shockRadius {
                    knockback(other, awayFrom: impactPoint, magnitude: 55 + power * 55)
                }
                shakeCamera(intensity: 0.35)
                playCombatVFX(.pavementImpact, at: impactPoint, size: shockRadius * 1.3, direction: 1)
            }
        }
        if zombie.damage(damage, canOverkill: zombie.isFrozenSolid) {
            comboSystem.defeat(zombie, reason: .impact)
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
        playerThrewThisWave = true
        // A confirming hit-stop "snap" right at the moment of a hard flick, scaled continuously
        // with zombie.lastImpactPower instead of the old fixed 1,850pt/s on-or-off cutoff — the
        // (usually bigger) landing-moment payoff happens separately in resolveImpact/defeat.
        if zombie.lastImpactPower > 0.65 {
            let power = zombie.lastImpactPower
            hitStop(duration: min(0.18, 0.08 + Double(power) * 0.09), slowFactor: max(0.18, 0.42 - power * 0.2))
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

    var activeZombies: [ZombieNode] {
        world.children.compactMap { $0 as? ZombieNode }
    }

    func sandboxSpawn(_ kind: ZombieKind) {
        guard level.isSandbox else { return }
        for _ in 0..<spawnDirector.sandboxSpawnBurst { spawnZombie(forceWalker: false, bossKind: kind.isBoss ? kind : nil, forcedKind: kind) }
    }

    func sandboxClear() {
        guard level.isSandbox else { return }
        activeZombies.forEach { $0.removeFromParent() }
        bossHUD.isHidden = true
    }

    func sandboxSetSpeed(_ speed: CGFloat) {
        guard level.isSandbox else { return }
        spawnDirector.sandboxSpeed = min(2.5, max(0.35, speed))
    }

    func sandboxSetGravity(_ gravity: CGFloat) {
        guard level.isSandbox else { return }
        physicsWorld.gravity = CGVector(dx: 0, dy: min(-1, max(-18, gravity)))
    }

    func sandboxSetBurst(_ count: Int) { spawnDirector.sandboxSpawnBurst = min(12, max(1, count)) }

    var sandboxStats: String { "ACTIVE \(activeZombies.count) • DEFEATS \(sandboxDefeats) • SPEED \(String(format: "%.1f", spawnDirector.sandboxSpeed))×" }

    /// Avoids SKNode.frame's accumulated-subtree walk by treating the zombie as a simple
    /// box around its position, since grounded zombies never need per-part precision here.
    private func zombieHasReachedHouse(_ zombie: ZombieNode) -> Bool {
        let frame = houseFrame.insetBy(dx: 18, dy: 0)
        let halfWidth = zombie.kind.size.width * 0.5
        let halfHeight = zombie.kind.size.height * 0.5
        guard zombie.position.x + halfWidth >= frame.minX, zombie.position.x - halfWidth <= frame.maxX else { return false }
        return zombie.position.y + halfHeight >= frame.minY && zombie.position.y - halfHeight <= frame.maxY
    }

    func spawnZombie(forceWalker: Bool, bossKind: ZombieKind? = nil, forcedKind: ZombieKind? = nil) {
        let unlockedCount = min(level.enemyRoster.count, max(1, 1 + wave))
        let roster = Array(level.enemyRoster.prefix(unlockedCount))
        // `roster` is empty only if a level is ever authored with an empty (or off-by-one-sliced)
        // enemyRoster — falls back to `.walker` instead of crashing on a force-unwrap/index.
        let kind = forcedKind ?? bossKind ?? (level.modifier == .volatileRush ? .volatile : (level.modifier == .waitressRush ? .waitress : (forceWalker ? (roster.contains(.walker) ? ZombieKind.walker : roster.first ?? .walker) : roster.randomElement() ?? .walker)))
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
            movementMultiplier: zombieSpeedScale * (difficulty?.speedMultiplier ?? 1) * settings.difficulty.enemySpeed * (level.isSandbox ? spawnDirector.sandboxSpeed : 1),
            healthMultiplier: (difficulty?.healthMultiplier ?? 1) * settings.difficulty.enemyHealth,
            dismembermentEnabled: settings.goreEnabled
        )
        zombie.position = CGPoint(
            x: fromLeft ? -kind.size.width : size.width + kind.size.width,
            y: groundY + kind.size.height * 0.39 + 2
        )
        zombie.zPosition = 10
        world.addChild(zombie)
        bossDirector.configureBossHooks(on: zombie)
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
        // STORM SHUTTERS floors at 1 damage regardless of stacking (see fortifiedDinerReduction)
        // so the diner is never literally unkillable, just much tankier.
        let bite = level.isSandbox ? 0 : max(1, Int((CGFloat(zombie.kind.dinerDamage) * perkSystem.fortifiedDinerReduction).rounded()))
        health = level.isSandbox ? health : max(0, health - bite)
        comboSystem.resetCombo()
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
        // Zombie Smash-style: a diner hit no longer kills the zombie — it stays parked at the
        // house and keeps biting (see ZombieNode.playDinerAttack's cooldown loop) until the
        // player actually kills it via grab/throw, a weapon, or a trap.
        if health == 0 { finish(won: false) }
    }

    func audioPan(for zombie: ZombieNode) -> Float {
        let normalized = (zombie.position.x / max(1, size.width)) * 2 - 1
        return Float(max(-0.9, min(0.9, normalized)))
    }

    /// Forwards to `weaponSystem` — kept as a same-named GameScene member because ComboSystemHost
    /// (which predates WeaponSystem's extraction) still requires it.
    func explodeVolatile(at point: CGPoint) { weaponSystem.explodeVolatile(at: point) }

    func spawnPhysicsDebris(from zombie: ZombieNode, reason: DefeatReason) {
        let impulseScale: CGFloat = reason == .explosion ? 1.8 : (zombie.kind.isBoss ? 0.75 : 1)
        if !settings.reducedMotion {
            let pieces = zombie.makePhysicsDebris()
            for (index, debris) in pieces.enumerated() {
                debris.position = zombie.position
                debris.zPosition = 28
                world.addChild(debris)
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

    func finish(won: Bool) {
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
        let earnedStars = level.isEndless ? 0 : GameRules.stars(score: comboSystem.score, health: health, startingHealth: startingHealth, won: won)
        let baseReward = level.isEndless ? GameRules.survivalReward(score: comboSystem.score) : (won ? level.reward + earnedStars * 40 : 0)
        // TIPS ARE POOLED only applies to endless (it's a perk from that mode's own perk pool) —
        // campaign/sandbox runs never populate perkSystem.activePerks, so nightShiftBonusMultiplier
        // is always exactly 1 there and this is a no-op.
        let reward = level.isSandbox ? 0 : Int(Double(baseReward) * settings.difficulty.rewardMultiplier * Double(perkSystem.nightShiftBonusMultiplier))
        // Sandbox has unlimited health/spawns, so every feat here is trivially farmable (stack ten
        // volatiles and pop them for a free CHAIN_REACTION_10) — same reasoning as reward above.
        let result = LevelResult(levelID: level.id, score: comboSystem.score, stars: earnedStars, reward: reward, won: won, defeats: comboSystem.defeats, maxCombo: comboSystem.maxCombo, wave: wave, feats: level.isSandbox ? [] : achievedFeats)
        gameDelegate?.gameScene(self, didFinish: result)
    }

    func spawnPickup(at point: CGPoint) {
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
                    weaponSystem.weaponCooldowns[weapon] = 0
                    specialCharge = min(1, specialCharge + 0.20 * Double(perkSystem.chargeRushBonus))
                    current.removeFromParent()
                    SoundManager.shared.play(.pickup)
                    announce(text: "\(weapon.title.uppercased()) READY", color: .yellow)
                    notifyDelegate()
                    return true
                } else if current.name == "pickup-coin" {
                    current.removeFromParent()
                    SoundManager.shared.play(.pickup)
                    comboSystem.awardPickupScore(75, at: location)
                    return true
                } else if current.name == "pickup-repair" {
                    health = min(startingHealth, health + GameRules.repairPickupAmount)
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

    func notifyDelegate() {
        gameDelegate?.gameScene(self, didUpdate: GameHUDSnapshot(
            score: comboSystem.score,
            wave: wave,
            waveStatus: spawnDirector.waveStatus,
            waveStatusHighlighted: spawnDirector.waveStatusHighlighted,
            health: health,
            maximumHealth: startingHealth,
            specialCharge: specialCharge,
            weaponCooldowns: weaponSystem.weaponCooldowns,
            trapCooldowns: weaponSystem.trapCooldowns,
            armedWeapon: weaponSystem.armedWeapon,
            perkChoices: perkSystem.pendingPerkChoices
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

    func burst(at point: CGPoint, color: SKColor) {
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

    func playCombatVFX(_ effect: CombatVFX, at point: CGPoint, size: CGFloat, direction: CGFloat, tint: SKColor? = nil) {
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
        // Brighter/more acidic than zombieSplatter's green — matches the toxic ooze in the
        // vfx_volatile_burst art rather than reusing the shared explosion's plain orange.
        case .volatileBurst: SKColor(red: 0.68, green: 0.95, blue: 0.22, alpha: 1)
        case .freezerBurst: .cyan
        }
        if !settings.reducedMotion {
            playDirectionalDebris(at: point, color: debrisColor, direction: direction, count: effect == .explosion || effect == .volatileBurst ? 14 : 8)
        }
    }

    func playDirectionalDebris(at point: CGPoint, color: SKColor, direction: CGFloat, count: Int) {
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

    /// `subtitle` (e.g. a wave modifier's banner text) renders as a second, smaller line under
    /// `text` on the same fade timing, so a wave announcement and a modifier announcement that
    /// land on the same wave read as one coordinated banner instead of two overlapping labels.
    func announce(text: String, color: SKColor, subtitle: String? = nil, subtitleColor: SKColor = .white) {
        let label = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        label.text = text
        label.fontSize = 42
        label.fontColor = color
        label.position = CGPoint(x: size.width / 2, y: size.height * 0.67)
        label.alpha = 0
        label.zPosition = 150
        world.addChild(label)
        label.run(.sequence([.fadeIn(withDuration: 0.16), .wait(forDuration: 0.65), .fadeOut(withDuration: 0.28), .removeFromParent()]))
        guard let subtitle else { return }
        let sub = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        sub.text = subtitle
        sub.fontSize = 20
        sub.fontColor = subtitleColor
        sub.position = CGPoint(x: size.width / 2, y: size.height * 0.67 - 34)
        sub.alpha = 0
        sub.zPosition = 150
        world.addChild(sub)
        sub.run(.sequence([.fadeIn(withDuration: 0.16), .wait(forDuration: 0.65), .fadeOut(withDuration: 0.28), .removeFromParent()]))
    }

    /// Queues a feat/achievement for the small delayed toast (see drainFeatToastsIfNeeded), but
    /// only the first time it's earned this run — several of the call sites (e.g. the per-frame
    /// SKY_LAUNCH height check) would otherwise re-fire every frame the condition still holds.
    func recordFeat(_ id: String) {
        guard achievedFeats.insert(id).inserted else { return }
        pendingFeatToasts.append(id)
        drainFeatToastsIfNeeded()
    }

    /// The three feedback layers on a single kill are deliberately never the same size or the
    /// same moment: the named combo-event banner is immediate and largest, the score/combo
    /// popups are secondary, and this progression toast is smallest, screen-anchored (not at the
    /// kill point), and held back a beat before it appears — so a kill that happens to trigger an
    /// achievement never reads as three labels landing on top of each other at once.
    private func drainFeatToastsIfNeeded() {
        guard !isDrainingFeatToasts, !pendingFeatToasts.isEmpty else { return }
        isDrainingFeatToasts = true
        let id = pendingFeatToasts.removeFirst()
        let title = Achievements.title(for: id) ?? id
        run(.sequence([
            .wait(forDuration: 0.6),
            .run { [weak self] in self?.showFeatToast(title: title) },
            .wait(forDuration: 1.4),
            .run { [weak self] in
                guard let self else { return }
                self.isDrainingFeatToasts = false
                self.drainFeatToastsIfNeeded()
            }
        ]))
    }

    /// Added directly to the scene (screen space), not `world` (which shakes with impacts and
    /// scrolls with the camera) — same trick bossHUD uses, so this toast holds still in its own
    /// corner of the screen regardless of what's happening in the fight underneath it.
    private func showFeatToast(title: String) {
        let label = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        label.text = "🏆 \(title) Unlocked"
        label.fontSize = 15
        label.fontColor = SKColor(red: 1.0, green: 0.82, blue: 0.4, alpha: 1)
        label.horizontalAlignmentMode = .center
        label.position = CGPoint(x: size.width / 2, y: size.height - 108)
        label.alpha = 0
        label.zPosition = 200
        addChild(label)
        label.run(.sequence([
            .fadeIn(withDuration: 0.25),
            .wait(forDuration: 1.1),
            .fadeOut(withDuration: 0.35),
            .removeFromParent()
        ]))
    }

    func shakeCamera(intensity: CGFloat = 1) {
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
    func hitStop(duration: TimeInterval, slowFactor: CGFloat = 0.04) {
        guard !settings.reducedMotion else { return }
        world.speed = slowFactor
        run(.sequence([.wait(forDuration: duration), .run { [weak self] in self?.world.speed = 1 }]), withKey: "hitStop")
    }

    func runHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard settings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    /// Stumble/knockback/slam/monster haptic tiers matching ZombieNode.lastImpactPower's 0...1.4
    /// scale, so a tiny flick barely taps and a monster slam hits as hard as UIKit allows.
    func impactHapticStyle(for power: CGFloat) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch power {
        case ..<0.18: .light
        case ..<0.5: .medium
        case ..<0.85: .heavy
        default: .rigid
        }
    }

    /// Small persistent crack marks in the pavement at a hard flick-impact point — distinct from
    /// `damageScenery` (which is specific to the diner's siding), purely a floor-level payoff for
    /// a satisfying slam. Gated to real impacts (see `resolveImpact`) so a tiny stumble stays quiet.
    private func spawnPavementCracks(at point: CGPoint, power: CGFloat) {
        guard !settings.reducedMotion else { return }
        let count = power < 0.45 ? 0 : (power < 0.85 ? 2 : 4)
        guard count > 0 else { return }
        for _ in 0..<count {
            let length = CGFloat.random(in: 14...26) * (0.85 + power * 0.4)
            let crack = SKShapeNode(rectOf: CGSize(width: length, height: 2.4), cornerRadius: 1.2)
            crack.fillColor = .black.withAlphaComponent(0.34)
            crack.strokeColor = .clear
            crack.zRotation = CGFloat.random(in: 0...(.pi))
            crack.position = CGPoint(x: point.x + CGFloat.random(in: -24...24), y: groundY + CGFloat.random(in: -3...5))
            crack.zPosition = 6
            crack.alpha = 0
            world.addChild(crack)
            crack.run(.sequence([.fadeAlpha(to: 0.85, duration: 0.05), .wait(forDuration: 3.2), .fadeOut(withDuration: 0.8), .removeFromParent()]))
        }
    }
}

extension GameScene: PerkSystemHost {}
extension GameScene: ComboSystemHost {}
extension GameScene: SpawnDirectorHost {}
extension GameScene: BossDirectorHost {}
extension GameScene: WeaponSystemHost {}
