# GraveFlick

GraveFlick is an original, touch-first survival-comedy game for iPhone and iPad. Defend the Last Light Diner by grabbing shambling creatures, flicking them into the air, and slamming them into the pavement before they reach the building.

The project takes inspiration from the tactile physics of early mobile games while using an original name, setting, characters, code, and fully authored production art. What started as a five-level vertical slice has grown into a full arcade survival game: a 25-night campaign, a standalone Endless Survival mode with roguelite perks and wave modifiers, a free-play Sandbox, 15 challenge missions, a twelve-weapon arsenal, three bosses, achievements, daily rewards, and optional Game Center leaderboards.

## Core loop

- Direct one-finger grabbing, dragging, flicking, and height-sensitive ground slams
- Two-finger pinch/rotate on a grabbed creature for extra flair before you let go
- Weapons are armed with a tap, then fired by performing that weapon's own aim gesture (drag-to-throw, tap-to-target, or hold-to-charge, depending on the weapon)
- Zombie-to-zombie collisions, volatile chain explosions, knockback, and hit-stop/screen-shake feedback on hard impacts
- **Grave Time**: a chargeable special that slows every creature on screen for a breather
- Named combo events (ZOMBIE BOWLING, CHAIN REACTION, AIR MAIL, FRIENDLY FIRE, DINER SPECIAL, HEAD OVER HEELS, GRAVEYARD SHIFT, DOUBLE TAP) with escalating score multipliers

## Enemies and bosses

- Nine articulated regular creatures — walker, runner, brute, crawler, armored, volatile, waitress, riot, groundskeeper — each with its own speed, weight, armor, health, and diner damage
- Three bosses with dedicated rigs, attacks, resistances, and a boss health HUD: **The Butcher**, **Neon Colossus**, and **The Bouncer** (whose armor only strips when it's actually thrown into by another creature, not just crowd contact)

## Arsenal

- Twelve weapons unlocked through campaign progress and coins: Bowling Ball, Scatterblast, Drop Anvil, Grave Grenade, Propane Roller, Neon Airstrike, Deadeye Rifle, Grease Fire, Arc Transformer, Wrecking Ball, Delivery Rush, and Midnight Meteor
- Two traps: Spike Strip and Flash Freezer
- Three permanent upgrades (Reinforced Diner, Flick Training, Rapid Gear), each purchasable across multiple levels with coins

## Modes and levels

- **Campaign**: 25 nights total — 5 hand-authored levels plus 20 procedurally-assembled missions across three later locations, each with escalating waves, mission modifiers (left/right-only, two-sided, hands-off, low gravity, sudden death, and more), stars, rewards, and unlocks
- **Endless Survival**: infinite waves with its own high score, ten stackable **roguelite perks** offered every 5th wave, and seven **wave modifiers** (fog, blackout, rush hour, heavyweights only, exploders only, Grave Time offline, double boss) gated by how far you've gotten in the campaign
- **Sandbox**: unlimited health and full manual control over spawn kind, spawn burst size, creature speed, and gravity, for testing builds or just messing around
- **15 standalone challenge missions** with their own fixed rosters and modifiers, separate from the campaign carousel

## Progression and meta

- Persistent coins, weapon/trap/upgrade unlocks, level stars, high scores, and tutorial state
- 14 achievements/skill feats (e.g. clearing all 25 campaign nights, a 20-hit combo, killing a boss via friendly fire, launching a creature off the top of the screen), each with its own coin payout
- A daily challenge (defeat 25 creatures across any run to claim a coin bonus)
- Optional Game Center integration for campaign/survival leaderboards and achievement reporting — opt-in, no account required to play

## Presentation and accessibility

- Synthesized music and sound effects, with independent music/sound/ambience volume sliders
- Optional haptics, reduced motion, high contrast, gore toggle, screen shake toggle, and flash toggle
- Three difficulty tiers (Casual, Standard, Nightmare) affecting enemy speed, health, spawn rate, and reward payout
- Original generated app icon and character atlas integrated into the runtime
- No advertising, analytics, tracking, or third-party runtime dependencies — Game Center is Apple's own framework and only used if the player opts in

## Open in Xcode

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
2. Run `xcodegen generate`
3. Open `GraveFlick.xcodeproj`
4. Choose an iPhone or iPad simulator and press Run

The deployment target is iOS 17. The bundle identifier is `com.bahlcorp.graveflick`; change the signing team or identifier locally if needed.

## Controls

- Touch a creature to grab it. Drag to reposition it; a second finger pinches/rotates it for style.
- Release quickly to flick it. A hard pavement impact defeats it.
- Tap a weapon icon to arm it, then perform its aim gesture on the battlefield to fire.
- Tap a trap icon to place it, or the special icon to trigger Grave Time once charged.
- Keep creatures away from the diner. Every creature that reaches it removes one heart.

## Project layout

- `Sources/App`: SwiftUI app shell, menus, HUD, and settings/upgrade/level-select screens
- `Sources/Game`: the SpriteKit scene and its owned subsystems — `GameScene` orchestrates world building, physics contacts, and wave/feat bookkeeping, while `PerkSystem`, `ComboSystem`, `SpawnDirector`, `BossDirector`, `WeaponSystem`, `InteractionController`, and `CombatVFXSystem` each own one cohesive slice (roguelite perks, combo/scoring, wave and spawn timing, boss orchestration, weapons/traps/aiming, touch grab/drag/flick input, and gore/hit-flash presentation, respectively)
- `Sources/Models`: `GameContent` (weapons, traps, upgrades, levels, difficulty, settings, saved progress), `Achievements`, and `ProgressStore`
- `Sources/Audio`: `SoundManager` — synthesized music and effects
- `Sources/Services`: optional Game Center leaderboard/achievement reporting
- `Sources/Diagnostics`: on-device MetricKit logging, no network calls
- `Tests`: unit tests for touch velocity and scoring math
- `project.yml`: XcodeGen project definition

## Privacy and store preparation

See `PRIVACY.md` for the privacy policy and `STORE_METADATA.md` for grounded App Store copy. The privacy manifest declares local preferences access and no tracking or collected data.

## Remaining release work

The code and simulator tests are validated by GitHub Actions. Physical-device balancing, final screenshots, Apple signing, App Store Connect creation, TestFlight distribution, and age-rating review still require live Apple developer access.
