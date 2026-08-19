import XCTest
@testable import GraveFlick

@MainActor
final class ProgressStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "GraveFlickTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testWinningUnlocksNextLevelAndPersistsReward() {
        let store = ProgressStore(defaults: defaults)
        store.complete(LevelResult(levelID: 1, score: 1_200, stars: 2, reward: 260, won: true, defeats: 10, maxCombo: 4, wave: 3))

        XCTAssertEqual(store.progress.highestUnlockedLevel, 2)
        // Starting 350 + 260 reward + 50 "first_shift" (easy tier — see Achievements.swift).
        XCTAssertEqual(store.progress.currency, 660)
        XCTAssertEqual(store.progress.highScores[1], 1_200)
        XCTAssertEqual(store.progress.stars[1], 2)

        let reloaded = ProgressStore(defaults: defaults)
        XCTAssertEqual(reloaded.progress, store.progress)
    }

    /// Skill-based feats (GameScene.achievedFeats — "kill 3 with one bowling ball," etc.) are just
    /// more achievement IDs by the time they reach ProgressStore: same grant loop, same +100 coins,
    /// same one-time-only guard as the existing score/completion achievements.
    func testLevelFeatsGrantAchievementsAndCoinsOnce() {
        let store = ProgressStore(defaults: defaults)
        let startingCurrency = store.progress.currency
        let result = LevelResult(levelID: 1, score: 500, stars: 1, reward: 180, won: true, defeats: 8, maxCombo: 3, wave: 3, feats: ["bowling_triple", "sky_launch"])

        store.complete(result)
        XCTAssertTrue(store.progress.achievements.contains("bowling_triple"))
        XCTAssertTrue(store.progress.achievements.contains("sky_launch"))
        // +180 reward, +50 "first_shift" (easy tier, won == true), +125 each for the two
        // skill-tier feats (bowling_triple, sky_launch) = +480.
        XCTAssertEqual(store.progress.currency, startingCurrency + 480)

        // A second run reporting the same feats shouldn't pay out again.
        store.complete(LevelResult(levelID: 1, score: 500, stars: 1, reward: 180, won: true, defeats: 8, maxCombo: 3, wave: 3, feats: ["bowling_triple"]))
        XCTAssertEqual(store.progress.currency, startingCurrency + 480 + 180)
    }

    /// The whole point of tiering (see AchievementTier): a genuinely hard skill feat must pay out
    /// more than a trivial first-clear achievement, not the same flat amount either used to grant.
    func testHarderAchievementTiersPayMoreThanEasyOnes() {
        XCTAssertEqual(Achievements.coinReward(for: "first_shift"), 50)
        XCTAssertEqual(Achievements.coinReward(for: "chain_reaction_10"), 250)
        XCTAssertEqual(Achievements.coinReward(for: "road_cleared"), 400)
        XCTAssertGreaterThan(Achievements.coinReward(for: "chain_reaction_10"), Achievements.coinReward(for: "first_shift"))

        let store = ProgressStore(defaults: defaults)
        let startingCurrency = store.progress.currency
        store.complete(LevelResult(levelID: 1, score: 100, stars: 0, reward: 0, won: false, defeats: 1, maxCombo: 1, wave: 1, feats: ["chain_reaction_10"]))
        XCTAssertEqual(store.progress.currency, startingCurrency + 250)
    }

    func testUpgradePurchaseChargesCoinsAndCapsAtThree() {
        let store = ProgressStore(defaults: defaults)
        XCTAssertTrue(store.buyUpgrade(.flickTraining))
        XCTAssertEqual(store.progress.upgradeLevel(.flickTraining), 1)
        XCTAssertEqual(store.progress.currency, 100)
        XCTAssertFalse(store.buyUpgrade(.flickTraining))
    }

    func testLossDoesNotUnlockNextLevel() {
        let store = ProgressStore(defaults: defaults)
        store.complete(LevelResult(levelID: 1, score: 500, stars: 0, reward: 0, won: false, defeats: 3, maxCombo: 2, wave: 2))
        XCTAssertEqual(store.progress.highestUnlockedLevel, 1)
        XCTAssertEqual(store.progress.highScores[1], 500)
    }

    func testEndlessLossAwardsRunAndDailyCurrencyWithoutUnlockingLevels() {
        let store = ProgressStore(defaults: defaults)
        let startingCurrency = store.progress.currency

        store.complete(LevelResult(levelID: GameLevel.endless.id, score: 3_000, stars: 0, reward: 330, won: false, defeats: 40, maxCombo: 6, wave: 12))

        XCTAssertEqual(store.progress.currency, startingCurrency + 330 + 250)
        XCTAssertTrue(store.progress.dailyClaimed)
        XCTAssertEqual(store.progress.highScores[GameLevel.endless.id], 3_000)
        XCTAssertEqual(store.progress.highestUnlockedLevel, 1)
    }

    /// Traps previously only ever unlocked via coin purchase — this is the fix that lets beating
    /// campaign levels grant them for free too, same as weapons already did.
    func testWinningLevelsGrantsTrapsAlongsideWeapons() {
        let store = ProgressStore(defaults: defaults)
        XCTAssertFalse(store.progress.isUnlocked(.spikeStrip))
        XCTAssertFalse(store.progress.isUnlocked(.freezer))

        store.complete(LevelResult(levelID: 1, score: 500, stars: 1, reward: 180, won: true, defeats: 8, maxCombo: 3, wave: 3))
        store.complete(LevelResult(levelID: 2, score: 600, stars: 1, reward: 260, won: true, defeats: 9, maxCombo: 3, wave: 4))
        XCTAssertTrue(store.progress.isUnlocked(.spikeStrip), "spikeStrip's campaignUnlockLevel is 2")
        XCTAssertFalse(store.progress.isUnlocked(.freezer), "freezer requires level 4, not yet reached")

        store.complete(LevelResult(levelID: 3, score: 700, stars: 1, reward: 340, won: true, defeats: 10, maxCombo: 3, wave: 4))
        store.complete(LevelResult(levelID: 4, score: 800, stars: 1, reward: 450, won: true, defeats: 11, maxCombo: 3, wave: 5))
        XCTAssertTrue(store.progress.isUnlocked(.freezer))
    }

    func testWeaponUpgradePersistsWithoutReplacingLegacyUpgrades() {
        let store = ProgressStore(defaults: defaults)
        XCTAssertTrue(store.buyWeaponUpgrade(.bowlingBall))
        XCTAssertEqual(store.progress.upgradeLevel(.bowlingBall), 1)
        XCTAssertEqual(store.progress.upgradeLevel(.flickTraining), 0)
        XCTAssertEqual(ProgressStore(defaults: defaults).progress.upgradeLevel(.bowlingBall), 1)
    }

    func testLegacyProgressPayloadDecodesWithNewMasteryDefaults() throws {
        let legacy = #"{"currency":900,"highestUnlockedLevel":3,"highScores":{},"stars":{},"upgradeLevels":{},"unlockedWeapons":["bowlingBall"],"unlockedTraps":[],"achievements":[],"dailyDate":"","dailyDefeats":0,"dailyClaimed":false,"hasSeenTutorial":true}"#
        defaults.set(Data(legacy.utf8), forKey: "graveflick.progress.v1")
        let progress = ProgressStore(defaults: defaults).progress
        XCTAssertEqual(progress.currency, 900)
        XCTAssertEqual(progress.totalDefeats, 0)
        XCTAssertEqual(progress.bestCombo, 0)
        XCTAssertTrue(progress.isUnlocked(.shotgun))
        XCTAssertTrue(progress.isUnlocked(.anvil))
        XCTAssertTrue(progress.isUnlocked(.grenade))
        XCTAssertTrue(progress.isUnlocked(.propaneTank))
        XCTAssertFalse(progress.isUnlocked(.airstrike))
    }

    func testLegacySettingsPayloadReceivesAudioMixDefaults() throws {
        let legacy = #"{"musicEnabled":true,"soundEnabled":false,"hapticsEnabled":true}"#
        defaults.set(Data(legacy.utf8), forKey: "graveflick.settings.v1")
        let settings = ProgressStore(defaults: defaults).settings
        XCTAssertEqual(settings.musicVolume, 0.78)
        XCTAssertEqual(settings.soundVolume, 0.86)
        XCTAssertEqual(settings.ambienceVolume, 0.72)
        XCTAssertFalse(settings.soundEnabled)
    }
}
