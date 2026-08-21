import XCTest
@testable import GraveFlick

final class ContentIntegrityTests: XCTestCase {
    func testEveryWeaponHasPlayerFacingGestureGuidance() {
        for weapon in WeaponKind.allCases {
            XCTAssertFalse(weapon.aimInstruction.isEmpty, "Missing help copy for \(weapon.title)")
            XCTAssertTrue(
                ["tap", "drag", "draw", "pull"].contains { weapon.aimInstruction.localizedCaseInsensitiveContains($0) },
                "Help copy for \(weapon.title) does not describe an actionable gesture"
            )
        }
    }

    func testCampaignContentIdentifiersAndBoundsAreReleaseSafe() {
        XCTAssertEqual(Set(GameLevel.campaign.map(\.id)).count, GameLevel.campaign.count)
        XCTAssertEqual(GameLevel.campaign.map(\.id), Array(1...25))
        for level in GameLevel.campaign {
            XCTAssertFalse(level.title.isEmpty)
            XCTAssertFalse(level.subtitle.isEmpty)
            XCTAssertFalse(level.enemyRoster.isEmpty)
            XCTAssertGreaterThan(level.totalWaves, 0)
            XCTAssertGreaterThan(level.waveDuration, 0)
            XCTAssertGreaterThan(level.baseSpawnInterval, 0)
            XCTAssertGreaterThan(level.reward, 0)
            XCTAssertTrue((1...8).contains(level.environmentID ?? level.id))
        }
    }

    func testChallengesCannotCollideWithCampaignOrSpecialModeIDs() {
        let reserved = Set(GameLevel.campaign.map(\.id) + [GameLevel.endless.id, GameLevel.sandbox.id])
        let challengeIDs = GameLevel.challenges.map(\.id)
        XCTAssertEqual(Set(challengeIDs).count, challengeIDs.count)
        XCTAssertTrue(Set(challengeIDs).isDisjoint(with: reserved))
        XCTAssertTrue(GameLevel.challenges.allSatisfy { !$0.enemyRoster.isEmpty && $0.totalWaves < .max })
    }

    func testUnlockScheduleMakesEveryToolEarnableInsideCampaign() {
        XCTAssertTrue(WeaponKind.allCases.allSatisfy { (1...GameLevel.campaign.count).contains($0.campaignUnlockLevel) })
        XCTAssertTrue(TrapKind.allCases.allSatisfy { (1...GameLevel.campaign.count).contains($0.campaignUnlockLevel) })
        XCTAssertEqual(WeaponKind.campaignLoadout(through: GameLevel.campaign.count), Set(WeaponKind.allCases.map(\.rawValue)))
        XCTAssertEqual(TrapKind.campaignLoadout(through: GameLevel.campaign.count), Set(TrapKind.allCases.map(\.rawValue)))
    }

    func testAchievementCatalogHasStableUniqueIdentifiers() {
        let identifiers = Achievements.all.map(\.0)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertTrue(Achievements.all.allSatisfy { !$0.0.isEmpty && !$0.1.isEmpty && !$0.2.isEmpty && $0.3.coinReward > 0 })
    }
}
