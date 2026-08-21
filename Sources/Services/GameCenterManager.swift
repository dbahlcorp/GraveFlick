import GameKit
import Combine
import SwiftUI
import UIKit

@MainActor
final class GameCenterManager: ObservableObject {
    static let shared = GameCenterManager()
    @Published private(set) var isAuthenticated = false

    /// Only called when the player has opted in from Settings (see GameSettings.gameCenterEnabled)
    /// — GraveFlick never triggers Apple's sign-in sheet on its own. GameKit hands back a
    /// `viewController` whenever the player isn't already signed in at the OS level; it's our job
    /// to present it, otherwise the sheet silently never appears and the player can never sign in.
    func authenticate() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                self?.isAuthenticated = error == nil && GKLocalPlayer.local.isAuthenticated
                if let viewController {
                    Self.topViewController()?.present(viewController, animated: true)
                }
            }
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

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

/// Apple's own Game Center leaderboard/achievement browser (SFSafariViewController-style system
/// UI), reachable from Settings once the player has signed in — see PRIVACY.md's promise that
/// sign-in and this dashboard are Apple's system UI, not a GraveFlick-built substitute.
struct GameCenterDashboard: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> GKGameCenterViewController {
        let controller = GKGameCenterViewController(state: .default)
        controller.gameCenterDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: GKGameCenterViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, GKGameCenterControllerDelegate {
        private let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
            dismiss()
        }
    }
}
