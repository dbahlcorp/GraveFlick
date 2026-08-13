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
        XCTAssertEqual(store.progress.currency, 710)
        XCTAssertEqual(store.progress.highScores[1], 1_200)
        XCTAssertEqual(store.progress.stars[1], 2)

        let reloaded = ProgressStore(defaults: defaults)
        XCTAssertEqual(reloaded.progress, store.progress)
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

    func testEndlessLossStillAwardsCurrencyWithoutUnlockingLevels() {
        let store = ProgressStore(defaults: defaults)
        let startingCurrency = store.progress.currency

        store.complete(LevelResult(levelID: GameLevel.endless.id, score: 3_000, stars: 0, reward: 330, won: false, defeats: 40, maxCombo: 6, wave: 12))

        XCTAssertEqual(store.progress.currency, startingCurrency + 330)
        XCTAssertEqual(store.progress.highScores[GameLevel.endless.id], 3_000)
        XCTAssertEqual(store.progress.highestUnlockedLevel, 1)
    }
}
