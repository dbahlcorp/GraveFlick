import SpriteKit

enum ZombieKind: String, CaseIterable, Codable {
    case walker
    case runner
    case brute
    case crawler
    case armored
    case volatile

    var assetName: String { rawValue }

    var size: CGSize {
        switch self {
        case .walker: CGSize(width: 72, height: 112)
        case .runner: CGSize(width: 72, height: 108)
        case .brute: CGSize(width: 106, height: 132)
        case .crawler: CGSize(width: 105, height: 72)
        case .armored: CGSize(width: 84, height: 120)
        case .volatile: CGSize(width: 104, height: 126)
        }
    }

    var speed: CGFloat {
        switch self {
        case .walker: 42
        case .runner: 76
        case .brute: 27
        case .crawler: 58
        case .armored: 34
        case .volatile: 38
        }
    }

    var hitPoints: CGFloat {
        switch self {
        case .walker: 1
        case .runner: 0.8
        case .brute: 3.2
        case .crawler: 1.25
        case .armored: 2.8
        case .volatile: 1.8
        }
    }

    var defeatImpulse: CGFloat {
        switch self {
        case .walker: 22
        case .runner: 18
        case .brute: 48
        case .crawler: 25
        case .armored: 42
        case .volatile: 30
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
        }
    }

    var dinerDamage: Int { self == .brute || self == .volatile ? 2 : 1 }
}

private enum RigPart: CaseIterable {
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

private enum RigState {
    case walking
    case grabbed
    case airborne
    case impact
    case recovering
    case defeated
}

final class ZombieNode: SKNode {
    let kind: ZombieKind
    let approachesFromLeft: Bool
    var isGrabbed = false
    var isThrown = false
    private(set) var isDefeated = false
    var hasResolvedImpact = false
    var highestPoint: CGFloat = 0
    private(set) var health: CGFloat

    private let rig = SKNode()
    private let shadowNode: SKShapeNode
    private let healthBar = SKShapeNode(rectOf: CGSize(width: 44, height: 5), cornerRadius: 2.5)
    private var sprites: [RigPart: SKSpriteNode] = [:]
    private var restPose: [RigPart: PartPose] = [:]
    private var walkPhase: CGFloat = 0
    private var slowTime: TimeInterval = 0
    private var recoveryTime: TimeInterval = 0
    private var hitReactionTime: TimeInterval = 0
    private var state: RigState = .walking

    var hasCompleteAnimationRig: Bool {
        sprites.count == RigPart.allCases.count && sprites.values.allSatisfy {
            guard let texture = $0.texture else { return false }
            return texture.size().width > 1 && texture.size().height > 1
        }
    }

    init(kind: ZombieKind, approachesFromLeft: Bool) {
        self.kind = kind
        self.approachesFromLeft = approachesFromLeft
        health = kind.hitPoints

        shadowNode = SKShapeNode(ellipseOf: CGSize(width: kind.size.width * 0.72, height: 16))
        shadowNode.fillColor = .black.withAlphaComponent(0.34)
        shadowNode.strokeColor = .clear
        shadowNode.position.y = -kind.size.height * 0.43

        super.init()

        name = "zombie"
        addChild(shadowNode)
        addChild(rig)
        buildRig()

        healthBar.fillColor = SKColor(red: 0.92, green: 0.24, blue: 0.18, alpha: 1)
        healthBar.strokeColor = .black.withAlphaComponent(0.55)
        healthBar.lineWidth = 1.5
        healthBar.position.y = kind.size.height * 0.56
        healthBar.isHidden = true
        healthBar.zPosition = 12
        addChild(healthBar)

        let physicsSize = CGSize(width: kind.size.width * 0.68, height: kind.size.height * 0.78)
        physicsBody = SKPhysicsBody(rectangleOf: physicsSize, center: CGPoint(x: 0, y: -kind.size.height * 0.04))
        physicsBody?.isDynamic = false
        physicsBody?.allowsRotation = true
        physicsBody?.restitution = kind == .brute ? 0.16 : 0.30
        physicsBody?.friction = 0.74
        physicsBody?.linearDamping = 0.17
        physicsBody?.angularDamping = 0.34
        physicsBody?.mass = kind == .brute ? 2.4 : (kind == .crawler ? 0.75 : 1.1)
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
            let lean: CGFloat = kind == .runner ? -0.12 : (kind == .brute ? 0.03 : -0.035)
            restPose = [
                .torso: PartPose(position: CGPoint(x: 0, y: kind.size.height * 0.02), rotation: lean),
                .head: PartPose(position: CGPoint(x: torsoWidth * 0.17, y: torsoHeight * 0.38), rotation: lean * 0.45),
                .backArm: PartPose(position: CGPoint(x: torsoWidth * 0.03, y: torsoHeight * 0.30), rotation: kind == .runner ? 0.38 : 0.10),
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
        guard !isDefeated else { return }

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

        if state == .impact { return }
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
        position.x += direction * kind.speed * slowMultiplier * CGFloat(deltaTime)
        guard !reducedMotion else { return }

        let cadence: CGFloat = kind == .runner ? 12.5 : (kind == .crawler ? 10.5 : (kind == .brute ? 6.2 : 8.2))
        walkPhase += CGFloat(deltaTime) * cadence * slowMultiplier
        applyWalkingPose()
    }

    private func applyWalkingPose() {
        let stride = sin(walkPhase)
        let counterStride = sin(walkPhase + .pi)
        let bob = abs(sin(walkPhase))
        let amplitude: CGFloat = kind == .runner ? 0.34 : (kind == .brute ? 0.16 : (kind == .crawler ? 0.24 : 0.25))
        let hitLean: CGFloat = hitReactionTime > 0 ? -0.18 : 0

        rig.position.y = bob * (kind == .brute ? 1.4 : 2.7)
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
        guard !isDefeated else { return }
        isGrabbed = true
        isThrown = false
        state = .grabbed
        hasResolvedImpact = false
        highestPoint = position.y
        physicsBody?.isDynamic = false
        physicsBody?.affectedByGravity = false
        physicsBody?.velocity = .zero
        physicsBody?.angularVelocity = 0
        removeAllActions()
        shadowNode.alpha = 0.18
        if !reducedMotion {
            rig.run(.scale(to: 1.08, duration: 0.08), withKey: "grabScale")
            applyGrabbedPose()
        }
    }

    func release(with velocity: CGVector, powerMultiplier: CGFloat) {
        guard !isDefeated else { return }
        isGrabbed = false
        isThrown = true
        state = .airborne
        hasResolvedImpact = false
        highestPoint = position.y
        physicsBody?.isDynamic = true
        physicsBody?.affectedByGravity = true
        physicsBody?.velocity = CGVector(dx: velocity.dx * powerMultiplier, dy: velocity.dy * powerMultiplier)
        physicsBody?.angularVelocity = max(-8, min(8, -velocity.dx / 175))
        rig.run(.scale(to: 1, duration: 0.08), withKey: "grabScale")
    }

    func launch(with impulse: CGVector) {
        guard !isDefeated else { return }
        isGrabbed = false
        isThrown = true
        state = .airborne
        hasResolvedImpact = false
        highestPoint = position.y
        physicsBody?.isDynamic = true
        physicsBody?.affectedByGravity = true
        physicsBody?.applyImpulse(impulse)
    }

    func playImpact(reducedMotion: Bool) {
        guard !isDefeated else { return }
        state = .impact
        shadowNode.alpha = 0.42
        guard !reducedMotion else { return }

        rig.removeAction(forKey: "impact")
        let squash = SKAction.group([
            .scaleX(to: 1.24, duration: 0.055),
            .scaleY(to: 0.68, duration: 0.055),
            .moveBy(x: 0, y: -4, duration: 0.055)
        ])
        let rebound = SKAction.group([
            .scaleX(to: 0.94, duration: 0.09),
            .scaleY(to: 1.08, duration: 0.09),
            .moveBy(x: 0, y: 4, duration: 0.09)
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
        position.y = max(position.y, groundY + kind.size.height * 0.39 + 2)
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

    @discardableResult
    func damage(_ amount: CGFloat) -> Bool {
        guard !isDefeated else { return true }
        health -= amount
        healthBar.isHidden = false
        healthBar.xScale = max(0.05, health / kind.hitPoints)
        hitReactionTime = 0.16
        for sprite in sprites.values {
            sprite.run(.sequence([
                .colorize(with: .white, colorBlendFactor: 0.9, duration: 0.04),
                .colorize(withColorBlendFactor: 0, duration: 0.12)
            ]))
        }
        if state == .walking {
            rig.run(.sequence([
                .moveBy(x: -5, y: 1, duration: 0.04),
                .moveBy(x: 5, y: -1, duration: 0.10)
            ]), withKey: "hit")
        }
        return health <= 0
    }

    func playDefeat(reducedMotion: Bool, completion: @escaping () -> Void) {
        guard !isDefeated else { return }
        isDefeated = true
        isGrabbed = false
        isThrown = false
        state = .defeated
        physicsBody?.categoryBitMask = PhysicsCategory.none
        physicsBody?.collisionBitMask = PhysicsCategory.none
        physicsBody?.contactTestBitMask = PhysicsCategory.none
        physicsBody?.isDynamic = false
        healthBar.isHidden = true
        shadowNode.run(.fadeOut(withDuration: 0.22))

        let duration: TimeInterval = reducedMotion ? 0.28 : 0.62
        let parts = RigPart.allCases
        for (index, part) in parts.enumerated() {
            guard let sprite = sprites[part] else { continue }
            sprite.removeAllActions()
            let horizontal = CGFloat((index % 2 == 0 ? 1 : -1) * (24 + index * 7))
            let vertical = CGFloat(18 + (index % 3) * 12)
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

    func slow(for duration: TimeInterval) {
        slowTime = max(slowTime, duration)
        for sprite in sprites.values {
            sprite.color = .cyan
            sprite.colorBlendFactor = 0.28
        }
        run(.sequence([
            .wait(forDuration: duration),
            .run { [weak self] in
                self?.sprites.values.forEach { $0.colorBlendFactor = 0 }
            }
        ]), withKey: "slow")
    }
}
