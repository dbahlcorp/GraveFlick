import SpriteKit
import SwiftUI

enum AppScreen: Equatable {
    case menu, levels, challenges, sandbox, upgrades, settings, credits, game
}

@MainActor
final class AppModel: ObservableObject {
    @Published var screen: AppScreen = .menu
    @Published var session: GameSessionModel?
    let store = ProgressStore()

    init() {
        SoundManager.shared.apply(store.settings)
        GameCenterManager.shared.authenticate()
    }

    func start(_ level: GameLevel) {
        session = GameSessionModel(level: level, progress: store.progress, settings: store.settings) { [weak self] result in
            self?.store.complete(result)
        }
        screen = .game
        SoundManager.shared.apply(store.settings)
        SoundManager.shared.startGameplayMusic()
    }

    func startSandbox() { start(.sandbox) }

    func leaveGame(to destination: AppScreen = .menu) {
        session = nil
        screen = destination
        SoundManager.shared.startMenuMusic()
    }

    func handleBackgrounding() {
        session?.pauseForBackground()
    }
}

@MainActor
final class GameSessionModel: ObservableObject, GameSceneDelegate {
    @Published private(set) var score = 0
    @Published private(set) var wave = 1
    @Published private(set) var waveStatus = "WAVE 1"
    @Published private(set) var health = GameRules.startingHealth
    @Published private(set) var specialCharge = 0.0
    @Published private(set) var weaponCooldowns: [WeaponKind: TimeInterval] = [:]
    @Published private(set) var trapCooldowns: [TrapKind: TimeInterval] = [:]
    @Published private(set) var isPaused = false
    @Published private(set) var result: LevelResult?
    @Published var showsTutorial: Bool

    let level: GameLevel
    let progress: PlayerProgress
    let scene: GameScene
    private let completion: (LevelResult) -> Void

    init(level: GameLevel, progress: PlayerProgress, settings: GameSettings, completion: @escaping (LevelResult) -> Void) {
        self.level = level
        self.progress = progress
        self.completion = completion
        showsTutorial = !progress.hasSeenTutorial
        health = level.isSandbox ? 99 : (level.modifier == .suddenDeath ? 1 : GameRules.startingHealth + progress.upgradeLevel(.reinforcedDiner))
        scene = GameScene(level: level, progress: progress, settings: settings, size: CGSize(width: 1194, height: 834))
        scene.gameDelegate = self
        if showsTutorial { scene.isGameplayPaused = true }
    }

    func gameScene(_ scene: GameScene, didUpdate snapshot: GameHUDSnapshot) {
        score = snapshot.score
        wave = snapshot.wave
        waveStatus = snapshot.waveStatus
        health = snapshot.health
        specialCharge = snapshot.specialCharge
        weaponCooldowns = snapshot.weaponCooldowns
        trapCooldowns = snapshot.trapCooldowns
    }

    func gameScene(_ scene: GameScene, didFinish result: LevelResult) {
        self.result = result
        isPaused = false
        completion(result)
        GameCenterManager.shared.report(result, achievements: progress.achievements)
    }

    func togglePause() {
        guard result == nil, !showsTutorial else { return }
        isPaused.toggle()
        scene.isGameplayPaused = isPaused
    }

    func pauseForBackground() {
        guard result == nil, !showsTutorial else { return }
        isPaused = true
        scene.isGameplayPaused = true
    }

    func dismissTutorial(store: ProgressStore) {
        showsTutorial = false
        store.markTutorialSeen()
        scene.isGameplayPaused = false
    }

    func use(_ weapon: WeaponKind) { scene.useWeapon(weapon) }
    func use(_ trap: TrapKind) { scene.useTrap(trap) }
    func useSpecial() { scene.useSpecial() }
}

struct GameRootView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch model.screen {
            case .menu:
                MainMenuView(model: model)
            case .levels:
                LevelSelectView(model: model, store: model.store)
            case .challenges:
                ChallengeSelectView(model: model)
            case .sandbox:
                Color.clear
            case .upgrades:
                UpgradeShopView(model: model, store: model.store)
            case .settings:
                SettingsView(model: model, store: model.store)
            case .credits:
                CreditsView(model: model, store: model.store)
            case .game:
                if let session = model.session {
                    GameContainerView(model: model, session: session, store: model.store)
                }
            }
        }
        .animation(.easeInOut(duration: model.store.settings.reducedMotion ? 0 : 0.22), value: model.screen)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.handleBackgrounding() }
        }
    }
}

private struct MainMenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ProgressStore
    @State private var neonPulse = false
    @State private var entered = false

    init(model: AppModel) {
        self.model = model
        store = model.store
    }

    private var continueLevel: GameLevel {
        GameLevel.campaign[max(0, min(GameLevel.campaign.count - 1, store.progress.highestUnlockedLevel - 1))]
    }

    var body: some View {
        ZStack {
            Image("menu_key_art")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
            LinearGradient(
                colors: [.clear, Color(red: 0.015, green: 0.02, blue: 0.045).opacity(0.38), .black.opacity(0.88)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.14), .clear, .black.opacity(0.52)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            GeometryReader { geometry in
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image("ui_graveflick_logo")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: min(geometry.size.width * 0.42, 560), maxHeight: geometry.size.height * 0.30)
                            .accessibilityLabel("GraveFlick, Last Light Diner")
                            .opacity(neonPulse ? 1 : 0.82)
                            .shadow(color: .red.opacity(neonPulse ? 0.48 : 0.16), radius: neonPulse ? 18 : 6)
                        Text("DEFEND THE LAST LIGHT")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .tracking(2.4)
                            .foregroundStyle(.white.opacity(0.78))
                            .shadow(color: .black, radius: 4)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    VStack(spacing: 8) {
                        Text("THE LAST LIGHT DINER NEVER CLOSES QUIETLY")
                            .font(.system(size: 10, weight: .black))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.72))
                            .multilineTextAlignment(.center)

                        MenuButton(title: store.progress.highestUnlockedLevel > 1 ? "CONTINUE" : "PLAY", subtitle: "NIGHT \(continueLevel.id) · \(continueLevel.title.uppercased())", icon: "ui_play", color: .orange) {
                            model.start(continueLevel)
                        }

                        HStack(spacing: 8) {
                            MenuTile(title: "LEVELS", subtitle: "CAMPAIGN", icon: "ui_levels", color: .cyan) { model.screen = .levels }
                            MenuTile(title: "SURVIVAL", subtitle: "ENDLESS", icon: "ui_survival", color: .red) { model.start(GameLevel.endless) }
                        }
                        HStack(spacing: 8) {
                            MenuTile(title: "CHALLENGES", subtitle: "SPECIAL RULES", icon: "ui_star", color: .yellow) { model.screen = .challenges }
                            MenuTile(title: "SANDBOX", subtitle: "FREE PLAY", icon: "ui_grave_time", color: .green) { model.startSandbox() }
                        }

                        HStack(spacing: 7) {
                            UtilityMenuButton(title: "UPGRADES", icon: "ui_upgrades", color: .purple) { model.screen = .upgrades }
                            UtilityMenuButton(title: "SETTINGS", icon: "ui_settings", color: .gray) { model.screen = .settings }
                            UtilityMenuButton(title: "CREDITS", icon: "ui_info", color: .indigo) { model.screen = .credits }
                        }

                        HStack(spacing: 8) {
                            Image("ui_currency_coin").resizable().scaledToFit().frame(width: 20, height: 20)
                            Text("\(store.progress.currency) NIGHT COINS")
                            Spacer(minLength: 8)
                            Text(store.dailySummary)
                                .foregroundStyle(store.progress.dailyClaimed ? .green : .cyan)
                        }
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    }
                    .frame(width: min(max(330, geometry.size.width * 0.46), 460))
                    .roadsidePanel(padding: 12)
                    .offset(x: entered ? 0 : 34)
                    .opacity(entered ? 1 : 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .foregroundStyle(.white)
        .onAppear {
            guard !store.settings.reducedMotion else { entered = true; neonPulse = true; return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) { entered = true }
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) { neonPulse = true }
        }
    }
}

private struct CreditsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ProgressStore

    private let achievements: [(String, String, String)] = [
        ("first_shift", "First Shift", "Clear any night"),
        ("perfect_shift", "Perfect Service", "Earn three stars"),
        ("combo_8", "Eight on the Floor", "Reach an eight-hit combo"),
        ("score_5000", "Neon Scoreboard", "Score 5,000 in one night"),
        ("last_light", "Still Glowing", "Clear the final night")
        ,("road_cleared", "Road Cleared", "Clear all 25 campaign nights")
        ,("survival_20", "Long Night", "Reach survival wave 20")
        ,("combo_20", "Floor Is Lava", "Reach a twenty-hit combo")
        ,("century", "Closing Crew", "Defeat 100 enemies in one shift")
    ]

    var body: some View {
        NightBackground {
            VStack(spacing: 16) {
                ScreenHeader(title: "CREDITS & ACHIEVEMENTS", subtitle: "An original midnight survival comedy") { model.screen = .menu }
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("CREATED BY DBAHLCORP").font(.headline.weight(.black))
                        Text("Design, gameplay, SwiftUI and SpriteKit implementation built for GraveFlick. Original character and App Store artwork generated specifically for this project with OpenAI image generation and integrated into the runtime.")
                            .font(.callout).foregroundStyle(.white.opacity(0.64))
                        Text("No artwork, code, characters, names, audio, or levels were copied from another game.")
                            .font(.caption.weight(.bold)).foregroundStyle(.cyan)
                        Text("Local diagnostics use Apple MetricKit and never leave the device through the app.")
                            .font(.caption).foregroundStyle(.white.opacity(0.52))
                    }
                    .padding(20)
                    .frame(maxWidth: 430, alignment: .leading)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))

                    VStack(spacing: 8) {
                        ForEach(achievements, id: \.0) { item in
                            let unlocked = store.progress.achievements.contains(item.0)
                            HStack {
                                RoadsideIcon(imageName: unlocked ? "ui_achievement" : "ui_lock", color: unlocked ? .yellow : .gray)
                                VStack(alignment: .leading) {
                                    Text(item.1).font(.subheadline.weight(.black))
                                    Text(item.2).font(.caption2).foregroundStyle(.white.opacity(0.55))
                                }
                                Spacer()
                                Text(unlocked ? "+100" : "—").font(.caption.weight(.black)).foregroundStyle(.cyan)
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 52)
                            .background(Color.white.opacity(unlocked ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    .frame(maxWidth: 440)
                }
            }
            .padding(32)
        }
    }
}

private struct LevelSelectView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ProgressStore

    var body: some View {
        NightBackground {
            VStack(spacing: 10) {
                ScreenHeader(title: "NIGHT ROUTE", subtitle: "Twenty-five shifts across eight haunted stops.") { model.screen = .menu }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(GameLevel.campaign) { level in
                            let unlocked = level.id <= store.progress.highestUnlockedLevel
                            Button {
                                if unlocked { model.start(level) }
                            } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    Image(level.environmentAssetName)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(alignment: .topLeading) {
                                            Text("NIGHT 0\(level.id)")
                                                .font(.caption2.weight(.black))
                                                .padding(.horizontal, 8).padding(.vertical, 5)
                                                .background(.black.opacity(0.72), in: Capsule())
                                                .padding(7)
                                        }
                                        .saturation(unlocked ? 1 : 0)
                                    HStack {
                                        Text(level.title).font(.headline.weight(.black))
                                        Spacer()
                                        Image(unlocked ? "ui_star" : "ui_lock").resizable().scaledToFit().frame(width: 24, height: 24)
                                    }
                                    Text(level.subtitle).font(.caption).foregroundStyle(.white.opacity(0.6))
                                    Spacer()
                                    Text(String(repeating: "★", count: store.progress.stars[level.id, default: 0]))
                                        .foregroundStyle(.yellow)
                                        .frame(height: 22)
                                    Text("BEST \(store.progress.highScores[level.id, default: 0])")
                                        .font(.caption2.weight(.black))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                                .foregroundStyle(unlocked ? .white : .white.opacity(0.38))
                                .padding(20)
                                .frame(width: 220, height: 220)
                                .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 22))
                                .overlay(RoundedRectangle(cornerRadius: 22).stroke(level.id == store.progress.highestUnlockedLevel ? Color.orange : Color.white.opacity(unlocked ? 0.22 : 0.08), lineWidth: level.id == store.progress.highestUnlockedLevel ? 2 : 1))
                                .shadow(color: level.id == store.progress.highestUnlockedLevel ? .orange.opacity(0.25) : .clear, radius: 12)
                            }
                            .buttonStyle(.plain)
                            .disabled(!unlocked)
                            .accessibilityLabel("Level \(level.id), \(level.title), \(unlocked ? "unlocked" : "locked")")
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(18)
        }
    }
}

private struct ChallengeSelectView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NightBackground {
            VStack(spacing: 12) {
                ScreenHeader(title: "BONUS NIGHTS", subtitle: "Fifteen original rule-bending shifts") { model.screen = .menu }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 12)], spacing: 12) {
                        ForEach(GameLevel.challenges) { level in
                            Button { model.start(level) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(level.title).font(.headline.weight(.black))
                                    Text(level.modifier.title).font(.caption).foregroundStyle(.cyan)
                                    Text("4 WAVES • +\(level.reward) COINS").font(.caption2.weight(.black)).foregroundStyle(.white.opacity(0.55))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.45)))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(24)
        }
    }
}

private struct UpgradeShopView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ProgressStore

    var body: some View {
        NightBackground {
            VStack(spacing: 16) {
                ScreenHeader(title: "NIGHT GARAGE", subtitle: "\(store.progress.currency) coins available") { model.screen = .menu }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 14)], spacing: 14) {
                        ForEach(UpgradeKind.allCases) { kind in
                            upgradeCard(kind)
                        }
                        ForEach(WeaponKind.allCases) { weapon in
                            let weaponLevel = store.progress.upgradeLevel(weapon)
                            unlockCard(title: weapon.title, detail: "Weapon • level \(weaponLevel)/3", icon: weapon.icon, unlocked: store.progress.isUnlocked(weapon) && weaponLevel >= 3) {
                                if store.progress.isUnlocked(weapon) { _ = store.buyWeaponUpgrade(weapon) }
                                else { _ = store.unlock(weapon) }
                            }
                        }
                        ForEach(TrapKind.allCases) { trap in
                            unlockCard(title: trap.title, detail: "Trap • \(trap.unlockCost) coins", icon: trap.icon, unlocked: store.progress.isUnlocked(trap)) {
                                _ = store.unlock(trap)
                            }
                        }
                    }
                }
            }
            .padding(32)
        }
    }

    private func upgradeCard(_ kind: UpgradeKind) -> some View {
        let level = store.progress.upgradeLevel(kind)
        let cost = kind.cost(forNextLevel: level)
        return Button { _ = store.buyUpgrade(kind) } label: {
            cardContent(title: kind.title, detail: kind.detail, footer: level >= 3 ? "MAX LEVEL" : "LEVEL \(level) • \(cost) COINS", icon: kind.icon)
        }
        .buttonStyle(.plain)
        .disabled(level >= 3 || store.progress.currency < cost)
        .opacity(level >= 3 || store.progress.currency >= cost ? 1 : 0.55)
    }

    private func unlockCard(title: String, detail: String, icon: String, unlocked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            cardContent(title: title, detail: detail, footer: unlocked ? "UNLOCKED" : "TAP TO UNLOCK", icon: icon)
        }
        .buttonStyle(.plain)
        .disabled(unlocked)
        .opacity(unlocked ? 0.72 : 1)
    }

    private func cardContent(title: String, detail: String, footer: String, icon: String) -> some View {
        HStack(spacing: 15) {
            Group {
                if icon.hasPrefix("weapon_") || icon.hasPrefix("trap_") || icon.hasPrefix("ui_") {
                    RoadsideIcon(imageName: icon, color: .orange)
                } else {
                    RoadsideIcon(systemName: icon, color: .orange)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline.weight(.black))
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.62))
                Text(footer).font(.caption2.weight(.black)).foregroundStyle(.cyan)
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(minHeight: 100)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.14)))
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: ProgressStore

    var body: some View {
        NightBackground {
            VStack(spacing: 16) {
                ScreenHeader(title: "SETTINGS", subtitle: "Tune the night shift") { model.screen = .menu }
                SettingsPanel(store: store)
            }
            .padding(32)
        }
    }
}

/// Shared settings controls, reused by the main-menu SettingsView and the in-game pause modal
/// so players can retune audio/accessibility options without abandoning a run.
private struct SettingsPanel: View {
    @ObservedObject var store: ProgressStore
    @State private var confirmsReset = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                settingToggle("Music", icon: "ui_music", keyPath: \.musicEnabled)
                settingToggle("Sound Effects", icon: "ui_sound", keyPath: \.soundEnabled)
                settingToggle("Haptics", icon: "ui_upgrade_flick", keyPath: \.hapticsEnabled)
                settingToggle("Reduced Motion", icon: "ui_upgrade_rapid", keyPath: \.reducedMotion)
                settingToggle("High Contrast", icon: "ui_contrast", keyPath: \.highContrast)
                settingToggle("Cartoon Gore", icon: "ui_heart", keyPath: \.goreEnabled)
                settingToggle("Screen Shake", icon: "ui_grave_time", keyPath: \.screenShakeEnabled)
                settingToggle("Flashes", icon: "ui_moon", keyPath: \.flashesEnabled)
                Picker("Difficulty", selection: $store.settings.difficulty) {
                    ForEach(GameDifficulty.allCases) { difficulty in Text(difficulty.title).tag(difficulty) }
                }
                .pickerStyle(.segmented).padding(.horizontal, 20)
            }
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
            .frame(maxWidth: 560)
            Button("RESET ALL PROGRESS", role: .destructive) { confirmsReset = true }
                .font(.caption.weight(.black))
            Text("GraveFlick uses no analytics, advertising identifiers, accounts, or network tracking.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.54))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .alert("Reset all progress?", isPresented: $confirmsReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { store.resetAll() }
        } message: {
            Text("Levels, high scores, upgrades, and coins will be erased from this device.")
        }
    }

    private func settingToggle(_ title: String, icon: String, keyPath: WritableKeyPath<GameSettings, Bool>) -> some View {
        Toggle(isOn: Binding(
            get: { store.settings[keyPath: keyPath] },
            set: { value in
                store.settings[keyPath: keyPath] = value
                SoundManager.shared.apply(store.settings)
            }
        )) {
            HStack(spacing: 12) {
                Image(icon).resizable().scaledToFit().frame(width: 30, height: 30)
                Text(title).font(.headline)
            }
        }
        .tint(.orange)
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(height: 54)
    }
}

private struct GameContainerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: GameSessionModel
    @ObservedObject var store: ProgressStore
    @State private var showsSettings = false
    @State private var lowHealthPulse = false
    @State private var tutorialGesture = false

    var body: some View {
        ZStack {
            SpriteView(scene: session.scene, options: [.ignoresSiblingOrder])
                .ignoresSafeArea()

            // <= 2, not == 1: a Brute/Volatile deals 2 diner damage in one hit (ZombieKind.dinerDamage),
            // so health can jump straight from 2 to 0 without ever passing through 1.
            if session.health > 0, session.health <= 2, session.result == nil { lowHealthVignette }

            VStack(spacing: 0) {
                gameplayHUD
                Text(session.waveStatus)
                    .font(.caption.weight(.black))
                    .foregroundStyle(session.waveStatus.contains("CLEAR") ? Color.yellow : Color.white.opacity(0.82))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(.top, 5)
                    .accessibilityLabel("Wave status, \(session.waveStatus)")
                Spacer()
                actionBar
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            if session.showsTutorial { tutorial }
            if session.isPaused {
                if showsSettings { settingsModal } else { pauseModal }
            }
            if let result = session.result { resultModal(result) }
        }
        .background(Color.black)
    }

    private var lowHealthVignette: some View {
        RadialGradient(colors: [.clear, Color.red.opacity(0.55)], center: .center, startRadius: 160, endRadius: 520)
            .ignoresSafeArea()
            .opacity(lowHealthPulse ? 0.85 : 0.32)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: lowHealthPulse)
            .onAppear { lowHealthPulse = true }
            .task {
                // Loops for as long as this view is on screen; SwiftUI cancels it automatically
                // once health rises above 1 (level restart) or the diner falls (view disappears).
                while !Task.isCancelled {
                    SoundManager.shared.play(.heartbeat)
                    try? await Task.sleep(nanoseconds: 900_000_000)
                }
            }
    }

    private var gameplayHUD: some View {
        HStack(spacing: 10) {
            Button { session.togglePause() } label: { Image("ui_pause").resizable().scaledToFit().frame(width: 25, height: 25) }
                .hudButton()
            stat("SCORE", "\(session.score)", icon: "ui_star", color: .yellow)
            stat("WAVE", session.level.isEndless ? "\(session.wave)" : "\(session.wave)/\(session.level.totalWaves)", icon: "ui_moon", color: .cyan)
            stat("DINER", String(repeating: "♥", count: session.health), icon: "ui_heart", color: .red)
            Spacer()
            Button { session.useSpecial() } label: {
                HStack(spacing: 8) {
                    Image("ui_grave_time").resizable().scaledToFit().frame(width: 24, height: 24)
                    Text(session.specialCharge >= 1 ? "GRAVE TIME" : "\(Int(session.specialCharge * 100))%")
                }
            }
            .hudButton(active: session.specialCharge >= 1)
            .disabled(session.specialCharge < 1)
            .accessibilityLabel("Grave Time special ability, \(Int(session.specialCharge * 100)) percent charged")
        }
        .padding(7)
        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(red: 0.28, green: 0.63, blue: 0.62).opacity(0.55)))
    }

    private var actionBar: some View {
        HStack(spacing: 5) {
            if session.level.isSandbox { sandboxControls }
            Text("WEAPONS").font(.system(size: 9, weight: .black)).foregroundStyle(.white.opacity(0.55))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(WeaponKind.allCases.filter { (session.level.isSandbox || session.progress.isUnlocked($0)) && (session.level.modifier != .limitedWeapons || $0 == .bowlingBall) }) { weapon in
                        CooldownButton(title: weapon.title, icon: weapon.icon, remaining: session.weaponCooldowns[weapon, default: 0]) { session.use(weapon) }
                    }
                }
            }
            Spacer()
            Text("TRAPS").font(.system(size: 9, weight: .black)).foregroundStyle(.white.opacity(0.55))
            ForEach(TrapKind.allCases.filter { session.progress.isUnlocked($0) }) { trap in
                CooldownButton(title: trap.title, icon: trap.icon, remaining: session.trapCooldowns[trap, default: 0]) { session.use(trap) }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.38)))
    }

    private var sandboxControls: some View {
        Menu {
            Section("Spawn Count") {
                ForEach([1, 3, 6, 12], id: \.self) { count in Button("\(count) AT ONCE") { session.scene.sandboxSetBurst(count) } }
            }
            Section("Simulation Speed") {
                Button("SLOW 0.5×") { session.scene.sandboxSetSpeed(0.5) }
                Button("NORMAL 1×") { session.scene.sandboxSetSpeed(1) }
                Button("CHAOS 2.5×") { session.scene.sandboxSetSpeed(2.5) }
            }
            Section("Gravity") {
                Button("MOON") { session.scene.sandboxSetGravity(-3.2) }
                Button("NORMAL") { session.scene.sandboxSetGravity(-8.8) }
                Button("HEAVY") { session.scene.sandboxSetGravity(-16) }
            }
            Section("Enemies") {
            ForEach(ZombieKind.allCases, id: \.rawValue) { kind in
                Button(kind.displayName) { session.scene.sandboxSpawn(kind) }
            }
            }
            Divider()
            Button("CLEAR LOT", role: .destructive) { session.scene.sandboxClear() }
        } label: {
            Text("SPAWN").font(.system(size: 9, weight: .black)).frame(minWidth: 48, minHeight: 30)
        }.hudButton(active: true, compact: true)
    }

    /// A pop animation + audible ping fires exactly once when `remaining` crosses from cooling
    /// down to ready, so recharged weapons/traps grab attention instead of going unnoticed.
    private struct CooldownButton: View {
        let title: String
        let icon: String
        let remaining: TimeInterval
        let action: () -> Void
        @State private var poppedReady = false

        var body: some View {
            Button(action: action) {
                VStack(spacing: 1) {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 21, height: 18)
                    Text(remaining > 0 ? "\(Int(ceil(remaining)))" : title.uppercased())
                        .font(.system(size: 7, weight: .black))
                        .lineLimit(1)
                }
                .frame(minWidth: 50, minHeight: 32)
                .overlay(alignment: .bottom) {
                    if remaining > 0 {
                        GeometryReader { proxy in
                            Rectangle()
                                .fill(Color.cyan.opacity(0.8))
                                .frame(width: proxy.size.width * min(1, remaining / 10), height: 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 2)
                    }
                }
            }
            .hudButton(active: remaining <= 0, compact: true)
            .disabled(remaining > 0)
            .scaleEffect(poppedReady ? 1.10 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.45), value: poppedReady)
            .accessibilityLabel("\(title), \(remaining > 0 ? "ready in \(Int(ceil(remaining))) seconds" : "ready")")
            .onChange(of: remaining) { oldValue, newValue in
                guard oldValue > 0, newValue <= 0 else { return }
                SoundManager.shared.play(.ready)
                poppedReady = true
                Task {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    poppedReady = false
                }
            }
        }
    }

    private func stat(_ label: String, _ value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Image(icon).resizable().scaledToFit().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 8, weight: .black)).foregroundStyle(.white.opacity(0.55))
                Text(value).font(.system(size: 15, weight: .black, design: .rounded)).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 42)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 13))
    }

    private var tutorial: some View {
        ModalCard {
            Image("ui_graveflick_logo").resizable().scaledToFit().frame(width: 260, height: 108)
            Text("YOUR FIRST NIGHT").font(.title.weight(.black))
            HStack(spacing: 24) {
                tutorialStep("1", "GRAB", "Touch and hold any creature", icon: "ui_tutorial_grab", motion: .scale)
                tutorialStep("2", "FLICK", "Drag quickly and release", icon: "ui_tutorial_flick", motion: .horizontal)
                tutorialStep("3", "SLAM", "Use height and pavement impact", icon: "ui_tutorial_slam", motion: .vertical)
            }
            Text("Weapons and traps recharge automatically. Defeats charge Grave Time.")
                .font(.caption).foregroundStyle(.white.opacity(0.65))
            Button("START NIGHT") { session.dismissTutorial(store: store) }
                .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
        }
        .onAppear {
            guard !store.settings.reducedMotion else { return }
            withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) { tutorialGesture = true }
        }
    }

    private enum TutorialMotion { case scale, horizontal, vertical }

    private func tutorialStep(_ number: String, _ title: String, _ detail: String, icon: String, motion: TutorialMotion) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.20)).frame(width: 48, height: 48)
                Image(icon).resizable().scaledToFit().frame(width: 40, height: 40)
            }
            .scaleEffect(motion == .scale && tutorialGesture ? 1.18 : 1)
            .offset(x: motion == .horizontal && tutorialGesture ? 15 : 0,
                    y: motion == .vertical && tutorialGesture ? 13 : 0)
            .overlay(alignment: .topLeading) {
                Text(number).font(.caption2.weight(.black)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(.red, in: Circle()).offset(x: -4, y: -4)
            }
            Text(title).font(.headline.weight(.black))
            Text(detail).font(.caption).foregroundStyle(.white.opacity(0.62)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 150)
    }

    private var pauseModal: some View {
        ModalCard {
            Text("NIGHT SHIFT PAUSED").font(.title.weight(.black))
            Button("RESUME") { session.togglePause() }.buttonStyle(.borderedProminent).tint(.orange)
            Button("SETTINGS") { showsSettings = true }.buttonStyle(.bordered)
            Button("RETURN TO DINER") { model.leaveGame() }.buttonStyle(.bordered)
        }
    }

    private var settingsModal: some View {
        ModalCard {
            Text("SETTINGS").font(.title.weight(.black))
            SettingsPanel(store: store)
            Button("DONE") { showsSettings = false }.buttonStyle(.borderedProminent).tint(.orange)
        }
    }

    private func resultModal(_ result: LevelResult) -> some View {
        ModalCard(animated: !store.settings.reducedMotion) {
            Image(result.won ? "diner_complete" : "diner_destroyed")
                .resizable().scaledToFit().frame(width: 280, height: 145)
            Text(result.won ? "LOT CLEARED" : (session.level.isEndless ? "NIGHT SHIFT ENDED" : "DINER OVERRUN")).font(.title.weight(.black))
            if session.level.isEndless {
                Text("REACHED WAVE \(result.wave)")
                    .font(.title2.weight(.black)).foregroundStyle(.cyan)
            } else {
                Text(String(repeating: "★", count: result.stars) + String(repeating: "☆", count: 3 - result.stars))
                    .font(.largeTitle).foregroundStyle(.yellow)
            }
            Text("SCORE \(result.score)  •  +\(result.reward) COINS")
                .font(.headline.weight(.black)).foregroundStyle(.white.opacity(0.72))
            HStack {
                Button("LEVELS") { model.leaveGame(to: .levels) }.buttonStyle(.bordered)
                if result.won, result.levelID < GameLevel.campaign.count {
                    Button("NEXT NIGHT") { model.start(GameLevel.campaign[result.levelID]) }
                        .buttonStyle(.borderedProminent).tint(.orange)
                } else {
                    Button("TRY AGAIN") { model.start(session.level) }
                        .buttonStyle(.borderedProminent).tint(.orange)
                }
            }
        }
    }
}

private struct NightBackground<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            Image("environment_01_closing_time")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.18), Color(red: 0.02, green: 0.025, blue: 0.06).opacity(0.78)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Rectangle().fill(.black.opacity(0.18)).ignoresSafeArea()
            content()
        }
        .foregroundStyle(.white)
    }
}

private struct ScreenHeader: View {
    let title: String
    let subtitle: String
    let back: () -> Void
    var body: some View {
        HStack {
            Button(action: back) { Image("ui_back").resizable().scaledToFit().frame(width: 27, height: 27) }.hudButton()
            VStack(alignment: .leading) {
                Text(title).font(.largeTitle.weight(.black))
                Text(subtitle).foregroundStyle(.white.opacity(0.58))
            }
            Spacer()
        }
        .roadsidePanel(padding: 12)
    }
}

private struct MenuButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Image(icon).resizable().scaledToFit().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.headline.weight(.black)).tracking(1.5)
                    Text(subtitle).font(.system(size: 8, weight: .bold)).tracking(0.8).foregroundStyle(.white.opacity(0.62))
                }
                Spacer()
                Image(systemName: "chevron.right")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(LinearGradient(colors: [color.opacity(0.44), Color.black.opacity(0.68)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.88), lineWidth: 1.5))
            .shadow(color: color.opacity(0.2), radius: 7)
        }
        .buttonStyle(.plain)
    }
}

private struct MenuTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(icon).resizable().scaledToFit().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .black)).tracking(0.8)
                    Text(subtitle).font(.system(size: 7, weight: .bold)).tracking(0.6).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 55)
            .background(LinearGradient(colors: [color.opacity(0.30), .black.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.68)))
        }
        .buttonStyle(.plain)
    }
}

private struct UtilityMenuButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(icon).resizable().scaledToFit().frame(width: 17, height: 17)
                Text(title).font(.system(size: 8, weight: .black)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(Color.black.opacity(0.50), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.56)))
        }
        .buttonStyle(.plain)
    }
}

private struct RoadsideIcon: View {
    var imageName: String?
    var systemName: String?
    let color: Color

    init(imageName: String, color: Color) {
        self.imageName = imageName
        systemName = nil
        self.color = color
    }

    init(systemName: String, color: Color) {
        imageName = nil
        self.systemName = systemName
        self.color = color
    }

    var body: some View {
        Group {
            if let imageName {
                Image(imageName).resizable().scaledToFit().padding(7)
            } else if let systemName {
                Image(systemName: systemName).font(.title2.weight(.bold))
            }
        }
        .foregroundStyle(color)
        .frame(width: 48, height: 48)
        .background(LinearGradient(colors: [color.opacity(0.24), .black.opacity(0.74)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(color.opacity(0.72)))
        .shadow(color: color.opacity(0.18), radius: 5)
    }
}

private struct ModalCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var animated = true
    @State private var presented = false

    init(animated: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.animated = animated
        self.content = content
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.67).ignoresSafeArea()
            VStack(spacing: 17) { content() }
                .foregroundStyle(.white)
                .padding(32)
                .background(LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.16), Color(red: 0.035, green: 0.045, blue: 0.07)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(red: 0.33, green: 0.72, blue: 0.69).opacity(0.62), lineWidth: 2))
                .shadow(radius: 30)
                .scaleEffect(presented ? 1 : 0.82)
                .opacity(presented ? 1 : 0)
        }
        .onAppear {
            if animated { withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { presented = true } }
            else { presented = true }
        }
    }
}

private extension View {
    func roadsidePanel(padding: CGFloat) -> some View {
        self
            .padding(padding)
            .background(LinearGradient(colors: [Color(red: 0.16, green: 0.16, blue: 0.17).opacity(0.94), Color(red: 0.035, green: 0.045, blue: 0.055).opacity(0.96)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color(red: 0.30, green: 0.65, blue: 0.63).opacity(0.62), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.5), radius: 14, y: 7)
    }

    func hudButton(active: Bool = true, compact: Bool = false) -> some View {
        self
            .foregroundStyle(active ? Color.white : Color.white.opacity(0.46))
            .padding(.horizontal, compact ? 6 : 13)
            .frame(minHeight: compact ? 36 : 42)
            .background(active ? Color.orange.opacity(0.72) : Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: compact ? 10 : 13))
            .overlay(RoundedRectangle(cornerRadius: compact ? 10 : 13).stroke(.white.opacity(0.18)))
            .buttonStyle(.plain)
    }
}
