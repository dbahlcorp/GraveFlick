import SpriteKit
import SwiftUI

@MainActor
final class GameViewModel: ObservableObject, GameSceneDelegate {
    @Published private(set) var score = 0
    @Published private(set) var wave = 1
    @Published private(set) var health = GameRules.startingHealth
    @Published private(set) var isPaused = false
    @Published private(set) var isGameOver = false

    let scene: GameScene

    init() {
        scene = GameScene(size: CGSize(width: 1194, height: 834))
        scene.scaleMode = .resizeFill
        scene.gameDelegate = self
    }

    func gameScene(_ scene: GameScene, didUpdateScore score: Int, wave: Int, health: Int) {
        self.score = score
        self.wave = wave
        self.health = health
    }

    func gameSceneDidEnd(_ scene: GameScene) {
        isGameOver = true
        isPaused = false
    }

    func togglePause() {
        guard !isGameOver else { return }
        isPaused.toggle()
        scene.isGameplayPaused = isPaused
    }

    func restart() {
        score = 0
        wave = 1
        health = GameRules.startingHealth
        isPaused = false
        isGameOver = false
        scene.restart()
    }
}

struct GameRootView: View {
    @StateObject private var model = GameViewModel()

    var body: some View {
        ZStack {
            SpriteView(scene: model.scene, options: [.ignoresSiblingOrder])
                .ignoresSafeArea()

            VStack(spacing: 0) {
                hud
                Spacer()
                instructionCard
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)

            if model.isPaused {
                modal(title: "Night Shift Paused", subtitle: "The horde will wait.", button: "Resume") {
                    model.togglePause()
                }
            }

            if model.isGameOver {
                modal(title: "The Last Light Went Dark", subtitle: "Final score: \(model.score)", button: "Try Again") {
                    model.restart()
                }
            }
        }
        .background(Color.black)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
    }

    private var hud: some View {
        HStack(spacing: 12) {
            statPill(icon: "star.fill", label: "SCORE", value: "\(model.score)", color: .yellow)
            statPill(icon: "moon.stars.fill", label: "WAVE", value: "\(model.wave)", color: .cyan)
            statPill(icon: "heart.fill", label: "DINER", value: String(repeating: "♥", count: model.health), color: .red)
            Spacer()
            Button(action: model.togglePause) {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .font(.title3.weight(.black))
                    .frame(width: 48, height: 44)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.2)))
            }
            .buttonStyle(.plain)
        }
    }

    private var instructionCard: some View {
        Text("GRAB  •  FLICK  •  SLAM")
            .font(.caption.weight(.black))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.black.opacity(0.48), in: Capsule())
            .accessibilityLabel("Grab a creature, flick it, and slam it into the pavement")
    }

    private func statPill(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 9, weight: .black)).foregroundStyle(.white.opacity(0.6))
                Text(value).font(.system(size: 17, weight: .black, design: .rounded)).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 44)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.2)))
    }

    private func modal(title: String, subtitle: String, button: String, action: @escaping () -> Void) -> some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea()
            VStack(spacing: 14) {
                Text(title)
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(subtitle).foregroundStyle(.white.opacity(0.72))
                Button(button, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.92, green: 0.32, blue: 0.18))
                    .fontWeight(.bold)
                    .controlSize(.large)
            }
            .foregroundStyle(.white)
            .padding(34)
            .background(Color(red: 0.08, green: 0.09, blue: 0.14), in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.18)))
            .shadow(radius: 30)
        }
    }
}

