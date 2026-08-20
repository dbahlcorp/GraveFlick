import SpriteKit
import UIKit

@MainActor
protocol InteractionControllerHost: AnyObject {
    var isGameplayPaused: Bool { get }
    var gameOver: Bool { get }
    var level: GameLevel { get }
    var settings: GameSettings { get }
    var groundY: CGFloat { get }
    var weaponSystem: WeaponSystem { get }
    var flickMultiplier: CGFloat { get }

    func collectPickup(at location: CGPoint) -> Bool
    func runHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle)
    func hitStop(duration: TimeInterval, slowFactor: CGFloat)
}

/// Grab/drag/flick input for zombies — touch tracking, dual-touch pinch/rotate, and the
/// release-to-flick velocity calculation. Owned by GameScene via `interactionController`.
///
/// A touch isn't claimed as a zombie grab until weapon aiming (WeaponSystem.detonateIfHit/
/// armedWeapon) and pickup collection have both had first refusal — those stay routed through
/// the host since they're not zombie-interaction concerns, just higher-priority interpretations
/// of the same touch. GameScene's touchesBegan/Moved/Ended/Cancelled overrides are thin
/// forwarders into this controller's matching methods, passing the scene itself so this can call
/// `UITouch.location(in:)`/`SKNode.nodes(at:)` without the host needing to wrap them.
///
/// @MainActor because GameScene (its sole host/caller) is implicitly main-actor-isolated via
/// SKScene, and this calls SoundManager (also @MainActor) directly.
@MainActor
final class InteractionController {
    weak var host: InteractionControllerHost?

    private var selectedZombies: [ObjectIdentifier: ZombieNode] = [:]
    private var touchSamples: [ObjectIdentifier: [(point: CGPoint, time: TimeInterval)]] = [:]
    private var dualTouchBaseline: (distance: CGFloat, angle: CGFloat)?

    /// Set whenever a release flicks a zombie — read by GameScene's GRACEFUL_WAVE feat check.
    var playerThrewThisWave = false
    /// Set by GameScene's didBegin() when a zombie the player actually flicked (not one an
    /// explosion/collision knocked) hits the ground — see ZombieNode.wasPlayerThrown.
    var playerThrownZombieGroundedThisWave = false

    func touchesBegan(_ touches: Set<UITouch>, in scene: SKScene) {
        guard let host, !host.isGameplayPaused, !host.gameOver else { return }
        let weaponSystem = host.weaponSystem
        for touch in touches {
            let key = ObjectIdentifier(touch)
            let location = touch.location(in: scene)
            if weaponSystem.detonateIfHit(at: location) { continue }
            if let armedWeapon = weaponSystem.armedWeapon {
                guard weaponSystem.aimTouchKey == nil else { continue }
                weaponSystem.beginAim(weapon: armedWeapon, key: key, location: location, timestamp: touch.timestamp)
                continue
            }
            if host.collectPickup(at: location) { continue }
            guard host.level.modifier != .noGrab, let zombie = zombie(at: location, in: scene), zombie.canBeGrabbed else { continue }
            let existingTouches = selectedZombies.values.filter { $0 === zombie }.count
            guard existingTouches < 2 else { continue }
            selectedZombies[key] = zombie
            touchSamples[key] = [(location, touch.timestamp)]
            if existingTouches == 0 { zombie.beginGrab(reducedMotion: host.settings.reducedMotion) }
            zombie.zPosition = 100
            SoundManager.shared.play(.grab)
            host.runHaptic(.light)
        }
        updateDualTouchGesture()
    }

    func touchesMoved(_ touches: Set<UITouch>, in scene: SKScene) {
        guard let host else { return }
        let weaponSystem = host.weaponSystem
        for touch in touches {
            let key = ObjectIdentifier(touch)
            if key == weaponSystem.aimTouchKey {
                weaponSystem.updateAim(location: touch.location(in: scene), timestamp: touch.timestamp)
                continue
            }
            guard let zombie = selectedZombies[key] else { continue }
            let location = touch.location(in: scene)
            zombie.position = CGPoint(
                x: min(scene.size.width - 20, max(20, location.x)),
                y: min(scene.size.height - 25, max(host.groundY + zombie.kind.size.height * 0.39 + 4, location.y))
            )
            touchSamples[key, default: []].append((location, touch.timestamp))
            touchSamples[key] = Array(touchSamples[key, default: []].suffix(8))
        }
        updateDualTouchGesture()
    }

    func touchesEnded(_ touches: Set<UITouch>, in scene: SKScene) {
        guard let host else { return }
        let weaponSystem = host.weaponSystem
        for touch in touches {
            if ObjectIdentifier(touch) == weaponSystem.aimTouchKey {
                weaponSystem.endAim(location: touch.location(in: scene), timestamp: touch.timestamp)
            } else {
                release(touch, in: scene)
            }
        }
        if selectedZombies.count < 2 { dualTouchBaseline = nil }
    }

    func touchesCancelled(_ touches: Set<UITouch>, in scene: SKScene) {
        guard let host else { return }
        let weaponSystem = host.weaponSystem
        for touch in touches {
            if ObjectIdentifier(touch) == weaponSystem.aimTouchKey {
                weaponSystem.cancelAim()
            } else {
                release(touch, in: scene)
            }
        }
        if selectedZombies.count < 2 { dualTouchBaseline = nil }
    }

    /// Clears any in-progress grabs — called from GameScene.finish() so a mid-drag zombie doesn't
    /// keep tracking a touch after the level ends.
    func releaseAll() {
        selectedZombies.removeAll()
        touchSamples.removeAll()
    }

    private func release(_ touch: UITouch, in scene: SKScene) {
        guard let host else { return }
        let key = ObjectIdentifier(touch)
        guard let zombie = selectedZombies.removeValue(forKey: key) else { return }
        let location = touch.location(in: scene)
        touchSamples[key, default: []].append((location, touch.timestamp))
        let samples = touchSamples.removeValue(forKey: key) ?? []
        guard !selectedZombies.values.contains(where: { $0 === zombie }) else {
            // A second touch is still holding this zombie (dual-touch pinch) — only stop
            // tracking this finger; the remaining touch keeps driving it via touchesMoved.
            return
        }
        zombie.position = CGPoint(x: location.x, y: max(host.groundY + zombie.kind.size.height * 0.39 + 4, location.y))
        var velocity = FlickMath.velocity(from: samples)
        if hypot(velocity.dx, velocity.dy) < 140 { velocity.dy = 180 }
        zombie.release(with: velocity, powerMultiplier: host.flickMultiplier)
        playerThrewThisWave = true
        // A confirming hit-stop "snap" right at the moment of a hard flick, scaled continuously
        // with zombie.lastImpactPower instead of the old fixed 1,850pt/s on-or-off cutoff — the
        // (usually bigger) landing-moment payoff happens separately in GameScene.resolveImpact.
        if zombie.lastImpactPower > 0.65 {
            let power = zombie.lastImpactPower
            host.hitStop(duration: min(0.18, 0.08 + Double(power) * 0.09), slowFactor: max(0.18, 0.42 - power * 0.2))
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

    private func zombie(at location: CGPoint, in scene: SKScene) -> ZombieNode? {
        for node in scene.nodes(at: location) {
            var candidate: SKNode? = node
            while let current = candidate {
                if let zombie = current as? ZombieNode, !zombie.isDefeated { return zombie }
                candidate = current.parent
            }
        }
        return nil
    }
}
