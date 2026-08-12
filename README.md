# GraveFlick

GraveFlick is an original, touch-first survival-comedy prototype for iPhone and iPad. Defend the Last Light Diner by grabbing shambling creatures, flicking them into the air, and slamming them into the pavement before they reach the building.

The project takes inspiration from the tactile physics of early mobile games while using an original name, setting, characters, code, and programmatic art.

## Playable prototype

- Direct one-finger grabbing, dragging, flicking, and ground slams
- Physics-driven throws with impact-based defeats
- Walkers and heavier brutes with different speed and toughness
- Endless waves, escalating spawn pressure, health, scoring, and combos
- Pause, restart, game-over, screen shake, impact bursts, and lightweight animation
- Responsive landscape layout for iPhone and iPad
- No third-party runtime dependencies and no external art assets

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

## Roadmap

The next vertical-slice milestones are original illustrated sprite sheets, sound and haptics, usable traps, weapon pickups, progression, accessibility options, and device playtesting.

