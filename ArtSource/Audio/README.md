# GraveFlick menu theme provenance

The editable Strudel sources are:

- `graveflick_menu_theme.strudel.js` — main-menu track, **Last Light After Midnight**.
- `graveflick_gameplay_ambience.strudel.js` — in-game track, **Closing Time Never Ends**.

- Composed specifically for GraveFlick on August 14, 2026.
- Rendered with the free, open-source [Strudel](https://strudel.cc/) browser music tool.
- Uses Strudel's built-in Web Audio oscillators (`sine`, `triangle`, `square`, and `sawtooth`) only.
- Contains no third-party samples, recordings, vocals, imported melodies, or material copied from another game.
- Runtime menu master: `Resources/Audio/graveflick_menu_theme.wav` (25.263 seconds, stereo, 44.1 kHz, 16-bit PCM).
- Runtime gameplay master: `Resources/Audio/graveflick_gameplay_ambience.wav` (30 seconds, stereo, 44.1 kHz, 16-bit PCM).
- Zombie voices are generated at runtime from original layered oscillator, formant, and filtered-noise synthesis in `SoundManager.swift`; they use no recorded samples.

The Strudel application is AGPL-3.0 software. GraveFlick does not embed or distribute Strudel; it ships only this project's original rendered composition and its small editable pattern source.
