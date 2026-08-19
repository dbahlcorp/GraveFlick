import Foundation

/// Reward tier for an achievement (see Achievements.all). Coarser than a one-off coin value per
/// achievement so the reward ladder stays legible at a glance: a first-clear achievement and a
/// genuinely hard skill feat should never pay the same, and this is the one place that decides it.
enum AchievementTier {
    case easy
    case skill
    case hard
    /// Reserved for the rarest, most bragging-rights achievements (e.g. clearing the whole
    /// campaign). Still a coin payout for now — there's no cosmetic/unlock system in the game yet
    /// to grant instead — but kept as its own tier so that reward can plug in later without
    /// re-classifying every achievement.
    case absurd

    var coinReward: Int {
        switch self {
        case .easy: 50
        case .skill: 125
        case .hard: 250
        case .absurd: 400
        }
    }
}

/// Single source of truth for achievement id → display metadata. CreditsView renders the full
/// list from this; GameScene looks up a title here for its live in-run "unlocked" toast; and
/// ProgressStore looks up the coin reward here — so id, title, and payout can never drift apart
/// across those three call sites.
enum Achievements {
    static let all: [(id: String, title: String, description: String, tier: AchievementTier)] = [
        ("first_shift", "First Shift", "Clear any night", .easy),
        ("perfect_shift", "Perfect Service", "Earn three stars", .skill),
        ("combo_8", "Eight on the Floor", "Reach an eight-hit combo", .skill),
        ("score_5000", "Neon Scoreboard", "Score 5,000 in one night", .skill),
        ("last_light", "Still Glowing", "Clear the final night", .hard),
        ("road_cleared", "Road Cleared", "Clear all 25 campaign nights", .absurd),
        ("survival_20", "Long Night", "Reach survival wave 20", .hard),
        ("combo_20", "Floor Is Lava", "Reach a twenty-hit combo", .hard),
        ("century", "Closing Crew", "Defeat 100 enemies in one shift", .skill),
        ("bowling_triple", "Strike", "Kill 3 zombies with one bowling ball roll", .skill),
        ("graceful_wave", "Not a Scratch", "Clear a whole wave without a grabbed zombie touching the ground", .skill),
        ("boss_friendly_fire", "Not Very Friendly", "Kill a boss by colliding it with another zombie", .hard),
        ("sky_launch", "Reach for the Stars", "Launch a zombie clean over the top of the screen", .skill),
        ("chain_reaction_10", "Ten-Pin Special", "Chain a single explosion into 10 kills", .hard)
    ]

    static func title(for id: String) -> String? {
        all.first { $0.id == id }?.title
    }

    static func coinReward(for id: String) -> Int {
        guard let match = all.first(where: { $0.id == id }) else {
            // A typo'd or removed id here would otherwise silently pay skill-tier coins for an
            // achievement that can never appear in CreditsView — loud in debug/test builds where
            // it's cheap to catch, not a crash risk for a released build.
            assertionFailure("Unknown achievement id \"\(id)\" — check Achievements.all and every recordFeat/append call site for a mismatch.")
            return AchievementTier.skill.coinReward
        }
        return match.tier.coinReward
    }
}
