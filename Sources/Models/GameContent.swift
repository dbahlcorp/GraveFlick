import Foundation
import SpriteKit

enum WeaponKind: String, CaseIterable, Codable, Identifiable {
    case bowlingBall
    case shotgun
    case airstrike

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bowlingBall: "Bowling Ball"
        case .shotgun: "Scatterblast"
        case .airstrike: "Neon Airstrike"
        }
    }
    var icon: String {
        switch self {
        case .bowlingBall: "weapon_bowling_ball"
        case .shotgun: "weapon_scatterblast"
        case .airstrike: "weapon_airstrike_beacon"
        }
    }
    var cooldown: TimeInterval {
        switch self {
        case .bowlingBall: 7
        case .shotgun: 11
        case .airstrike: 28
        }
    }
    var unlockCost: Int {
        switch self {
        case .bowlingBall: 0
        case .shotgun: 450
        case .airstrike: 900
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
        case .reinforcedDiner: "+1 diner heart per level"
        case .flickTraining: "+10% throw power per level"
        case .rapidGear: "-8% weapon cooldown per level"
        }
    }
    var icon: String {
        switch self {
        case .reinforcedDiner: "shield.fill"
        case .flickTraining: "hand.tap.fill"
        case .rapidGear: "timer"
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

    var environmentAssetName: String {
        let slug = switch id {
        case 1: "closing_time"
        case 2: "freeway_hunger"
        case 3: "hard_hats"
        case 4: "pressure_cooker"
        default: "last_light"
        }
        return String(format: "environment_%02d_%@", id, slug)
    }

    static let all: [GameLevel] = [
        GameLevel(id: 1, title: "Closing Time", subtitle: "Learn the night shift", totalWaves: 3, waveDuration: 15, baseSpawnInterval: 1.65, reward: 180, enemyRoster: [.walker, .runner], skyColor: color(8, 12, 29), horizonColor: color(22, 31, 55)),
        GameLevel(id: 2, title: "Freeway Hunger", subtitle: "Fast feet, bad intentions", totalWaves: 4, waveDuration: 16, baseSpawnInterval: 1.45, reward: 260, enemyRoster: [.walker, .runner, .crawler], skyColor: color(10, 17, 38), horizonColor: color(24, 45, 67)),
        GameLevel(id: 3, title: "Hard Hats", subtitle: "Armor changes the impact", totalWaves: 4, waveDuration: 18, baseSpawnInterval: 1.30, reward: 340, enemyRoster: [.walker, .runner, .armored, .brute], skyColor: color(20, 12, 30), horizonColor: color(57, 29, 55)),
        GameLevel(id: 4, title: "Pressure Cooker", subtitle: "Keep volatile guests apart", totalWaves: 5, waveDuration: 18, baseSpawnInterval: 1.15, reward: 450, enemyRoster: [.runner, .crawler, .armored, .volatile], skyColor: color(23, 9, 22), horizonColor: color(75, 31, 34)),
        GameLevel(id: 5, title: "Last Light", subtitle: "Everything wants breakfast", totalWaves: 6, waveDuration: 19, baseSpawnInterval: 0.98, reward: 650, enemyRoster: ZombieKind.allCases, skyColor: color(4, 8, 22), horizonColor: color(18, 41, 57))
    ]

    private static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> SKColor {
        SKColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }
}

struct GameSettings: Codable, Equatable {
    var musicEnabled = true
    var soundEnabled = true
    var hapticsEnabled = true
    var reducedMotion = false
    var highContrast = false
}

struct PlayerProgress: Codable, Equatable {
    var currency = 350
    var highestUnlockedLevel = 1
    var highScores: [Int: Int] = [:]
    var stars: [Int: Int] = [:]
    var upgradeLevels: [String: Int] = [:]
    var unlockedWeapons: Set<String> = [WeaponKind.bowlingBall.rawValue]
    var unlockedTraps: Set<String> = []
    var achievements: Set<String> = []
    var dailyDate = ""
    var dailyDefeats = 0
    var dailyClaimed = false
    var hasSeenTutorial = false

    func upgradeLevel(_ kind: UpgradeKind) -> Int { upgradeLevels[kind.rawValue, default: 0] }
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
}
