import Foundation

@MainActor
final class ProgressStore: ObservableObject {
    @Published private(set) var progress: PlayerProgress
    @Published private(set) var recoveredCorruptSave = false
    @Published var settings: GameSettings {
        didSet { saveSettings() }
    }

    private let defaults: UserDefaults
    private let progressKey = "graveflick.progress.v1"
    private let settingsKey = "graveflick.settings.v1"
    private var progressBackupKey: String { "\(progressKey).backup" }
    private var settingsBackupKey: String { "\(settingsKey).backup" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loadedProgress = Self.load(PlayerProgress.self, primary: progressKey, backup: "\(progressKey).backup", defaults: defaults)
        let loadedSettings = Self.load(GameSettings.self, primary: settingsKey, backup: "\(settingsKey).backup", defaults: defaults)
        progress = Self.normalized(loadedProgress.value ?? PlayerProgress())
        settings = loadedSettings.value ?? GameSettings()
        recoveredCorruptSave = loadedProgress.recovered || loadedSettings.recovered
        // Seed recovery for legacy installs before their next mutation. A future corrupt write can
        // now fall back even if the player only launches and leaves without completing a run.
        Self.seedBackupIfNeeded(PlayerProgress.self, primary: progressKey, backup: "\(progressKey).backup", defaults: defaults)
        Self.seedBackupIfNeeded(GameSettings.self, primary: settingsKey, backup: "\(settingsKey).backup", defaults: defaults)
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
        defaults.removeObject(forKey: progressBackupKey)
        defaults.removeObject(forKey: settingsBackupKey)
        recoveredCorruptSave = false
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
        guard let encoded = try? JSONEncoder().encode(progress) else { return }
        preserveValidPrimary(key: progressKey, backupKey: progressBackupKey, as: PlayerProgress.self)
        defaults.set(encoded, forKey: progressKey)
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
        guard let encoded = try? JSONEncoder().encode(settings) else { return }
        preserveValidPrimary(key: settingsKey, backupKey: settingsBackupKey, as: GameSettings.self)
        defaults.set(encoded, forKey: settingsKey)
    }

    private func preserveValidPrimary<T: Decodable>(key: String, backupKey: String, as type: T.Type) {
        guard let existing = defaults.data(forKey: key), Self.decode(type, from: existing) != nil else { return }
        defaults.set(existing, forKey: backupKey)
    }

    private static func load<T: Decodable>(_ type: T.Type, primary: String, backup: String, defaults: UserDefaults) -> (value: T?, recovered: Bool) {
        let primaryData = defaults.data(forKey: primary)
        if let decoded = decode(type, from: primaryData) { return (decoded, false) }
        guard primaryData != nil, let recovered = decode(type, from: defaults.data(forKey: backup)) else {
            return (nil, false)
        }
        // Repair the primary immediately so every subsequent launch starts from healthy data.
        if let backupData = defaults.data(forKey: backup) { defaults.set(backupData, forKey: primary) }
        return (recovered, true)
    }

    private static func seedBackupIfNeeded<T: Decodable>(_ type: T.Type, primary: String, backup: String, defaults: UserDefaults) {
        guard defaults.data(forKey: backup) == nil,
              let data = defaults.data(forKey: primary),
              decode(type, from: data) != nil else { return }
        defaults.set(data, forKey: backup)
    }

    private static func normalized(_ value: PlayerProgress) -> PlayerProgress {
        var result = value
        result.currency = max(0, result.currency)
        result.highestUnlockedLevel = min(GameLevel.campaign.count, max(1, result.highestUnlockedLevel))
        result.highScores = result.highScores.mapValues { max(0, $0) }
        result.stars = result.stars.mapValues { min(3, max(0, $0)) }
        result.upgradeLevels = result.upgradeLevels.mapValues { min(3, max(0, $0)) }
        result.dailyDefeats = max(0, result.dailyDefeats)
        result.totalDefeats = max(0, result.totalDefeats)
        result.bestCombo = max(0, result.bestCombo)
        result.bossDefeats = max(0, result.bossDefeats)
        return result
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
