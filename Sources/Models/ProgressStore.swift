import Foundation

@MainActor
final class ProgressStore: ObservableObject {
    @Published private(set) var progress: PlayerProgress
    @Published var settings: GameSettings {
        didSet { saveSettings() }
    }

    private let defaults: UserDefaults
    private let progressKey = "graveflick.progress.v1"
    private let settingsKey = "graveflick.settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        progress = Self.decode(PlayerProgress.self, from: defaults.data(forKey: progressKey)) ?? PlayerProgress()
        settings = Self.decode(GameSettings.self, from: defaults.data(forKey: settingsKey)) ?? GameSettings()
        refreshDaily()
    }

    func complete(_ result: LevelResult) {
        refreshDaily()
        progress.highScores[result.levelID] = max(progress.highScores[result.levelID, default: 0], result.score)
        progress.stars[result.levelID] = max(progress.stars[result.levelID, default: 0], result.stars)
        progress.dailyDefeats += result.defeats
        if result.won {
            progress.currency += result.reward
            progress.highestUnlockedLevel = min(GameLevel.all.count, max(progress.highestUnlockedLevel, result.levelID + 1))
        }
        var newAchievements: [String] = []
        if result.won { newAchievements.append("first_shift") }
        if result.stars == 3 { newAchievements.append("perfect_shift") }
        if result.maxCombo >= 8 { newAchievements.append("combo_8") }
        if result.score >= 5_000 { newAchievements.append("score_5000") }
        if result.levelID == 5 && result.won { newAchievements.append("last_light") }
        for achievement in newAchievements where !progress.achievements.contains(achievement) {
            progress.achievements.insert(achievement)
            progress.currency += 100
        }
        if progress.dailyDefeats >= 25, !progress.dailyClaimed {
            progress.dailyClaimed = true
            progress.currency += 250
        }
        saveProgress()
    }

    @discardableResult
    func buyUpgrade(_ kind: UpgradeKind) -> Bool {
        let level = progress.upgradeLevel(kind)
        guard level < 3 else { return false }
        let cost = kind.cost(forNextLevel: level)
        guard progress.currency >= cost else { return false }
        progress.currency -= cost
        progress.upgradeLevels[kind.rawValue] = level + 1
        saveProgress()
        return true
    }

    @discardableResult
    func unlock(_ weapon: WeaponKind) -> Bool {
        guard !progress.isUnlocked(weapon), progress.currency >= weapon.unlockCost else { return false }
        progress.currency -= weapon.unlockCost
        progress.unlockedWeapons.insert(weapon.rawValue)
        saveProgress()
        return true
    }

    @discardableResult
    func unlock(_ trap: TrapKind) -> Bool {
        guard !progress.isUnlocked(trap), progress.currency >= trap.unlockCost else { return false }
        progress.currency -= trap.unlockCost
        progress.unlockedTraps.insert(trap.rawValue)
        saveProgress()
        return true
    }

    func markTutorialSeen() {
        progress.hasSeenTutorial = true
        saveProgress()
    }

    func resetAll() {
        progress = PlayerProgress()
        settings = GameSettings()
        defaults.removeObject(forKey: progressKey)
        defaults.removeObject(forKey: settingsKey)
    }

    var dailySummary: String {
        progress.dailyClaimed ? "Daily complete • +250 coins" : "Daily: defeat \(min(25, progress.dailyDefeats))/25 creatures"
    }

    private func refreshDaily() {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        if progress.dailyDate != today {
            progress.dailyDate = today
            progress.dailyDefeats = 0
            progress.dailyClaimed = false
            saveProgress()
        }
    }

    private func saveProgress() {
        defaults.set(try? JSONEncoder().encode(progress), forKey: progressKey)
    }

    private func saveSettings() {
        defaults.set(try? JSONEncoder().encode(settings), forKey: settingsKey)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
