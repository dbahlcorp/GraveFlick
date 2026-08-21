import SpriteKit
import UIKit

@MainActor
protocol WeaponSystemHost: AnyObject {
    var world: SKNode { get }
    var size: CGSize { get }
    var settings: GameSettings { get }
    var level: GameLevel { get }
    var groundY: CGFloat { get }
    var houseFrame: CGRect { get }
    var physicsWorld: SKPhysicsWorld { get }
    var gameOver: Bool { get }
    var specialCharge: Double { get set }
    var activeZombies: [ZombieNode] { get }
    var rapidGearLevel: Int { get }
    var perkSystem: PerkSystem { get }
    var comboSystem: ComboSystem { get }
    /// True while `WaveModifier.graveTimeDisabled` is this wave's active modifier.
    var isGraveTimeDisabled: Bool { get }

    func nodes(at point: CGPoint) -> [SKNode]
    func upgradeLevel(_ kind: WeaponKind) -> Int
    func isUnlocked(_ weapon: WeaponKind) -> Bool
    func isUnlocked(_ trap: TrapKind) -> Bool
    func fireDefender()
    func notifyDelegate()
    func announce(text: String, color: SKColor, subtitle: String?, subtitleColor: SKColor)
    func playCombatVFX(_ effect: CombatVFX, at point: CGPoint, size: CGFloat, direction: CGFloat, tint: SKColor?)
    func playDirectionalDebris(at point: CGPoint, color: SKColor, direction: CGFloat, count: Int)
    func shakeCamera(intensity: CGFloat)
    func hitStop(duration: TimeInterval, slowFactor: CGFloat)
    func recordFeat(_ id: String)
}

/// Weapon/trap arming, aim-gesture state, cooldowns, and every fire function — the biggest system
/// by line count but mechanically the safest to extract: most fire functions are self-contained,
/// each just needing world/layout/perk-bonus/combo/VFX access through `host`. Also owns
/// `useSpecial()` ("Grave Time") — it doesn't cleanly fit any single system, but it's activated
/// the same way as a weapon special and reads weapon-cooldown-adjacent state.
///
/// Owned by GameScene via `weaponSystem`. `armWeapon`/`beginAim`/`updateAim`/`endAim`/`cancelAim`/
/// `detonateIfHit` are its public entry points — GameScene's touch handlers (not yet extracted)
/// call these directly.
///
/// @MainActor because GameScene (its sole host/caller) is implicitly main-actor-isolated via
/// SKScene, and several fire functions call SoundManager (also @MainActor) directly.
@MainActor
final class WeaponSystem {
    weak var host: WeaponSystemHost?

    private(set) var armedWeapon: WeaponKind?
    private(set) var aimTouchKey: ObjectIdentifier?
    /// The touch-down point, held stable for the whole gesture — `aimSamples` is trimmed to a
    /// short rolling window for velocity math, so it can't be trusted to still hold this by the
    /// time a long drag ends.
    private var aimOrigin: CGPoint?
    private var aimSamples: [(point: CGPoint, time: TimeInterval)] = []
    private var aimPathPoints: [CGPoint] = []
    private var aimPreviewNode: SKNode?
    private struct Detonatable { let node: SKNode; let detonate: () -> Void }
    private var detonatables: [ObjectIdentifier: Detonatable] = [:]
    private var deliveryTruckVictims: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]
    var weaponCooldowns: [WeaponKind: TimeInterval] = [:]
    var trapCooldowns: [TrapKind: TimeInterval] = [:]

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

    private func defenderMuzzle(_ host: WeaponSystemHost) -> CGPoint {
        CGPoint(x: host.houseFrame.midX + host.houseFrame.width * 0.18, y: host.groundY + host.houseFrame.height * 0.43)
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
        guard let host, !host.gameOver else { return }
        if armedWeapon == kind {
            cancelAim()
            host.notifyDelegate()
            return
        }
        guard (host.level.isSandbox || host.isUnlocked(kind)), weaponCooldowns[kind, default: 0] <= 0 else { return }
        cancelAim()
        armedWeapon = kind
        spawnAimPreview(for: kind)
        host.notifyDelegate()
    }

    func beginAim(weapon: WeaponKind, key: ObjectIdentifier, location: CGPoint, timestamp: TimeInterval) {
        switch aimGesture(for: weapon) {
        case .tap:
            commitFire(weapon, aim: .point(location))
        case .tapOnNode(let name):
            guard let host else { return }
            let hitProp = host.nodes(at: location).contains { node in
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

    func updateAim(location: CGPoint, timestamp: TimeInterval) {
        guard let armedWeapon else { return }
        aimSamples.append((location, timestamp))
        aimSamples = Array(aimSamples.suffix(8))
        aimPathPoints.append(location)
        updateAimPreview(weapon: armedWeapon, location: location)
    }

    func endAim(location: CGPoint, timestamp: TimeInterval) {
        aimTouchKey = nil
        guard let host, let weapon = armedWeapon else { return }
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
            commitFire(weapon, aim: .line(origin: defenderMuzzle(host), through: location))
        case .paintPath:
            commitFire(weapon, aim: .path(aimPathPoints))
        }
    }

    func cancelAim() {
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
        host?.notifyDelegate()
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
        guard let host else { return }
        switch aimGesture(for: kind) {
        case .tap:
            break
        case .tapOnNode:
            aimPreviewNode = spawnTransformerPole(host)
        case .dragRelease:
            // Delivery Truck has no on-screen prop to drag — it starts off-screen and uses the
            // gesture's horizontal direction plus release height, so it gets a live lane preview
            // (drawn in updateAimPreview) rather than a ready sprite here.
            guard kind != .deliveryTruck, let node = makeDragReadyNode(for: kind, host) else { return }
            aimPreviewNode = node
            host.world.addChild(node)
        case .pendulumDragRelease:
            guard let node = makeDragReadyNode(for: kind, host) else { return }
            aimPreviewNode = node
            host.world.addChild(node)
        case .dragAimReleaseLine, .paintPath:
            break
        }
    }

    private func transformerPolePosition(_ host: WeaponSystemHost) -> CGPoint {
        CGPoint(x: host.houseFrame.minX - 90, y: host.groundY + 70)
    }

    /// A static pivot anchored near the top of the screen with the ball hanging below it at rest
    /// — the joint (built fresh in `swingWreckingBall` at release, not here) treats this as its
    /// rest arm length, so the ball's dragged-to position at release is what the pendulum swings
    /// from.
    private func wreckingBallPivotPosition(_ host: WeaponSystemHost) -> CGPoint {
        CGPoint(x: host.size.width * 0.5, y: host.size.height * 0.92)
    }
    private func wreckingBallArmLength(_ host: WeaponSystemHost) -> CGFloat {
        min(260, host.size.height * 0.42)
    }

    /// The tappable prop Transformer arms — expires after 6s if untapped so the player isn't
    /// stuck armed forever without spending the weapon's cooldown.
    private func spawnTransformerPole(_ host: WeaponSystemHost) -> SKNode {
        let pole = SKSpriteNode(texture: WeaponKind.transformer.authoredTexture, size: CGSize(width: 60, height: 108))
        pole.name = "transformerPole"
        pole.position = transformerPolePosition(host)
        pole.zPosition = 34
        host.world.addChild(pole)
        if host.settings.reducedMotion {
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
        host?.notifyDelegate()
    }

    private func weaponReadySpot(for kind: WeaponKind, _ host: WeaponSystemHost) -> CGPoint {
        switch kind {
        case .grenade:
            // Close to the diner — this is a hand-thrown weapon, it should visibly come from
            // the player's position at the window, not materialize at mid-field.
            return CGPoint(x: host.houseFrame.midX + host.houseFrame.width * 0.1, y: host.groundY + host.houseFrame.height * 0.3)
        default:
            return CGPoint(x: host.size.width * 0.5, y: host.groundY + 40)
        }
    }

    /// The weapon-prop sprite a `dragRelease` weapon presents at its ready spot when armed —
    /// physics-less until `commitFire` hands it to that weapon's fire function.
    private func makeDragReadyNode(for kind: WeaponKind, _ host: WeaponSystemHost) -> SKSpriteNode? {
        switch kind {
        case .bowlingBall:
            let ball = SKSpriteNode(texture: EquipmentArt.bowlingBall.texture)
            ball.size = EquipmentArt.bowlingBall.fittedSize(inside: CGSize(width: 67, height: 67))
            ball.name = WeaponKind.bowlingBall.rawValue
            ball.position = weaponReadySpot(for: kind, host)
            ball.zPosition = 30
            return ball
        case .grenade:
            let grenade = SKSpriteNode(texture: WeaponKind.grenade.authoredTexture, size: CGSize(width: 44, height: 58))
            grenade.name = WeaponKind.grenade.rawValue
            grenade.position = weaponReadySpot(for: kind, host)
            grenade.zPosition = 30
            return grenade
        case .propaneTank:
            let tank = SKSpriteNode(texture: WeaponKind.propaneTank.authoredTexture, size: CGSize(width: 86, height: 58))
            tank.name = WeaponKind.propaneTank.rawValue
            tank.position = weaponReadySpot(for: kind, host)
            tank.zPosition = 30
            return tank
        case .wreckingBall:
            let pivot = wreckingBallPivotPosition(host)
            let ball = SKSpriteNode(texture: WeaponKind.wreckingBall.authoredTexture, size: CGSize(width: 118, height: 118))
            ball.name = WeaponKind.wreckingBall.rawValue
            ball.position = CGPoint(x: pivot.x, y: pivot.y - wreckingBallArmLength(host))
            ball.zPosition = 30
            return ball
        default:
            return nil
        }
    }

    private func updateAimPreview(weapon: WeaponKind, location: CGPoint) {
        guard let host else { return }
        switch aimGesture(for: weapon) {
        case .tap, .tapOnNode:
            break
        case .dragRelease:
            if weapon == .deliveryTruck {
                updateDeliveryTruckPreview(from: aimOrigin ?? location, to: location)
            } else {
                aimPreviewNode?.position = CGPoint(
                    x: min(host.size.width - 30, max(30, location.x)),
                    y: min(host.size.height - 30, max(host.groundY + 20, location.y))
                )
            }
        case .dragAimReleaseLine:
            updateDirectionalPreview(from: defenderMuzzle(host), to: location, color: SKColor(red: 1, green: 0.82, blue: 0.28, alpha: 0.7))
        case .paintPath:
            updatePaintPathPreview(weapon: weapon)
        case .pendulumDragRelease:
            // Cosmetic-only clamp while dragging — the ball has no physics body yet (added fresh
            // in swingWreckingBall at release), so nothing here fights a physics constraint.
            let pivot = wreckingBallPivotPosition(host)
            let armLength = wreckingBallArmLength(host)
            let dx = location.x - pivot.x
            let dy = location.y - pivot.y
            let distance = max(1, hypot(dx, dy))
            let clamped = min(armLength, distance)
            let angle = atan2(dy, dx)
            aimPreviewNode?.position = CGPoint(x: pivot.x + cos(angle) * clamped, y: pivot.y + sin(angle) * clamped)
        }
    }

    /// Live polyline reading back the zone/path the player is painting, tinted per-weapon.
    private func updatePaintPathPreview(weapon: WeaponKind) {
        guard let host else { return }
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
        line.glowWidth = host.settings.reducedMotion ? 0 : 4
        line.zPosition = 133
        host.world.addChild(line)
        aimPreviewNode = line
    }

    /// Live drag-direction indicator for Sniper's aim line.
    private func updateDirectionalPreview(from origin: CGPoint, to location: CGPoint, color: SKColor) {
        guard let host else { return }
        aimPreviewNode?.removeFromParent()
        let path = CGMutablePath()
        path.move(to: origin)
        path.addLine(to: location)
        let line = SKShapeNode(path: path)
        line.strokeColor = color
        line.lineWidth = 3
        line.glowWidth = host.settings.reducedMotion ? 0 : 3
        line.zPosition = 133
        host.world.addChild(line)
        aimPreviewNode = line
    }

    /// Delivery Rush chooses its travel direction from the horizontal drag and its road lane from
    /// the release height. A full-width preview communicates the actual sweep instead of implying
    /// that the truck will follow the short gesture line literally.
    private func updateDeliveryTruckPreview(from origin: CGPoint, to location: CGPoint) {
        guard let host else { return }
        aimPreviewNode?.removeFromParent()
        let fromLeft = location.x >= origin.x
        let laneProgress = min(1, max(0, (location.y - host.groundY) / max(1, host.size.height - host.groundY)))
        let laneY = host.groundY + 52 + laneProgress * 20
        let path = CGMutablePath()
        path.move(to: CGPoint(x: fromLeft ? -24 : host.size.width + 24, y: laneY))
        path.addLine(to: CGPoint(x: fromLeft ? host.size.width + 24 : -24, y: laneY))
        let lane = SKShapeNode(path: path)
        lane.strokeColor = SKColor(red: 0.98, green: 0.77, blue: 0.24, alpha: 0.42)
        lane.lineWidth = 15
        lane.glowWidth = host.settings.reducedMotion ? 0 : 5

        let centerLine = SKShapeNode(path: path)
        centerLine.strokeColor = SKColor(red: 0.34, green: 0.92, blue: 0.95, alpha: 0.78)
        centerLine.lineWidth = 3

        let preview = SKNode()
        preview.zPosition = 133
        preview.addChild(lane)
        preview.addChild(centerLine)
        host.world.addChild(preview)
        aimPreviewNode = preview
    }

    func detonateIfHit(at location: CGPoint) -> Bool {
        guard let host else { return false }
        for node in host.nodes(at: location) {
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
        guard let host else { return }
        let preview = releaseAimPreview()
        if !Self.weaponsThatKeepPreview.contains(kind) { preview?.removeFromParent() }
        let weaponLevel = host.upgradeLevel(kind)
        weaponCooldowns[kind] = host.level.isSandbox ? 0 : GameRules.cooldown(base: kind.cooldown, rapidGearLevel: host.rapidGearLevel + weaponLevel)
        SoundManager.shared.playWeapon(kind)
        if kind == .shotgun || kind == .sniper { host.fireDefender() }
        switch kind {
        case .bowlingBall:
            if let flick = aim.resolvedFlick { launchBowlingBall(preview: preview, velocity: flick.velocity) }
        case .shotgun: fireScatterblast(toward: aim.resolvedPoint ?? CGPoint(x: host.size.width / 2, y: host.groundY + 110))
        case .airstrike: launchAirstrike(along: aim.resolvedPath ?? [CGPoint(x: host.size.width / 2, y: host.groundY + 54)])
        case .anvil: dropAnvils(at: aim.resolvedPoint ?? CGPoint(x: host.size.width / 2, y: 0))
        case .grenade:
            if let flick = aim.resolvedFlick { throwGrenade(preview: preview, velocity: flick.velocity) }
        case .propaneTank:
            if let flick = aim.resolvedFlick { launchPropaneTank(preview: preview, velocity: flick.velocity) }
        case .wreckingBall:
            if let flick = aim.resolvedFlick { swingWreckingBall(preview: preview, velocity: flick.velocity) }
        case .sniper:
            if let line = aim.resolvedLine { fireSniper(through: line.through) }
        case .greaseFire: igniteGreaseFire(along: aim.resolvedPath ?? [CGPoint(x: host.size.width / 2, y: host.groundY + 20)])
        case .transformer: chainLightning()
        case .deliveryTruck:
            if let flick = aim.resolvedFlick {
                launchDeliveryTruck(from: flick.origin, toward: flick.releasePoint, velocity: flick.velocity)
            }
        case .meteor: launchMeteor(target: aim.resolvedPoint ?? CGPoint(x: host.size.width / 2, y: host.groundY + 25))
        }
        host.notifyDelegate()
    }

    func useTrap(_ kind: TrapKind) {
        guard let host, host.isUnlocked(kind), trapCooldowns[kind, default: 0] <= 0, !host.gameOver else { return }
        trapCooldowns[kind] = GameRules.cooldown(base: kind.cooldown, rapidGearLevel: host.rapidGearLevel)
        SoundManager.shared.playTrap(kind)
        switch kind {
        case .spikeStrip: placeSpikeStrips()
        case .freezer: triggerFreezer()
        }
        host.notifyDelegate()
    }

    func useSpecial() {
        guard let host, host.specialCharge >= 1, !host.gameOver, !host.isGraveTimeDisabled else { return }
        host.specialCharge = 0
        SoundManager.shared.play(.special)
        SoundManager.shared.duckMusic(strength: 0.34, duration: 0.55)
        host.announce(text: "GRAVE TIME", color: .cyan, subtitle: nil, subtitleColor: .white)
        let slowDuration = 8 + host.perkSystem.graveTimeBonusDuration
        for zombie in host.activeZombies {
            zombie.slow(for: slowDuration, reducedMotion: host.settings.reducedMotion)
            zombie.physicsBody?.velocity.dx *= 0.35
            zombie.physicsBody?.velocity.dy *= 0.35
        }
        if !host.settings.reducedMotion {
            let wash = SKShapeNode(rectOf: host.size)
            wash.fillColor = .cyan.withAlphaComponent(0.18)
            wash.strokeColor = .clear
            wash.position = CGPoint(x: host.size.width / 2, y: host.size.height / 2)
            wash.zPosition = 180
            host.world.addChild(wash)
            wash.run(.sequence([.fadeOut(withDuration: 0.8), .removeFromParent()]))
        }
        host.notifyDelegate()
    }

    /// Central place for weapon-specific impact sounds, keyed by the WeaponKind name every weapon
    /// node is now tagged with, so a new weapon needing a unique impact sound is one case here
    /// instead of another hardcoded node-name branch in GameScene.didBegin.
    func impactSound(for weaponKind: WeaponKind) -> SoundManager.Effect? {
        weaponKind == .bowlingBall ? .bowlingImpact : nil
    }

    /// Running kill count stashed directly on a projectile's own `userData` (self-cleaning — it
    /// disappears with the node, no external dictionary to prune) so ZOMBIE BOWLING can tell a
    /// bowling ball's 2nd+ kill on a single roll apart from its first.
    func incrementKillTally(on node: SKNode?) -> Int {
        guard let node else { return 1 }
        let key = "killTally"
        let userData = node.userData ?? {
            let dictionary = NSMutableDictionary()
            node.userData = dictionary
            return dictionary
        }()
        let tally = ((userData[key] as? Int) ?? 0) + 1
        userData[key] = tally
        return tally
    }

    /// Contact callbacks can repeat while a fast, non-colliding body overlaps a zombie. Tracking
    /// each victim by identity in `deliveryTruckVictims` (keyed on the truck's own ObjectIdentifier,
    /// mirroring `detonatables` above) guarantees one damage event per pass and identifies the
    /// first collision, which earns the heavier audio/camera response. This avoids deriving a
    /// dictionary key from a zombie's hashValue, which is address-based and could collide with a
    /// new ZombieNode allocated at a since-deallocated victim's old address while the truck (whose
    /// entry is cleared in `launchDeliveryTruck` once it's removed) is still alive.
    func registerDeliveryTruckHit(on zombie: ZombieNode, truck node: SKNode?) -> (accepted: Bool, firstImpact: Bool) {
        guard let node, node.name == WeaponKind.deliveryTruck.rawValue else { return (true, false) }
        let truckKey = ObjectIdentifier(node)
        let zombieKey = ObjectIdentifier(zombie)
        var victims = deliveryTruckVictims[truckKey] ?? []
        guard !victims.contains(zombieKey) else { return (false, false) }
        let firstImpact = victims.isEmpty
        victims.insert(zombieKey)
        deliveryTruckVictims[truckKey] = victims
        return (true, firstImpact)
    }

    func tickCooldowns(_ deltaTime: TimeInterval) {
        for key in weaponCooldowns.keys { weaponCooldowns[key] = max(0, weaponCooldowns[key, default: 0] - deltaTime) }
        for key in trapCooldowns.keys { trapCooldowns[key] = max(0, trapCooldowns[key, default: 0] - deltaTime) }
    }

    func explodeVolatile(at point: CGPoint) {
        guard let host else { return }
        let radius: CGFloat = 170 * host.perkSystem.volatileBlastRadiusBonus
        let nearby = host.activeZombies.filter {
            !$0.isDefeated && hypot($0.position.x - point.x, $0.position.y - point.y) < radius
        }
        var killTally = 0
        for zombie in nearby {
            if zombie.damage(1.6) {
                killTally += 1
                host.comboSystem.defeat(zombie, reason: .explosion, multiKillTally: killTally)
            } else {
                zombie.launch(with: radialImpulse(from: point, to: zombie.position, radius: radius, maxImpulse: 380, minImpulse: 140))
            }
        }
        if killTally >= 10 { host.recordFeat("chain_reaction_10") }
        host.playCombatVFX(.volatileBurst, at: point, size: 270, direction: 1, tint: nil)
        SoundManager.shared.play(.explosion)
        SoundManager.shared.duckMusic(strength: 0.48, duration: 0.42)
        host.shakeCamera(intensity: 1.2)
    }

    /// `preview` is the ready sprite the player dragged (see `makeDragReadyNode`); falls back to
    /// spawning fresh only if a shot somehow arrives with no preview (defensive, shouldn't happen).
    private func launchBowlingBall(preview: SKNode?, velocity: CGVector) {
        guard let host else { return }
        let ball = (preview as? SKSpriteNode) ?? {
            let fallback = SKSpriteNode(texture: EquipmentArt.bowlingBall.texture)
            fallback.size = EquipmentArt.bowlingBall.fittedSize(inside: CGSize(width: 67, height: 67))
            fallback.position = CGPoint(x: host.size.width * 0.5, y: host.groundY + 34)
            host.world.addChild(fallback)
            return fallback
        }()
        ball.name = WeaponKind.bowlingBall.rawValue
        ball.zPosition = 30
        // Matches the ~82% shrink, then a further ~55% shrink, applied to ZombieKind.size — a
        // full-size ball rolling through the now-smaller zombies would be relatively chunkier
        // than intended, hitting more of each body than the original size ratio called for.
        ball.physicsBody = SKPhysicsBody(circleOfRadius: 12)
        ball.physicsBody?.mass = 3.5
        // GUTTER? NEVER HEARD OF HER: bouncing off the boundary (instead of just rolling past it
        // and despawning) turns one throw into several passes through the crowd, so it also gets a
        // livelier bounce and a longer lifetime to actually use it.
        ball.physicsBody?.restitution = host.perkSystem.hasBowlingRicochet ? 0.62 : 0.32
        ball.physicsBody?.friction = 0.7
        ball.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        ball.physicsBody?.collisionBitMask = PhysicsCategory.zombie | PhysicsCategory.ground | (host.perkSystem.hasBowlingRicochet ? PhysicsCategory.boundary : PhysicsCategory.none)
        ball.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        ball.physicsBody?.velocity = velocity
        SoundManager.shared.play(.bowlingRoll)
        if !host.settings.reducedMotion {
            ball.run(.repeatForever(.rotate(byAngle: velocity.dx < 0 ? .pi * 2 : -.pi * 2, duration: 0.38)), withKey: "roll")
        }
        ball.run(.sequence([.wait(forDuration: host.perkSystem.hasBowlingRicochet ? 9 : 5), .removeFromParent()]))
    }

    /// Half-angle of the scatterblast cone, in radians (~22°).
    private let scatterblastHalfAngle: CGFloat = 0.38
    private func scatterblastRange(_ host: WeaponSystemHost) -> CGFloat { host.size.width * 0.62 }

    /// Knockback follows the real direction to each zombie (not a flattened left/right), and both
    /// damage and impulse taper with distance from the muzzle: a point-blank hit sends a zombie
    /// flying, a zombie at the edge of the cone's range barely staggers.
    private func fireScatterblast(toward aimPoint: CGPoint) {
        guard let host else { return }
        let origin = defenderMuzzle(host)
        let aimAngle = atan2(aimPoint.y - origin.y, aimPoint.x - origin.x)
        let range = scatterblastRange(host)
        let zombies = host.activeZombies.filter { !$0.isDefeated }
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
            if zombie.damage(damage) { host.comboSystem.defeat(zombie, reason: .weapon, multiKillTally: 1, weaponKind: nil) }
        }
        fireBuckshotSpread(from: origin, angle: aimAngle)
        radialFlash(at: origin, color: .yellow)
        host.playDirectionalDebris(at: origin, color: .orange, direction: cos(aimAngle) < 0 ? -1 : 1, count: 10)
        host.shakeCamera(intensity: 0.8)
    }

    private func shortestAngleDelta(from a: CGFloat, to b: CGFloat) -> CGFloat {
        var delta = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return delta
    }

    /// Authored pellet-cluster sprite reading as a shotgun blast out of the defender's window,
    /// rotated to the aimed direction and shot outward along it so the blast itself is legible
    /// instead of looking like an unexplained shockwave.
    private func fireBuckshotSpread(from origin: CGPoint, angle: CGFloat) {
        guard let host, host.settings.flashesEnabled else { return }
        let range = scatterblastRange(host)
        let texture = SKTexture(imageNamed: "weapon_scatterblast_pellets")
        let aspect = texture.size().height / max(1, texture.size().width)
        // Scales with `scatterblastRange` (itself screen-width-based) instead of a fixed size, so
        // the blast reads proportionally the same on a small phone and a wide iPad rather than
        // looking oversized or tiny relative to the cone it's actually covering.
        let width = min(220, max(90, range * 0.3))
        let pellets = SKSpriteNode(texture: texture, size: CGSize(width: width, height: width * aspect))
        pellets.position = CGPoint(x: origin.x + cos(angle) * range * 0.3, y: origin.y + sin(angle) * range * 0.3)
        pellets.zRotation = angle
        pellets.zPosition = 133
        host.world.addChild(pellets)
        let travel = CGVector(dx: cos(angle) * range * 0.62, dy: sin(angle) * range * 0.62)
        pellets.run(.sequence([
            .group([.move(by: travel, duration: host.settings.reducedMotion ? 0.08 : 0.14), .fadeOut(withDuration: host.settings.reducedMotion ? 0.08 : 0.14)]),
            .removeFromParent()
        ]))
    }

    /// Impact count/spacing scale with the painted swipe's length (2–5 impacts) instead of the
    /// old fixed 3-point pattern.
    private func launchAirstrike(along path: [CGPoint]) {
        guard let host else { return }
        let xs = path.map(\.x)
        let minX = xs.min() ?? host.size.width * 0.18
        let maxX = xs.max() ?? host.size.width * 0.82
        let span = maxX - minX
        let impactCount = span < 40 ? 2 : min(5, max(2, Int(span / 90) + 2))
        let targets: [CGFloat] = (0..<impactCount).map { index in
            impactCount == 1 ? (minX + maxX) / 2 : minX + span * CGFloat(index) / CGFloat(impactCount - 1)
        }

        let beacon = SKSpriteNode(texture: EquipmentArt.airstrikeBeacon.actionFrames[0], size: CGSize(width: 108, height: 108))
        beacon.position = CGPoint(x: (minX + maxX) / 2, y: host.groundY + 54)
        beacon.zPosition = 32
        beacon.setScale(0.05)
        host.world.addChild(beacon)
        if host.settings.reducedMotion { beacon.texture = EquipmentArt.airstrikeBeacon.actionFrames[1] }
        else { beacon.run(.repeatForever(.animate(with: EquipmentArt.airstrikeBeacon.actionFrames, timePerFrame: 0.16, resize: false, restore: true)), withKey: "artFrames") }
        if host.settings.reducedMotion {
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
            host.world.run(.sequence([
                .wait(forDuration: Double(index) * 0.24),
                .run { [weak self] in self?.airstrikeImpact(x: x) }
            ]))
        }
    }

    /// A single tap-targeted anvil, replacing the old auto-drop-on-up-to-3-nearest-zombies — a
    /// deliberate trade of total coverage for precision, since the player now aims it themselves.
    private func dropAnvils(at target: CGPoint) {
        guard let host else { return }
        let anvil = SKSpriteNode(texture: WeaponKind.anvil.authoredTexture, size: CGSize(width: 82, height: 68))
        anvil.name = WeaponKind.anvil.rawValue
        anvil.position = CGPoint(x: target.x, y: host.size.height + 45)
        anvil.zPosition = 40
        anvil.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 58, height: 42))
        anvil.physicsBody?.mass = 5
        anvil.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        anvil.physicsBody?.collisionBitMask = PhysicsCategory.zombie | PhysicsCategory.ground
        anvil.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        host.world.addChild(anvil)
        anvil.run(.sequence([.wait(forDuration: 4), .removeFromParent()]))
    }

    /// Drag-thrown, physics-bounced grenade with a fixed fuse — explodes wherever it's landed
    /// ~2.2s after release, via the same point-based `throwExplosive` propane/meteor use.
    private func throwGrenade(preview: SKNode?, velocity: CGVector) {
        guard let host else { return }
        let grenade = (preview as? SKSpriteNode) ?? {
            let fallback = SKSpriteNode(texture: WeaponKind.grenade.authoredTexture, size: CGSize(width: 44, height: 58))
            fallback.position = weaponReadySpot(for: .grenade, host)
            host.world.addChild(fallback)
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
        attachFuseSpark(to: grenade, host)
        grenade.run(.sequence([
            .wait(forDuration: 2.2),
            .run { [weak self, weak grenade] in
                guard let self, let grenade else { return }
                self.throwExplosive(at: grenade.position, radius: 150, damage: 4.5, effect: .grenadeExplosion)
                grenade.removeFromParent()
            }
        ]))
    }

    private func attachFuseSpark(to grenade: SKNode, _ host: WeaponSystemHost) {
        guard !host.settings.reducedMotion else { return }
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
        guard let host else { return }
        let tank = (preview as? SKSpriteNode) ?? {
            let fallback = SKSpriteNode(texture: WeaponKind.propaneTank.authoredTexture, size: CGSize(width: 86, height: 58))
            fallback.position = CGPoint(x: host.size.width * 0.5, y: host.groundY + 34)
            host.world.addChild(fallback)
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
            self.throwExplosive(at: tank.position, radius: 175, damage: 5.5, effect: .propaneExplosion)
            tank.removeFromParent()
        }
        detonatables[key] = Detonatable(node: tank, detonate: detonate)
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

    private func throwExplosive(at point: CGPoint, radius rawRadius: CGFloat, damage: CGFloat, maxImpulse: CGFloat = 460, minImpulse: CGFloat = 140, effect: CombatVFX?) {
        guard let host else { return }
        let radius = rawRadius * host.perkSystem.explosiveWeaponRadiusBonus
        var killTally = 0
        for zombie in host.activeZombies where !zombie.isDefeated && hypot(zombie.position.x - point.x, zombie.position.y - point.y) < radius {
            if zombie.damage(damage * zombie.kind.weaponDamageMultiplier, canOverkill: true) {
                killTally += 1
                host.comboSystem.defeat(zombie, reason: .explosion, multiKillTally: killTally, weaponKind: nil)
            } else {
                zombie.launch(with: radialImpulse(from: point, to: zombie.position, radius: radius, maxImpulse: maxImpulse, minImpulse: minImpulse))
            }
        }
        if killTally >= 10 { host.recordFeat("chain_reaction_10") }
        if let effect {
            host.playCombatVFX(effect, at: point, size: radius * 1.7, direction: 1, tint: nil)
        }
        SoundManager.shared.play(.explosion)
        SoundManager.shared.duckMusic(strength: 0.48, duration: 0.42)
    }

    /// A real `SKPhysicsJointPin` pendulum instead of the old scripted (non-physics) sweep. The
    /// joint is built here, fresh, using wherever the ball was dragged to at release — not up
    /// front when armed — so its rest arm always matches the ball's actual release position
    /// instead of risking a snap back to a stale offset computed before the drag.
    private func swingWreckingBall(preview: SKNode?, velocity: CGVector) {
        guard let host else { return }
        let pivot = wreckingBallPivotPosition(host)
        let armLength = wreckingBallArmLength(host)
        let ball = (preview as? SKSpriteNode) ?? {
            let fallback = SKSpriteNode(texture: WeaponKind.wreckingBall.authoredTexture, size: CGSize(width: 118, height: 118))
            fallback.position = CGPoint(x: pivot.x, y: pivot.y - armLength)
            host.world.addChild(fallback)
            return fallback
        }()
        ball.name = WeaponKind.wreckingBall.rawValue
        ball.zPosition = 30

        let anchor = SKNode()
        anchor.position = pivot
        anchor.physicsBody = SKPhysicsBody(circleOfRadius: 4)
        anchor.physicsBody?.isDynamic = false
        anchor.physicsBody?.categoryBitMask = PhysicsCategory.none
        anchor.physicsBody?.collisionBitMask = PhysicsCategory.none
        anchor.physicsBody?.contactTestBitMask = PhysicsCategory.none
        host.world.addChild(anchor)

        ball.physicsBody = SKPhysicsBody(circleOfRadius: 50)
        ball.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        ball.physicsBody?.collisionBitMask = PhysicsCategory.none
        ball.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        ball.physicsBody?.mass = 4
        ball.physicsBody?.linearDamping = 0.25
        ball.physicsBody?.angularDamping = 0.4
        ball.physicsBody?.velocity = velocity

        let joint = SKPhysicsJointPin.joint(withBodyA: anchor.physicsBody!, bodyB: ball.physicsBody!, anchor: anchor.position)
        host.physicsWorld.add(joint)

        host.world.run(.sequence([
            .wait(forDuration: 6),
            .run { [weak self, weak anchor, weak ball] in
                guard let self else { return }
                self.host?.physicsWorld.remove(joint)
                anchor?.removeFromParent()
                ball?.removeFromParent()
            }
        ]))
    }

    /// Drag-aimed piercing shot: everything within a body-width of the aimed line gets hit, full
    /// damage on the first zombie in the line with falloff per zombie behind it, capped at 4 —
    /// turns the old single-target near-guaranteed kill into a lane-clear tool.
    private func fireSniper(through releasePoint: CGPoint) {
        guard let host else { return }
        let origin = defenderMuzzle(host)
        let raw = CGVector(dx: releasePoint.x - origin.x, dy: releasePoint.y - origin.y)
        let rawLength = max(1, hypot(raw.dx, raw.dy))
        let unit = CGVector(dx: raw.dx / rawLength, dy: raw.dy / rawLength)
        let lineEnd = CGPoint(x: origin.x + unit.dx * host.size.width * 1.6, y: origin.y + unit.dy * host.size.width * 1.6)
        // Matches the ~82% shrink, then a further ~55% shrink, applied to ZombieKind.size, so the
        // pierce band still tracks roughly one body-width instead of becoming relatively wider
        // than the zombies it's testing against.
        let tolerance: CGFloat = 12

        let pierced = host.activeZombies.filter { !$0.isDefeated }.compactMap { zombie -> (zombie: ZombieNode, along: CGFloat)? in
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
        tracer.lineWidth = host.settings.reducedMotion ? 2 : 4
        tracer.glowWidth = host.settings.reducedMotion ? 0 : 5
        tracer.zPosition = 134
        host.world.addChild(tracer)
        tracer.run(.sequence([.wait(forDuration: 0.04), .fadeOut(withDuration: 0.10), .removeFromParent()]))

        for (index, entry) in pierced.enumerated() {
            let zombie = entry.zombie
            let falloff = pow(0.5, CGFloat(index))
            let hitDamage = (zombie.kind.isBoss ? zombie.kind.hitPoints * 0.14 : zombie.kind.hitPoints * 1.2) * falloff
            if zombie.damage(hitDamage) { host.comboSystem.defeat(zombie, reason: .weapon, multiKillTally: 1, weaponKind: nil) }
            host.playDirectionalDebris(at: zombie.position, color: .yellow, direction: zombie.approachesFromLeft ? -1 : 1, count: max(2, 6 - index))
        }
        if !pierced.isEmpty { host.hitStop(duration: 0.14, slowFactor: 0.04) }
    }

    /// The painted zone's x-range replaces the old fixed ~420px-wide band at screen center,
    /// clamped so a barely-there swipe and a full-screen swipe both stay reasonable.
    private func igniteGreaseFire(along path: [CGPoint]) {
        guard let host else { return }
        let xs = path.map(\.x)
        let minX = xs.min() ?? host.size.width / 2
        let maxX = xs.max() ?? host.size.width / 2
        let width = min(320, max(140, maxX - minX))
        let halfWidth = width / 2
        let center = CGPoint(x: (minX + maxX) / 2, y: host.groundY + 20)
        for tick in 0..<5 {
            host.world.run(.sequence([.wait(forDuration: Double(tick) * 0.5), .run { [weak self] in
                guard let self, let host = self.host else { return }
                for zombie in host.activeZombies where !zombie.isDefeated && abs(zombie.position.x - center.x) < halfWidth {
                    if zombie.damage(0.85 * zombie.kind.weaponDamageMultiplier) { host.comboSystem.defeat(zombie, reason: .weapon, multiKillTally: 1, weaponKind: nil) }
                }
                host.playCombatVFX(.greaseFireExplosion, at: center, size: halfWidth * 2.1, direction: 1, tint: nil)
            }]))
        }
    }

    /// Chains outward from the tapped pole, nearest zombie first — previously chained through
    /// the first 6 zombies in spawn order, regardless of where they actually were.
    private func chainLightning() {
        guard let host else { return }
        let origin = transformerPolePosition(host)
        let ordered = host.activeZombies
            .filter { !$0.isDefeated }
            .sorted { hypot($0.position.x - origin.x, $0.position.y - origin.y) < hypot($1.position.x - origin.x, $1.position.y - origin.y) }
            .prefix(6)
        for (index, zombie) in ordered.enumerated() {
            host.world.run(.sequence([.wait(forDuration: Double(index) * 0.09), .run { [weak self, weak zombie] in
                guard let self, let zombie, let host = self.host else { return }
                if zombie.damage(2.4 * zombie.kind.weaponDamageMultiplier) { host.comboSystem.defeat(zombie, reason: .weapon, multiKillTally: 1, weaponKind: nil) }
                self.radialFlash(at: zombie.position, color: .cyan)
            }]))
        }
        radialFlash(at: origin, color: .cyan)
    }

    /// The horizontal flick selects the entry side and the release height selects a lane. The
    /// truck holds that lane for a reliable sweep instead of drifting diagonally away from the
    /// player's preview.
    private func launchDeliveryTruck(from origin: CGPoint, toward releasePoint: CGPoint, velocity: CGVector) {
        guard let host else { return }
        let fallbackIntent = releasePoint.x - origin.x
        let horizontalIntent = abs(velocity.dx) >= 80 ? velocity.dx : fallbackIntent
        let fromLeft = horizontalIntent == 0 ? origin.x < host.size.width / 2 : horizontalIntent > 0
        let laneProgress = min(1, max(0, (releasePoint.y - host.groundY) / max(1, host.size.height - host.groundY)))
        let laneY = host.groundY + 52 + laneProgress * 20
        let truck = SKSpriteNode(texture: DeliveryTruckArt.driveFrames[0], size: CGSize(width: 210, height: 118))
        truck.name = WeaponKind.deliveryTruck.rawValue
        truck.position = CGPoint(x: fromLeft ? -130 : host.size.width + 130, y: laneY)
        // Source art faces left; mirror only when the truck is driving right.
        truck.xScale = fromLeft ? -1 : 1
        truck.zPosition = 35
        truck.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 190, height: 82))
        truck.physicsBody?.affectedByGravity = false
        truck.physicsBody?.categoryBitMask = PhysicsCategory.weapon
        truck.physicsBody?.collisionBitMask = PhysicsCategory.none
        truck.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
        let travelDistance = host.size.width + 240
        let dx: CGFloat = (fromLeft ? 1 : -1) * travelDistance / 1.05
        truck.physicsBody?.velocity = .zero
        host.world.addChild(truck)
        spawnDeliveryTruckHeadlightFlash(at: truck.position, direction: fromLeft ? 1 : -1)

        if !host.settings.reducedMotion {
            truck.run(.repeatForever(.animate(with: DeliveryTruckArt.driveFrames, timePerFrame: 0.085, resize: false, restore: false)), withKey: "driveCycle")
            truck.run(.repeatForever(.sequence([
                .run { [weak self, weak truck] in
                    guard let truck else { return }
                    self?.spawnDeliveryTruckTrail(behind: truck, direction: fromLeft ? 1 : -1)
                },
                .wait(forDuration: 0.075),
            ])), withKey: "roadTrail")
        }
        let truckKey = ObjectIdentifier(truck)
        truck.run(.sequence([
            .wait(forDuration: 0.12),
            .run { [weak truck] in truck?.physicsBody?.velocity = CGVector(dx: dx, dy: 0) },
            .wait(forDuration: 1.05),
            .fadeOut(withDuration: 0.15),
            .run { [weak self, weak truck] in
                self?.deliveryTruckVictims.removeValue(forKey: truckKey)
                truck?.removeFromParent()
            },
        ]))
    }

    private func spawnDeliveryTruckHeadlightFlash(at point: CGPoint, direction: CGFloat) {
        guard let host, host.settings.flashesEnabled else { return }
        let flash = SKShapeNode(ellipseOf: CGSize(width: 92, height: 42))
        flash.fillColor = SKColor(red: 0.40, green: 0.96, blue: 1, alpha: 0.34)
        flash.strokeColor = SKColor(red: 0.72, green: 1, blue: 1, alpha: 0.78)
        flash.glowWidth = host.settings.reducedMotion ? 0 : 8
        flash.position = CGPoint(x: point.x + direction * 88, y: point.y + 8)
        flash.zPosition = 34
        host.world.addChild(flash)
        flash.run(.sequence([.group([.scale(to: 1.8, duration: 0.14), .fadeOut(withDuration: 0.18)]), .removeFromParent()]))
    }

    private func spawnDeliveryTruckTrail(behind truck: SKNode, direction: CGFloat) {
        guard let host else { return }
        for offset in [CGFloat(-10), 8] {
            let puff = SKShapeNode(circleOfRadius: CGFloat.random(in: 5...11))
            puff.fillColor = Bool.random()
                ? SKColor(red: 0.22, green: 0.26, blue: 0.27, alpha: 0.42)
                : SKColor(red: 0.20, green: 0.78, blue: 0.82, alpha: 0.30)
            puff.strokeColor = .clear
            puff.position = CGPoint(x: truck.position.x - direction * 94, y: truck.position.y - 32 + offset)
            puff.zPosition = 32
            host.world.addChild(puff)
            puff.run(.sequence([
                .group([
                    .moveBy(x: -direction * CGFloat.random(in: 20...42), y: CGFloat.random(in: 8...24), duration: 0.30),
                    .scale(to: 1.8, duration: 0.30),
                    .fadeOut(withDuration: 0.32),
                ]),
                .removeFromParent(),
            ]))
        }
    }

    private func launchMeteor(target rawTarget: CGPoint) {
        guard let host else { return }
        let target = CGPoint(x: rawTarget.x, y: host.groundY + 25)
        spawnMeteorWarning(at: target)
        host.world.run(.sequence([
            .wait(forDuration: 0.6),
            .run { [weak self] in self?.dropMeteor(at: target) }
        ]))
    }

    private func dropMeteor(at target: CGPoint) {
        guard let host else { return }
        // Frame 1's rock sits toward the streak's leading (lower-right) end, not canvas center —
        // anchoring there instead of (0.5, 0.5) keeps the actual rock tracking toward `target`
        // instead of the mostly-empty tail padding.
        let meteor = SKSpriteNode(texture: EquipmentArt.meteor.actionFrames[0], size: CGSize(width: 150, height: 150))
        meteor.anchorPoint = CGPoint(x: 0.75, y: 0.32)
        meteor.xScale = -1 // art's nose points down-right; flight path here always goes down-left
        meteor.position = CGPoint(x: target.x + 160, y: host.size.height + 80)
        meteor.zPosition = 140
        host.world.addChild(meteor)
        meteor.run(.sequence([
            .move(to: target, duration: 0.48),
            .run { [weak self] in self?.resolveMeteorImpact(at: target) },
            .removeFromParent()
        ]))
    }

    /// Ground reticle telegraphing where the meteor will land before it drops, so the tap-aimed
    /// target reads clearly instead of the impact appearing without warning.
    private func spawnMeteorWarning(at target: CGPoint) {
        guard let host else { return }
        let reticle = SKShapeNode(ellipseOf: CGSize(width: 130, height: 40))
        reticle.strokeColor = SKColor(red: 1, green: 0.42, blue: 0.12, alpha: 0.85)
        reticle.lineWidth = 3
        reticle.glowWidth = host.settings.reducedMotion ? 0 : 4
        reticle.fillColor = SKColor(red: 1, green: 0.30, blue: 0.05, alpha: 0.16)
        reticle.position = CGPoint(x: target.x, y: host.groundY + 6)
        reticle.zPosition = 6
        host.world.addChild(reticle)
        reticle.run(.sequence([
            .repeat(.sequence([.fadeAlpha(to: 0.35, duration: 0.16), .fadeAlpha(to: 1, duration: 0.16)]), count: host.settings.reducedMotion ? 1 : 2),
            .wait(forDuration: 0.08),
            .removeFromParent()
        ]))
    }

    private func resolveMeteorImpact(at target: CGPoint) {
        playMeteorImpactArt(at: target)
        // Bigger radial impulse than a grenade/propane blast, matching the "enormous physics
        // impulse" this weapon is meant for.
        throwExplosive(at: target, radius: 260, damage: 10, maxImpulse: 640, minImpulse: 220, effect: nil)
    }

    /// Bespoke impact-flash-to-smoke-cloud sequence. The radial damage call deliberately skips a
    /// CombatVFX overlay so this authored Meteor art remains the complete visual identity.
    /// Both frames are composed with their ground contact at the very bottom of the canvas, so a
    /// bottom-center anchor keeps the explosion rooted at `target` instead of floating around it.
    private func playMeteorImpactArt(at target: CGPoint) {
        guard let host else { return }
        let impact = SKSpriteNode(texture: EquipmentArt.meteor.actionFrames[1], size: CGSize(width: 280, height: 280))
        impact.anchorPoint = CGPoint(x: 0.5, y: 0)
        impact.position = target
        impact.zPosition = 135
        impact.alpha = 0
        host.world.addChild(impact)
        impact.run(.sequence([
            .group([.fadeIn(withDuration: 0.05), .scale(to: 1.1, duration: 0.12)]),
            .wait(forDuration: 0.10),
            .run { impact.texture = EquipmentArt.meteor.actionFrames[2] },
            .wait(forDuration: 0.26),
            .fadeOut(withDuration: 0.30),
            .removeFromParent()
        ]))
    }

    private func indexDirection(for x: CGFloat, _ host: WeaponSystemHost) -> CGFloat {
        x < host.size.width / 2 ? -1 : 1
    }

    private func radialFlash(at point: CGPoint, color: SKColor) {
        guard let host, host.settings.flashesEnabled else { return }
        let ring = SKShapeNode(circleOfRadius: 24)
        ring.fillColor = .clear
        ring.strokeColor = color
        ring.lineWidth = 12
        ring.position = point
        ring.zPosition = 130
        host.world.addChild(ring)
        ring.run(.sequence([.group([.scale(to: host.settings.reducedMotion ? 2 : 7, duration: 0.32), .fadeOut(withDuration: 0.34)]), .removeFromParent()]))
    }

    private func airstrikeImpact(x: CGFloat) {
        guard let host else { return }
        let point = CGPoint(x: x, y: host.groundY + 35)
        for zombie in host.activeZombies where !zombie.isDefeated && abs(zombie.position.x - x) < host.size.width * 0.22 {
            if zombie.damage(5) { host.comboSystem.defeat(zombie, reason: .weapon, multiKillTally: 1, weaponKind: nil) }
        }
        host.playCombatVFX(.airstrikeExplosion, at: point, size: 238, direction: indexDirection(for: x, host), tint: nil)
        SoundManager.shared.play(.explosion)
        SoundManager.shared.duckMusic(strength: 0.44, duration: 0.36)
        host.shakeCamera(intensity: 1.1)
    }

    private func placeSpikeStrips() {
        guard let host else { return }
        for x in [host.houseFrame.minX - 115, host.houseFrame.maxX + 115] {
            let strip = SKSpriteNode(texture: EquipmentArt.spikeStrip.actionFrames[0], size: CGSize(width: 135, height: 54))
            strip.position = CGPoint(x: x, y: host.groundY + 10)
            strip.zPosition = 8
            strip.physicsBody = SKPhysicsBody(rectangleOf: CGSize(width: 125, height: 30))
            strip.physicsBody?.isDynamic = false
            strip.physicsBody?.categoryBitMask = PhysicsCategory.trap
            strip.physicsBody?.collisionBitMask = PhysicsCategory.none
            strip.physicsBody?.contactTestBitMask = PhysicsCategory.zombie
            host.world.addChild(strip)
            if host.settings.reducedMotion { strip.texture = EquipmentArt.spikeStrip.actionFrames[2] }
            else { strip.run(.animate(with: EquipmentArt.spikeStrip.actionFrames, timePerFrame: 0.09, resize: false, restore: false), withKey: "artFrames") }
            if !host.settings.reducedMotion {
                strip.setScale(0.15)
                strip.run(.sequence([.scale(to: 1.12, duration: 0.12), .scale(to: 1, duration: 0.1)]))
            }
            strip.run(.sequence([.wait(forDuration: 9), .fadeOut(withDuration: 0.3), .removeFromParent()]))
        }
    }

    private func triggerFreezer() {
        guard let host else { return }
        let freezer = SKSpriteNode(texture: EquipmentArt.flashFreezer.actionFrames[0], size: CGSize(width: 150, height: 116))
        freezer.position = CGPoint(x: host.size.width / 2, y: host.groundY + 58)
        freezer.zPosition = 136
        host.world.addChild(freezer)
        if host.settings.reducedMotion { freezer.texture = EquipmentArt.flashFreezer.actionFrames[2] }
        else { freezer.run(.animate(with: EquipmentArt.flashFreezer.actionFrames, timePerFrame: 0.10, resize: false, restore: false), withKey: "artFrames") }
        if !host.settings.reducedMotion {
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
        for zombie in host.activeZombies where !zombie.isDefeated && !zombie.isGrabbed && !zombie.isThrown {
            zombie.freezeSolid(for: 7, reducedMotion: host.settings.reducedMotion)
        }
        host.playCombatVFX(.freezerBurst, at: CGPoint(x: host.size.width / 2, y: host.groundY + 84), size: min(host.size.width * 0.72, 520), direction: 1, tint: nil)
        radialFlash(at: CGPoint(x: host.size.width / 2, y: host.size.height / 2), color: .cyan)
    }
}
