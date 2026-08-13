import GameKit
import Combine

@MainActor
final class GameCenterManager: ObservableObject {
    static let shared = GameCenterManager()
    @Published private(set) var isAuthenticated = false

    func authenticate() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] _, error in
            Task { @MainActor in self?.isAuthenticated = error == nil && GKLocalPlayer.local.isAuthenticated }
        }
    }

    func report(_ result: LevelResult, achievements: Set<String>) {
        guard GKLocalPlayer.local.isAuthenticated else { return }
        let leaderboard = result.levelID == GameLevel.endless.id ? "graveflick.survival.score" : "graveflick.campaign.score"
        GKLeaderboard.submitScore(result.score, context: result.levelID, player: GKLocalPlayer.local, leaderboardIDs: [leaderboard]) { _ in }
        let mapped = achievements.map { key -> GKAchievement in
            let item = GKAchievement(identifier: "graveflick.\(key)")
            item.percentComplete = 100
            item.showsCompletionBanner = true
            return item
        }
        GKAchievement.report(mapped) { _ in }
    }
}
