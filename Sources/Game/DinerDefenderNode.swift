import SpriteKit

enum DinerDefenderAnimationState: Equatable {
    case idle, aiming, firing, reloading, ducking, wounded, retreated, celebrating
}

/// The Last Light's resident defender. He is deliberately framed inside the diner's window so
/// he feels like part of the building instead of a weapon HUD pasted over the playfield.
final class DinerDefenderNode: SKCropNode {
    private let reducedMotion: Bool
    private let windowSize: CGSize
    private let restingCharacterPosition: CGPoint
    private let interior = SKShapeNode()
    private let idleTexture = SKTexture(imageNamed: "diner_defender")
    private let firingTexture = SKTexture(imageNamed: "diner_defender_fire")
    private let reloadTexture = SKTexture(imageNamed: "diner_defender_reload")
    private let character: SKSpriteNode
    private let muzzleFlash = SKNode()
    private let weaponSheen = SKShapeNode()
    private var facing: CGFloat = 1
    private(set) var weaponTier = 0
    private(set) var isReloading = false
    private(set) var currentAnimationState: DinerDefenderAnimationState = .idle

    var hasAuthoredTexture: Bool {
        [idleTexture, firingTexture, reloadTexture].allSatisfy {
            $0.size().width > 1 && $0.size().height > 1
        }
    }

    init(windowSize: CGSize, reducedMotion: Bool, weaponTier: Int) {
        self.windowSize = windowSize
        self.reducedMotion = reducedMotion
        restingCharacterPosition = CGPoint(x: -windowSize.width * 0.015, y: -windowSize.height * 0.43)
        character = SKSpriteNode(texture: idleTexture)
        super.init()

        name = "diner-defender"
        zPosition = 3.25

        let mask = SKShapeNode(rectOf: windowSize, cornerRadius: min(7, windowSize.height * 0.12))
        mask.fillColor = .white
        mask.strokeColor = .clear
        maskNode = mask

        interior.path = CGPath(
            roundedRect: CGRect(x: -windowSize.width / 2, y: -windowSize.height / 2,
                                width: windowSize.width, height: windowSize.height),
            cornerWidth: 7,
            cornerHeight: 7,
            transform: nil
        )
        interior.fillColor = SKColor(red: 0.055, green: 0.035, blue: 0.025, alpha: 0.94)
        interior.strokeColor = .clear
        interior.zPosition = 0
        addChild(interior)

        [idleTexture, firingTexture, reloadTexture].forEach { $0.filteringMode = .linear }
        let source = character.texture?.size() ?? CGSize(width: 1, height: 1)
        let height = windowSize.height * 1.72
        character.size = CGSize(width: height * source.width / max(1, source.height), height: height)
        character.position = restingCharacterPosition
        character.anchorPoint = CGPoint(x: 0.5, y: 0.39)
        character.zPosition = 2
        addChild(character)

        weaponSheen.path = CGPath(
            roundedRect: CGRect(x: -windowSize.width * 0.02, y: -1,
                                width: windowSize.width * 0.36, height: 2),
            cornerWidth: 1,
            cornerHeight: 1,
            transform: nil
        )
        weaponSheen.position = CGPoint(x: windowSize.width * 0.06, y: -windowSize.height * 0.05)
        weaponSheen.strokeColor = .clear
        weaponSheen.zPosition = 3
        character.addChild(weaponSheen)

        configureMuzzleFlash()
        character.addChild(muzzleFlash)
        setWeaponTier(weaponTier)
        startIdle()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setWeaponTier(_ tier: Int) {
        weaponTier = max(0, min(3, tier))
        switch weaponTier {
        case 1:
            weaponSheen.fillColor = SKColor(red: 0.88, green: 0.46, blue: 0.18, alpha: 0.58)
            weaponSheen.glowWidth = 1
        case 2:
            weaponSheen.fillColor = SKColor(red: 0.88, green: 0.76, blue: 0.30, alpha: 0.72)
            weaponSheen.glowWidth = 2
        case 3:
            weaponSheen.fillColor = SKColor(red: 0.42, green: 0.92, blue: 1, alpha: 0.88)
            weaponSheen.glowWidth = 3
        default:
            weaponSheen.fillColor = SKColor.white.withAlphaComponent(0.22)
            weaponSheen.glowWidth = 0
        }
    }

    func aim(at localPoint: CGPoint?) {
        guard !isReloading, currentAnimationState != .retreated, currentAnimationState != .celebrating else { return }
        guard currentAnimationState != .firing, currentAnimationState != .ducking else { return }
        guard let localPoint else {
            currentAnimationState = .idle
            character.run(.rotate(toAngle: 0, duration: reducedMotion ? 0.01 : 0.22, shortestUnitArc: true), withKey: "aim")
            return
        }
        currentAnimationState = .aiming
        facing = localPoint.x < position.x ? -1 : 1
        character.xScale = facing
        let angle = atan2(localPoint.y - position.y, abs(localPoint.x - position.x))
        let clamped = max(-0.11, min(0.14, angle * 0.22)) * facing
        character.run(.rotate(toAngle: clamped, duration: reducedMotion ? 0.01 : 0.12, shortestUnitArc: true), withKey: "aim")
    }

    func fire() {
        guard alpha > 0.1 else { return }
        character.removeAction(forKey: "idle")
        character.removeAction(forKey: "reload")
        isReloading = false
        currentAnimationState = .firing
        character.texture = firingTexture
        muzzleFlash.removeAllActions()
        muzzleFlash.alpha = 1

        if reducedMotion {
            muzzleFlash.run(.sequence([.wait(forDuration: 0.05), .fadeOut(withDuration: 0.05)]))
            character.run(.sequence([.wait(forDuration: 0.12), .run { [weak self] in self?.reload() }]))
            return
        }

        ejectShell()
        let recoil = -facing * windowSize.width * 0.08
        muzzleFlash.setScale(0.35)
        muzzleFlash.run(.group([
            .sequence([.scale(to: 1.28, duration: 0.035), .scale(to: 0.72, duration: 0.055)]),
            .sequence([.wait(forDuration: 0.035), .fadeOut(withDuration: 0.07)])
        ]))
        character.run(.sequence([
            .group([.moveBy(x: recoil, y: -2, duration: 0.045), .rotate(byAngle: -facing * 0.045, duration: 0.045)]),
            .group([.moveBy(x: -recoil, y: 2, duration: 0.11), .rotate(byAngle: facing * 0.045, duration: 0.11)]),
            .run { [weak self] in self?.reload() }
        ]), withKey: "shot")
    }

    func reactToDamage(stage: Int) {
        switch stage {
        case 1:
            isReloading = false
            currentAnimationState = .ducking
            character.texture = idleTexture
            character.removeAction(forKey: "shot")
            character.removeAction(forKey: "reload")
            character.run(.sequence([
                .moveBy(x: 0, y: -windowSize.height * 0.22, duration: reducedMotion ? 0.01 : 0.08),
                .wait(forDuration: reducedMotion ? 0.02 : 0.22),
                .moveBy(x: 0, y: windowSize.height * 0.22, duration: reducedMotion ? 0.01 : 0.16),
                .run { [weak self] in self?.startIdle() }
            ]), withKey: "duck")
        case 2:
            character.removeAction(forKey: "duck")
            character.position = restingCharacterPosition
            currentAnimationState = .wounded
            alpha = 0.62
            character.color = .darkGray
            character.colorBlendFactor = 0.20
        case 3...:
            currentAnimationState = .retreated
            removeAllActions()
            character.removeAllActions()
            run(.fadeOut(withDuration: reducedMotion ? 0.01 : 0.16), withKey: "retreat")
        default:
            break
        }
    }

    func celebrate() {
        guard !reducedMotion, alpha > 0.1 else { return }
        currentAnimationState = .celebrating
        character.texture = idleTexture
        character.removeAction(forKey: "idle")
        character.run(.sequence([
            .rotate(byAngle: 0.08, duration: 0.10),
            .rotate(byAngle: -0.16, duration: 0.16),
            .rotate(toAngle: 0, duration: 0.18),
            .run { [weak self] in self?.startIdle() }
        ]), withKey: "celebrate")
    }

    private func reload() {
        isReloading = true
        currentAnimationState = .reloading
        character.texture = reloadTexture
        let duration = reducedMotion ? 0.01 : max(0.18, 0.44 - Double(weaponTier) * 0.055)
        character.run(.sequence([
            .group([.rotate(toAngle: facing * -0.10, duration: duration * 0.42), .moveBy(x: 0, y: -3, duration: duration * 0.42)]),
            .wait(forDuration: duration * 0.24),
            .group([.rotate(toAngle: 0, duration: duration * 0.34), .moveBy(x: 0, y: 3, duration: duration * 0.34)]),
            .run { [weak self] in
                self?.isReloading = false
                self?.startIdle()
            }
        ]), withKey: "reload")
    }

    private func startIdle() {
        currentAnimationState = .idle
        character.texture = idleTexture
        character.position = restingCharacterPosition
        character.zRotation = 0
        guard !reducedMotion, alpha > 0.1, !isReloading else { return }
        character.run(.repeatForever(.sequence([
            .scaleY(to: 0.985, duration: 0.8),
            .scaleY(to: 1, duration: 0.9),
            .wait(forDuration: 0.35),
            .moveBy(x: facing * 1.2, y: 0, duration: 0.45),
            .moveBy(x: -facing * 1.2, y: 0, duration: 0.45)
        ])), withKey: "idle")
    }

    private func ejectShell() {
        let shell = SKShapeNode(rectOf: CGSize(width: 5.5, height: 2.2), cornerRadius: 1)
        shell.fillColor = SKColor(red: 0.92, green: 0.64, blue: 0.16, alpha: 1)
        shell.strokeColor = SKColor(red: 0.34, green: 0.17, blue: 0.04, alpha: 1)
        shell.lineWidth = 0.6
        shell.position = CGPoint(x: facing * windowSize.width * 0.10, y: windowSize.height * 0.02)
        shell.zPosition = 6
        addChild(shell)
        shell.run(.sequence([
            .group([
                .moveBy(x: -facing * windowSize.width * 0.20, y: windowSize.height * 0.25, duration: 0.20),
                .rotate(byAngle: facing * 5.2, duration: 0.20)
            ]),
            .group([.moveBy(x: -facing * 5, y: -windowSize.height * 0.30, duration: 0.22), .fadeOut(withDuration: 0.22)]),
            .removeFromParent()
        ]))
    }

    private func configureMuzzleFlash() {
        muzzleFlash.position = CGPoint(x: windowSize.width * 0.43, y: -windowSize.height * 0.045)
        muzzleFlash.zPosition = 5
        muzzleFlash.alpha = 0

        let core = SKShapeNode(ellipseOf: CGSize(width: windowSize.width * 0.25, height: windowSize.height * 0.18))
        core.fillColor = .white
        core.strokeColor = .yellow
        core.glowWidth = reducedMotion ? 0 : 5
        muzzleFlash.addChild(core)

        for angle in [-0.48, 0, 0.48] as [CGFloat] {
            let ray = SKShapeNode(rectOf: CGSize(width: windowSize.width * 0.30, height: 2), cornerRadius: 1)
            ray.fillColor = .yellow
            ray.strokeColor = .clear
            ray.position.x = windowSize.width * 0.13
            ray.zRotation = angle
            muzzleFlash.addChild(ray)
        }
    }
}
