# GraveFlick

GraveFlick is an original, touch-first survival-comedy prototype for iPhone and iPad. Defend the Last Light Diner by grabbing shambling creatures, flicking them into the air, and slamming them into the pavement before they reach the building.

The project takes inspiration from the tactile physics of early mobile games while using an original name, setting, characters, code, and fully authored production art.

## Complete vertical slice

- Direct one-finger grabbing, dragging, flicking, and height-sensitive ground slams
- Six original illustrated enemies with different speed, weight, armor, health, and diner damage
- Zombie-to-zombie collisions, volatile chain explosions, combo scoring, and Grave Time
- Nine articulated regular zombies, including the infected waitress, riot cop, and graveyard groundskeeper
- Two unique bosses: The Butcher and Neon Colossus, with dedicated rigs, attacks, resistances, and boss health UI
- Three weapons: Bowling Ball, Scatterblast, and Neon Airstrike
- Two traps: Spike Strip and Flash Freezer
- Five finite levels with escalating waves, stars, rewards, unlocks, and high scores
- Persistent coins, upgrades, level progress, tutorial state, and settings
- Synthesized music and effects, optional haptics, reduced motion, and high contrast
- Original generated app icon and character atlas integrated into the runtime
- No advertising, accounts, analytics, tracking, or third-party runtime dependencies

## Open in Xcode

1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
2. Run `xcodegen generate`
3. Open `GraveFlick.xcodeproj`
4. Choose an iPhone or iPad simulator and press Run

The deployment target is iOS 17. The bundle identifier is `com.bahlcorp.graveflick`; change the signing team or identifier locally if needed.

## Controls

- Touch a creature to grab it.
- Drag to reposition it.
- Release quickly to flick it. A hard pavement impact defeats it.
- Keep creatures away from the diner. Every creature that reaches it removes one heart.

## Project layout

- `Sources/App`: SwiftUI app shell and HUD
- `Sources/Game`: SpriteKit scene, creatures, physics, and scoring rules
- `Tests`: unit tests for touch velocity and scoring math
- `project.yml`: XcodeGen project definition

## Privacy and store preparation

See `PRIVACY.md` for the privacy policy and `STORE_METADATA.md` for grounded App Store copy. The privacy manifest declares local preferences access and no tracking or collected data.

## Remaining release work

The code and simulator tests are validated by GitHub Actions. Physical-device balancing, final screenshots, Apple signing, App Store Connect creation, TestFlight distribution, and age-rating review still require live Apple developer access.
