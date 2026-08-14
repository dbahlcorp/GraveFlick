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

    func testSurvivalRewardScalesWithScoreAndCaps() {
        XCTAssertEqual(GameRules.survivalReward(score: 0), 80)
        XCTAssertEqual(GameRules.survivalReward(score: 1_200), 180)
        XCTAssertEqual(GameRules.survivalReward(score: 100_000), 2_000)
    }

    func testEndlessLevelIsExcludedFromTheLevelCarousel() {
        XCTAssertTrue(GameLevel.endless.isEndless)
        XCTAssertFalse(GameLevel.all.contains { $0.id == GameLevel.endless.id })
    }

    func testEveryZombieHasACompleteSixPartAnimationRig() {
        for kind in ZombieKind.allCases {
            let zombie = ZombieNode(kind: kind, approachesFromLeft: true)
            XCTAssertTrue(zombie.hasCompleteAnimationRig, "Missing articulated animation art for \(kind.rawValue)")
        }
    }

    func testCampaignWavesHaveFiniteIncreasingSpawnQuotas() {
        let first = GameRules.campaignSpawnCount(wave: 1, waveDuration: 16, baseSpawnInterval: 1.45)
        let fourth = GameRules.campaignSpawnCount(wave: 4, waveDuration: 16, baseSpawnInterval: 1.45)
        XCTAssertGreaterThanOrEqual(first, 5)
        XCTAssertGreaterThan(fourth, first)
        XCTAssertLessThanOrEqual(fourth, 14)
    }

    func testExpandedRosterContainsThreeNewRegularsAndTwoUniqueBosses() {
        XCTAssertTrue(ZombieKind.regularCases.contains(.waitress))
        XCTAssertTrue(ZombieKind.regularCases.contains(.riot))
        XCTAssertTrue(ZombieKind.regularCases.contains(.groundskeeper))
        XCTAssertFalse(ZombieKind.regularCases.contains(.butcher))
        XCTAssertFalse(ZombieKind.regularCases.contains(.colossus))
        XCTAssertTrue(ZombieKind.butcher.isBoss)
        XCTAssertTrue(ZombieKind.colossus.isBoss)
        XCTAssertGreaterThan(ZombieKind.colossus.hitPoints, ZombieKind.butcher.hitPoints)
        XCTAssertGreaterThan(ZombieKind.butcher.hitPoints, ZombieKind.riot.hitPoints)
    }

    func testBossWavesAlternateUniqueBosses() {
        XCTAssertNil(GameRules.bossKind(forWave: 4))
        XCTAssertEqual(GameRules.bossKind(forWave: 5), .butcher)
        XCTAssertEqual(GameRules.bossKind(forWave: 10), .colossus)
        XCTAssertEqual(GameRules.bossKind(forWave: 15), .butcher)
        XCTAssertNil(GameRules.storyBossKind(levelID: 3, wave: 4, totalWaves: 4))
        XCTAssertEqual(GameRules.storyBossKind(levelID: 4, wave: 5, totalWaves: 5), .butcher)
        XCTAssertEqual(GameRules.storyBossKind(levelID: 5, wave: 6, totalWaves: 6), .colossus)
    }

    func testDifficultyProfilesChangePressureAndRewards() {
        XCTAssertLessThan(GameDifficulty.casual.enemySpeed, GameDifficulty.standard.enemySpeed)
        XCTAssertGreaterThan(GameDifficulty.nightmare.enemyHealth, GameDifficulty.standard.enemyHealth)
        XCTAssertGreaterThan(GameDifficulty.nightmare.rewardMultiplier, GameDifficulty.standard.rewardMultiplier)
    }

    func testCampaignIncludesFifteenDistinctChallengeRules() {
        XCTAssertEqual(GameLevel.challenges.count, 15)
        XCTAssertTrue(GameLevel.challenges.contains { $0.modifier == .noGrab })
        XCTAssertTrue(GameLevel.challenges.contains { $0.modifier == .volatileRush })
        XCTAssertTrue(GameLevel.challenges.contains { $0.modifier == .suddenDeath })
        XCTAssertTrue(GameLevel.sandbox.isSandbox)
    }

    func testFullCampaignHasTwentyFiveMissionsAndEightLocations() {
        XCTAssertEqual(GameLevel.campaign.count, 25)
        XCTAssertEqual(Set(GameLevel.campaign.compactMap(\.environmentID)).intersection([6, 7, 8]), Set([6, 7, 8]))
        XCTAssertTrue(GameLevel.campaign.map(\.id).elementsEqual(1...25))
    }

    func testExpandedArsenalHasTwelveDistinctWeaponsAndUpgradeKeys() {
        XCTAssertEqual(WeaponKind.allCases.count, 12)
        XCTAssertEqual(Set(WeaponKind.allCases.map(\.rawValue)).count, 12)
        let progress = PlayerProgress()
        XCTAssertEqual(progress.upgradeLevel(.meteor), 0)
        XCTAssertEqual(progress.unlockedWeapons, WeaponKind.campaignLoadout(through: 1))
        XCTAssertTrue(progress.isUnlocked(.bowlingBall))
        XCTAssertTrue(progress.isUnlocked(.shotgun))
        XCTAssertTrue(progress.isUnlocked(.anvil))
    }

    func testCampaignLoadoutAddsDistinctWeaponsAsLevelsUnlock() {
        let levelThree = WeaponKind.campaignLoadout(through: 3)
        XCTAssertTrue(levelThree.contains(WeaponKind.grenade.rawValue))
        XCTAssertTrue(levelThree.contains(WeaponKind.propaneTank.rawValue))
        XCTAssertFalse(levelThree.contains(WeaponKind.airstrike.rawValue))
        XCTAssertEqual(WeaponKind.campaignLoadout(through: 20).count, WeaponKind.allCases.count)
    }

    func testNewEnvironmentAndWeaponAssetsArePresent() {
        for name in ["environment_06_campground", "environment_07_neon_motel", "environment_08_drive_in"] {
            XCTAssertNotNil(UIImage(named: name), "Missing \(name)")
        }
        for weapon in WeaponKind.allCases where weapon.rawValue != WeaponKind.airstrike.rawValue {
            XCTAssertGreaterThan(UIImage(named: weapon.icon)?.size.width ?? 0, 1, "Missing \(weapon.icon)")
        }
    }

    func testBossesRequireAStunBeforeTheyCanBeGrabbed() {
        let boss = ZombieNode(kind: .butcher, approachesFromLeft: true)
        XCTAssertFalse(boss.canBeGrabbed)
        _ = boss.damage(ZombieKind.butcher.hitPoints * 0.13)
        XCTAssertTrue(boss.canBeGrabbed)
        _ = boss.damage(ZombieKind.butcher.hitPoints * 0.6)
        XCTAssertGreaterThanOrEqual(boss.bossPhase, 2)
    }

    func testSurvivalDifficultyKeepsScalingAndAddsBossPressure() {
        let waveOne = GameRules.survivalDifficulty(wave: 1)
        let waveTen = GameRules.survivalDifficulty(wave: 10)
        let waveFifty = GameRules.survivalDifficulty(wave: 50)

        XCTAssertGreaterThan(waveOne.spawnInterval, waveTen.spawnInterval)
        XCTAssertGreaterThan(waveTen.spawnInterval, waveFifty.spawnInterval)
        XCTAssertGreaterThan(waveTen.speedMultiplier, waveOne.speedMultiplier)
        XCTAssertGreaterThan(waveFifty.healthMultiplier, waveTen.healthMultiplier)
        XCTAssertGreaterThan(waveFifty.spawnCount, waveOne.spawnCount)
        XCTAssertTrue(waveTen.isBossWave)
        XCTAssertFalse(GameRules.survivalDifficulty(wave: 11).isBossWave)
    }

    func testReducedMotionUsesOneReadableAnimationFrame() {
        XCTAssertEqual(GameRules.animationFrameIndices(totalFrames: 4, reducedMotion: true, emphasizedFrame: 2), [2])
        XCTAssertEqual(GameRules.animationFrameIndices(totalFrames: 4, reducedMotion: false, emphasizedFrame: 2), [0, 1, 2, 3])
        XCTAssertEqual(GameRules.animationFrameIndices(totalFrames: 0, reducedMotion: true, emphasizedFrame: 2), [])
    }

    func testZombieRigTraversesEveryInteractiveAnimationState() {
        let zombie = ZombieNode(kind: .walker, approachesFromLeft: true)
        XCTAssertEqual(zombie.currentAnimationState, .walking)

        zombie.beginGrab(reducedMotion: false)
        XCTAssertEqual(zombie.currentAnimationState, .grabbed)
        zombie.release(with: CGVector(dx: 300, dy: 240), powerMultiplier: 1)
        XCTAssertEqual(zombie.currentAnimationState, .airborne)
        zombie.playImpact(reducedMotion: false)
        XCTAssertEqual(zombie.currentAnimationState, .impact)
        zombie.resumeWalking(on: 40)
        XCTAssertEqual(zombie.currentAnimationState, .recovering)

        let attacker = ZombieNode(kind: .brute, approachesFromLeft: true)
        XCTAssertTrue(attacker.playDinerAttack(reducedMotion: false) {})
        XCTAssertEqual(attacker.currentAnimationState, .attacking)

        let defeated = ZombieNode(kind: .volatile, approachesFromLeft: true)
        defeated.playDefeat(style: .explosion, reducedMotion: false) {}
        XCTAssertEqual(defeated.currentAnimationState, .defeated)
    }

    func testDinerHasCompleteAnimatedAsset() {
        let diner = DinerNode(
            frame: CGRect(x: 0, y: 0, width: 260, height: 250),
            reducedMotion: true,
            highContrast: false
        )
        XCTAssertTrue(diner.hasCompleteAssetSet)
    }

    func testDinerDamageStagesStopIdleComponentLoops() {
        let diner = DinerNode(frame: CGRect(x: 0, y: 0, width: 260, height: 250), reducedMotion: false, highContrast: false)
        XCTAssertTrue(diner.componentAnimationIsRunning)
        diner.takeHit(remainingHealth: 3, maximumHealth: 5)
        XCTAssertEqual(diner.currentDamageStage, 1)
        XCTAssertFalse(diner.componentAnimationIsRunning)
        diner.takeHit(remainingHealth: 1, maximumHealth: 5)
        XCTAssertEqual(diner.currentDamageStage, 2)
        diner.takeHit(remainingHealth: 0, maximumHealth: 5)
        XCTAssertEqual(diner.currentDamageStage, 3)
        XCTAssertFalse(diner.componentAnimationIsRunning)
    }

    func testEquipmentHasCompleteIllustratedAssetSet() {
        XCTAssertTrue(EquipmentArt.hasCompleteSet)
    }

    func testEveryLevelHasAnIllustratedEnvironment() {
        for level in GameLevel.all {
            let environment = EnvironmentNode(levelID: level.id, sceneSize: CGSize(width: 852, height: 393), reducedMotion: true, highContrast: false)
            XCTAssertTrue(environment.hasCompleteAsset, "Missing environment art for level \(level.id)")
            XCTAssertTrue(environment.hasCompleteAnimatedAtmosphere, "Missing animated atmosphere for level \(level.id)")
        }
    }

    func testCombatVFXHasCompleteAuthoredAssetSet() {
        XCTAssertTrue(CombatVFX.hasCompleteSet)
        XCTAssertTrue(CombatVFX.allCases.allSatisfy { $0.frames.count == 4 })
    }

    func testProductionUIHasCompleteAuthoredAssetSet() {
        XCTAssertTrue(UIArt.hasCompleteSet)
        XCTAssertTrue(GameLevel.all.allSatisfy { UIImage(named: $0.environmentAssetName) != nil })
        let icons = [
            "ui_upgrade_diner", "ui_upgrade_flick", "ui_upgrade_rapid", "ui_currency_coin", "ui_achievement", "ui_settings",
            "ui_pause", "ui_lock", "ui_star", "ui_music", "ui_sound", "ui_contrast", "ui_play", "ui_levels", "ui_survival",
            "ui_upgrades", "ui_info", "ui_back", "ui_grave_time", "ui_heart", "ui_moon", "ui_tutorial_grab", "ui_tutorial_flick", "ui_tutorial_slam"
        ]
        XCTAssertTrue(icons.allSatisfy { UIImage(named: $0) != nil })
    }
}
