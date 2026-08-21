# GraveFlick Release Checklist

## Automated gate

- [ ] Animation and art verification scripts pass from a clean checkout
- [ ] Debug build and all unit tests pass on the oldest supported iOS simulator
- [ ] Release archive contains `Assets.car`, app icons, dSYM, privacy manifest, and both music files
- [ ] Fresh install, upgrade install, corrupt-save recovery, and Reset All Progress are exercised
- [ ] No stale counts or feature claims remain in README, store copy, screenshots, or review notes

## Device matrix

- [ ] Smallest supported iPhone in landscape: no clipped HUD, modals, or tutorial content
- [ ] Current standard and Pro Max iPhones: touch targets and aim previews remain comfortable
- [ ] iPad: correct full-screen landscape presentation
- [ ] Thirty-minute Endless run: stable frame pacing, memory, temperature, audio, and particle count
- [ ] Background/foreground, interruption, rotation lock, low-power mode, and memory warning behavior
- [ ] Music, effects, ambience, haptics, reduced motion, contrast, gore, flashes, and shake toggles

## Playtest gate

- [ ] A new player can clear Night 1 without verbal coaching
- [ ] Players discover how to aim each unlocked weapon; Field Guide wording matches behavior
- [ ] Coin earnings support meaningful purchases without mandatory grinding
- [ ] Casual is forgiving, Standard teaches mastery, and Nightmare is difficult without cheap deaths
- [ ] Boss vulnerability windows and Bouncer armor rules are readable without developer explanation
- [ ] Campaign unlock cadence, Endless perks/modifiers, challenges, and daily reward all function

## App Store Connect

- [ ] App record, bundle ID, signing, agreements, banking/tax status, and SKU are complete
- [ ] Game Center leaderboard and achievement identifiers exactly match runtime identifiers
- [ ] Privacy nutrition label matches `PRIVACY.md` and `PrivacyInfo.xcprivacy`
- [ ] Age rating accounts for cartoon fantasy violence and optional gore
- [ ] Support and privacy URLs are public and reachable without authentication
- [ ] Screenshots are captured for every required device class and match current UI/content
- [ ] Subtitle, description, keywords, categories, copyright, review notes, and contact details are final
- [ ] TestFlight internal pass completed before external testing or review submission

## Launch decision

- [ ] No known progress-loss, crash, soft-lock, signing, or submission blocker remains
- [ ] Remaining balance and presentation issues are recorded and explicitly accepted for this version
- [ ] Marketing version, build number, tag, release notes, and uploaded archive all identify the same build
