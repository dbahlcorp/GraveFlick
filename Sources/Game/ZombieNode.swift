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

final class ZombieNode: SKNode {
    let kind: ZombieKind
    let approachesFromLeft: Bool
    var isGrabbed = false
    var isThrown = false
    private(set) var isDefeated = false
    var hasResolvedImpact = false
    var highestPoint: CGFloat = 0
    private(set) var health: CGFloat

    private let art: SKSpriteNode
    private let shadowNode: SKShapeNode
    private let healthBar = SKShapeNode(rectOf: CGSize(width: 44, height: 5), cornerRadius: 2.5)
    private var walkPhase: CGFloat = 0
    private var slowTime: TimeInterval = 0

    init(kind: ZombieKind, approachesFromLeft: Bool) {
        self.kind = kind
        self.approachesFromLeft = approachesFromLeft
        health = kind.hitPoints

        let texture = SKTexture(imageNamed: kind.assetName)
        texture.filteringMode = .linear
        art = SKSpriteNode(texture: texture, size: kind.size)
        art.anchorPoint = CGPoint(x: 0.5, y: 0.43)

        shadowNode = SKShapeNode(ellipseOf: CGSize(width: kind.size.width * 0.72, height: 16))
        shadowNode.fillColor = .black.withAlphaComponent(0.34)
        shadowNode.strokeColor = .clear
        shadowNode.position.y = -kind.size.height * 0.43

        super.init()

        name = "zombie"
        addChild(shadowNode)
        addChild(art)
        healthBar.fillColor = SKColor(red: 0.92, green: 0.24, blue: 0.18, alpha: 1)
        healthBar.strokeColor = .black.withAlphaComponent(0.55)
        healthBar.lineWidth = 1.5
        healthBar.position.y = kind.size.height * 0.56
        healthBar.isHidden = true
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

    func updateWalking(deltaTime: TimeInterval, reducedMotion: Bool) {
        if slowTime > 0 { slowTime -= deltaTime }
        guard !isGrabbed, !isThrown else {
            highestPoint = max(highestPoint, position.y)
            return
        }
        let direction: CGFloat = approachesFromLeft ? 1 : -1
        let slowMultiplier: CGFloat = slowTime > 0 ? 0.42 : 1
        position.x += direction * kind.speed * slowMultiplier * CGFloat(deltaTime)
        guard !reducedMotion else { return }
        walkPhase += CGFloat(deltaTime) * (kind == .runner ? 12 : 8)
        art.zRotation = sin(walkPhase) * (kind == .crawler ? 0.035 : 0.06)
        art.position.y = abs(sin(walkPhase * 0.5)) * (kind == .brute ? 1.5 : 3)
        shadowNode.xScale = 1 - abs(sin(walkPhase * 0.5)) * 0.08
    }

    func beginGrab(reducedMotion: Bool) {
        isGrabbed = true
        isThrown = false
        hasResolvedImpact = false
        highestPoint = position.y
        physicsBody?.isDynamic = false
        physicsBody?.affectedByGravity = false
        physicsBody?.velocity = .zero
        physicsBody?.angularVelocity = 0
        removeAllActions()
        if !reducedMotion { run(.scale(to: 1.10, duration: 0.08)) }
    }

    func release(with velocity: CGVector, powerMultiplier: CGFloat) {
        isGrabbed = false
        isThrown = true
        hasResolvedImpact = false
        highestPoint = position.y
        physicsBody?.isDynamic = true
        physicsBody?.affectedByGravity = true
        physicsBody?.velocity = CGVector(dx: velocity.dx * powerMultiplier, dy: velocity.dy * powerMultiplier)
        physicsBody?.angularVelocity = max(-8, min(8, -velocity.dx / 175))
        run(.scale(to: 1, duration: 0.08))
    }

    func resumeWalking(on groundY: CGFloat) {
        isThrown = false
        hasResolvedImpact = false
        zRotation = 0
        physicsBody?.isDynamic = false
        physicsBody?.affectedByGravity = false
        physicsBody?.velocity = .zero
        physicsBody?.angularVelocity = 0
        position.y = max(position.y, groundY + kind.size.height * 0.39 + 2)
    }

    @discardableResult
    func damage(_ amount: CGFloat) -> Bool {
        health -= amount
        healthBar.isHidden = false
        healthBar.xScale = max(0.05, health / kind.hitPoints)
        art.run(.sequence([
            .colorize(with: .white, colorBlendFactor: 0.9, duration: 0.04),
            .colorize(withColorBlendFactor: 0, duration: 0.12)
        ]))
        return health <= 0
    }

    /// Marks this zombie as gone so GameScene's various zombie-iterating effects (splash
    /// damage, hit-testing) skip it for the rest of the frame, even before removeFromParent()
    /// takes it out of the node tree.
    func markDefeated() {
        isDefeated = true
    }

    func slow(for duration: TimeInterval) {
        slowTime = max(slowTime, duration)
        art.color = .cyan
        art.colorBlendFactor = 0.28
        run(.sequence([
            .wait(forDuration: duration),
            .run { [weak self] in self?.art.colorBlendFactor = 0 }
        ]), withKey: "slow")
    }
}

