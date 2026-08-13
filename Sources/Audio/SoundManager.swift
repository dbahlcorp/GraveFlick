import AVFoundation

@MainActor
final class SoundManager {
    static let shared = SoundManager()

    enum Effect {
        case grab, impact, defeat, dinerHit, weapon, trap, pickup, victory, ready, heartbeat, zombieVoice, bossRoar
    }

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

    private let engine = AVAudioEngine()
    private let musicNode = AVAudioPlayerNode()
    private var effectNodes: [AVAudioPlayerNode] = []
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var settings = GameSettings()

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
        if settings.musicEnabled { startMusic() } else { musicNode.stop() }
    }

    func startMusic() {
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

    func playBossLayer(phase: Int) {
        guard settings.musicEnabled else { return }
        let notes = phase >= 3 ? [82.41, 55, 98] : [65.41, 73.42, 55]
        guard let node = effectNodes.first(where: { !$0.isPlaying }), let buffer = fanfare(notes: notes, noteDuration: 0.16, volume: 0.11) else { return }
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
        default:
            var toneSpec = spec(for: effect)
            if effect == .defeat {
                toneSpec.frequency *= pow(1.05, Double(min(comboScale - 1, 14)))
            }
            buffer = tone(toneSpec)
        }

        guard let buffer else { return }
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
        case .trap: ToneSpec(frequency: 320, duration: 0.18, volume: 0.13, pitchSweep: 0.85, noiseMix: 0.10)
        case .ready: ToneSpec(frequency: 880, duration: 0.05, volume: 0.09, pitchSweep: 1.15, noiseMix: 0, detune: false)
        case .pickup, .victory, .heartbeat, .zombieVoice, .bossRoar: ToneSpec(frequency: 660, duration: 0.1, volume: 0.13)
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
