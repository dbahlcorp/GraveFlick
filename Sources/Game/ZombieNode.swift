import SpriteKit

enum ZombieKind: CaseIterable {
    case walker
    case brute

    var size: CGSize {
        switch self {
        case .walker: CGSize(width: 48, height: 76)
        case .brute: CGSize(width: 68, height: 92)
        }
    }

    var speed: CGFloat {
        switch self {
        case .walker: 43
        case .brute: 28
        }
    }

    var defeatImpulse: CGFloat {
        switch self {
        case .walker: 23
        case .brute: 38
        }
    }
}

final class ZombieNode: SKNode {
    let kind: ZombieKind
    let approachesFromLeft: Bool
    var isGrabbed = false
    var isThrown = false
    var hasResolvedImpact = false

    private let bodyNode: SKShapeNode
    private let headNode: SKShapeNode
    private let leftLeg: SKShapeNode
    private let rightLeg: SKShapeNode
    private var walkPhase: CGFloat = 0

    init(kind: ZombieKind, approachesFromLeft: Bool) {
        self.kind = kind
        self.approachesFromLeft = approachesFromLeft

        let bodyColor: SKColor = kind == .brute
            ? SKColor(red: 0.24, green: 0.43, blue: 0.34, alpha: 1)
            : SKColor(red: 0.36, green: 0.62, blue: 0.43, alpha: 1)
        let shirtColor: SKColor = kind == .brute
            ? SKColor(red: 0.33, green: 0.18, blue: 0.16, alpha: 1)
            : SKColor(red: 0.22, green: 0.28, blue: 0.48, alpha: 1)

        bodyNode = SKShapeNode(rectOf: CGSize(width: kind.size.width, height: kind.size.height * 0.5), cornerRadius: 10)
        bodyNode.fillColor = shirtColor
        bodyNode.strokeColor = .black.withAlphaComponent(0.35)
        bodyNode.lineWidth = 3
        bodyNode.position.y = -4

        headNode = SKShapeNode(circleOfRadius: kind.size.width * 0.34)
        headNode.fillColor = bodyColor
        headNode.strokeColor = .black.withAlphaComponent(0.35)
        headNode.lineWidth = 3
        headNode.position.y = kind.size.height * 0.31

        let legSize = CGSize(width: kind.size.width * 0.22, height: kind.size.height * 0.34)
        leftLeg = SKShapeNode(rectOf: legSize, cornerRadius: 5)
        rightLeg = SKShapeNode(rectOf: legSize, cornerRadius: 5)
        for leg in [leftLeg, rightLeg] {
            leg.fillColor = SKColor(red: 0.16, green: 0.16, blue: 0.20, alpha: 1)
            leg.strokeColor = .black.withAlphaComponent(0.3)
            leg.lineWidth = 2
            leg.position.y = -kind.size.height * 0.37
        }
        leftLeg.position.x = -kind.size.width * 0.2
        rightLeg.position.x = kind.size.width * 0.2

        super.init()

        name = "zombie"
        addChild(leftLeg)
        addChild(rightLeg)
        addChild(bodyNode)
        addChild(headNode)
        addFace()

        let physicsSize = CGSize(width: kind.size.width * 0.9, height: kind.size.height)
        physicsBody = SKPhysicsBody(rectangleOf: physicsSize, center: CGPoint(x: 0, y: -3))
        physicsBody?.isDynamic = false
        physicsBody?.allowsRotation = true
        physicsBody?.restitution = 0.28
        physicsBody?.friction = 0.72
        physicsBody?.linearDamping = 0.18
        physicsBody?.angularDamping = 0.35
        physicsBody?.categoryBitMask = PhysicsCategory.zombie
        physicsBody?.collisionBitMask = PhysicsCategory.ground | PhysicsCategory.boundary
        physicsBody?.contactTestBitMask = PhysicsCategory.ground
        xScale = approachesFromLeft ? 1 : -1
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateWalking(deltaTime: TimeInterval) {
        guard !isGrabbed, !isThrown else { return }
        let direction: CGFloat = approachesFromLeft ? 1 : -1
        position.x += direction * kind.speed * CGFloat(deltaTime)
        walkPhase += CGFloat(deltaTime) * 8
        leftLeg.zRotation = sin(walkPhase) * 0.18
        rightLeg.zRotation = -sin(walkPhase) * 0.18
        bodyNode.position.y = -4 + abs(sin(walkPhase * 0.5)) * 2
    }

    func beginGrab() {
        isGrabbed = true
        isThrown = false
        hasResolvedImpact = false
        physicsBody?.isDynamic = false
        physicsBody?.affectedByGravity = false
        physicsBody?.velocity = .zero
        physicsBody?.angularVelocity = 0
        removeAllActions()
        run(.scale(to: 1.1, duration: 0.08))
    }

    func release(with velocity: CGVector) {
        isGrabbed = false
        isThrown = true
        hasResolvedImpact = false
        physicsBody?.isDynamic = true
        physicsBody?.affectedByGravity = true
        physicsBody?.velocity = velocity
        physicsBody?.angularVelocity = max(-7, min(7, -velocity.dx / 190))
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
        position.y = max(position.y, groundY + kind.size.height * 0.5 + 2)
    }

    private func addFace() {
        let eyeY = kind.size.height * 0.36
        for x in [-kind.size.width * 0.12, kind.size.width * 0.12] {
            let eye = SKShapeNode(circleOfRadius: kind == .brute ? 4.5 : 3.5)
            eye.fillColor = SKColor(red: 1, green: 0.78, blue: 0.18, alpha: 1)
            eye.strokeColor = .clear
            eye.position = CGPoint(x: x, y: eyeY)
            addChild(eye)
        }

        let mouth = SKShapeNode(rectOf: CGSize(width: kind.size.width * 0.28, height: 4), cornerRadius: 2)
        mouth.fillColor = SKColor(red: 0.18, green: 0.08, blue: 0.10, alpha: 1)
        mouth.strokeColor = .clear
        mouth.position.y = kind.size.height * 0.21
        mouth.zRotation = approachesFromLeft ? -0.12 : 0.12
        addChild(mouth)
    }
}
