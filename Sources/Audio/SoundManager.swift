import AVFoundation

@MainActor
final class SoundManager {
    static let shared = SoundManager()

    private enum MusicTrack { case menu, gameplay }

    enum Effect {
        case grab, impact, defeat, dinerHit, weapon, special, bowlingRoll, bowlingImpact, waveClear, trap, pickup, victory, loss, ready, heartbeat, zombieVoice, bossRoar, armorBreak, explosion
    }

    enum ZombieVoiceMoment { case spawn, hurt, attack, defeat }

    private struct ToneSpec {
        var frequency: Double
        let duration: Double
        let volume: Float
        /// Ratio the frequency sweeps to by the end of the tone (1 = no sweep, <1 = downward "thud", >1 = upward "chirp").
        var pitchSweep: Double = 1
        /// 0 = pure tone, 1 = pure filtered noise. Used for thuds/impacts that need body beyond a sine wave.
        var noiseMix: Float = 0
        /// Randomizes frequency slightly per play so repeated hits during a combo chain don't sound mechanical.
        var detune: Bool = true
    }

    private struct ZombieVoiceSpec {
        var fundamental: Double
        var duration: Double
        var volume: Float
        var pitchSweep: Double
        var noiseMix: Float
        var raspRate: Double
        var formant: Double
    }

    private let engine = AVAudioEngine()
    private let musicNode = AVAudioPlayerNode()
    private let ambienceNode = AVAudioPlayerNode()
    private let tensionNode = AVAudioPlayerNode()
    private var menuPlayer: AVAudioPlayer?
    private var gameplayPlayer: AVAudioPlayer?
    private var effectNodes: [AVAudioPlayerNode] = []
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var settings = GameSettings()
    private var desiredMusicTrack: MusicTrack = .menu
    private var environmentID = 1
    private var gameplayIntensity: Float = 0.12
    private var duckScale: Float = 1
    private var duckGeneration = 0

    private init() {
        engine.attach(musicNode)
        engine.connect(musicNode, to: engine.mainMixerNode, format: format)
        engine.attach(ambienceNode)
        engine.connect(ambienceNode, to: engine.mainMixerNode, format: format)
        engine.attach(tensionNode)
        engine.connect(tensionNode, to: engine.mainMixerNode, format: format)
        for _ in 0..<10 {
            let node = AVAudioPlayerNode()
            effectNodes.append(node)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.prepare()
        try? engine.start()
    }

    func apply(_ settings: GameSettings) {
        self.settings = settings
        if settings.soundEnabled { _ = ensureEffectsEngine() }
        applyMixVolumes()
        if settings.musicEnabled { playDesiredMusic() } else { stopMusic() }
        if !settings.soundEnabled {
            ambienceNode.stop()
            tensionNode.stop()
            effectNodes.forEach { $0.stop() }
        }
        else if desiredMusicTrack == .gameplay, !ambienceNode.isPlaying { startEnvironmentalLayers() }
    }

    func startMenuMusic() {
        desiredMusicTrack = .menu
        ambienceNode.stop()
        tensionNode.stop()
        playDesiredMusic()
    }

    func startGameplayMusic(environmentID: Int) {
        desiredMusicTrack = .gameplay
        self.environmentID = environmentID
        _ = ensureEffectsEngine()
        playDesiredMusic()
        startEnvironmentalLayers()
    }

    func setApplicationActive(_ active: Bool) {
        if active {
            try? AVAudioSession.sharedInstance().setActive(true)
            _ = ensureEffectsEngine()
            playDesiredMusic()
            if desiredMusicTrack == .gameplay, settings.soundEnabled, !ambienceNode.isPlaying { startEnvironmentalLayers() }
        } else {
            menuPlayer?.pause()
            gameplayPlayer?.pause()
            engine.pause()
        }
    }

    private func playDesiredMusic() {
        guard settings.musicEnabled else { return }
        switch desiredMusicTrack {
        case .menu: playMenuMusic()
        case .gameplay: playGameplayMusic()
        }
    }

    private func playMenuMusic() {
        guard menuPlayer?.isPlaying != true else { return }
        musicNode.stop()

        if menuPlayer == nil,
           let url = Bundle.main.url(forResource: "graveflick_menu_theme", withExtension: "wav") {
            menuPlayer = try? AVAudioPlayer(contentsOf: url)
            menuPlayer?.numberOfLoops = -1
            menuPlayer?.volume = 0
            menuPlayer?.prepareToPlay()
        }

        // The procedural loop is a safe fallback if the packaged WAV ever fails to load.
        guard menuPlayer?.play() == true else { playProceduralMenuMusic(); return }
        gameplayPlayer?.setVolume(0, fadeDuration: 0.35)
        menuPlayer?.setVolume(menuMusicVolume, fadeDuration: 0.35)
        stopPlayerAfterFade(gameplayPlayer, unless: .gameplay)
    }

    private func playGameplayMusic() {
        guard settings.musicEnabled, gameplayPlayer?.isPlaying != true else { return }
        musicNode.stop()

        if gameplayPlayer == nil,
           let url = Bundle.main.url(forResource: "graveflick_gameplay_ambience", withExtension: "wav") {
            gameplayPlayer = try? AVAudioPlayer(contentsOf: url)
            gameplayPlayer?.numberOfLoops = -1
            gameplayPlayer?.volume = 0
            gameplayPlayer?.prepareToPlay()
        }

        guard gameplayPlayer?.play() == true else { playProceduralGameplayMusic(); return }
        menuPlayer?.setVolume(0, fadeDuration: 0.35)
        gameplayPlayer?.setVolume(gameplayMusicVolume, fadeDuration: 0.35)
        stopPlayerAfterFade(menuPlayer, unless: .menu)
    }

    private func playProceduralGameplayMusic() {
        playProceduralMusic(notes: [55, 65.41, 73.42, 49], duration: 8, pulseScale: 0.035)
    }

    /// A calmer, higher fallback loop for the menu so a failed WAV load doesn't leave the player
    /// hearing the low, bassy combat-ambience cue while sitting at the main menu.
    private func playProceduralMenuMusic() {
        playProceduralMusic(notes: [49, 58.27, 65.41, 43.65], duration: 10, pulseScale: 0.028)
    }

    private func playProceduralMusic(notes: [Double], duration: Double, pulseScale: Double) {
        guard settings.musicEnabled, !musicNode.isPlaying else { return }
        guard let buffer = makeBuffer(duration: duration) else { return }
        let frames = Int(buffer.frameLength)
        let sampleRate = format.sampleRate
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<frames {
                let time = Double(index) / sampleRate
                let note = notes[min(notes.count - 1, Int(time / 2))]
                let pulse = (sin(time * .pi) * 0.5 + 0.5) * pulseScale
                channel[index] = Float((sin(2 * .pi * note * time) + 0.35 * sin(2 * .pi * note * 2 * time)) * pulse)
            }
        }
        musicNode.scheduleBuffer(buffer, at: nil, options: .loops)
        musicNode.play()
    }

    private func stopMusic() {
        musicNode.stop()
        menuPlayer?.stop()
        gameplayPlayer?.stop()
    }

    private func startEnvironmentalLayers() {
        guard settings.soundEnabled, desiredMusicTrack == .gameplay, ensureEffectsEngine() else { return }
        ambienceNode.stop()
        tensionNode.stop()
        if let ambience = environmentalAmbience(for: environmentID) {
            ambienceNode.scheduleBuffer(ambience, at: nil, options: .loops)
            ambienceNode.play()
        }
        if let tension = tensionPulse() {
            tensionNode.scheduleBuffer(tension, at: nil, options: .loops)
            tensionNode.play()
        }
        applyMixVolumes()
    }

    func playWeapon(_ kind: WeaponKind) {
        let spec: LayeredSpec = switch kind {
        case .bowlingBall: LayeredSpec(low: 105, high: 280, duration: 0.20, volume: 0.18, noise: 0.34, sweep: 0.62, pulses: 1)
        case .shotgun: LayeredSpec(low: 72, high: 1_850, duration: 0.34, volume: 0.30, noise: 0.72, sweep: 0.38, pulses: 1)
        case .airstrike: LayeredSpec(low: 160, high: 1_180, duration: 0.48, volume: 0.16, noise: 0.12, sweep: 1.55, pulses: 3)
        case .anvil: LayeredSpec(low: 96, high: 1_450, duration: 0.46, volume: 0.19, noise: 0.28, sweep: 0.44, pulses: 1)
        case .grenade: LayeredSpec(low: 128, high: 2_200, duration: 0.28, volume: 0.16, noise: 0.18, sweep: 1.42, pulses: 2)
        case .propaneTank: LayeredSpec(low: 82, high: 520, duration: 0.38, volume: 0.20, noise: 0.42, sweep: 0.68, pulses: 2)
        case .wreckingBall: LayeredSpec(low: 48, high: 340, duration: 0.72, volume: 0.23, noise: 0.38, sweep: 0.58, pulses: 2)
        case .sniper: LayeredSpec(low: 116, high: 3_100, duration: 0.22, volume: 0.27, noise: 0.52, sweep: 0.52, pulses: 1)
        case .greaseFire: LayeredSpec(low: 92, high: 760, duration: 0.64, volume: 0.18, noise: 0.64, sweep: 0.78, pulses: 1)
        case .transformer: LayeredSpec(low: 74, high: 2_500, duration: 0.62, volume: 0.19, noise: 0.22, sweep: 1.72, pulses: 5)
        case .deliveryTruck: LayeredSpec(low: 92, high: 370, duration: 0.78, volume: 0.21, noise: 0.18, sweep: 0.88, pulses: 2)
        case .meteor: LayeredSpec(low: 42, high: 920, duration: 0.86, volume: 0.25, noise: 0.55, sweep: 0.32, pulses: 1)
        }
        playLayered(spec)
        if [.shotgun, .sniper, .meteor].contains(kind) { duckMusic(strength: 0.44, duration: 0.36) }
    }

    func playTrap(_ kind: TrapKind) {
        let spec = kind == .spikeStrip
            ? LayeredSpec(low: 118, high: 1_720, duration: 0.34, volume: 0.20, noise: 0.40, sweep: 0.64, pulses: 3)
            : LayeredSpec(low: 52, high: 1_260, duration: 0.78, volume: 0.18, noise: 0.58, sweep: 1.28, pulses: 1)
        playLayered(spec)
    }

    func playMovement(for kind: ZombieKind, pan: Float) {
        let spec: LayeredSpec = switch kind {
        case .crawler: LayeredSpec(low: 86, high: 460, duration: 0.24, volume: 0.07, noise: 0.72, sweep: 0.76, pulses: 1)
        case .brute, .butcher, .colossus: LayeredSpec(low: 43, high: 124, duration: 0.30, volume: 0.13, noise: 0.50, sweep: 0.55, pulses: 1)
        case .armored, .riot: LayeredSpec(low: 62, high: 780, duration: 0.22, volume: 0.09, noise: 0.38, sweep: 0.72, pulses: 1)
        case .runner: LayeredSpec(low: 92, high: 330, duration: 0.14, volume: 0.07, noise: 0.55, sweep: 0.65, pulses: 2)
        default: LayeredSpec(low: 68, high: 240, duration: 0.20, volume: 0.065, noise: 0.62, sweep: 0.70, pulses: 1)
        }
        playLayered(spec, pan: pan)
    }

    func playBossPhase(_ phase: Int, pan: Float = 0) {
        playBossLayer(phase: phase)
        let spec = LayeredSpec(low: phase >= 3 ? 36 : 48, high: phase >= 3 ? 820 : 620, duration: 0.82, volume: 0.25, noise: 0.48, sweep: 0.48, pulses: phase)
        playLayered(spec, pan: pan)
        duckMusic(strength: 0.62, duration: 0.68)
    }

    private struct LayeredSpec {
        let low: Double
        let high: Double
        let duration: Double
        let volume: Float
        let noise: Float
        let sweep: Double
        let pulses: Int
    }

    private func playLayered(_ spec: LayeredSpec, pan: Float = 0) {
        guard settings.soundEnabled, ensureEffectsEngine(),
              let node = effectNodes.first(where: { !$0.isPlaying }),
              let buffer = layeredEffect(spec) else { return }
        node.pan = max(-0.9, min(0.9, pan))
        node.volume = Float(settings.soundVolume)
        node.scheduleBuffer(buffer)
        node.play()
    }

    private var menuMusicVolume: Float { Float(settings.musicVolume) * 0.62 * duckScale }
    private var gameplayMusicVolume: Float { Float(settings.musicVolume) * 0.48 * duckScale }

    private func applyMixVolumes() {
        menuPlayer?.volume = desiredMusicTrack == .menu ? menuMusicVolume : 0
        gameplayPlayer?.volume = desiredMusicTrack == .gameplay ? gameplayMusicVolume : 0
        musicNode.volume = Float(settings.musicVolume) * 0.7 * duckScale
        ambienceNode.volume = settings.soundEnabled ? Float(settings.ambienceVolume) * 0.28 : 0
        tensionNode.volume = settings.soundEnabled ? Float(settings.ambienceVolume) * gameplayIntensity * 0.34 : 0
    }

    private func stopPlayerAfterFade(_ player: AVAudioPlayer?, unless track: MusicTrack) {
        Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard let self, self.desiredMusicTrack != track else { return }
            player?.stop()
        }
    }

    func updateGameplayMix(wave: Int, healthFraction: CGFloat, bossPhase: Int = 0) {
        let wavePressure = min(0.55, Float(max(0, wave - 1)) * 0.08)
        let damagePressure = Float(max(0, 1 - healthFraction)) * 0.38
        let bossPressure = bossPhase > 0 ? 0.22 + Float(max(0, bossPhase - 1)) * 0.14 : 0
        gameplayIntensity = min(1, 0.10 + wavePressure + damagePressure + bossPressure)
        applyMixVolumes()
    }

    func duckMusic(strength: Float = 0.55, duration: TimeInterval = 0.42) {
        guard settings.musicEnabled, settings.soundEnabled else { return }
        duckGeneration += 1
        let generation = duckGeneration
        duckScale = max(0.18, 1 - strength)
        menuPlayer?.setVolume(menuMusicVolume, fadeDuration: 0.04)
        gameplayPlayer?.setVolume(gameplayMusicVolume, fadeDuration: 0.04)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            guard let self, self.duckGeneration == generation else { return }
            self.duckScale = 1
            self.menuPlayer?.setVolume(self.menuMusicVolume, fadeDuration: 0.22)
            self.gameplayPlayer?.setVolume(self.gameplayMusicVolume, fadeDuration: 0.22)
        }
    }

    private var lastZombieVoiceTime: TimeInterval = 0

    /// zombieVocal does real per-sample synthesis (tens of thousands of sin/pow/tanh calls), so
    /// this throttle bounds how many can stack up in one frame when several zombies spawn/attack
    /// at once — without it, a busy moment could pile up multiple multi-millisecond calls.
    func playZombieVoice(for kind: ZombieKind, moment: ZombieVoiceMoment, pan: Float = 0) {
        guard settings.soundEnabled, ensureEffectsEngine() else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastZombieVoiceTime >= 0.05 else { return }
        guard let node = effectNodes.first(where: { !$0.isPlaying }),
              let buffer = zombieVocal(zombieVoiceSpec(for: kind, moment: moment)) else { return }
        lastZombieVoiceTime = now
        node.pan = max(-0.9, min(0.9, pan))
        node.volume = Float(settings.soundVolume)
        node.scheduleBuffer(buffer)
        node.play()
    }

    func playBossLayer(phase: Int) {
        guard settings.musicEnabled, ensureEffectsEngine() else { return }
        let notes = phase >= 3 ? [82.41, 55, 98] : [65.41, 73.42, 55]
        guard let node = effectNodes.first(where: { !$0.isPlaying }), let buffer = fanfare(notes: notes, noteDuration: 0.16, volume: 0.11) else { return }
        node.pan = 0
        node.volume = Float(settings.musicVolume)
        node.scheduleBuffer(buffer); node.play()
    }

    /// - Parameter comboScale: raises the pitch a semitone-ish step per combo hit, the classic
    ///   escalating-reward cue for chained defeats. Ignored by effects that aren't combo-driven.
    func play(_ effect: Effect, comboScale: Int = 1) {
        guard settings.soundEnabled, ensureEffectsEngine() else { return }
        guard let node = effectNodes.first(where: { !$0.isPlaying }) else { return }

        let buffer: AVAudioPCMBuffer?
        switch effect {
        case .victory:
            buffer = fanfare(notes: [523.25, 659.25, 783.99, 1046.50], noteDuration: 0.13, volume: 0.17)
        case .loss:
            buffer = fanfare(notes: [196, 155.56, 116.54, 73.42], noteDuration: 0.20, volume: 0.19)
        case .pickup:
            buffer = fanfare(notes: [659.25, 987.77], noteDuration: 0.07, volume: 0.13)
        case .heartbeat:
            buffer = heartbeatPulse()
        case .bossRoar:
            buffer = tone(ToneSpec(frequency: 68, duration: 0.62, volume: 0.26, pitchSweep: 0.52, noiseMix: 0.48))
        case .armorBreak:
            buffer = layeredEffect(LayeredSpec(low: 94, high: 1_680, duration: 0.42, volume: 0.23, noise: 0.64, sweep: 0.48, pulses: 3))
        case .explosion:
            buffer = layeredEffect(LayeredSpec(low: 44, high: 720, duration: 0.58, volume: 0.28, noise: 0.74, sweep: 0.34, pulses: 1))
        case .zombieVoice:
            buffer = tone(ToneSpec(frequency: 115, duration: 0.28, volume: 0.13, pitchSweep: 0.72, noiseMix: 0.36))
        case .bowlingRoll:
            buffer = tone(ToneSpec(frequency: 92, duration: 0.95, volume: 0.19, pitchSweep: 0.78, noiseMix: 0.58, detune: false))
        case .waveClear:
            buffer = fanfare(notes: [392, 523.25, 659.25], noteDuration: 0.10, volume: 0.15)
        default:
            var toneSpec = spec(for: effect)
            if effect == .defeat {
                toneSpec.frequency *= pow(1.05, Double(min(comboScale - 1, 14)))
            }
            buffer = tone(toneSpec)
        }

        guard let buffer else { return }
        node.pan = 0
        node.volume = Float(settings.soundVolume)
        node.scheduleBuffer(buffer)
        node.play()
    }

    /// AVAudioPlayer continues to play the music masters even when AVAudioEngine failed to start,
    /// which can make a run appear to have ambience but no zombie or weapon effects. Recover the
    /// effects graph at the point of use instead of relying on the one launch-time start attempt.
    @discardableResult
    private func ensureEffectsEngine() -> Bool {
        guard settings.soundEnabled else { return false }
        if engine.isRunning { return true }

        do {
            try AVAudioSession.sharedInstance().setActive(true)
            engine.prepare()
            try engine.start()
            return true
        } catch {
            engine.reset()
            engine.prepare()
            do {
                try engine.start()
                return true
            } catch {
                return false
            }
        }
    }

    /// .pickup, .victory, and .heartbeat are synthesized separately in `play` and never reach here;
    /// their branch only exists to keep this switch exhaustive over `Effect`.
    private func spec(for effect: Effect) -> ToneSpec {
        switch effect {
        case .grab: ToneSpec(frequency: 460, duration: 0.055, volume: 0.11, pitchSweep: 1.25, noiseMix: 0)
        case .impact: ToneSpec(frequency: 150, duration: 0.15, volume: 0.24, pitchSweep: 0.5, noiseMix: 0.32)
        case .defeat: ToneSpec(frequency: 220, duration: 0.20, volume: 0.17, pitchSweep: 1.3, noiseMix: 0.10)
        case .dinerHit: ToneSpec(frequency: 78, duration: 0.32, volume: 0.27, pitchSweep: 0.42, noiseMix: 0.42)
        case .weapon: ToneSpec(frequency: 640, duration: 0.16, volume: 0.15, pitchSweep: 1.4, noiseMix: 0.06)
        case .special: ToneSpec(frequency: 54, duration: 0.72, volume: 0.22, pitchSweep: 1.82, noiseMix: 0.34, detune: false)
        case .bowlingImpact: ToneSpec(frequency: 82, duration: 0.26, volume: 0.27, pitchSweep: 0.48, noiseMix: 0.50, detune: false)
        case .trap: ToneSpec(frequency: 320, duration: 0.18, volume: 0.13, pitchSweep: 0.85, noiseMix: 0.10)
        case .ready: ToneSpec(frequency: 880, duration: 0.05, volume: 0.09, pitchSweep: 1.15, noiseMix: 0, detune: false)
        case .pickup, .victory, .loss, .heartbeat, .zombieVoice, .bossRoar, .armorBreak, .explosion, .bowlingRoll, .waveClear: ToneSpec(frequency: 660, duration: 0.1, volume: 0.13)
        }
    }

    private func layeredEffect(_ spec: LayeredSpec) -> AVAudioPCMBuffer? {
        guard let buffer = makeBuffer(duration: spec.duration), let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        let sampleRate = format.sampleRate
        var lowPhase = 0.0
        var highPhase = 0.0
        var filteredNoise: Float = 0
        let pulseCount = max(1, spec.pulses)
        for index in 0..<frames {
            let time = Double(index) / sampleRate
            let progress = Double(index) / Double(frames)
            let lowFrequency = spec.low * pow(spec.sweep, progress)
            let highFrequency = spec.high * pow(max(0.55, min(1.8, 2 - spec.sweep)), progress)
            lowPhase += 2 * .pi * lowFrequency / sampleRate
            highPhase += 2 * .pi * highFrequency / sampleRate
            filteredNoise = nextFilteredNoise(filteredNoise, smoothing: 0.76)
            let body = Float(sin(lowPhase) + 0.28 * sin(lowPhase * 2.03))
            let edge = Float(sin(highPhase))
            let pulsePhase = (progress * Double(pulseCount)).truncatingRemainder(dividingBy: 1)
            let pulseEnvelope = Float(pow(max(0, 1 - pulsePhase), pulseCount > 1 ? 2.2 : 0.5))
            let attack = min(1, Float(index) / Float(max(1, Int(sampleRate * 0.006))))
            let decay = Float(pow(1 - progress, 1.55))
            let tonal = body * 0.64 + edge * 0.36
            let sample = tonal * (1 - spec.noise) + filteredNoise * spec.noise
            channel[index] = Float(tanh(Double(sample * 1.35))) * spec.volume * attack * decay * pulseEnvelope
        }
        return buffer
    }

    /// A low diner hum, distant road wash, neon buzz, and location-specific weather texture.
    private func environmentalAmbience(for environmentID: Int) -> AVAudioPCMBuffer? {
        let duration = 12.0
        guard let buffer = makeBuffer(duration: duration), let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        let sampleRate = format.sampleRate
        let weatherMix: Float = [2, 5, 7].contains(environmentID) ? 0.72 : ([3, 6, 8].contains(environmentID) ? 0.48 : 0.30)
        let humFrequency = 57.0 + Double(environmentID % 4) * 3.0
        var roadNoise: Float = 0
        var rainNoise: Float = 0
        for index in 0..<frames {
            let time = Double(index) / sampleRate
            roadNoise = roadNoise * 0.994 + Float.random(in: -1...1) * 0.006
            rainNoise = rainNoise * 0.72 + Float.random(in: -1...1) * 0.28
            let hum = Float(sin(2 * .pi * humFrequency * time) + 0.22 * sin(2 * .pi * humFrequency * 2 * time))
            let neon = Float(sin(2 * .pi * 120 * time)) * (sin(2 * .pi * 0.17 * time) > 0.84 ? 1 : 0.12)
            let distantTraffic = roadNoise * Float(0.55 + 0.45 * sin(2 * .pi * 0.035 * time))
            let weather = rainNoise * weatherMix * Float(0.45 + 0.20 * sin(2 * .pi * 0.11 * time))
            channel[index] = (hum * 0.025 + neon * 0.009 + distantTraffic * 0.12 + weather * 0.055)
        }
        return buffer
    }

    private func tensionPulse() -> AVAudioPCMBuffer? {
        let duration = 4.0
        guard let buffer = makeBuffer(duration: duration), let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        let sampleRate = format.sampleRate
        for index in 0..<frames {
            let time = Double(index) / sampleRate
            let swell = Float(pow(sin(.pi * time / duration), 2))
            let bass = Float(sin(2 * .pi * 43.65 * time) + 0.35 * sin(2 * .pi * 65.41 * time))
            let pulse = Float(0.42 + 0.58 * max(0, sin(2 * .pi * 0.75 * time)))
            channel[index] = bass * swell * pulse * 0.12
        }
        return buffer
    }

    /// Renders a short sequence of notes into one buffer so a multi-note cue only occupies a single voice.
    private func fanfare(notes: [Double], noteDuration: Double, volume: Float) -> AVAudioPCMBuffer? {
        let totalDuration = noteDuration * Double(notes.count)
        guard let buffer = makeBuffer(duration: totalDuration), let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        let sampleRate = format.sampleRate
        let noteFrames = max(1, Int(noteDuration * sampleRate))
        let attackFrames = max(1, Int(0.006 * sampleRate))
        for index in 0..<frames {
            let noteIndex = min(notes.count - 1, index / noteFrames)
            let frameInNote = index - noteIndex * noteFrames
            let time = Double(frameInNote) / sampleRate
            let progress = Float(frameInNote) / Float(noteFrames)
            let attackEnvelope = frameInNote < attackFrames ? Float(frameInNote) / Float(attackFrames) : 1
            let decayEnvelope = exp(-progress * 3.4)
            let tone = sin(2 * Double.pi * notes[noteIndex] * time)
            channel[index] = Float(tone) * volume * attackEnvelope * decayEnvelope
        }
        return buffer
    }

    /// A low "lub-dub" double-thump used to warn the player the diner is one hit from losing.
    private func heartbeatPulse() -> AVAudioPCMBuffer? {
        let beats: [(offset: Double, duration: Double, volume: Float)] = [(0, 0.09, 0.20), (0.16, 0.10, 0.16)]
        let totalDuration = 0.34
        guard let buffer = makeBuffer(duration: totalDuration), let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        let sampleRate = format.sampleRate
        var filteredNoise: Float = 0
        for index in 0..<frames {
            let time = Double(index) / sampleRate
            guard let beat = beats.last(where: { time >= $0.offset && time < $0.offset + $0.duration }) else {
                channel[index] = 0
                continue
            }
            let localTime = time - beat.offset
            let progress = Float(localTime / beat.duration)
            let toneSample = Float(sin(2 * Double.pi * 58 * localTime))
            filteredNoise = nextFilteredNoise(filteredNoise, smoothing: 0.85)
            let sample = toneSample * 0.75 + filteredNoise * 0.25
            let decayEnvelope = exp(-progress * 4.2)
            channel[index] = sample * beat.volume * decayEnvelope
        }
        return buffer
    }

    private func zombieVoiceSpec(for kind: ZombieKind, moment: ZombieVoiceMoment) -> ZombieVoiceSpec {
        let base: ZombieVoiceSpec = switch kind {
        case .walker: ZombieVoiceSpec(fundamental: 78, duration: 0.52, volume: 0.17, pitchSweep: 0.72, noiseMix: 0.28, raspRate: 22, formant: 430)
        case .runner: ZombieVoiceSpec(fundamental: 118, duration: 0.34, volume: 0.15, pitchSweep: 0.84, noiseMix: 0.34, raspRate: 31, formant: 620)
        case .brute: ZombieVoiceSpec(fundamental: 54, duration: 0.68, volume: 0.22, pitchSweep: 0.62, noiseMix: 0.30, raspRate: 17, formant: 310)
        case .crawler: ZombieVoiceSpec(fundamental: 136, duration: 0.30, volume: 0.14, pitchSweep: 1.18, noiseMix: 0.48, raspRate: 39, formant: 760)
        case .armored: ZombieVoiceSpec(fundamental: 64, duration: 0.48, volume: 0.18, pitchSweep: 0.78, noiseMix: 0.22, raspRate: 19, formant: 350)
        case .volatile: ZombieVoiceSpec(fundamental: 94, duration: 0.55, volume: 0.18, pitchSweep: 1.28, noiseMix: 0.44, raspRate: 28, formant: 680)
        case .waitress: ZombieVoiceSpec(fundamental: 154, duration: 0.42, volume: 0.13, pitchSweep: 0.68, noiseMix: 0.36, raspRate: 34, formant: 890)
        case .riot: ZombieVoiceSpec(fundamental: 59, duration: 0.56, volume: 0.20, pitchSweep: 0.70, noiseMix: 0.25, raspRate: 18, formant: 330)
        case .groundskeeper: ZombieVoiceSpec(fundamental: 72, duration: 0.52, volume: 0.18, pitchSweep: 0.76, noiseMix: 0.38, raspRate: 24, formant: 470)
        case .butcher: ZombieVoiceSpec(fundamental: 46, duration: 1.05, volume: 0.25, pitchSweep: 0.52, noiseMix: 0.38, raspRate: 14, formant: 270)
        case .colossus: ZombieVoiceSpec(fundamental: 36, duration: 1.24, volume: 0.27, pitchSweep: 0.46, noiseMix: 0.42, raspRate: 11, formant: 220)
        }

        var result = base
        result.fundamental *= Double.random(in: 0.94...1.06)
        switch moment {
        case .spawn:
            result.duration *= 0.92
        case .hurt:
            result.fundamental *= 1.32
            result.duration *= 0.48
            result.pitchSweep = 0.66
            result.volume *= 0.82
        case .attack:
            result.fundamental *= 0.88
            result.duration *= 0.72
            result.pitchSweep *= 0.82
            result.volume *= 1.08
        case .defeat:
            result.duration *= 0.88
            result.pitchSweep = min(result.pitchSweep, 0.44)
            result.noiseMix = min(0.58, result.noiseMix + 0.12)
        }
        return result
    }

    /// Layered, formant-like vocal synthesis. The low oscillator supplies the throat, the
    /// rectified formant adds a mouth-shaped rasp, and filtered noise keeps it organic.
    private func zombieVocal(_ spec: ZombieVoiceSpec) -> AVAudioPCMBuffer? {
        guard let buffer = makeBuffer(duration: spec.duration), let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        let sampleRate = format.sampleRate
        let attack = max(1, Int(sampleRate * 0.018))
        var throatPhase = 0.0
        var formantPhase = 0.0
        var filteredNoise: Float = 0

        for index in 0..<frames {
            let time = Double(index) / sampleRate
            let progress = Double(index) / Double(frames)
            let frequency = spec.fundamental * pow(spec.pitchSweep, progress) * (1 + 0.035 * sin(2 * .pi * spec.raspRate * time))
            throatPhase += 2 * .pi * frequency / sampleRate
            formantPhase += 2 * .pi * spec.formant * (1 + 0.025 * sin(2 * .pi * 5.2 * time)) / sampleRate

            let throat = Float(sin(throatPhase) + 0.34 * sin(throatPhase * 2.01) + 0.16 * sin(throatPhase * 3.03))
            let mouth = Float(sin(formantPhase)) * (0.32 + 0.68 * abs(Float(sin(throatPhase))))
            filteredNoise = nextFilteredNoise(filteredNoise, smoothing: 0.88)
            let voiced = throat * (1 - spec.noiseMix) + (mouth * 0.42 + filteredNoise * 0.58) * spec.noiseMix
            let attackEnvelope = index < attack ? Float(index) / Float(attack) : 1
            let decayEnvelope = Float(pow(1 - progress, 1.35))
            let tremolo = Float(0.78 + 0.22 * sin(2 * .pi * spec.raspRate * 0.48 * time))
            let softened = Float(tanh(Double(voiced * 1.45)))
            channel[index] = softened * spec.volume * attackEnvelope * decayEnvelope * tremolo
        }
        return buffer
    }

    private func tone(_ spec: ToneSpec) -> AVAudioPCMBuffer? {
        guard let buffer = makeBuffer(duration: spec.duration), let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        let sampleRate = format.sampleRate
        let attackFrames = max(1, Int(0.004 * sampleRate))
        let frequency = spec.detune ? spec.frequency * Double.random(in: 0.97...1.03) : spec.frequency
        var filteredNoise: Float = 0
        for index in 0..<frames {
            let time = Double(index) / sampleRate
            let progress = Double(index) / Double(frames)
            let sweptFrequency = frequency * pow(spec.pitchSweep, progress)
            let toneSample = Float(sin(2 * Double.pi * sweptFrequency * time))

            var sample = toneSample
            if spec.noiseMix > 0 {
                filteredNoise = nextFilteredNoise(filteredNoise, smoothing: 0.8)
                sample = toneSample * (1 - spec.noiseMix) + filteredNoise * spec.noiseMix
            }

            let attackEnvelope = index < attackFrames ? Float(index) / Float(attackFrames) : 1
            let decayEnvelope = exp(-Float(progress) * 5.0)
            channel[index] = sample * spec.volume * attackEnvelope * decayEnvelope
        }
        return buffer
    }

    /// One-pole low-pass filtered noise step shared by every synth voice below, so a smoothing-
    /// coefficient fix made for one voice doesn't silently fail to propagate to the others.
    private func nextFilteredNoise(_ previous: Float, smoothing: Float) -> Float {
        previous * smoothing + Float.random(in: -1...1) * (1 - smoothing)
    }

    private func makeBuffer(duration: Double) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        buffer.frameLength = capacity
        return buffer
    }
}
