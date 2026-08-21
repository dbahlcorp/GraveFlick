import SwiftUI

/// A permanent, replayable counterpart to the short first-run overlay. It intentionally uses the
/// existing production icon kit so help feels like part of GraveFlick rather than a generic sheet.
struct FieldGuideView: View {
    let back: () -> Void
    @State private var section: GuideSection = .basics

    private enum GuideSection: String, CaseIterable, Identifiable {
        case basics = "BASICS"
        case gear = "GEAR"
        case threats = "THREATS"
        case modes = "MODES"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            BundledArtImage(name: "environment_05_last_light", subdirectory: "Art/Environments")
                .scaledToFill().ignoresSafeArea()
                .accessibilityHidden(true)
            LinearGradient(colors: [.black.opacity(0.60), Color(red: 0.02, green: 0.035, blue: 0.08).opacity(0.92), .black.opacity(0.82)], startPoint: .leading, endPoint: .trailing)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Button(action: back) {
                        BundledArtImage(name: "ui_back", subdirectory: "Art/UI/Icons").scaledToFit().frame(width: 28, height: 28).padding(10)
                    }
                    .buttonStyle(.plain)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Back to diner")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FIELD GUIDE").font(.title2.weight(.black))
                        Text("Everything the first night does not tell you").font(.caption).foregroundStyle(.white.opacity(0.62))
                    }
                    Spacer()
                    Picker("Guide section", selection: $section) {
                        ForEach(GuideSection.allCases) { item in Text(item.rawValue).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 440)
                }

                ScrollView(showsIndicators: false) {
                    content
                        .padding(.vertical, 6)
                }
            }
            .padding(20)
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .basics:
            LazyVGrid(columns: columns, spacing: 12) {
                guideCard(icon: "ui_tutorial_grab", title: "GRAB", detail: "Touch and hold a creature. Drag it directly; a second finger can pinch or rotate it for extra control.", color: .cyan)
                guideCard(icon: "ui_tutorial_flick", title: "FLICK", detail: "Move quickly and release. Speed and direction determine the launch, while Flick Training adds power.", color: .orange)
                guideCard(icon: "ui_tutorial_slam", title: "SLAM", detail: "Lift first, then drive creatures into the pavement. Harder and higher impacts deal more damage.", color: .red)
                guideCard(icon: "ui_grave_time", title: "GRAVE TIME", detail: "Defeats fill the moon meter. Trigger it at full charge to slow the entire horde and regain control.", color: .purple)
                guideCard(icon: "ui_heart", title: "THE DINER", detail: "Creatures that reach the diner bite away its health. The shift ends when the final heart is gone.", color: .green)
                guideCard(icon: "ui_star", title: "COMBOS & STARS", detail: "Chain fast, creative defeats for multipliers. Campaign stars reward winning with diner health and score intact.", color: .yellow)
            }
        case .gear:
            VStack(alignment: .leading, spacing: 12) {
                guideCallout("Tap a weapon icon once to arm it. The cooldown begins only after the battlefield gesture successfully fires.")
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(WeaponKind.allCases) { weapon in
                        guideCard(icon: weapon.icon, title: weapon.title.uppercased(), detail: weapon.aimInstruction, color: weaponColor(weapon))
                    }
                    guideCard(icon: TrapKind.spikeStrip.icon, title: "SPIKE STRIP", detail: "Tap its icon to place road spikes automatically across the active approach.", color: .orange)
                    guideCard(icon: TrapKind.freezer.icon, title: "FLASH FREEZER", detail: "Tap its icon to freeze the current crowd. Frozen volatile creatures cannot chain-explode.", color: .cyan)
                }
            }
        case .threats:
            LazyVGrid(columns: columns, spacing: 12) {
                guideCard(icon: "ui_tutorial_flick", title: "ARMORED & RIOT", detail: "Armor absorbs ordinary hits. Use repeated hard impacts, gear, or thrown creatures to break through.", color: .gray)
                guideCard(icon: "ui_grave_time", title: "VOLATILE", detail: "Keep them separated or weaponize the blast. One explosion can ignite a much larger chain reaction.", color: .green)
                guideCard(icon: "ui_survival", title: "THE BUTCHER", detail: "Damage the boss until stunned, then grab and slam during the opening.", color: .red)
                guideCard(icon: "ui_contrast", title: "NEON COLOSSUS", detail: "Survive its heavy pressure, build damage, and exploit the stun window before it recovers.", color: .purple)
                guideCard(icon: "ui_upgrade_flick", title: "THE BOUNCER", detail: "Throw other creatures into its three armor plates. It cannot be grabbed until every plate is gone.", color: .orange)
                guideCard(icon: "ui_moon", title: "WAVE MODIFIERS", detail: "Endless waves can alter visibility, gravity, enemy weight, Grave Time, or even boss count. Read the wave banner.", color: .cyan)
            }
        case .modes:
            LazyVGrid(columns: columns, spacing: 12) {
                guideCard(icon: "ui_levels", title: "CAMPAIGN", detail: "Clear 25 nights to unlock locations, bosses, gear, stars, and escalating mission rules.", color: .cyan)
                guideCard(icon: "ui_survival", title: "SURVIVAL", detail: "Endless waves, perk choices every fifth wave, unlocked modifiers, and a dedicated high score.", color: .red)
                guideCard(icon: "ui_star", title: "CHALLENGES", detail: "Fifteen fixed missions built around special rosters and rules. Each clear awards coins.", color: .yellow)
                guideCard(icon: "ui_grave_time", title: "SANDBOX", detail: "Unlimited diner health with manual creature, burst, speed, and gravity controls.", color: .green)
                guideCard(icon: "ui_upgrades", title: "NIGHT GARAGE", detail: "Spend coins on permanent diner, flick, cooldown, and weapon mastery upgrades.", color: .purple)
                guideCard(icon: "ui_achievement", title: "ACHIEVEMENTS", detail: "Skill feats and milestones pay one-time coin rewards. Track them on the Credits & Achievements screen.", color: .orange)
            }
        }
    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 245), spacing: 12)] }

    private func guideCallout(_ text: String) -> some View {
        Text(text).font(.callout.weight(.bold)).foregroundStyle(.cyan)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(Color.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cyan.opacity(0.35)))
    }

    private func guideCard(icon: String, title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 13) {
            BundledArtImage(name: icon, subdirectory: "Art/Weapons").scaledToFit().frame(width: 42, height: 42).padding(8)
                .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.black)).foregroundStyle(color)
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.72)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(LinearGradient(colors: [color.opacity(0.12), .black.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(color.opacity(0.32)))
        .accessibilityElement(children: .combine)
    }

    private func weaponColor(_ weapon: WeaponKind) -> Color {
        switch weapon {
        case .bowlingBall, .anvil, .wreckingBall: .gray
        case .shotgun, .sniper, .deliveryTruck: .orange
        case .airstrike, .transformer: .cyan
        case .grenade, .propaneTank, .greaseFire: .red
        case .meteor: .purple
        }
    }
}
