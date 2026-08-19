import SpriteKit

enum ZombieKind: String, CaseIterable, Codable {
    case walker
    case runner
    case brute
    case crawler
    case armored
    case volatile
    case waitress
    case riot
    case groundskeeper
    case butcher
    case colossus
    case bouncer

    static let regularCases: [ZombieKind] = [.walker, .runner, .brute, .crawler, .armored, .volatile, .waitress, .riot, .groundskeeper]

    var isBoss: Bool { self == .butcher || self == .colossus || self == .bouncer }

    var displayName: String {
        switch self {
        case .butcher: "THE BUTCHER"
        case .colossus: "NEON COLOSSUS"
        case .bouncer: "THE BOUNCER"
        default: rawValue.uppercased()
        }
    }

    /// The Bouncer has no art of its own — it reuses `riot`'s rig at boss scale (see ZombieNode's
    /// armor-plate overlay for what actually makes it read as a distinct boss rather than a big
    /// riot zombie).
    var assetName: String { self == .bouncer ? ZombieKind.riot.rawValue : rawValue }

    /// Regular kinds are scaled to ~82% of the original art size, then shrunk again to ~55% of that
    /// on top (Zombie Smash-style small sprites so the play field reads as much larger) — physics
    /// bodies, hit-testing, and spawn positioning all derive from this, so the shrink stays
    /// consistent across visuals and gameplay. Bosses (butcher, colossus) keep their full original
    /// size — they're supposed to loom over the lot.
    var size: CGSize {
        switch self {
        case .walker: CGSize(width: 32, height: 51)
        case .runner: CGSize(width: 32, height: 49)
        case .brute: CGSize(width: 48, height: 59)
        case .crawler: CGSize(width: 47, height: 32)
        case .armored: CGSize(width: 38, height: 54)
        case .volatile: CGSize(width: 47, height: 57)
        case .waitress: CGSize(width: 35, height: 52)
        case .riot: CGSize(width: 41, height: 57)
        case .groundskeeper: CGSize(width: 40, height: 55)
        case .butcher: CGSize(width: 142, height: 164)
        case .colossus: CGSize(width: 154, height: 174)
        // Deliberately stockier/smaller than the other two bosses — it reads as a wall of armor
        // rather than a looming giant, which fits a boss whose whole identity is "can't be
        // grabbed until you chip its armor away" rather than sheer size.
        case .bouncer: CGSize(width: 118, height: 150)
        }
    }

    var speed: CGFloat {
        switch self {
        case .walker: 42
        case .runner: 90
        case .brute: 27
        case .crawler: 58
        case .armored: 34
        case .volatile: 38
        case .waitress: 62
        case .riot: 31
        case .groundskeeper: 46
        case .butcher: 22
        case .colossus: 18
        case .bouncer: 26
        }
    }

    var hitPoints: CGFloat {
        switch self {
        case .walker: 5
        case .runner: 4
        case .brute: 12
        case .crawler: 5.5
        case .armored: 11
        case .volatile: 7
        case .waitress: 4.5
        case .riot: 14
        case .groundskeeper: 9
        case .butcher: 44
        case .colossus: 68
        case .bouncer: 54
        }
    }

    /// Regular enemies survive their first ordinary hit so combat reads as damage, stagger, then
    /// defeat instead of every contact deleting a full-health zombie. Heavy scripted explosions
    /// can opt out; bosses already rely on their larger health pools and phase thresholds.
    var firstHitHealthFloor: CGFloat {
        switch self {
        case .runner, .waitress: 0.28
        case .walker, .crawler, .volatile: 0.38
        case .brute, .armored, .riot, .groundskeeper: 0.48
        case .butcher, .colossus, .bouncer: 0
        }
    }

    // Bumped ~7-8% (brute/boss ~7%) alongside the restitution increase in ZombieNode.init —
    // SpriteKit's collisionImpulse for a ground contact scales with (1+restitution), so raising
    // restitution alone would have quietly made every fall more lethal at the same fall height.
    // This is an estimate matching that scaling factor, not a measured value; revisit after a
    // playtest pass.
    var defeatImpulse: CGFloat {
        switch self {
        case .walker: 24
        case .runner: 19
        case .brute: 51
        case .crawler: 27
        case .armored: 45
        case .volatile: 32
        case .waitress: 22
        case .riot: 52
        case .groundskeeper: 37
        case .butcher: 80
        case .colossus: 98
        case .bouncer: 78
        }
    }

    var scoreValue: Int {
        switch self {
        case .walker: 100
        case .runner: 140
        case .brute: 300
        case .crawler: 175
        case .armored: 260
        case .volatile: 240
        case .waitress: 165
        case .riot: 340
        case .groundskeeper: 220
        case .bouncer: 1_900
        case .butcher: 1_500
        case .colossus: 2_200
        }
    }

    /// Scaled for GameRules.startingHealth's numeric pool (100), not the old 5-heart scale —
    /// small relative to the pool since bites repeat every ~1.1s (see playDinerAttack) rather
    /// than being a single hit that ends the zombie.
    var dinerDamage: Int {
        if self == .butcher { return 14 }
        if self == .colossus { return 20 }
        if self == .bouncer { return 17 }
        return self == .brute || self == .volatile || self == .groundskeeper ? 8 : 4
    }

    var throwResistance: CGFloat {
        switch self {
        case .riot: 1.25
        // Boss-tier resistance despite not being a boss — matches its 2.4 physics mass (more than
        // double a regular zombie's 1.1, see ZombieNode.init) and its whole "big, slow, heavy"
        // identity: a full-power flick should still barely budge it, not send it flying like a
        // Walker.
        case .brute: 1.8
        case .butcher: 1.8
        case .colossus: 2.15
        case .bouncer: 1.9
        default: 1
        }
    }

    var weaponDamageMultiplier: CGFloat {
        switch self {
        case .riot: 0.6
        case .butcher: 0.72
        case .colossus: 0.58
        case .bouncer: 0.65
        default: 1
        }
    }

    var trapDamageMultiplier: CGFloat {
        switch self {
        case .riot: 0.55
        case .butcher: 0.8
        case .colossus: 0.45
        case .bouncer: 0.6
        default: 1
        }
    }

    /// Kinds that always growl on defeat rather than rolling the ambient random-vocalization chance.
    var alwaysVocalizesOnDefeat: Bool { self == .brute || self == .volatile }
}

private enum RigPart: CaseIterable, Hashable {
    case head
    case torso
    case frontArm
    case backArm
    case frontLeg
    case backLeg

    var assetSuffix: String {
        switch self {
        case .head: "head"
        case .torso: "torso"
        case .frontArm: "frontArm"
        case .backArm: "backArm"
        case .frontLeg: "frontLeg"
        case .backLeg: "backLeg"
        }
    }
}

private struct PartPose {
    let position: CGPoint
    let rotation: CGFloat
}

enum ZombieAnimationState: CaseIterable, Equatable {
    case walking
    case attacking
    case grabbed
    case airborne
    case impact
    case recovering
    case frozen
    case defeated
    /// Parked at the diner between bites — not moving, waiting out `dinerAttackCooldown` before
    /// the next `playDinerAttack`. Distinct from `.attacking`, which is only the bite animation
    /// itself, so the zombie stays alive and attackable until the player actually kills it.
    case holdingAtDiner
}

enum ZombieDefeatStyle {
    case pavement, collision, weapon, trap, thrownOut, explosion
}

final class ZombieNode: SKNode {
    let kind: ZombieKind
    let approachesFromLeft: Bool
    var isGrabbed = false
    var isThrown = false
    private(set) var isDefeated = false
    /// Set by the Flash Freezer trap only — distinct from the generic `slowTime` used by the
    /// unrelated boss-stun mechanic, so a stunned boss doesn't briefly become brittle-physics too.
    private(set) var isFrozenSolid = false
    /// Ground-impact and weapon-contact damage is multiplied by this while frozen solid, so
    /// flicking or hitting a frozen zombie into something reads as it shattering.
    var frozenImpactDamageMultiplier: CGFloat { isFrozenSolid ? 3.5 : 1 }
    var hasResolvedImpact = false
    var highestPoint: CGFloat = 0
    /// Normalized ~0...1.4 severity of the throw/knockback that most recently sent this zombie
    /// airborne (1 = the hardest possible ordinary flick), set by release()/launch() and cleared
    /// by resumeWalking() once it lands safely. GameScene reads it when this zombie hits the
    /// ground or is defeated, to scale impact feedback (screen shake, haptics, sound, particles,
    /// hit-stop, pavement cracks) to how hard it actually got hit instead of every impact feeling
    /// the same. Cleared on a safe landing so a later, unrelated kill (weapon/trap/collision)
    /// doesn't inherit a stale reading from an old throw.
    private(set) var lastImpactPower: CGFloat = 0
    /// True only when the current/most recent flight is a direct player flick (release()), false
    /// for an explosion/knockback launch() — GameScene reads this to tell the two apart for
    /// feat-tracking (e.g. "no *grabbed* zombie touches the ground this wave" shouldn't count a
    /// zombie a bowling ball happened to knock into the pavement).
    private(set) var wasPlayerThrown = false
    private(set) var health: CGFloat
    private let maximumHealth: CGFloat
    private let movementMultiplier: CGFloat
    private let dismembermentEnabled: Bool

    private let rig = SKNode()
    private let shadowNode: SKShapeNode
    private let healthBarTrack = SKShapeNode(rectOf: CGSize(width: 48, height: 7), cornerRadius: 3.5)
    private let healthBarFill = SKSpriteNode(color: SKColor(red: 0.34, green: 0.90, blue: 0.32, alpha: 1), size: CGSize(width: 44, height: 4))
    private var sprites: [RigPart: SKSpriteNode] = [:]
    private var restPose: [RigPart: PartPose] = [:]
    private var walkPhase: CGFloat = 0
    private var slowTime: TimeInterval = 0
    private var recoveryTime: TimeInterval = 0
    private var hitReactionTime: TimeInterval = 0
    private var damageProtectionRemaining: TimeInterval = 0
    private var dinerAttackCooldown: TimeInterval = 0
    private var hasTakenOrdinaryHit = false
    private(set) var severedLimbCount = 0
    private var severedParts: Set<RigPart> = []
    private var armorBroken = false
    private var volatileWarningActive = false
    private var freezeOverlay: SKNode?
    private var state: ZombieAnimationState = .walking
    var onHealthChanged: ((CGFloat) -> Void)?
    var onArmorBroken: (() -> Void)?
    var onBossPhaseChanged: ((Int) -> Void)?
    private(set) var bossIsStunned = false
    private var bossStunDamage: CGFloat = 0
    private(set) var bossPhase = 1
    private var abilityTime: TimeInterval = 0
    /// THE BOUNCER only: physical armor-plate overlays that must be knocked off one at a time by
    /// another zombie being thrown/knocked into it (see GameScene.didBegin's zombie-zombie
    /// collision branch) before it can be grabbed at all — a mechanic gate, not a health-threshold
    /// cosmetic like `armorBroken` above. Empty for every other kind.
    private var armorPlateNodes: [SKNode] = []
    private(set) var armorPlateCount = 0
    var isArmored: Bool { armorPlateCount > 0 }
    var onArmorFullyStripped: (() -> Void)?

    var currentAnimationState: ZombieAnimationState { state }
    var healthFraction: CGFloat { max(0, health / maximumHealth) }
    var canBeGrabbed: Bool { kind == .bouncer ? !isArmored : (!kind.isBoss || bossIsStunned) }
    /// Only a plainly-walking zombie can be sent into a knockback launch — mid-air, grabbed,
    /// frozen, attacking, or already-recovering zombies own their own physics/state transitions
    /// and a launch() here would fight them. Bosses are excluded from casual knockback the same
    /// way canBeGrabbed excludes them from casual grabs — a stray weapon graze or pileup bump
    /// shouldn't fling a butcher/colossus around. Also excluded below a low health floor: a
    /// non-lethal hit here already used up this zombie's `firstHitHealthFloor` protection (see
    /// that property), so launching a near-dead zombie into a fall could kill it on landing —
    /// bundling two hits' worth of damage into what reads to the player as one action.
    var canBeKnockedBack: Bool { state == .walking && (!kind.isBoss || bossIsStunned) && healthFraction > 0.2 }

    var hasCompleteAnimationRig: Bool {
        sprites.count == RigPart.allCases.count && sprites.values.allSatisfy {
            guard let texture = $0.texture else { return false }
            return texture.size().width > 1 && texture.size().height > 1
        }
    }

    init(kind: ZombieKind, approachesFromLeft: Bool, movementMultiplier: CGFloat = 1, healthMultiplier: CGFloat = 1, dismembermentEnabled: Bool = true) {
        self.kind = kind
        self.approachesFromLeft = approachesFromLeft
        self.movementMultiplier = movementMultiplier
        self.dismembermentEnabled = dismembermentEnabled
        maximumHealth = kind.hitPoints * healthMultiplier
        health = maximumHealth

        shadowNode = SKShapeNode(ellipseOf: CGSize(width: kind.size.width * 0.72, height: 16))
        shadowNode.fillColor = .black.withAlphaComponent(0.02)
        shadowNode.strokeColor = .clear
        shadowNode.position.y = -kind.size.height * 0.43

        super.init()

        name = "zombie"
        addChild(shadowNode)
        addChild(rig)
        buildRig()
        buildArmorPlates()

        healthBarTrack.fillColor = .black.withAlphaComponent(0.72)
        healthBarTrack.strokeColor = .white.withAlphaComponent(0.48)
        healthBarTrack.lineWidth = 1
        healthBarTrack.position.y = kind.size.height * 0.56
        healthBarTrack.isHidden = true
        healthBarTrack.zPosition = 12
        addChild(healthBarTrack)
        healthBarFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        healthBarFill.position = CGPoint(x: -22, y: 0)
        healthBarFill.zPosition = 1
        healthBarTrack.addChild(healthBarFill)

        let physicsSize = CGSize(width: kind.size.width * 0.68, height: kind.size.height * 0.78)
        physicsBody = SKPhysicsBody(rectangleOf: physicsSize, center: CGPoint(x: 0, y: -kind.size.height * 0.04))
        physicsBody?.isDynamic = false
        physicsBody?.allowsRotation = true
        // Bumped from 0.16/0.30 and friction/damping loosened for a bouncier, more chaotic
        // Zombie Smash-style landing/tumble — see release()/launch() for the matching wider
        // spin range, and GameScene.knockback for the new non-lethal-hit launches this now
        // needs to sell (a stiff, high-friction body reads as barely reacting to a hit).
        physicsBody?.restitution = kind == .brute || kind.isBoss ? 0.24 : 0.40
        physicsBody?.friction = 0.58
        physicsBody?.linearDamping = 0.12
        physicsBody?.angularDamping = 0.24
        physicsBody?.mass = kind.isBoss ? 4.2 : (kind == .brute ? 2.4 : (kind == .crawler ? 0.75 : 1.1))
        physicsBody?.categoryBitMask = PhysicsCategory.zombie
        physicsBody?.collisionBitMask = PhysicsCategory.ground | PhysicsCategory.boundary | PhysicsCategory.zombie | PhysicsCategory.weapon
        physicsBody?.contactTestBitMask = PhysicsCategory.ground | PhysicsCategory.zombie | PhysicsCategory.weapon | PhysicsCategory.trap
        xScale = approachesFromLeft ? 1 : -1
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildRig() {
        let height = kind.size.height
        let crawlerScale: CGFloat = kind == .crawler ? 0.88 : 1
        let targetHeights: [RigPart: CGFloat] = [
            .head: height * (kind == .crawler ? 0.36 : 0.34),
            .torso: height * (kind == .crawler ? 0.48 : 0.58),
            .frontArm: height * (kind == .crawler ? 0.58 : 0.49),
            .backArm: height * (kind == .crawler ? 0.58 : 0.49),
            .frontLeg: height * (kind == .crawler ? 0.52 : 0.57),
            .backLeg: height * (kind == .crawler ? 0.52 : 0.57)
        ]

        for part in RigPart.allCases {
            let texture = SKTexture(imageNamed: "\(kind.assetName)_\(part.assetSuffix)")
            texture.filteringMode = .linear
            let sourceSize = texture.size()
            let targetHeight = targetHeights[part, default: height * 0.5] * crawlerScale
            let aspect = sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 1
            let maxWidth = kind.size.width * (part == .torso ? 0.94 : 0.72)
            var size = CGSize(width: targetHeight * aspect, height: targetHeight)
            if size.width > maxWidth {
                let multiplier = maxWidth / size.width
                size.width *= multiplier
                size.height *= multiplier
            }

            let sprite = SKSpriteNode(texture: texture, size: size)
            sprite.name = part.assetSuffix
            switch part {
            case .head: sprite.anchorPoint = CGPoint(x: 0.25, y: 0.25)
            case .torso: sprite.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            case .frontArm, .backArm: sprite.anchorPoint = CGPoint(x: 0.28, y: 0.84)
            case .frontLeg, .backLeg: sprite.anchorPoint = CGPoint(x: 0.35, y: 0.89)
            }
            sprites[part] = sprite
            rig.addChild(sprite)
        }

        configureRestPose()
        applyRestPose()
    }

    /// THE BOUNCER's armor overlays, parented to `rig` (so they ride along with its walk-bob/pose
    /// transforms like any other part) standing between it and `canBeGrabbed`. All three are real
    /// art now (shoulders, torso, belt). Order matters: `armorPlateNodes` is built bottom-to-top
    /// so `knockArmorPlate`'s `popLast()` strips the belt first, the chest plate second, and the
    /// shoulder guard — the biggest, most dramatic piece — last, right as the armor fully comes off.
    private func buildArmorPlates() {
        guard kind == .bouncer else { return }
        let torsoWidth = sprites[.torso]?.size.width ?? kind.size.width * 0.5
        let torsoHeight = sprites[.torso]?.size.height ?? kind.size.height * 0.5

        let shoulderWidth = torsoWidth * 0.95
        let shoulders = SKSpriteNode(
            texture: SKTexture(imageNamed: "bouncer_armor_shoulders"),
            size: CGSize(width: shoulderWidth, height: shoulderWidth * (944.0 / 1667.0))
        )
        shoulders.position = CGPoint(x: 0, y: torsoHeight * 0.40)
        shoulders.zPosition = 8
        rig.addChild(shoulders)

        let chestWidth = torsoWidth * 0.78
        let chest = SKSpriteNode(
            texture: SKTexture(imageNamed: "bouncer_armor_torso"),
            size: CGSize(width: chestWidth, height: chestWidth * (1024.0 / 1536.0))
        )
        chest.position = CGPoint(x: 0, y: torsoHeight * 0.12)
        chest.zPosition = 8
        rig.addChild(chest)

        let beltWidth = torsoWidth * 0.9
        let belt = SKSpriteNode(
            texture: SKTexture(imageNamed: "bouncer_armor_belt"),
            size: CGSize(width: beltWidth, height: beltWidth * (977.0 / 1610.0))
        )
        belt.position = CGPoint(x: 0, y: -torsoHeight * 0.30)
        belt.zPosition = 8
        rig.addChild(belt)

        armorPlateNodes = [shoulders, chest, belt]
        armorPlateCount = armorPlateNodes.count
    }

    /// Called by GameScene when another zombie is genuinely thrown/knocked into the Bouncer (not
    /// just incidental crowd contact — see the caller). Knocks one plate loose and drops it to the
    /// ground, and once the last one's gone, flags it grabbable via `canBeGrabbed` and fires
    /// `onArmorFullyStripped` for GameScene to announce.
    @discardableResult
    func knockArmorPlate() -> Bool {
        guard isArmored, let plate = armorPlateNodes.popLast() else { return false }
        armorPlateCount -= 1
        // Detach from `rig` into the zombie's own parent (the same world layer every other prop
        // in the fight lives in) *before* animating — move(toParent:) preserves the plate's
        // current absolute position/rotation, so it falls straight from wherever it actually was
        // instead of staying hostage to `rig`'s walk-bob, a later flick, or the zombie's own
        // eventual removal cutting the fall short mid-animation.
        if let parent {
            plate.move(toParent: parent)
            // zPosition 8 only meant "above this zombie's own body parts" while the plate was a
            // child of `rig`; as a sibling of every other world-layer node now, it needs to beat
            // a walking zombie's own zPosition (10, see GameScene.spawnZombie) or the plate falls
            // invisibly behind the Bouncer's torso instead of visibly dropping off in front of it.
            plate.zPosition = 15
        }
        let sideDrift = CGFloat.random(in: -60...60)
        let fallTarget = CGPoint(x: plate.position.x + sideDrift, y: plate.position.y - CGFloat.random(in: 78...112))
        let fall = SKAction.move(to: fallTarget, duration: 0.34)
        fall.timingMode = .easeIn
        let tumble = SKAction.rotate(byAngle: (sideDrift >= 0 ? 1 : -1) * CGFloat.random(in: 3...6), duration: 0.34)
        let bounce = SKAction.sequence([
            .moveBy(x: sideDrift * 0.12, y: 10, duration: 0.08),
            .moveBy(x: 0, y: -10, duration: 0.09)
        ])
        plate.run(.sequence([
            .group([fall, tumble]),
            bounce,
            .wait(forDuration: 0.6),
            .fadeOut(withDuration: 0.35),
            .removeFromParent()
        ]))
        hitReactionTime = 0.16
        rig.run(.sequence([.colorize(with: .white, colorBlendFactor: 0.85, duration: 0.05), .colorize(withColorBlendFactor: 0, duration: 0.14)]))
        if !isArmored {
            sprites.values.forEach { $0.color = .cyan; $0.colorBlendFactor = 0.28 }
            // Restores whatever tint should actually be showing (a phase color, or none) rather
            // than blindly zeroing colorBlendFactor — same reasoning as the bossStun cleanup
            // above, which this would otherwise fight if a phase change lands in the same window.
            run(.sequence([.wait(forDuration: 0.5), .run { [weak self] in self?.applyBossPhaseTint() }]))
            onArmorFullyStripped?()
        }
        return true
    }

    private func configureRestPose() {
        guard let torso = sprites[.torso] else { return }
        let torsoWidth = torso.size.width
        let torsoHeight = torso.size.height

        if kind == .crawler {
            restPose = [
                .torso: PartPose(position: CGPoint(x: -8, y: -2), rotation: -0.08),
                .head: PartPose(position: CGPoint(x: torsoWidth * 0.30, y: torsoHeight * 0.18), rotation: -0.10),
                .backArm: PartPose(position: CGPoint(x: torsoWidth * 0.10, y: torsoHeight * 0.06), rotation: 0.22),
                .frontArm: PartPose(position: CGPoint(x: torsoWidth * 0.26, y: torsoHeight * 0.02), rotation: -0.08),
                .backLeg: PartPose(position: CGPoint(x: -torsoWidth * 0.31, y: -torsoHeight * 0.19), rotation: 0.31),
                .frontLeg: PartPose(position: CGPoint(x: -torsoWidth * 0.10, y: -torsoHeight * 0.22), rotation: -0.10)
            ]
        } else {
            let lean: CGFloat = kind == .runner || kind == .waitress ? -0.12 : (kind == .brute || kind.isBoss ? 0.03 : -0.035)
            let backShoulderX: CGFloat = switch kind {
            case .brute, .armored, .volatile, .riot, .groundskeeper, .butcher, .colossus, .bouncer: -torsoWidth * 0.30
            case .runner, .waitress: -torsoWidth * 0.16
            default: torsoWidth * 0.03
            }
            restPose = [
                .torso: PartPose(position: CGPoint(x: 0, y: kind.size.height * 0.02), rotation: lean),
                .head: PartPose(position: CGPoint(x: torsoWidth * 0.17, y: torsoHeight * 0.38), rotation: lean * 0.45),
                .backArm: PartPose(position: CGPoint(x: backShoulderX, y: torsoHeight * 0.30), rotation: kind == .runner ? 0.38 : 0.10),
                .frontArm: PartPose(position: CGPoint(x: torsoWidth * 0.16, y: torsoHeight * 0.27), rotation: kind == .runner ? -0.18 : -0.05),
                .backLeg: PartPose(position: CGPoint(x: -torsoWidth * 0.17, y: -torsoHeight * 0.31), rotation: kind == .runner ? 0.16 : 0.05),
                .frontLeg: PartPose(position: CGPoint(x: torsoWidth * 0.10, y: -torsoHeight * 0.32), rotation: kind == .runner ? -0.17 : -0.03)
            ]
        }

        sprites[.backArm]?.zPosition = 0
        sprites[.backLeg]?.zPosition = 0
        sprites[.torso]?.zPosition = 2
        sprites[.frontLeg]?.zPosition = 3
        sprites[.frontArm]?.zPosition = 4
        sprites[.head]?.zPosition = 5
    }

    private func applyRestPose() {
        rig.position = .zero
        rig.zRotation = 0
        rig.xScale = 1
        rig.yScale = 1
        for (part, pose) in restPose {
            sprites[part]?.position = pose.position
            sprites[part]?.zRotation = pose.rotation
        }
    }

    func updateWalking(deltaTime: TimeInterval, reducedMotion: Bool) {
        if slowTime > 0 { slowTime -= deltaTime }
        if hitReactionTime > 0 { hitReactionTime -= deltaTime }
        if damageProtectionRemaining > 0 { damageProtectionRemaining -= deltaTime }
        if dinerAttackCooldown > 0 { dinerAttackCooldown -= deltaTime }
        guard !isDefeated else { return }
        abilityTime += deltaTime
        if kind == .waitress, abilityTime >= 2.4, state == .walking {
            abilityTime = 0
            position.x += (approachesFromLeft ? 1 : -1) * 34
            if !reducedMotion { rig.run(.sequence([.moveBy(x: 0, y: 28, duration: 0.12), .moveBy(x: 0, y: -28, duration: 0.16)])) }
        } else if kind == .groundskeeper, abilityTime >= 3.8, state == .walking {
            abilityTime = 0
            slowTime = -0.75
            if !reducedMotion { rig.run(.sequence([.rotate(byAngle: 0.08, duration: 0.12), .rotate(byAngle: -0.08, duration: 0.12)])) }
        }

        if state == .airborne || isThrown {
            highestPoint = max(highestPoint, position.y)
            guard !reducedMotion else { return }
            walkPhase += CGFloat(deltaTime) * 11
            applyAirbornePose()
            return
        }

        if state == .grabbed || isGrabbed {
            highestPoint = max(highestPoint, position.y)
            guard !reducedMotion else { return }
            walkPhase += CGFloat(deltaTime) * 7
            applyGrabbedPose()
            return
        }

        // Frozen-solid zombies are dynamic physics bodies now (see freezeSolid) — gravity and
        // collisions drive position, not the manual walk-cycle code below.
        if state == .impact || state == .attacking || state == .frozen || state == .holdingAtDiner { return }
        if state == .recovering {
            recoveryTime -= deltaTime
            if recoveryTime <= 0 {
                state = .walking
                applyRestPose()
            }
            return
        }

        let direction: CGFloat = approachesFromLeft ? 1 : -1
        let slowMultiplier: CGFloat = slowTime > 0 ? 0.42 : 1
        position.x += direction * kind.speed * movementMultiplier * slowMultiplier * CGFloat(deltaTime)
        guard !reducedMotion else { return }

        let cadence: CGFloat = kind == .runner || kind == .waitress ? 12.5 : (kind == .crawler ? 10.5 : (kind == .brute || kind.isBoss ? 5.4 : 8.2))
        walkPhase += CGFloat(deltaTime) * cadence * slowMultiplier
        applyWalkingPose()
    }

    private func applyWalkingPose() {
        let stride = sin(walkPhase)
        let counterStride = sin(walkPhase + .pi)
        let bob = abs(sin(walkPhase))
        let amplitude: CGFloat = kind == .runner || kind == .waitress ? 0.34 : (kind == .brute || kind.isBoss ? 0.16 : (kind == .crawler ? 0.24 : 0.25))
        let hitLean: CGFloat = hitReactionTime > 0 ? -0.18 : 0

        rig.position.y = bob * (kind == .brute || kind.isBoss ? 1.4 : 2.7)
        rig.zRotation = (kind == .crawler ? stride * 0.025 : stride * 0.018) + hitLean
        rig.xScale = 1 + bob * 0.018
        rig.yScale = 1 - bob * 0.018
        shadowNode.xScale = 1 - bob * 0.10

        setRotation(.frontArm, offset: stride * amplitude)
        setRotation(.backArm, offset: counterStride * amplitude)
        setRotation(.frontLeg, offset: counterStride * amplitude * 0.82)
        setRotation(.backLeg, offset: stride * amplitude * 0.82)
        setRotation(.head, offset: sin(walkPhase * 0.5) * 0.045 - bob * 0.025)
        setRotation(.torso, offset: stride * 0.022)
    }

    private func applyGrabbedPose() {
        let wobble = sin(walkPhase) * 0.08
        rig.zRotation = wobble * 0.25
        rig.position.y = sin(walkPhase * 0.7) * 1.5
        setRotation(.head, offset: -0.18 + wobble)
        setRotation(.frontArm, offset: 0.72 + wobble)
        setRotation(.backArm, offset: 0.48 - wobble)
        setRotation(.frontLeg, offset: -0.42 - wobble)
        setRotation(.backLeg, offset: 0.48 + wobble)
    }

    private func applyAirbornePose() {
        let flail = sin(walkPhase)
        let counter = cos(walkPhase * 0.83)
        rig.position.y = 0
        rig.zRotation = flail * 0.055
        rig.xScale = 1
        rig.yScale = 1
        shadowNode.alpha = 0.12
        setRotation(.head, offset: counter * 0.22)
        setRotation(.frontArm, offset: 0.78 + flail * 0.52)
        setRotation(.backArm, offset: -0.58 - counter * 0.56)
        setRotation(.frontLeg, offset: -0.72 + counter * 0.52)
        setRotation(.backLeg, offset: 0.68 - flail * 0.48)
    }

    private func setRotation(_ part: RigPart, offset: CGFloat) {
        guard let pose = restPose[part] else { return }
        sprites[part]?.zRotation = pose.rotation + offset
    }

    func beginGrab(reducedMotion: Bool) {
        guard !isDefeated, canBeGrabbed else {
            if kind.isBoss { rig.run(.sequence([.colorize(with: .red, colorBlendFactor: 0.65, duration: 0.08), .colorize(withColorBlendFactor: 0, duration: 0.14)])) }
            return
        }
        isGrabbed = true
        isThrown = false
        state = .grabbed
        hasResolvedImpact = false
        highestPoint = position.y
        physicsBody?.isDynamic = false
        physicsBody?.affectedByGravity = false
        physicsBody?.velocity = .zero
        physicsBody?.angularVelocity = 0
        removeAction(forKey: "dinerAttack")
        shadowNode.alpha = 0.18
        if !reducedMotion {
            rig.run(.scale(to: 1.08, duration: 0.08), withKey: "grabScale")
            applyGrabbedPose()
        }
    }

    func applyPinch(scale: CGFloat, rotation: CGFloat) {
        guard isGrabbed, !isDefeated else { return }
        rig.setScale(min(1.22, max(0.78, scale)))
        rig.zRotation = min(0.65, max(-0.65, rotation))
    }

    func damageAt(_ scenePoint: CGPoint, amount: CGFloat, canOverkill: Bool = false) -> Bool {
        guard let parent else { return damage(amount, canOverkill: canOverkill) }
        let local = convert(scenePoint, from: parent)
        let preferredPart: RigPart = if local.y > kind.size.height * 0.28 {
            .head
        } else if local.y < -kind.size.height * 0.12 {
            local.x >= 0 ? .frontLeg : .backLeg
        } else {
            local.x >= 0 ? .frontArm : .backArm
        }
        return applyDamage(amount * (local.y > kind.size.height * 0.23 ? 1.75 : 1), canOverkill: canOverkill, preferredPart: preferredPart)
    }

    /// Shared "become airborne" transition for release() (a player flick) and launch() (an
    /// impulse from an explosion, weapon knockback, or zombie collision). If the zombie is
    /// already mid-flight, this preserves the in-progress highestPoint/hasResolvedImpact
    /// tracking instead of resetting it to the current (possibly lower, mid-fall) position —
    /// re-launching a still-airborne zombie used to silently understate its eventual fall
    /// damage by discarding how high it had actually gotten.
    private func beginAirborne() {
        let alreadyAirborne = isThrown && state == .airborne
        isGrabbed = false
        isThrown = true
        state = .airborne
        if alreadyAirborne {
            highestPoint = max(highestPoint, position.y)
        } else {
            hasResolvedImpact = false
            highestPoint = position.y
        }
        physicsBody?.isDynamic = true
        physicsBody?.affectedByGravity = true
    }

    func release(with velocity: CGVector, powerMultiplier: CGFloat) {
        guard !isDefeated else { return }
        beginAirborne()
        wasPlayerThrown = true
        let launchVelocity = CGVector(dx: velocity.dx * powerMultiplier / kind.throwResistance, dy: velocity.dy * powerMultiplier / kind.throwResistance)
        physicsBody?.velocity = launchVelocity
        // Normalized against the flick speed cap (GameRules.maximumFlickSpeed) using the actual
        // post-resistance launch speed, so a fully-resisted riot/butcher/colossus reads as a
        // weaker hit even off a maxed-out flick, matching what the player actually sees fly.
        lastImpactPower = min(1.4, hypot(launchVelocity.dx, launchVelocity.dy) / GameRules.maximumFlickSpeed)
        // Widened from ±8 and given a random jitter on top of the dx-derived spin so throws
        // tumble more and don't all rotate at an identical, predictable rate.
        physicsBody?.angularVelocity = max(-11, min(11, -velocity.dx / 160 + CGFloat.random(in: -1.8...1.8)))
        rig.run(.scale(to: 1, duration: 0.08), withKey: "grabScale")
    }

    func launch(with impulse: CGVector) {
        // A currently-grabbed zombie is under direct player control (see beginGrab and
        // GameScene's touchesMoved/releaseZombie, which keep driving its position/state every
        // frame the finger is down) — an explosion or weapon knockback launching it out from
        // under the player's finger would fight that touch handling, so it's excluded here
        // rather than relying on every caller to remember to check first.
        guard !isDefeated, !isGrabbed else { return }
        beginAirborne()
        // Deliberately NOT resetting wasPlayerThrown here: it's already false unless release()
        // set it, and if it did, this launch is an explosion/knockback catching a zombie that's
        // still mid-flight from the player's own throw — that shouldn't erase the credit before
        // it lands (see GameScene's GRACEFUL_WAVE tracking). resumeWalking() is the actual reset
        // point, once the flight fully resolves.
        // Magnitude is intentionally NOT divided by kind.throwResistance here, unlike release():
        // explodeVolatile/fireScatterblast/throwExplosive already tune their radialImpulse
        // constants per-weapon assuming this applies them as-is, and dividing again here would
        // quietly weaken every one of those against riot/butcher/colossus. GameScene.knockback
        // applies its own throwResistance scaling before calling this, for the caller that wants
        // per-kind resistance without touching the pre-tuned explosion/scatter constants.
        physicsBody?.applyImpulse(impulse)
        // Spin kick — applyImpulse alone (no offset point) imparts no torque, which used to leave
        // explosion/collision knockbacks flying dead straight with no tumble.
        physicsBody?.angularVelocity = max(-10, min(10, -impulse.dx / 55 + CGFloat.random(in: -2.2...2.2)))
        // Impulse and flick velocity aren't directly comparable units, but knockback()'s clamped
        // ranges and the explosion radialImpulse constants both land roughly in 90...760, so 500
        // is a reasonable estimate to put a knockback-driven impact on the same 0...1.4 power
        // scale a player flick produces.
        lastImpactPower = min(1.4, hypot(impulse.dx, impulse.dy) / 500)
    }

    /// `power` (0...1.4, see `lastImpactPower`) exaggerates the squash/rebound for a harder-hit
    /// landing — a tiny stumble barely dips, a monster slam flattens dramatically — so the same
    /// impact pose reads as proportionally more violent instead of identical at every speed.
    func playImpact(reducedMotion: Bool, power: CGFloat = 0) {
        guard !isDefeated else { return }
        state = .impact
        shadowNode.alpha = 0.42
        guard !reducedMotion else { return }

        let punch = max(0, min(1.4, power))
        rig.removeAction(forKey: "impact")
        let squash = SKAction.group([
            .scaleX(to: 1.24 + punch * 0.20, duration: 0.055),
            .scaleY(to: 0.68 - punch * 0.16, duration: 0.055),
            .moveBy(x: 0, y: -4 - punch * 3, duration: 0.055)
        ])
        let rebound = SKAction.group([
            .scaleX(to: 0.94 - punch * 0.06, duration: 0.09),
            .scaleY(to: 1.08 + punch * 0.12, duration: 0.09),
            .moveBy(x: 0, y: 4 + punch * 2, duration: 0.09)
        ])
        let settle = SKAction.group([
            .scaleX(to: 1, duration: 0.12),
            .scaleY(to: 1, duration: 0.12)
        ])
        rig.run(.sequence([squash, rebound, settle]), withKey: "impact")
        setRotation(.frontArm, offset: 0.92)
        setRotation(.backArm, offset: -0.86)
        setRotation(.frontLeg, offset: -0.72)
        setRotation(.backLeg, offset: 0.66)
        setRotation(.head, offset: -0.28)
    }

    func resumeWalking(on groundY: CGFloat) {
        guard !isDefeated else { return }
        isThrown = false
        hasResolvedImpact = false
        state = .recovering
        recoveryTime = 0.18
        zRotation = 0
        physicsBody?.isDynamic = false
        physicsBody?.affectedByGravity = false
        physicsBody?.velocity = .zero
        physicsBody?.angularVelocity = 0
        // Cleared on a safe landing so a later, unrelated kill (weapon/trap/collision, with no
        // throw of its own) doesn't inherit this throw's impact-feedback power (see
        // lastImpactPower).
        lastImpactPower = 0
        wasPlayerThrown = false
        // Unconditional, not max(position.y, ...): physics is disabled right after this and never
        // touches position.y again until the next throw, so if the impact bounce left the zombie
        // still elevated when this fires, max() would let it walk stuck at that height forever.
        position.y = groundY + kind.size.height * 0.39 + 2
        shadowNode.alpha = 1
        rig.removeAction(forKey: "impact")
        rig.run(.group([
            .scaleX(to: 1, duration: recoveryTime),
            .scaleY(to: 1, duration: recoveryTime),
            .move(to: .zero, duration: recoveryTime),
            .rotate(toAngle: 0, duration: recoveryTime, shortestUnitArc: true)
        ]))
        for (part, pose) in restPose {
            sprites[part]?.run(.group([
                .move(to: pose.position, duration: recoveryTime),
                .rotate(toAngle: pose.rotation, duration: recoveryTime, shortestUnitArc: true)
            ]))
        }
    }

    func playSpawn(reducedMotion: Bool) {
        guard !reducedMotion else { return }
        let travel: CGFloat = approachesFromLeft ? 34 : -34
        alpha = 0
        rig.position.x = -travel
        rig.xScale = 0.78
        rig.yScale = 1.18
        run(.fadeIn(withDuration: 0.16))
        rig.run(.sequence([
            .group([.moveBy(x: travel * 1.12, y: 0, duration: 0.18), .scaleX(to: 1.08, duration: 0.18), .scaleY(to: 0.92, duration: 0.18)]),
            .group([.moveBy(x: -travel * 0.12, y: 0, duration: 0.11), .scaleX(to: 1, duration: 0.11), .scaleY(to: 1, duration: 0.11)])
        ]), withKey: "spawn")
    }

    /// Zombie Smash-style: reaching the diner doesn't kill the zombie, it starts a repeating bite
    /// loop (paced by `dinerAttackCooldown`) that only stops when the player actually kills it —
    /// see `resolveDinerAttack` in GameScene, which no longer calls `playDefeat` after a hit.
    @discardableResult
    func playDinerAttack(reducedMotion: Bool, completion: @escaping () -> Void) -> Bool {
        guard !isDefeated, state != .attacking, dinerAttackCooldown <= 0 else { return false }
        state = .attacking
        dinerAttackCooldown = 1.1
        physicsBody?.isDynamic = false
        physicsBody?.velocity = .zero
        let direction: CGFloat = approachesFromLeft ? 1 : -1

        if reducedMotion {
            run(.sequence([.wait(forDuration: 0.12), .run { [weak self] in self?.state = .holdingAtDiner; completion() }]), withKey: "dinerAttack")
            return true
        }

        let attack: [SKAction]
        switch kind {
        case .runner, .waitress:
            setRotation(.frontArm, offset: -1.18)
            setRotation(.backArm, offset: 0.62)
            attack = [.group([.moveBy(x: -direction * 13, y: 0, duration: 0.08), .rotate(toAngle: -direction * 0.15, duration: 0.08)]),
                      .group([.moveBy(x: direction * 32, y: 1, duration: 0.055), .rotate(toAngle: direction * 0.18, duration: 0.055)]),
                      .group([.moveBy(x: -direction * 19, y: -1, duration: 0.12), .rotate(toAngle: 0, duration: 0.12)])]
        case .crawler:
            setRotation(.frontArm, offset: -0.98)
            setRotation(.backArm, offset: -0.72)
            attack = [.group([.moveBy(x: -direction * 5, y: -4, duration: 0.10), .scaleY(to: 0.76, duration: 0.10)]),
                      .group([.moveBy(x: direction * 24, y: 10, duration: 0.09), .scaleY(to: 1.12, duration: 0.09)]),
                      .group([.moveBy(x: -direction * 19, y: -6, duration: 0.12), .scaleY(to: 1, duration: 0.12)])]
        case .brute, .groundskeeper:
            setRotation(.frontArm, offset: -1.32)
            setRotation(.backArm, offset: -1.04)
            attack = [.group([.moveBy(x: -direction * 10, y: 5, duration: 0.18), .scale(to: 1.08, duration: 0.18)]),
                      .group([.moveBy(x: direction * 27, y: -7, duration: 0.10), .scaleX(to: 1.15, duration: 0.10), .scaleY(to: 0.88, duration: 0.10)]),
                      .group([.moveBy(x: -direction * 17, y: 2, duration: 0.18), .scale(to: 1, duration: 0.18)])]
        case .armored, .riot, .bouncer:
            setRotation(.frontArm, offset: -0.54)
            attack = [.group([.moveBy(x: -direction * 8, y: 0, duration: 0.14), .rotate(toAngle: -direction * 0.12, duration: 0.14)]),
                      .group([.moveBy(x: direction * 25, y: 0, duration: 0.09), .rotate(toAngle: direction * 0.22, duration: 0.09)]),
                      .group([.moveBy(x: -direction * 17, y: 0, duration: 0.14), .rotate(toAngle: 0, duration: 0.14)])]
        case .volatile:
            setRotation(.frontArm, offset: -0.72)
            setRotation(.backArm, offset: -0.72)
            attack = [.group([.moveBy(x: -direction * 6, y: 0, duration: 0.12), .scale(to: 1.16, duration: 0.12)]),
                      .group([.moveBy(x: direction * 22, y: 2, duration: 0.075), .scale(to: 0.92, duration: 0.075)]),
                      .group([.moveBy(x: -direction * 16, y: -2, duration: 0.13), .scale(to: 1, duration: 0.13)])]
        case .butcher:
            setRotation(.frontArm, offset: -1.48)
            setRotation(.backArm, offset: -1.12)
            attack = [.group([.moveBy(x: -direction * 14, y: 9, duration: 0.24), .scale(to: 1.1, duration: 0.24)]),
                      .group([.moveBy(x: direction * 39, y: -12, duration: 0.11), .rotate(toAngle: direction * 0.24, duration: 0.11)]),
                      .group([.moveBy(x: -direction * 25, y: 3, duration: 0.22), .scale(to: 1, duration: 0.22), .rotate(toAngle: 0, duration: 0.22)])]
        case .colossus:
            setRotation(.frontArm, offset: -1.62)
            setRotation(.backArm, offset: 0.48)
            attack = [.group([.moveBy(x: -direction * 18, y: 4, duration: 0.28), .scaleX(to: 1.12, duration: 0.28)]),
                      .group([.moveBy(x: direction * 46, y: -9, duration: 0.12), .scaleY(to: 0.82, duration: 0.12)]),
                      .group([.moveBy(x: -direction * 28, y: 5, duration: 0.25), .scale(to: 1, duration: 0.25)])]
        case .walker:
            setRotation(.head, offset: -0.22)
            setRotation(.frontArm, offset: -0.88)
            setRotation(.backArm, offset: -0.52)
            attack = [.group([.moveBy(x: -direction * 7, y: 0, duration: 0.11), .rotate(toAngle: -direction * 0.09, duration: 0.11)]),
                      .group([.moveBy(x: direction * 20, y: 2, duration: 0.08), .rotate(toAngle: direction * 0.12, duration: 0.08)]),
                      .group([.moveBy(x: -direction * 13, y: -2, duration: 0.10), .rotate(toAngle: 0, duration: 0.10)])]
        }
        rig.run(.sequence(attack + [.run { [weak self] in self?.state = .holdingAtDiner; completion() }]), withKey: "dinerAttack")
        return true
    }

    @discardableResult
    func damage(_ amount: CGFloat, canOverkill: Bool = false) -> Bool {
        applyDamage(amount, canOverkill: canOverkill, preferredPart: nil)
    }

    @discardableResult
    private func applyDamage(_ amount: CGFloat, canOverkill: Bool, preferredPart: RigPart?) -> Bool {
        guard !isDefeated else { return true }
        guard damageProtectionRemaining <= 0 else { return false }

        let appliedDamage: CGFloat
        if !canOverkill, !kind.isBoss, !hasTakenOrdinaryHit {
            let healthFloor = maximumHealth * kind.firstHitHealthFloor
            appliedDamage = min(amount, max(0, health - healthFloor))
            hasTakenOrdinaryHit = true
        } else {
            appliedDamage = amount
        }
        health -= appliedDamage
        damageProtectionRemaining = canOverkill ? 0.04 : 0.11
        if kind.isBoss {
            let fraction = max(0, health / maximumHealth)
            let nextPhase = fraction <= 0.33 ? 3 : (fraction <= 0.66 ? 2 : 1)
            if nextPhase != bossPhase {
                bossPhase = nextPhase
                onBossPhaseChanged?(nextPhase)
                abilityTime = max(abilityTime, 3)
                applyBossPhaseTint()
                rig.run(.sequence([.scale(to: 1.1, duration: 0.16), .scale(to: 1, duration: 0.16)]), withKey: "bossPhase")
            }
        }
        if kind.isBoss, !bossIsStunned {
            bossStunDamage += appliedDamage
            if bossStunDamage >= maximumHealth * 0.12 {
                bossIsStunned = true
                bossStunDamage = 0
                slowTime = 4
                sprites.values.forEach {
                    $0.color = .cyan
                    $0.colorBlendFactor = 0.28
                }
                run(.sequence([.wait(forDuration: 4), .run { [weak self] in
                    self?.bossIsStunned = false
                    self?.applyBossPhaseTint()
                }]), withKey: "bossStun")
            }
        }
        onHealthChanged?(healthFraction)
        healthBarTrack.isHidden = false
        healthBarFill.xScale = max(0.02, healthFraction)
        healthBarFill.color = healthFraction > 0.62
            ? SKColor(red: 0.34, green: 0.90, blue: 0.32, alpha: 1)
            : (healthFraction > 0.30 ? .yellow : SKColor(red: 0.94, green: 0.18, blue: 0.12, alpha: 1))
        hitReactionTime = 0.16
        for sprite in sprites.values {
            sprite.run(.sequence([
                .colorize(with: .white, colorBlendFactor: 0.9, duration: 0.04),
                .colorize(withColorBlendFactor: 0, duration: 0.12)
            ]))
        }
        if state == .walking {
            let direction: CGFloat = approachesFromLeft ? -1 : 1
            rig.run(.sequence([
                .moveBy(x: direction * 7, y: 2, duration: 0.04),
                .moveBy(x: -direction * 7, y: -2, duration: 0.10)
            ]), withKey: "hit")
        }
        if (kind == .armored || kind == .riot), !armorBroken, health <= maximumHealth * 0.48 {
            armorBroken = true
            playArmorBreak()
            onArmorBroken?()
        }
        if kind == .volatile, !volatileWarningActive, health <= maximumHealth * 0.55 {
            volatileWarningActive = true
            playVolatileWarning()
        }
        if health > 0, !kind.isBoss {
            maybeSeverLimb(preferred: preferredPart, impactDamage: appliedDamage)
        }
        return health <= 0
    }

    private func maybeSeverLimb(preferred: RigPart?, impactDamage: CGFloat) {
        guard dismembermentEnabled else { return }
        let targetSeverCount = healthFraction <= 0.30 ? 2 : (healthFraction <= 0.68 ? 1 : 0)
        let targetedHeavyHit = preferred != nil && healthFraction <= 0.74 && impactDamage >= maximumHealth * 0.22
        guard severedLimbCount < targetSeverCount || targetedHeavyHit else { return }

        let ordinaryLimbs: [RigPart] = [.frontArm, .backArm, .frontLeg, .backLeg]
        let preferredIsAllowed = preferred != .head || healthFraction <= 0.42
        let candidate = if let preferred, preferredIsAllowed, !severedParts.contains(preferred) {
            preferred
        } else {
            ordinaryLimbs.first { !severedParts.contains($0) }
        }
        guard let candidate else { return }
        sever(candidate)
    }

    private func sever(_ part: RigPart) {
        guard part != .torso,
              !severedParts.contains(part),
              let sprite = sprites[part],
              let texture = sprite.texture,
              let parent else { return }

        let localPoint = convert(sprite.position, from: rig)
        let debris = SKSpriteNode(texture: texture, size: sprite.size)
        debris.position = parent.convert(localPoint, from: self)
        debris.zPosition = zPosition + 12
        debris.zRotation = zRotation + rig.zRotation + sprite.zRotation
        debris.xScale = xScale
        debris.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: max(8, sprite.size.width * 0.62), height: max(8, sprite.size.height * 0.62)))
        debris.physicsBody?.mass = part == .head ? 0.46 : 0.34
        debris.physicsBody?.restitution = 0.48
        debris.physicsBody?.friction = 0.68
        debris.physicsBody?.categoryBitMask = PhysicsCategory.none
        debris.physicsBody?.collisionBitMask = PhysicsCategory.ground | PhysicsCategory.boundary
        parent.addChild(debris)

        let direction: CGFloat = approachesFromLeft ? -1 : 1
        debris.physicsBody?.applyImpulse(CGVector(dx: direction * CGFloat.random(in: 55...115), dy: CGFloat.random(in: 95...165)))
        debris.physicsBody?.angularVelocity = CGFloat.random(in: -8...8)
        debris.run(.sequence([.wait(forDuration: 2.2), .fadeOut(withDuration: 0.55), .removeFromParent()]))

        sprite.removeFromParent()
        sprites[part] = nil
        severedParts.insert(part)
        severedLimbCount += 1

        let wound = SKShapeNode(circleOfRadius: part == .head ? 6 : 4)
        wound.fillColor = SKColor(red: 0.42, green: 0.03, blue: 0.02, alpha: 0.92)
        wound.strokeColor = SKColor(red: 0.80, green: 0.12, blue: 0.05, alpha: 0.72)
        wound.lineWidth = 1
        wound.position = localPoint
        wound.zPosition = 5
        addChild(wound)
        wound.run(.sequence([.fadeAlpha(to: 0.58, duration: 0.22), .wait(forDuration: 1.1), .fadeOut(withDuration: 0.45), .removeFromParent()]))
    }

    /// Reapplies the current bossPhase's enrage tint (or clears it in phase 1). Called both on a
    /// phase transition and when a stun wears off, so un-stunning doesn't reset an enraged boss
    /// back to its neutral color.
    private func applyBossPhaseTint() {
        guard kind.isBoss else { return }
        if bossPhase >= 2 {
            let tint: SKColor = bossPhase >= 3 ? .red : .orange
            sprites.values.forEach { $0.color = tint; $0.colorBlendFactor = 0.18 }
        } else {
            sprites.values.forEach { $0.colorBlendFactor = 0 }
        }
    }

    /// Rust-brown "exposed" color for a health-threshold armor-crack cosmetic — see playArmorBreak.
    private var armorExposedTint: SKColor { SKColor(red: 0.46, green: 0.25, blue: 0.18, alpha: 1) }

    private func playArmorBreak() {
        guard let torso = sprites[.torso] else { return }
        torso.color = armorExposedTint
        torso.colorBlendFactor = 0.28
        for index in 0..<5 {
            let shard = SKShapeNode(rectOf: CGSize(width: 7, height: 4), cornerRadius: 1)
            shard.fillColor = .darkGray
            shard.strokeColor = .yellow.withAlphaComponent(0.7)
            shard.position = CGPoint(x: 0, y: kind.size.height * 0.14)
            shard.zPosition = 14
            addChild(shard)
            let destination = CGPoint(x: CGFloat(index - 2) * 15, y: CGFloat(22 + index * 4))
            shard.run(.sequence([.group([.move(to: destination, duration: 0.28), .rotate(byAngle: CGFloat(index - 2), duration: 0.28), .fadeOut(withDuration: 0.32)]), .removeFromParent()]))
        }
    }

    private func playVolatileWarning() {
        let pulse = SKAction.sequence([
            .group([.scale(to: 1.08, duration: 0.16), .colorize(with: .orange, colorBlendFactor: 0.48, duration: 0.16)]),
            .group([.scale(to: 1, duration: 0.18), .colorize(withColorBlendFactor: 0.08, duration: 0.18)])
        ])
        rig.run(.repeatForever(pulse), withKey: "volatileWarning")
    }

    func playDefeat(style: ZombieDefeatStyle = .pavement, reducedMotion: Bool, completion: @escaping () -> Void) {
        guard !isDefeated else { return }
        isDefeated = true
        isGrabbed = false
        isThrown = false
        state = .defeated
        physicsBody?.categoryBitMask = PhysicsCategory.none
        physicsBody?.collisionBitMask = PhysicsCategory.none
        physicsBody?.contactTestBitMask = PhysicsCategory.none
        physicsBody?.isDynamic = false
        healthBarTrack.isHidden = true
        shadowNode.run(.fadeOut(withDuration: 0.22))

        let duration: TimeInterval = reducedMotion ? 0.28 : 0.62
        let parts = RigPart.allCases
        for (index, part) in parts.enumerated() {
            guard let sprite = sprites[part] else { continue }
            sprite.removeAllActions()
            let styleDirection: CGFloat = switch style {
            case .thrownOut: approachesFromLeft ? 1 : -1
            case .collision: index.isMultiple(of: 2) ? -1 : 1
            default: index.isMultiple(of: 2) ? 1 : -1
            }
            let kindForce: CGFloat = switch kind {
            case .brute, .groundskeeper: 0.72
            case .runner, .waitress: 1.28
            case .crawler: 0.88
            case .volatile: 1.22
            case .riot: 0.68
            case .butcher: 0.48
            case .colossus: 0.38
            case .bouncer: 0.55
            default: 1
            }
            let styleForce: CGFloat = switch style {
            case .explosion: 1.9
            case .weapon: 1.45
            case .trap: 0.72
            default: 1
            }
            let force = kindForce * styleForce
            let horizontal = styleDirection * CGFloat(24 + index * 7) * force
            let vertical = CGFloat(18 + (index % 3) * 12) * force
            let scatter = reducedMotion ? SKAction.wait(forDuration: 0) : .group([
                .moveBy(x: horizontal, y: vertical, duration: duration),
                .rotate(byAngle: CGFloat(index % 2 == 0 ? 1 : -1) * (1.1 + CGFloat(index) * 0.27), duration: duration)
            ])
            sprite.run(.sequence([
                .group([scatter, .fadeOut(withDuration: duration)]),
                .removeFromParent()
            ]))
        }

        run(.sequence([
            .wait(forDuration: duration),
            .run(completion),
            .removeFromParent()
        ]), withKey: "defeat")
    }

    func makePhysicsDebris() -> [SKSpriteNode] {
        RigPart.allCases.compactMap { part in
            guard let source = sprites[part], let texture = source.texture else { return nil }
            let debris = SKSpriteNode(texture: texture, size: source.size)
            debris.position = convert(source.position, from: rig)
            debris.zRotation = source.zRotation + zRotation
            debris.xScale = xScale
            debris.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: source.size.width * 0.7, height: source.size.height * 0.7))
            debris.physicsBody?.mass = kind.isBoss ? 0.9 : 0.38
            debris.physicsBody?.restitution = 0.55
            debris.physicsBody?.friction = 0.65
            debris.physicsBody?.categoryBitMask = PhysicsCategory.none
            debris.physicsBody?.collisionBitMask = PhysicsCategory.ground | PhysicsCategory.boundary
            return debris
        }
    }

    func slow(for duration: TimeInterval, reducedMotion: Bool = false) {
        slowTime = max(slowTime, duration)
        for sprite in sprites.values {
            sprite.color = .cyan
            sprite.colorBlendFactor = 0.28
        }
        showFrozenOverlay(reducedMotion: reducedMotion)
        run(.sequence([
            .wait(forDuration: max(0, duration - 0.55)),
            .run { [weak self] in self?.playThaw() },
            .wait(forDuration: 0.55),
            .run { [weak self] in
                self?.sprites.values.forEach { $0.colorBlendFactor = 0 }
            }
        ]), withKey: "slow")
    }

    /// Flash Freezer: turns the zombie into a real dynamic physics body for the duration instead
    /// of the walk-speed-only slow `slow(for:)` applies — it can be knocked around, falls under
    /// gravity, and (via `frozenImpactDamageMultiplier`) shatters for much higher damage on its
    /// next impact.
    func freezeSolid(for duration: TimeInterval, reducedMotion: Bool) {
        guard !isDefeated, !isGrabbed, !isThrown, state != .attacking else { return }
        isFrozenSolid = true
        state = .frozen
        physicsBody?.isDynamic = true
        physicsBody?.affectedByGravity = true
        physicsBody?.velocity = .zero
        physicsBody?.angularVelocity = 0
        for sprite in sprites.values {
            sprite.color = .cyan
            sprite.colorBlendFactor = 0.28
        }
        showFrozenOverlay(reducedMotion: reducedMotion)
        run(.sequence([
            .wait(forDuration: duration),
            .run { [weak self] in self?.thawFromSolid() }
        ]), withKey: "frozenSolid")
    }

    /// Only resets physics/state if the zombie is still passively `.frozen` — if it's been
    /// grabbed, thrown, or is mid-recovery from a landing since freezing, that logic already owns
    /// `physicsBody`/`state` and resetting them here would fight it.
    private func thawFromSolid() {
        guard isFrozenSolid else { return }
        isFrozenSolid = false
        sprites.values.forEach { $0.colorBlendFactor = 0 }
        playThaw()
        guard !isDefeated, !isGrabbed, !isThrown, state == .frozen else { return }
        state = .recovering
        recoveryTime = 0.18
        physicsBody?.isDynamic = false
        physicsBody?.affectedByGravity = false
        physicsBody?.velocity = .zero
        physicsBody?.angularVelocity = 0
    }

    private func showFrozenOverlay(reducedMotion: Bool) {
        freezeOverlay?.removeFromParent()
        let overlay = SKNode()
        overlay.zPosition = 15
        for index in 0..<7 {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 14))
            path.addLine(to: CGPoint(x: -5, y: -5))
            path.addLine(to: CGPoint(x: 5, y: -5))
            path.closeSubpath()
            let crystal = SKShapeNode(path: path)
            crystal.fillColor = .cyan.withAlphaComponent(0.46)
            crystal.strokeColor = .white.withAlphaComponent(0.78)
            crystal.lineWidth = 1
            crystal.position = CGPoint(x: CGFloat(index - 3) * kind.size.width * 0.10, y: -kind.size.height * 0.34 + CGFloat(index % 2) * 5)
            crystal.zRotation = CGFloat(index - 3) * 0.08
            overlay.addChild(crystal)
        }
        addChild(overlay)
        freezeOverlay = overlay
        overlay.setScale(reducedMotion ? 1 : 0.25)
        overlay.alpha = reducedMotion ? 0.75 : 0
        if !reducedMotion {
            overlay.run(.group([.scale(to: 1, duration: 0.16), .fadeAlpha(to: 0.82, duration: 0.12)]))
            rig.run(.repeatForever(.sequence([.moveBy(x: -1.5, y: 0, duration: 0.055), .moveBy(x: 3, y: 0, duration: 0.055), .moveBy(x: -1.5, y: 0, duration: 0.055), .wait(forDuration: 0.52)])), withKey: "frozenShiver")
        }
    }

    private func playThaw() {
        rig.removeAction(forKey: "frozenShiver")
        freezeOverlay?.run(.sequence([.group([.scale(to: 1.18, duration: 0.20), .fadeOut(withDuration: 0.28)]), .removeFromParent()]))
        freezeOverlay = nil
    }
}
