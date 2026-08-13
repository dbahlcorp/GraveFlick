import SpriteKit

final class DinerNode: SKNode {
    private let building = SKSpriteNode(imageNamed: "diner_complete")
    private let damagedBuilding = SKSpriteNode(imageNamed: "diner_damaged")
    private let severeBuilding = SKSpriteNode(imageNamed: "diner_severe")
    private let destroyedBuilding = SKSpriteNode(imageNamed: "diner_destroyed")
    private let title = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let neonGlow = SKShapeNode(rectOf: CGSize(width: 1, height: 1), cornerRadius: 16)
    private let leftWindowGlow = SKShapeNode(rectOf: CGSize(width: 1, height: 1), cornerRadius: 8)
    private let rightWindowGlow = SKShapeNode(rectOf: CGSize(width: 1, height: 1), cornerRadius: 8)
    private let doorGlint = SKShapeNode(rectOf: CGSize(width: 1, height: 1), cornerRadius: 3)
    private let ventAnchor = SKNode()
    private let marqueeArt = SKSpriteNode(imageNamed: "diner_marquee_1")
    private let doorArt = SKSpriteNode(imageNamed: "diner_door_1")
    private let ventArt = SKSpriteNode(imageNamed: "diner_vent_1")
    private let reducedMotion: Bool
    private var damageStage = 0
    var currentDamageStage: Int { damageStage }
    var componentAnimationIsRunning: Bool {
        marqueeArt.action(forKey: "marqueeFrames") != nil || doorArt.action(forKey: "doorFrames") != nil || ventArt.action(forKey: "ventFrames") != nil
    }

    init(frame: CGRect, reducedMotion: Bool, highContrast: Bool) {
        self.reducedMotion = reducedMotion
        super.init()

        name = "house"
        zPosition = 5

        building.texture?.filteringMode = .linear
        building.size = Self.aspectFit(building.texture?.size() ?? .zero, inside: frame.size)
        building.zPosition = 2
        addChild(building)
        for (sprite, zPosition) in [(damagedBuilding, CGFloat(2.05)), (severeBuilding, CGFloat(2.1)), (destroyedBuilding, CGFloat(2.2))] {
            sprite.texture?.filteringMode = .linear
            sprite.size = building.size
            sprite.zPosition = zPosition
            sprite.alpha = 0
            addChild(sprite)
        }
        if highContrast {
            [building, damagedBuilding, severeBuilding, destroyedBuilding].forEach {
                $0.color = .white
                $0.colorBlendFactor = 0.12
            }
        }
        position = CGPoint(x: frame.midX, y: frame.minY + building.size.height / 2)

        let width = building.size.width
        let height = building.size.height

        neonGlow.path = CGPath(roundedRect: CGRect(x: -width * 0.285, y: -height * 0.075,
                                                   width: width * 0.57, height: height * 0.15),
                                cornerWidth: 16, cornerHeight: 16, transform: nil)
        neonGlow.position = CGPoint(x: -width * 0.018, y: height * 0.33)
        neonGlow.fillColor = SKColor(red: 1, green: 0.08, blue: 0.03, alpha: 0.08)
        neonGlow.strokeColor = SKColor(red: 1, green: 0.48, blue: 0.16, alpha: 0.58)
        neonGlow.lineWidth = 4
        neonGlow.glowWidth = reducedMotion ? 0 : 12
        neonGlow.zPosition = 3
        addChild(neonGlow)

        title.text = "LAST LIGHT"
        title.fontSize = min(22, width * 0.083)
        title.fontColor = .white
        title.verticalAlignmentMode = .center
        title.horizontalAlignmentMode = .center
        title.position = neonGlow.position
        title.zPosition = 4
        addChild(title)

        configureGlow(leftWindowGlow, rect: CGRect(x: -width * 0.42, y: -height * 0.20,
                                                    width: width * 0.31, height: height * 0.27))
        configureGlow(rightWindowGlow, rect: CGRect(x: width * 0.11, y: -height * 0.20,
                                                     width: width * 0.31, height: height * 0.27))

        doorGlint.path = CGPath(roundedRect: CGRect(x: -width * 0.012, y: -height * 0.16,
                                                    width: width * 0.024, height: height * 0.30),
                                 cornerWidth: 3, cornerHeight: 3, transform: nil)
        doorGlint.position = CGPoint(x: width * 0.018, y: -height * 0.11)
        doorGlint.fillColor = .white.withAlphaComponent(0.14)
        doorGlint.strokeColor = .clear
        doorGlint.zPosition = 3
        addChild(doorGlint)

        ventAnchor.position = CGPoint(x: width * 0.36, y: height * 0.30)
        addChild(ventAnchor)
        configureComponentArt(width: width, height: height)
        startIdleAnimations()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var hasCompleteAssetSet: Bool {
        let buildingsComplete = [building, damagedBuilding, severeBuilding, destroyedBuilding].allSatisfy {
            guard let texture = $0.texture else { return false }
            return texture.size().width > 1 && texture.size().height > 1
        }
        let componentsComplete = ["marquee", "door", "vent"].allSatisfy { component in
            (1...4).allSatisfy { SKTexture(imageNamed: "diner_\(component)_\($0)").size().width > 1 }
        }
        return buildingsComplete && componentsComplete
    }

    private func configureComponentArt(width: CGFloat, height: CGFloat) {
        marqueeArt.size = CGSize(width: width * 0.55, height: height * 0.20)
        marqueeArt.position = CGPoint(x: 0, y: height * 0.34)
        marqueeArt.zPosition = 3.5
        marqueeArt.alpha = 0.82
        addChild(marqueeArt)
        doorArt.size = CGSize(width: width * 0.21, height: height * 0.43)
        doorArt.position = CGPoint(x: 0, y: -height * 0.15)
        doorArt.zPosition = 3.4
        doorArt.alpha = 0.72
        addChild(doorArt)
        ventArt.size = CGSize(width: width * 0.16, height: height * 0.15)
        ventArt.position = ventAnchor.position
        ventArt.zPosition = 3.4
        ventArt.alpha = 0.72
        addChild(ventArt)
    }

    func takeHit(remainingHealth: Int, maximumHealth: Int) {
        let ratio = CGFloat(max(0, remainingHealth)) / CGFloat(max(1, maximumHealth))
        damageStage = max(damageStage, ratio <= 0 ? 3 : (ratio <= 0.34 ? 2 : (ratio <= 0.67 ? 1 : 0)))

        [building, damagedBuilding, severeBuilding, destroyedBuilding].forEach {
            $0.run(.sequence([
                .colorize(with: .red, colorBlendFactor: 0.82, duration: 0.06),
                .colorize(withColorBlendFactor: damageStage >= 2 ? 0.12 : 0, duration: 0.22)
            ]), withKey: "damageFlash")
        }

        neonGlow.run(.sequence([
            .fadeAlpha(to: 0.08, duration: 0.035),
            .fadeAlpha(to: 1, duration: 0.06),
            .fadeAlpha(to: damageStage >= 2 ? 0.42 : 1, duration: 0.10)
        ]), withKey: "neonHit")
        title.run(.sequence([
            .fadeAlpha(to: 0.12, duration: 0.04),
            .fadeAlpha(to: damageStage >= 2 ? 0.58 : 1, duration: 0.13)
        ]), withKey: "titleHit")

        guard !reducedMotion else {
            applyDamageAppearance()
            return
        }

        run(.sequence([
            .rotate(toAngle: -0.025, duration: 0.035),
            .rotate(toAngle: 0.032, duration: 0.045),
            .rotate(toAngle: -0.016, duration: 0.04),
            .rotate(toAngle: 0, duration: 0.07)
        ]), withKey: "dinerHit")
        doorGlint.run(.sequence([
            .moveBy(x: -8, y: 0, duration: 0.04),
            .moveBy(x: 14, y: 0, duration: 0.06),
            .moveBy(x: -6, y: 0, duration: 0.07)
        ]), withKey: "doorRattle")
        emitSparks()
        applyDamageAppearance()
    }

    private func configureGlow(_ node: SKShapeNode, rect: CGRect) {
        node.path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        node.fillColor = SKColor(red: 1, green: 0.56, blue: 0.08, alpha: 0.08)
        node.strokeColor = .clear
        node.zPosition = 3
        addChild(node)
    }

    private func startIdleAnimations() {
        guard !reducedMotion else { return }
        neonGlow.run(.repeatForever(.sequence([
            .fadeAlpha(to: 0.68, duration: 0.055),
            .fadeAlpha(to: 1, duration: 0.08),
            .wait(forDuration: 1.8),
            .fadeAlpha(to: 0.84, duration: 0.05),
            .fadeAlpha(to: 1, duration: 0.06),
            .wait(forDuration: 2.7)
        ])), withKey: "neonFlicker")
        title.run(.repeatForever(.sequence([
            .fadeAlpha(to: 0.70, duration: 0.08),
            .fadeAlpha(to: 1, duration: 0.12),
            .wait(forDuration: 2.2)
        ])), withKey: "titleFlicker")
        leftWindowGlow.run(.repeatForever(.sequence([
            .fadeAlpha(to: 0.42, duration: 1.3),
            .fadeAlpha(to: 1, duration: 1.6)
        ])), withKey: "windowGlow")
        rightWindowGlow.run(.repeatForever(.sequence([
            .wait(forDuration: 0.55),
            .fadeAlpha(to: 0.48, duration: 1.5),
            .fadeAlpha(to: 1, duration: 1.25)
        ])), withKey: "windowGlow")
        doorGlint.run(.repeatForever(.sequence([
            .fadeAlpha(to: 0.42, duration: 0.7),
            .fadeAlpha(to: 1, duration: 0.8),
            .wait(forDuration: 2.4)
        ])), withKey: "doorGlint")
        run(.repeatForever(.sequence([
            .wait(forDuration: 1.15),
            .run { [weak self] in self?.emitSteam() }
        ])), withKey: "steam")
        marqueeArt.run(.repeatForever(.animate(with: Self.textures(component: "marquee", frames: [1, 2, 1, 3]), timePerFrame: 0.38, resize: false, restore: true)), withKey: "marqueeFrames")
        doorArt.run(.repeatForever(.sequence([
            .wait(forDuration: 4.2),
            .animate(with: Self.textures(component: "door", frames: [1, 2, 3, 2, 1]), timePerFrame: 0.12, resize: false, restore: true)
        ])), withKey: "doorFrames")
        ventArt.run(.repeatForever(.animate(with: Self.textures(component: "vent", frames: [1, 2, 3, 2]), timePerFrame: 0.32, resize: false, restore: true)), withKey: "ventFrames")
    }

    private func applyDamageAppearance() {
        switch damageStage {
        case 1:
            transition(to: damagedBuilding, hiding: building)
            rightWindowGlow.alpha = 0.58
            neonGlow.zRotation = -0.014
            setComponentDamageFrame(2)
        case 2:
            transition(to: severeBuilding, hiding: damagedBuilding)
            building.alpha = 0
            rightWindowGlow.alpha = 0.12
            leftWindowGlow.alpha = 0.34
            neonGlow.alpha = 0.42
            neonGlow.zRotation = -0.038
            title.alpha = 0.58
            startDamageSmoke()
            setComponentDamageFrame(3)
        case 3:
            transition(to: destroyedBuilding, hiding: severeBuilding)
            building.alpha = 0
            damagedBuilding.alpha = 0
            rightWindowGlow.alpha = 0
            leftWindowGlow.alpha = 0.08
            neonGlow.alpha = 0.10
            title.alpha = 0.08
            destroyedBuilding.run(.sequence([
                .group([.scaleX(to: 1.045, duration: 0.10), .scaleY(to: 0.91, duration: 0.10), .moveBy(x: 0, y: -7, duration: 0.10)]),
                .group([.scaleX(to: 1, duration: 0.16), .scaleY(to: 1, duration: 0.16), .moveBy(x: 0, y: 2, duration: 0.16)])
            ]), withKey: "collapse")
            emitDebris()
            startEmbers()
            // Stop the idle frame loops first — they run forever and would otherwise overwrite
            // this destroyed-stage texture on their very next tick.
            setComponentDamageFrame(4)
        default:
            break
        }
    }

    private func transition(to revealed: SKSpriteNode, hiding hidden: SKSpriteNode) {
        revealed.removeAction(forKey: "reveal")
        hidden.removeAction(forKey: "hide")
        revealed.run(.fadeIn(withDuration: reducedMotion ? 0.01 : 0.22), withKey: "reveal")
        hidden.run(.fadeOut(withDuration: reducedMotion ? 0.01 : 0.22), withKey: "hide")
    }

    private func setComponentDamageFrame(_ frame: Int) {
        marqueeArt.removeAction(forKey: "marqueeFrames")
        doorArt.removeAction(forKey: "doorFrames")
        ventArt.removeAction(forKey: "ventFrames")
        marqueeArt.texture = SKTexture(imageNamed: "diner_marquee_\(frame)")
        doorArt.texture = SKTexture(imageNamed: "diner_door_\(frame)")
        ventArt.texture = SKTexture(imageNamed: "diner_vent_\(frame)")
    }

    private func startDamageSmoke() {
        guard !reducedMotion, action(forKey: "damageSmoke") == nil else { return }
        run(.repeatForever(.sequence([
            .run { [weak self] in self?.emitSteam(dark: true) },
            .wait(forDuration: 0.52)
        ])), withKey: "damageSmoke")
    }

    private func startEmbers() {
        guard !reducedMotion, action(forKey: "embers") == nil else { return }
        run(.repeatForever(.sequence([
            .run { [weak self] in self?.emitEmber() },
            .wait(forDuration: 0.22)
        ])), withKey: "embers")
    }

    private func emitEmber() {
        let ember = SKShapeNode(circleOfRadius: CGFloat.random(in: 1.4...2.8))
        ember.fillColor = Bool.random() ? .orange : .yellow
        ember.strokeColor = .clear
        ember.position = CGPoint(x: CGFloat.random(in: -building.size.width * 0.32...building.size.width * 0.32),
                                 y: CGFloat.random(in: -building.size.height * 0.17...building.size.height * 0.05))
        ember.zPosition = 7
        addChild(ember)
        ember.run(.sequence([.group([.moveBy(x: CGFloat.random(in: -16...16), y: CGFloat.random(in: 28...58), duration: 0.65), .fadeOut(withDuration: 0.65)]), .removeFromParent()]))
    }

    private func emitDebris() {
        guard !reducedMotion else { return }
        for index in 0..<10 {
            let debris = SKShapeNode(rectOf: CGSize(width: CGFloat.random(in: 4...10), height: CGFloat.random(in: 3...7)), cornerRadius: 1)
            debris.fillColor = index.isMultiple(of: 3) ? SKColor(red: 0.22, green: 0.40, blue: 0.39, alpha: 1) : .darkGray
            debris.strokeColor = .black
            debris.position = CGPoint(x: CGFloat.random(in: -building.size.width * 0.38...building.size.width * 0.38), y: building.size.height * 0.18)
            debris.zPosition = 8
            addChild(debris)
            debris.run(.sequence([.group([.moveBy(x: CGFloat.random(in: -38...38), y: CGFloat.random(in: -48 ... -24), duration: 0.42), .rotate(byAngle: CGFloat.random(in: -2.4...2.4), duration: 0.42), .fadeOut(withDuration: 0.46)]), .removeFromParent()]))
        }
    }

    private func emitSteam(dark: Bool = false) {
        guard !reducedMotion else { return }
        let puff = SKShapeNode(circleOfRadius: dark ? 9 : 6)
        puff.fillColor = (dark ? SKColor.darkGray : SKColor.white).withAlphaComponent(dark ? 0.48 : 0.28)
        puff.strokeColor = .clear
        puff.position = ventAnchor.position
        puff.zPosition = 5
        addChild(puff)
        puff.run(.sequence([
            .group([
                .moveBy(x: CGFloat.random(in: -10...12), y: dark ? 54 : 38, duration: dark ? 0.75 : 1.0),
                .scale(to: dark ? 2.2 : 1.7, duration: dark ? 0.75 : 1.0),
                .fadeOut(withDuration: dark ? 0.75 : 1.0)
            ]),
            .removeFromParent()
        ]))
    }

    private func emitSparks() {
        guard !reducedMotion else { return }
        for index in 0..<6 {
            let spark = SKShapeNode(circleOfRadius: 2.3)
            spark.fillColor = index.isMultiple(of: 2) ? .yellow : .orange
            spark.strokeColor = .clear
            spark.position = neonGlow.position
            spark.zPosition = 7
            addChild(spark)
            let angle = CGFloat(index) / 6 * .pi * 2
            spark.run(.sequence([
                .group([
                    .moveBy(x: cos(angle) * 34, y: sin(angle) * 30 - 12, duration: 0.24),
                    .fadeOut(withDuration: 0.25)
                ]),
                .removeFromParent()
            ]))
        }
    }

    private static func aspectFit(_ source: CGSize, inside bounds: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return bounds }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    private static func textures(component: String, frames: [Int]) -> [SKTexture] {
        frames.map { index in
            let texture = SKTexture(imageNamed: "diner_\(component)_\(index)")
            texture.filteringMode = .linear
            return texture
        }
    }
}
