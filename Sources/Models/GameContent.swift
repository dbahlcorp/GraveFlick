import Foundation
import SpriteKit

enum WeaponKind: String, CaseIterable, Codable, Identifiable {
    case bowlingBall
    case shotgun
    case airstrike
    case anvil
    case grenade
    case propaneTank
    case wreckingBall
    case sniper
    case greaseFire
    case transformer
    case deliveryTruck
    case meteor

    var id: String { rawValue }
    static let starterLoadout: Set<WeaponKind> = [.bowlingBall, .shotgun, .anvil]

    var campaignUnlockLevel: Int {
        switch self {
        case .bowlingBall, .shotgun, .anvil: 1
        case .grenade: 2
        case .propaneTank: 3
        case .airstrike: 4
        case .sniper: 5
        case .greaseFire: 7
        case .transformer: 10
        case .wreckingBall: 12
        case .deliveryTruck: 15
        case .meteor: 20
        }
    }

    static func campaignLoadout(through level: Int) -> Set<String> {
        Set(allCases.filter { $0.campaignUnlockLevel <= max(1, level) }.map(\.rawValue))
    }

    var title: String {
        switch self {
        case .bowlingBall: "Bowling Ball"
        case .shotgun: "Scatterblast"
        case .airstrike: "Neon Airstrike"
        case .anvil: "Drop Anvil"
        case .grenade: "Grave Grenade"
        case .propaneTank: "Propane Roller"
        case .wreckingBall: "Wrecking Ball"
        case .sniper: "Deadeye Rifle"
        case .greaseFire: "Grease Fire"
        case .transformer: "Arc Transformer"
        case .deliveryTruck: "Delivery Rush"
        case .meteor: "Midnight Meteor"
        }
    }
    var icon: String {
        switch self {
        case .bowlingBall: "weapon_bowling_ball"
        case .shotgun: "weapon_scatterblast"
        case .airstrike: "weapon_airstrike_beacon"
        case .anvil: "weapon_anvil"
        case .grenade: "weapon_grenade"
        case .propaneTank: "weapon_propane"
        case .wreckingBall: "weapon_wrecking_ball"
        case .sniper: "weapon_sniper"
        case .greaseFire: "weapon_grease_fire"
        case .transformer: "weapon_transformer"
        case .deliveryTruck: "weapon_delivery_truck"
        case .meteor: "weapon_meteor"
        }
    }
    var cooldown: TimeInterval {
        switch self {
        case .bowlingBall: 7
        case .shotgun: 11
        case .airstrike: 28
        case .anvil: 13
        case .grenade: 15
        case .propaneTank: 18
        case .wreckingBall: 24
        case .sniper: 9
        case .greaseFire: 17
        case .transformer: 21
        case .deliveryTruck: 26
        case .meteor: 34
        }
    }
    var unlockCost: Int {
        switch self {
        case .bowlingBall: 0
        case .shotgun: 450
        case .airstrike: 900
        case .anvil: 350
        case .grenade: 525
        case .propaneTank: 700
        case .wreckingBall: 1_100
        case .sniper: 1_250
        case .greaseFire: 1_400
        case .transformer: 1_650
        case .deliveryTruck: 1_900
        case .meteor: 2_400
        }
    }
}

enum GameDifficulty: String, CaseIterable, Codable, Identifiable {
    case casual, standard, nightmare
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var enemySpeed: CGFloat { self == .casual ? 0.82 : (self == .nightmare ? 1.24 : 1) }
    var enemyHealth: CGFloat { self == .casual ? 0.78 : (self == .nightmare ? 1.38 : 1) }
    var spawnRate: Double { self == .casual ? 1.22 : (self == .nightmare ? 0.78 : 1) }
    var rewardMultiplier: Double { self == .casual ? 0.85 : (self == .nightmare ? 1.45 : 1) }
}

enum MissionModifier: String, Hashable {
    case standard, leftOnly, rightOnly, doubleSided, noGrab, volatileRush, waitressRush, limitedWeapons, lowGravity, suddenDeath
    var title: String {
        switch self {
        case .standard: "Standard Shift"
        case .leftOnly: "Left-Side Lockdown"
        case .rightOnly: "Right-Side Lockdown"
        case .doubleSided: "Two-Sided Siege"
        case .noGrab: "Hands Off"
        case .volatileRush: "Pressure Leak"
        case .waitressRush: "Last Call Rush"
        case .limitedWeapons: "Bare Essentials"
        case .lowGravity: "Moonlight Gravity"
        case .suddenDeath: "One Heart Night"
        }
    }
}

enum TrapKind: String, CaseIterable, Codable, Identifiable {
    case spikeStrip
    case freezer

    var id: String { rawValue }
    var title: String { self == .spikeStrip ? "Spike Strip" : "Flash Freezer" }
    var icon: String { self == .spikeStrip ? "trap_spike_strip" : "trap_flash_freezer" }
    var cooldown: TimeInterval { self == .spikeStrip ? 15 : 22 }
    var unlockCost: Int { self == .spikeStrip ? 300 : 650 }

    /// Mirrors WeaponKind.campaignUnlockLevel — traps previously had no campaign-progress path at
    /// all (coin purchase only), which is exactly the "25 disconnected levels" problem campaign
    /// completion unlocking endless toys is meant to fix. freezer unlocks alongside level 4
    /// ("Pressure Cooker"), which is also where `.volatile` zombies are introduced — a flash-frozen
    /// volatile can't chain-explode, so the trap and the level's own teaching moment reinforce
    /// each other.
    var campaignUnlockLevel: Int {
        switch self {
        case .spikeStrip: 2
        case .freezer: 4
        }
    }

    static func campaignLoadout(through level: Int) -> Set<String> {
        Set(allCases.filter { $0.campaignUnlockLevel <= max(1, level) }.map(\.rawValue))
    }
}

enum UpgradeKind: String, CaseIterable, Codable, Identifiable {
    case reinforcedDiner
    case flickTraining
    case rapidGear

    var id: String { rawValue }
    var title: String {
        switch self {
        case .reinforcedDiner: "Reinforced Diner"
        case .flickTraining: "Flick Training"
        case .rapidGear: "Rapid Gear"
        }
    }
    var detail: String {
        switch self {
        case .reinforcedDiner: "+20 diner health per level"
        case .flickTraining: "+10% throw power per level"
        case .rapidGear: "-8% weapon cooldown per level"
        }
    }
    var icon: String {
        switch self {
        case .reinforcedDiner: "ui_upgrade_diner"
        case .flickTraining: "ui_upgrade_flick"
        case .rapidGear: "ui_upgrade_rapid"
        }
    }
    func cost(forNextLevel level: Int) -> Int { 250 + level * 300 }
}

struct GameLevel: Identifiable, Hashable {
    let id: Int
    let title: String
    let subtitle: String
    let totalWaves: Int
    let waveDuration: TimeInterval
    let baseSpawnInterval: TimeInterval
    let reward: Int
    let enemyRoster: [ZombieKind]
    let skyColor: SKColor
    let horizonColor: SKColor
    var isEndless = false
    var isSandbox = false
    var environmentID: Int? = nil
    var modifier: MissionModifier = .standard

    var environmentAssetName: String {
        if isEndless || isSandbox { return "environment_05_last_light" }
        let visualID = environmentID ?? id
        let slug = switch visualID {
        case 1: "closing_time"
        case 2: "freeway_hunger"
        case 3: "hard_hats"
        case 4: "pressure_cooker"
        case 6: "campground"
        case 7: "neon_motel"
        case 8: "drive_in"
        default: "last_light"
        }
        return String(format: "environment_%02d_%@", visualID, slug)
    }

    static let all: [GameLevel] = [
        GameLevel(id: 1, title: "Closing Time", subtitle: "Learn the night shift", totalWaves: 3, waveDuration: 15, baseSpawnInterval: 1.65, reward: 180, enemyRoster: [.walker, .runner, .waitress], skyColor: color(8, 12, 29), horizonColor: color(22, 31, 55), modifier: .leftOnly),
        GameLevel(id: 2, title: "Freeway Hunger", subtitle: "Fast feet, bad intentions", totalWaves: 4, waveDuration: 16, baseSpawnInterval: 1.45, reward: 260, enemyRoster: [.walker, .runner, .crawler, .groundskeeper], skyColor: color(10, 17, 38), horizonColor: color(24, 45, 67), modifier: .leftOnly),
        GameLevel(id: 3, title: "Hard Hats", subtitle: "Armor changes the impact", totalWaves: 4, waveDuration: 18, baseSpawnInterval: 1.30, reward: 340, enemyRoster: [.walker, .waitress, .riot, .armored, .brute], skyColor: color(20, 12, 30), horizonColor: color(57, 29, 55), modifier: .rightOnly),
        GameLevel(id: 4, title: "Pressure Cooker", subtitle: "Keep volatile guests apart", totalWaves: 5, waveDuration: 18, baseSpawnInterval: 1.15, reward: 450, enemyRoster: [.runner, .crawler, .groundskeeper, .riot, .volatile], skyColor: color(23, 9, 22), horizonColor: color(75, 31, 34), modifier: .rightOnly),
        GameLevel(id: 5, title: "Last Light", subtitle: "Everything wants breakfast", totalWaves: 6, waveDuration: 19, baseSpawnInterval: 0.98, reward: 650, enemyRoster: ZombieKind.regularCases, skyColor: color(4, 8, 22), horizonColor: color(18, 41, 57))
    ]

    /// Not part of `.all` on purpose — it doesn't participate in the level-select carousel,
    /// star ratings, or unlock progression, only its own tracked high score.
    static let endless = GameLevel(
        id: 0,
        title: "Night Shift Forever",
        subtitle: "Survive as long as you can",
        totalWaves: .max,
        waveDuration: 16,
        baseSpawnInterval: 1.05,
        reward: 0,
        enemyRoster: ZombieKind.regularCases,
        skyColor: color(4, 8, 22),
        horizonColor: color(18, 41, 57),
        isEndless: true
    )

    static let challenges: [GameLevel] = [
        challenge(101, "West Door Panic", 1, .leftOnly, [.walker, .waitress]),
        challenge(102, "East Lot Stampede", 1, .rightOnly, [.runner, .waitress]),
        challenge(103, "Split Service", 2, .doubleSided, [.walker, .runner, .crawler]),
        challenge(104, "Hands Off", 2, .noGrab, [.walker, .groundskeeper, .armored]),
        challenge(105, "Waitress Rush", 1, .waitressRush, [.waitress]),
        challenge(106, "Pressure Leak", 4, .volatileRush, [.volatile]),
        challenge(107, "Bare Essentials", 3, .limitedWeapons, [.riot, .armored, .brute]),
        challenge(108, "Moon Toss", 5, .lowGravity, regularCasesForChallenge),
        challenge(109, "One Heart Night", 4, .suddenDeath, [.runner, .volatile, .riot]),
        challenge(110, "Double-Sided Brutes", 3, .doubleSided, [.brute, .groundskeeper]),
        challenge(111, "Neon Riot", 5, .standard, [.riot, .colossus]),
        challenge(112, "Kitchen Nightmare", 4, .standard, [.waitress, .butcher]),
        challenge(113, "Crawler Moon", 2, .lowGravity, [.crawler, .volatile]),
        challenge(114, "Armored Closing", 3, .noGrab, [.armored, .riot]),
        challenge(115, "Last Light Gauntlet", 5, .doubleSided, ZombieKind.regularCases)
    ]

    static let campaign: [GameLevel] = all + (6...25).map { mission in
        let visualID = 6 + (mission - 6) % 3
        let modifiers: [MissionModifier] = [.standard, .leftOnly, .rightOnly, .doubleSided, .noGrab, .volatileRush, .waitressRush, .limitedWeapons, .lowGravity, .suddenDeath]
        let location = visualID == 6 ? "Camp Hollow" : (visualID == 7 ? "Neon Vacancy" : "Final Screening")
        return GameLevel(id: mission, title: "\(location) \(mission - 5)", subtitle: modifiers[(mission - 6) % modifiers.count].title,
                         totalWaves: min(8, 4 + (mission - 6) / 5), waveDuration: 17, baseSpawnInterval: max(0.72, 1.22 - Double(mission - 6) * 0.018),
                         reward: 420 + mission * 35, enemyRoster: ZombieKind.regularCases, skyColor: color(5, 10, 25), horizonColor: color(22, 36, 52),
                         environmentID: visualID, modifier: modifiers[(mission - 6) % modifiers.count])
    }

    static let sandbox = GameLevel(
        id: -1, title: "Midnight Laboratory", subtitle: "Unlimited health and full control", totalWaves: .max,
        waveDuration: 999_999, baseSpawnInterval: 999_999, reward: 0, enemyRoster: ZombieKind.regularCases,
        skyColor: color(4, 8, 22), horizonColor: color(18, 41, 57), isSandbox: true
    )

    private static var regularCasesForChallenge: [ZombieKind] { [.walker, .runner, .waitress, .groundskeeper, .volatile] }

    private static func challenge(_ id: Int, _ title: String, _ environmentID: Int, _ modifier: MissionModifier, _ roster: [ZombieKind]) -> GameLevel {
        GameLevel(id: id, title: title, subtitle: modifier.title, totalWaves: 4, waveDuration: 16, baseSpawnInterval: 1.18,
                  reward: 360, enemyRoster: roster, skyColor: color(7, 11, 26), horizonColor: color(28, 36, 52),
                  environmentID: environmentID, modifier: modifier)
    }

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> SKColor {
        SKColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }
}

struct GameSettings: Codable, Equatable {
    var musicEnabled = true
    var soundEnabled = true
    var musicVolume = 0.78
    var soundVolume = 0.86
    var ambienceVolume = 0.72
    var hapticsEnabled = true
    var reducedMotion = false
    var highContrast = false
    var goreEnabled = true
    var screenShakeEnabled = true
    var flashesEnabled = true
    var difficulty: GameDifficulty = .standard

    private enum CodingKeys: String, CodingKey { case musicEnabled, soundEnabled, musicVolume, soundVolume, ambienceVolume, hapticsEnabled, reducedMotion, highContrast, goreEnabled, screenShakeEnabled, flashesEnabled, difficulty }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        musicEnabled = try values.decodeIfPresent(Bool.self, forKey: .musicEnabled) ?? true
        soundEnabled = try values.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        musicVolume = try values.decodeIfPresent(Double.self, forKey: .musicVolume) ?? 0.78
        soundVolume = try values.decodeIfPresent(Double.self, forKey: .soundVolume) ?? 0.86
        ambienceVolume = try values.decodeIfPresent(Double.self, forKey: .ambienceVolume) ?? 0.72
        hapticsEnabled = try values.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
        reducedMotion = try values.decodeIfPresent(Bool.self, forKey: .reducedMotion) ?? false
        highContrast = try values.decodeIfPresent(Bool.self, forKey: .highContrast) ?? false
        goreEnabled = try values.decodeIfPresent(Bool.self, forKey: .goreEnabled) ?? true
        screenShakeEnabled = try values.decodeIfPresent(Bool.self, forKey: .screenShakeEnabled) ?? true
        flashesEnabled = try values.decodeIfPresent(Bool.self, forKey: .flashesEnabled) ?? true
        difficulty = try values.decodeIfPresent(GameDifficulty.self, forKey: .difficulty) ?? .standard
    }
}

struct PlayerProgress: Codable, Equatable {
    var currency = 350
    var highestUnlockedLevel = 1
    var highScores: [Int: Int] = [:]
    var stars: [Int: Int] = [:]
    var upgradeLevels: [String: Int] = [:]
    var unlockedWeapons: Set<String> = WeaponKind.campaignLoadout(through: 1)
    var unlockedTraps: Set<String> = []
    var achievements: Set<String> = []
    var dailyDate = ""
    var dailyDefeats = 0
    var dailyClaimed = false
    var hasSeenTutorial = false
    var totalDefeats = 0
    var bestCombo = 0
    var bossDefeats = 0

    private enum CodingKeys: String, CodingKey { case currency, highestUnlockedLevel, highScores, stars, upgradeLevels, unlockedWeapons, unlockedTraps, achievements, dailyDate, dailyDefeats, dailyClaimed, hasSeenTutorial, totalDefeats, bestCombo, bossDefeats }

    init() {}
    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        currency = try v.decodeIfPresent(Int.self, forKey: .currency) ?? 350
        highestUnlockedLevel = try v.decodeIfPresent(Int.self, forKey: .highestUnlockedLevel) ?? 1
        highScores = try v.decodeIfPresent([Int: Int].self, forKey: .highScores) ?? [:]
        stars = try v.decodeIfPresent([Int: Int].self, forKey: .stars) ?? [:]
        upgradeLevels = try v.decodeIfPresent([String: Int].self, forKey: .upgradeLevels) ?? [:]
        unlockedWeapons = try v.decodeIfPresent(Set<String>.self, forKey: .unlockedWeapons) ?? WeaponKind.campaignLoadout(through: highestUnlockedLevel)
        unlockedTraps = try v.decodeIfPresent(Set<String>.self, forKey: .unlockedTraps) ?? []
        achievements = try v.decodeIfPresent(Set<String>.self, forKey: .achievements) ?? []
        dailyDate = try v.decodeIfPresent(String.self, forKey: .dailyDate) ?? ""
        dailyDefeats = try v.decodeIfPresent(Int.self, forKey: .dailyDefeats) ?? 0
        dailyClaimed = try v.decodeIfPresent(Bool.self, forKey: .dailyClaimed) ?? false
        hasSeenTutorial = try v.decodeIfPresent(Bool.self, forKey: .hasSeenTutorial) ?? false
        totalDefeats = try v.decodeIfPresent(Int.self, forKey: .totalDefeats) ?? 0
        bestCombo = try v.decodeIfPresent(Int.self, forKey: .bestCombo) ?? 0
        bossDefeats = try v.decodeIfPresent(Int.self, forKey: .bossDefeats) ?? 0
    }

    func upgradeLevel(_ kind: UpgradeKind) -> Int { upgradeLevels[kind.rawValue, default: 0] }
    func upgradeLevel(_ kind: WeaponKind) -> Int { upgradeLevels["weapon.\(kind.rawValue)", default: 0] }
    func isUnlocked(_ weapon: WeaponKind) -> Bool { unlockedWeapons.contains(weapon.rawValue) }
    func isUnlocked(_ trap: TrapKind) -> Bool { unlockedTraps.contains(trap.rawValue) }
}

struct LevelResult {
    let levelID: Int
    let score: Int
    let stars: Int
    let reward: Int
    let won: Bool
    let defeats: Int
    let maxCombo: Int
    let wave: Int
    /// Skill-based feats performed this run (see GameScene.achievedFeats) — "how you played," not
    /// score/completion thresholds. Achievement IDs, folded directly into ProgressStore.complete's
    /// existing achievement-granting loop rather than a parallel system.
    var feats: Set<String> = []
}
