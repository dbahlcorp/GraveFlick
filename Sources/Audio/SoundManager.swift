import AVFoundation

@MainActor
final class SoundManager {
    static let shared = SoundManager()

    private enum MusicTrack { case menu, gameplay }

    enum Effect {
        case grab, impact, defeat, dinerHit, weapon, bowlingRoll, bowlingImpact, waveClear, trap, pickup, victory, ready, heartbeat, zombieVoice, bossRoar
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
    private var menuPlayer: AVAudioPlayer?
    private var gameplayPlayer: AVAudioPlayer?
    private var effectNodes: [AVAudioPlayerNode] = []
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var settings = GameSettings()
    private var desiredMusicTrack: MusicTrack = .menu

    private init() {
        engine.attach(musicNode)
        engine.connect(musicNode, to: engine.mainMixerNode, format: format)
        for _ in 0..<10 {
            let node = AVAudioPlayerNode()
            effectNodes.append(node)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }

    func apply(_ settings: GameSettings) {
        self.settings = settings
        if settings.musicEnabled { playDesiredMusic() } else { stopMusic() }
    }

    func startMenuMusic() {
        desiredMusicTrack = .menu
        playDesiredMusic()
    }

    func startGameplayMusic() {
        desiredMusicTrack = .gameplay
        playDesiredMusic()
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
        gameplayPlayer?.stop()

        if menuPlayer == nil,
           let url = Bundle.main.url(forResource: "graveflick_menu_theme", withExtension: "wav") {
            menuPlayer = try? AVAudioPlayer(contentsOf: url)
            menuPlayer?.numberOfLoops = -1
            menuPlayer?.volume = 0.62
            menuPlayer?.prepareToPlay()
        }

        // The procedural loop is a safe fallback if the packaged WAV ever fails to load.
        if menuPlayer?.play() != true { playProceduralGameplayMusic() }
    }

    private func playGameplayMusic() {
        guard settings.musicEnabled, gameplayPlayer?.isPlaying != true else { return }
        menuPlayer?.stop()
        musicNode.stop()

        if gameplayPlayer == nil,
           let url = Bundle.main.url(forResource: "graveflick_gameplay_ambience", withExtension: "wav") {
            gameplayPlayer = try? AVAudioPlayer(contentsOf: url)
            gameplayPlayer?.numberOfLoops = -1
            gameplayPlayer?.volume = 0.48
            gameplayPlayer?.prepareToPlay()
        }

        if gameplayPlayer?.play() != true { playProceduralGameplayMusic() }
    }

    private func playProceduralGameplayMusic() {
        guard settings.musicEnabled, !musicNode.isPlaying else { return }
        let notes: [Double] = [55, 65.41, 73.42, 49]
        let duration = 8.0
        guard let buffer = makeBuffer(duration: duration) else { return }
        let frames = Int(buffer.frameLength)
        let sampleRate = format.sampleRate
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<frames {
                let time = Double(index) / sampleRate
                let note = notes[min(notes.count - 1, Int(time / 2))]
                let pulse = (sin(time * .pi) * 0.5 + 0.5) * 0.035
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

    func playZombieVoice(for kind: ZombieKind, moment: ZombieVoiceMoment, pan: Float = 0) {
        guard settings.soundEnabled,
              let node = effectNodes.first(where: { !$0.isPlaying }),
              let buffer = zombieVocal(zombieVoiceSpec(for: kind, moment: moment)) else { return }
        node.pan = max(-0.9, min(0.9, pan))
        node.scheduleBuffer(buffer)
        node.play()
    }

    func playBossLayer(phase: Int) {
        guard settings.musicEnabled else { return }
        let notes = phase >= 3 ? [82.41, 55, 98] : [65.41, 73.42, 55]
        guard let node = effectNodes.first(where: { !$0.isPlaying }), let buffer = fanfare(notes: notes, noteDuration: 0.16, volume: 0.11) else { return }
        node.pan = 0
        node.scheduleBuffer(buffer); node.play()
    }

    /// - Parameter comboScale: raises the pitch a semitone-ish step per combo hit, the classic
    ///   escalating-reward cue for chained defeats. Ignored by effects that aren't combo-driven.
    func play(_ effect: Effect, comboScale: Int = 1) {
        guard settings.soundEnabled else { return }
        guard let node = effectNodes.first(where: { !$0.isPlaying }) else { return }

        let buffer: AVAudioPCMBuffer?
        switch effect {
        case .victory:
            buffer = fanfare(notes: [523.25, 659.25, 783.99, 1046.50], noteDuration: 0.13, volume: 0.17)
        case .pickup:
            buffer = fanfare(notes: [659.25, 987.77], noteDuration: 0.07, volume: 0.13)
        case .heartbeat:
            buffer = heartbeatPulse()
        case .bossRoar:
            buffer = tone(ToneSpec(frequency: 68, duration: 0.62, volume: 0.26, pitchSweep: 0.52, noiseMix: 0.48))
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
        node.scheduleBuffer(buffer)
        node.play()
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
        case .bowlingImpact: ToneSpec(frequency: 82, duration: 0.26, volume: 0.27, pitchSweep: 0.48, noiseMix: 0.50, detune: false)
        case .trap: ToneSpec(frequency: 320, duration: 0.18, volume: 0.13, pitchSweep: 0.85, noiseMix: 0.10)
        case .ready: ToneSpec(frequency: 880, duration: 0.05, volume: 0.09, pitchSweep: 1.15, noiseMix: 0, detune: false)
        case .pickup, .victory, .heartbeat, .zombieVoice, .bossRoar, .bowlingRoll, .waveClear: ToneSpec(frequency: 660, duration: 0.1, volume: 0.13)
        }
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
            let rawNoise = Float.random(in: -1...1)
            filteredNoise = filteredNoise * 0.85 + rawNoise * 0.15
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
            filteredNoise = filteredNoise * 0.88 + Float.random(in: -1...1) * 0.12
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
                let rawNoise = Float.random(in: -1...1)
                filteredNoise = filteredNoise * 0.8 + rawNoise * 0.2
                sample = toneSample * (1 - spec.noiseMix) + filteredNoise * spec.noiseMix
            }

            let attackEnvelope = index < attackFrames ? Float(index) / Float(attackFrames) : 1
            let decayEnvelope = exp(-Float(progress) * 5.0)
            channel[index] = sample * spec.volume * attackEnvelope * decayEnvelope
        }
        return buffer
    }

    private func makeBuffer(duration: Double) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        buffer.frameLength = capacity
        return buffer
    }
}
