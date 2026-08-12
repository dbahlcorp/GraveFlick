import SpriteKit
import UIKit

enum PhysicsCategory {
    static let none: UInt32 = 0
    static let ground: UInt32 = 1 << 0
    static let boundary: UInt32 = 1 << 1
    static let zombie: UInt32 = 1 << 2
}

@MainActor
protocol GameSceneDelegate: AnyObject {
    func gameScene(_ scene: GameScene, didUpdateScore score: Int, wave: Int, health: Int)
    func gameSceneDidEnd(_ scene: GameScene)
}

final class GameScene: SKScene, SKPhysicsContactDelegate {
    weak var gameDelegate: GameSceneDelegate?

    var isGameplayPaused = false {
        didSet {
            world.isPaused = isGameplayPaused
        }
    }

    private let world = SKNode()
    private var selectedZombie: ZombieNode?
    private var touchSamples: [(point: CGPoint, time: TimeInterval)] = []
    private var lastUpdateTime: TimeInterval = 0
    private var elapsedTime: TimeInterval = 0
    private var timeSinceSpawn: TimeInterval = 0
    private var score = 0
    private var health = GameRules.startingHealth
    private var wave = 1
    private var combo = 0
    private var lastDefeatTime: TimeInterval = -10
    private var gameOver = false
    private var didBuildWorld = false

    private var groundY: CGFloat { max(70, size.height * 0.13) }
    private var houseFrame: CGRect {
        let width = min(260, size.width * 0.24)
        return CGRect(x: size.width * 0.5 - width * 0.5, y: groundY, width: width, height: min(250, size.height * 0.34))
    }

    override func didMove(to view: SKView) {
        guard !didBuildWorld else { return }
        didBuildWorld = true
        anchorPoint = .zero
        backgroundColor = SKColor(red: 0.035, green: 0.045, blue: 0.09, alpha: 1)
        physicsWorld.gravity = CGVector(dx: 0, dy: -8.8)
        physicsWorld.contactDelegate = self
        addChild(world)
        buildEnvironment()
        notifyDelegate()
        spawnZombie(forceWalker: true)
    }

    func restart() {
        world.removeAllChildren()
        removeAllActions()
        selectedZombie = nil
        touchSamples.removeAll()
        lastUpdateTime = 0
        elapsedTime = 0
        timeSinceSpawn = 0
        score = 0
        health = GameRules.startingHealth
        wave = 1
        combo = 0
        lastDefeatTime = -10
        gameOver = false
        isGameplayPaused = false
        buildEnvironment()
        notifyDelegate()
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

        let newWave = Int(elapsedTime / 20) + 1
        if newWave != wave {
            wave = newWave
            announceWave()
            notifyDelegate()
        }

        let spawnInterval = max(0.52, 1.55 - Double(wave) * 0.10)
        if timeSinceSpawn >= spawnInterval {
            timeSinceSpawn = 0
            spawnZombie(forceWalker: false)
        }

        for case let zombie as ZombieNode in world.children {
            zombie.updateWalking(deltaTime: deltaTime)
            if !zombie.isGrabbed, !zombie.isThrown, zombie.frame.intersects(houseFrame.insetBy(dx: 18, dy: 0)) {
                zombieReachedHouse(zombie)
            } else if zombie.position.y < -160 || zombie.position.x < -180 || zombie.position.x > size.width + 180 {
                defeat(zombie, thrownOut: true)
            }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isGameplayPaused, !gameOver, selectedZombie == nil, let touch = touches.first else { return }
        let location = touch.location(in: self)
        guard let zombie = zombie(at: location) else { return }
        selectedZombie = zombie
        touchSamples = [(location, touch.timestamp)]
        zombie.beginGrab()
        zombie.zPosition = 100
        runHaptic(.light)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let zombie = selectedZombie, let touch = touches.first else { return }
        let location = touch.location(in: self)
        zombie.position = CGPoint(
            x: min(size.width - 20, max(20, location.x)),
            y: min(size.height - 25, max(groundY + zombie.kind.size.height * 0.5 + 4, location.y))
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

    func didBegin(_ contact: SKPhysicsContact) {
        guard !gameOver else { return }
        let bodies = [contact.bodyA, contact.bodyB]
        guard bodies.contains(where: { $0.categoryBitMask == PhysicsCategory.ground }),
              let zombieBody = bodies.first(where: { $0.categoryBitMask == PhysicsCategory.zombie }),
              let zombie = zombieBody.node as? ZombieNode,
              zombie.isThrown,
              !zombie.hasResolvedImpact else { return }

        zombie.hasResolvedImpact = true
        if contact.collisionImpulse >= zombie.kind.defeatImpulse {
            defeat(zombie, thrownOut: false)
        } else {
            zombie.run(.sequence([
                .wait(forDuration: 0.38),
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
            zombie.position = CGPoint(x: location.x, y: max(groundY + zombie.kind.size.height * 0.5 + 4, location.y))
        }
        var velocity = FlickMath.velocity(from: touchSamples)
        if hypot(velocity.dx, velocity.dy) < 140 {
            velocity.dy = 180
        }
        zombie.release(with: velocity)
        zombie.zPosition = 20
        selectedZombie = nil
        touchSamples.removeAll()
    }

    private func zombie(at location: CGPoint) -> ZombieNode? {
        for node in nodes(at: location) {
            var candidate: SKNode? = node
            while let current = candidate {
                if let zombie = current as? ZombieNode { return zombie }
                candidate = current.parent
            }
        }
        return nil
    }

    private func spawnZombie(forceWalker: Bool) {
        let kind: ZombieKind = !forceWalker && wave >= 3 && Int.random(in: 0..<5) == 0 ? .brute : .walker
        let fromLeft = Bool.random()
        let zombie = ZombieNode(kind: kind, approachesFromLeft: fromLeft)
        let y = groundY + kind.size.height * 0.5 + 2
        zombie.position = CGPoint(x: fromLeft ? -kind.size.width : size.width + kind.size.width, y: y)
        zombie.zPosition = 10
        world.addChild(zombie)
    }

    private func zombieReachedHouse(_ zombie: ZombieNode) {
        zombie.removeFromParent()
        health = max(0, health - 1)
        combo = 0
        flashHouse()
        runHaptic(.heavy)
        notifyDelegate()
        if health == 0 {
            gameOver = true
            selectedZombie = nil
            world.children.compactMap { $0 as? ZombieNode }.forEach { $0.physicsBody?.isDynamic = false }
            gameDelegate?.gameSceneDidEnd(self)
        }
    }

    private func defeat(_ zombie: ZombieNode, thrownOut: Bool) {
        guard zombie.parent != nil else { return }
        if elapsedTime - lastDefeatTime <= 1.8 { combo += 1 } else { combo = 1 }
        lastDefeatTime = elapsedTime
        score += GameRules.score(for: zombie.kind, combo: combo)
        let impactPoint = zombie.position
        zombie.removeFromParent()
        burst(at: impactPoint, color: thrownOut ? .cyan : SKColor(red: 0.45, green: 0.78, blue: 0.24, alpha: 1))
        if !thrownOut { shakeCamera() }
        runHaptic(.medium)
        showCombo(at: impactPoint)
        notifyDelegate()
    }

    private func notifyDelegate() {
        gameDelegate?.gameScene(self, didUpdateScore: score, wave: wave, health: health)
    }

    private func buildEnvironment() {
        buildSky()
        buildGround()
        buildHouse()
    }

    private func buildSky() {
        let moon = SKShapeNode(circleOfRadius: min(size.width, size.height) * 0.07)
        moon.fillColor = SKColor(red: 0.94, green: 0.86, blue: 0.58, alpha: 1)
        moon.strokeColor = SKColor.white.withAlphaComponent(0.2)
        moon.lineWidth = 8
        moon.position = CGPoint(x: size.width * 0.82, y: size.height * 0.76)
        moon.glowWidth = 14
        moon.zPosition = -20
        world.addChild(moon)

        for index in 0..<42 {
            let radius = CGFloat.random(in: 1...2.6)
            let star = SKShapeNode(circleOfRadius: radius)
            star.fillColor = .white.withAlphaComponent(CGFloat.random(in: 0.3...0.9))
            star.strokeColor = .clear
            star.position = CGPoint(x: CGFloat.random(in: 20...(size.width - 20)), y: CGFloat.random(in: (groundY + 170)...(size.height - 20)))
            star.zPosition = -30
            star.run(.repeatForever(.sequence([
                .fadeAlpha(to: 0.25, duration: Double.random(in: 0.8...1.8)),
                .fadeAlpha(to: 1, duration: Double.random(in: 0.8...1.8))
            ])))
            star.name = "star-\(index)"
            world.addChild(star)
        }

        let skyline = SKShapeNode(rectOf: CGSize(width: size.width, height: 145))
        skyline.fillColor = SKColor(red: 0.055, green: 0.075, blue: 0.12, alpha: 1)
        skyline.strokeColor = .clear
        skyline.position = CGPoint(x: size.width * 0.5, y: groundY + 72)
        skyline.zPosition = -15
        world.addChild(skyline)
    }

    private func buildGround() {
        let pavement = SKShapeNode(rectOf: CGSize(width: size.width + 80, height: groundY * 2))
        pavement.fillColor = SKColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1)
        pavement.strokeColor = SKColor(red: 0.28, green: 0.30, blue: 0.34, alpha: 1)
        pavement.lineWidth = 4
        pavement.position = CGPoint(x: size.width * 0.5, y: 0)
        pavement.zPosition = 0
        world.addChild(pavement)

        let ground = SKNode()
        ground.position = CGPoint(x: 0, y: groundY)
        ground.physicsBody = SKPhysicsBody(edgeFrom: .zero, to: CGPoint(x: size.width, y: 0))
        ground.physicsBody?.categoryBitMask = PhysicsCategory.ground
        ground.physicsBody?.collisionBitMask = PhysicsCategory.zombie
        ground.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        world.addChild(ground)

        let boundaries = SKNode()
        boundaries.physicsBody = SKPhysicsBody(edgeLoopFrom: CGRect(x: -120, y: -120, width: size.width + 240, height: size.height + 240))
        boundaries.physicsBody?.categoryBitMask = PhysicsCategory.boundary
        boundaries.physicsBody?.collisionBitMask = PhysicsCategory.zombie
        world.addChild(boundaries)
    }

    private func buildHouse() {
        let frame = houseFrame
        let building = SKShapeNode(rect: frame, cornerRadius: 10)
        building.name = "house"
        building.fillColor = SKColor(red: 0.16, green: 0.12, blue: 0.15, alpha: 1)
        building.strokeColor = SKColor(red: 0.55, green: 0.31, blue: 0.22, alpha: 1)
        building.lineWidth = 6
        building.zPosition = 5
        world.addChild(building)

        let sign = SKShapeNode(rectOf: CGSize(width: frame.width * 0.82, height: 52), cornerRadius: 12)
        sign.name = "houseSign"
        sign.fillColor = SKColor(red: 0.92, green: 0.28, blue: 0.16, alpha: 1)
        sign.strokeColor = SKColor(red: 1, green: 0.77, blue: 0.26, alpha: 1)
        sign.lineWidth = 5
        sign.glowWidth = 8
        sign.position = CGPoint(x: frame.midX, y: frame.maxY - 48)
        sign.zPosition = 7
        world.addChild(sign)

        let title = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        title.text = "LAST LIGHT"
        title.fontSize = min(24, frame.width * 0.095)
        title.fontColor = .white
        title.verticalAlignmentMode = .center
        title.position = sign.position
        title.zPosition = 8
        world.addChild(title)

        let door = SKShapeNode(rectOf: CGSize(width: frame.width * 0.24, height: frame.height * 0.45), cornerRadius: 5)
        door.fillColor = SKColor(red: 0.08, green: 0.07, blue: 0.09, alpha: 1)
        door.strokeColor = SKColor(red: 0.9, green: 0.55, blue: 0.22, alpha: 1)
        door.lineWidth = 4
        door.position = CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.225)
        door.zPosition = 6
        world.addChild(door)

        for side in [CGFloat(-1), CGFloat(1)] {
            let window = SKShapeNode(rectOf: CGSize(width: frame.width * 0.22, height: frame.height * 0.2), cornerRadius: 4)
            window.fillColor = SKColor(red: 1, green: 0.73, blue: 0.24, alpha: 0.88)
            window.strokeColor = SKColor(red: 0.30, green: 0.17, blue: 0.12, alpha: 1)
            window.lineWidth = 5
            window.glowWidth = 5
            window.position = CGPoint(x: frame.midX + side * frame.width * 0.31, y: frame.minY + frame.height * 0.34)
            window.zPosition = 6
            world.addChild(window)
        }
    }

    private func burst(at point: CGPoint, color: SKColor) {
        for index in 0..<12 {
            let particle = SKShapeNode(circleOfRadius: CGFloat.random(in: 3...8))
            particle.fillColor = color
            particle.strokeColor = .clear
            particle.position = point
            particle.zPosition = 90
            world.addChild(particle)
            let angle = CGFloat(index) / 12 * .pi * 2
            let distance = CGFloat.random(in: 45...110)
            let destination = CGPoint(x: point.x + cos(angle) * distance, y: point.y + sin(angle) * distance)
            particle.run(.sequence([
                .group([.move(to: destination, duration: 0.32), .fadeOut(withDuration: 0.34), .scale(to: 0.25, duration: 0.34)]),
                .removeFromParent()
            ]))
        }
    }

    private func showCombo(at point: CGPoint) {
        guard combo >= 2 else { return }
        let label = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        label.text = "×\(combo) COMBO"
        label.fontSize = 24
        label.fontColor = SKColor(red: 1, green: 0.8, blue: 0.2, alpha: 1)
        label.position = CGPoint(x: point.x, y: min(size.height - 60, point.y + 52))
        label.zPosition = 120
        world.addChild(label)
        label.run(.sequence([
            .group([.moveBy(x: 0, y: 38, duration: 0.65), .fadeOut(withDuration: 0.65)]),
            .removeFromParent()
        ]))
    }

    private func announceWave() {
        let label = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        label.text = "WAVE \(wave)"
        label.fontSize = 46
        label.fontColor = .white
        label.position = CGPoint(x: size.width * 0.5, y: size.height * 0.67)
        label.alpha = 0
        label.zPosition = 150
        world.addChild(label)
        label.run(.sequence([
            .group([.fadeIn(withDuration: 0.18), .scale(to: 1.12, duration: 0.18)]),
            .wait(forDuration: 0.62),
            .group([.fadeOut(withDuration: 0.3), .moveBy(x: 0, y: 20, duration: 0.3)]),
            .removeFromParent()
        ]))
    }

    private func flashHouse() {
        guard let house = world.childNode(withName: "house") else { return }
        house.run(.sequence([
            .colorize(with: .red, colorBlendFactor: 0.85, duration: 0.08),
            .colorize(withColorBlendFactor: 0, duration: 0.22)
        ]))
        shakeCamera()
    }

    private func shakeCamera() {
        world.removeAction(forKey: "shake")
        world.run(.sequence([
            .moveBy(x: -8, y: 3, duration: 0.035),
            .moveBy(x: 15, y: -5, duration: 0.045),
            .moveBy(x: -10, y: 4, duration: 0.04),
            .move(to: .zero, duration: 0.055)
        ]), withKey: "shake")
    }

    private func runHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
