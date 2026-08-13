import CoreGraphics
import UIKit
import XCTest
@testable import GraveFlick

final class GameRulesTests: XCTestCase {
    func testFlickVelocityUsesRecentTouchHistory() {
        let samples: [(point: CGPoint, time: TimeInterval)] = [
            (CGPoint(x: 0, y: 0), 0),
            (CGPoint(x: 20, y: 10), 0.20),
            (CGPoint(x: 120, y: 60), 0.30)
        ]

        let velocity = FlickMath.velocity(from: samples)

        XCTAssertEqual(velocity.dx, 1_000, accuracy: 0.01)
        XCTAssertEqual(velocity.dy, 500, accuracy: 0.01)
    }

    func testFlickVelocityIsClamped() {
        let velocity = FlickMath.clamped(CGVector(dx: 10_000, dy: 0), maximum: 2_200)
        XCTAssertEqual(velocity.dx, 2_200, accuracy: 0.01)
        XCTAssertEqual(velocity.dy, 0, accuracy: 0.01)
    }

    func testComboAndBruteScoring() {
        XCTAssertEqual(GameRules.score(for: .walker, combo: 1), 100)
        XCTAssertEqual(GameRules.score(for: .walker, combo: 3), 150)
        XCTAssertEqual(GameRules.score(for: .brute, combo: 2), 325)
    }

    func testStarsRewardSurvivalAndScore() {
        XCTAssertEqual(GameRules.stars(score: 2_500, health: 5, startingHealth: 5, won: true), 3)
        XCTAssertEqual(GameRules.stars(score: 900, health: 3, startingHealth: 5, won: true), 2)
        XCTAssertEqual(GameRules.stars(score: 900, health: 1, startingHealth: 5, won: true), 1)
        XCTAssertEqual(GameRules.stars(score: 9_000, health: 5, startingHealth: 5, won: false), 0)
    }

    func testRapidGearCooldownHasFloor() {
        XCTAssertEqual(GameRules.cooldown(base: 10, rapidGearLevel: 2), 8.4, accuracy: 0.001)
        XCTAssertEqual(GameRules.cooldown(base: 10, rapidGearLevel: 99), 6.8, accuracy: 0.001)
    }

    func testEveryZombieHasACompleteSixPartAnimationRig() {
        XCTAssertTrue(ZombieNode.hasCompleteStateAnimationSet)
        for kind in ZombieKind.allCases {
            let zombie = ZombieNode(kind: kind, approachesFromLeft: true)
            XCTAssertTrue(zombie.hasCompleteAnimationRig, "Missing articulated animation art for \(kind.rawValue)")
        }
    }

    func testDinerHasCompleteAnimatedAsset() {
        let diner = DinerNode(
            frame: CGRect(x: 0, y: 0, width: 260, height: 250),
            reducedMotion: true,
            highContrast: false
        )
        XCTAssertTrue(diner.hasCompleteAssetSet)
    }

    func testEquipmentHasCompleteIllustratedAssetSet() {
        XCTAssertTrue(EquipmentArt.hasCompleteSet)
    }

    func testEveryLevelHasAnIllustratedEnvironment() {
        for level in GameLevel.all {
            let environment = EnvironmentNode(levelID: level.id, sceneSize: CGSize(width: 852, height: 393), reducedMotion: true, highContrast: false)
            XCTAssertTrue(environment.hasCompleteAsset, "Missing environment art for level \(level.id)")
        }
    }

    func testCombatVFXHasCompleteAuthoredAssetSet() {
        XCTAssertTrue(CombatVFX.hasCompleteSet)
    }

    func testProductionUIHasCompleteAuthoredAssetSet() {
        XCTAssertTrue(UIArt.hasCompleteSet)
        XCTAssertTrue(GameLevel.all.allSatisfy { UIImage(named: $0.environmentAssetName) != nil })
    }
}
