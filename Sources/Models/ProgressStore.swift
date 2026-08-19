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
        grantCampaignUnlocks()
        refreshDaily()
    }

    func complete(_ result: LevelResult) {
        refreshDaily()
        progress.highScores[result.levelID] = max(progress.highScores[result.levelID, default: 0], result.score)
        progress.stars[result.levelID] = max(progress.stars[result.levelID, default: 0], result.stars)
        progress.dailyDefeats += result.defeats
        progress.totalDefeats += result.defeats
        progress.bestCombo = max(progress.bestCombo, result.maxCombo)
        if result.won && (result.levelID == 4 || result.levelID == 5 || result.levelID == 25) { progress.bossDefeats += 1 }
        // Endless mode always ends with won == false but still carries a positive reward
        // (GameRules.survivalReward), so currency is gated on having a reward at all, not on
        // winning — level-unlock progression stays win-gated since endless isn't in GameLevel.all.
        if result.won || result.reward > 0 {
            progress.currency += result.reward
        }
        if result.won, GameLevel.campaign.indices.contains(result.levelID - 1) {
            progress.highestUnlockedLevel = min(GameLevel.campaign.count, max(progress.highestUnlockedLevel, result.levelID + 1))
            grantCampaignUnlocks()
        }
        var newAchievements: [String] = []
        if result.won { newAchievements.append("first_shift") }
        if result.stars == 3 { newAchievements.append("perfect_shift") }
        if result.maxCombo >= 8 { newAchievements.append("combo_8") }
        if result.score >= 5_000 { newAchievements.append("score_5000") }
        if result.levelID == 5 && result.won { newAchievements.append("last_light") }
        if result.levelID == 25 && result.won { newAchievements.append("road_cleared") }
        if result.wave >= 20 { newAchievements.append("survival_20") }
        if result.maxCombo >= 20 { newAchievements.append("combo_20") }
        if result.defeats >= 100 { newAchievements.append("century") }
        // Skill-based feats (see GameScene.achievedFeats) are just more achievement IDs by the
        // time they get here — same grant loop, same tiered payout (Achievements.coinReward),
        // same persistence.
        newAchievements.append(contentsOf: result.feats)
        for achievement in newAchievements where !progress.achievements.contains(achievement) {
            progress.achievements.insert(achievement)
            progress.currency += Achievements.coinReward(for: achievement)
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
    func buyWeaponUpgrade(_ kind: WeaponKind) -> Bool {
        guard progress.isUnlocked(kind) else { return false }
        let key = "weapon.\(kind.rawValue)"
        let level = progress.upgradeLevels[key, default: 0]
        guard level < 3 else { return false }
        let cost = 200 + level * 275
        guard progress.currency >= cost else { return false }
        progress.currency -= cost
        progress.upgradeLevels[key] = level + 1
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

    /// Campaign progress is the free, "learn it and it's yours" unlock path for both weapons and
    /// traps; coin purchase (unlock(_:)) is the alternate path for players who want a toy before
    /// they've reached its teaching level, or don't want to play campaign at all.
    private func grantCampaignUnlocks() {
        let weaponLoadout = WeaponKind.campaignLoadout(through: progress.highestUnlockedLevel)
        let trapLoadout = TrapKind.campaignLoadout(through: progress.highestUnlockedLevel)
        guard !weaponLoadout.isSubset(of: progress.unlockedWeapons) || !trapLoadout.isSubset(of: progress.unlockedTraps) else { return }
        progress.unlockedWeapons.formUnion(weaponLoadout)
        progress.unlockedTraps.formUnion(trapLoadout)
        saveProgress()
    }

    private func saveSettings() {
        defaults.set(try? JSONEncoder().encode(settings), forKey: settingsKey)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
