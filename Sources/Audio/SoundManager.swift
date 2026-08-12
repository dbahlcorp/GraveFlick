import AVFoundation

@MainActor
final class SoundManager {
    static let shared = SoundManager()

    enum Effect {
        case grab, impact, defeat, dinerHit, weapon, trap, victory
    }

    private let engine = AVAudioEngine()
    private let musicNode = AVAudioPlayerNode()
    private var effectNodes: [AVAudioPlayerNode] = []
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var settings = GameSettings()

    private init() {
        engine.attach(musicNode)
        engine.connect(musicNode, to: engine.mainMixerNode, format: format)
        for _ in 0..<6 {
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

    func play(_ effect: Effect) {
        guard settings.soundEnabled else { return }
        let parameters: (Double, Double, Float) = switch effect {
        case .grab: (420, 0.06, 0.10)
        case .impact: (90, 0.12, 0.22)
        case .defeat: (170, 0.22, 0.18)
        case .dinerHit: (62, 0.28, 0.24)
        case .weapon: (720, 0.15, 0.16)
        case .trap: (310, 0.18, 0.14)
        case .victory: (880, 0.42, 0.16)
        }
        guard let node = effectNodes.first(where: { !$0.isPlaying }),
              let buffer = tone(frequency: parameters.0, duration: parameters.1, volume: parameters.2) else { return }
        node.scheduleBuffer(buffer)
        node.play()
    }

    private func tone(frequency: Double, duration: Double, volume: Float) -> AVAudioPCMBuffer? {
        guard let buffer = makeBuffer(duration: duration), let channel = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        for index in 0..<frames {
            let time = Double(index) / format.sampleRate
            let decay = max(0, 1 - Float(index) / Float(frames))
            channel[index] = sin(Float(2 * Double.pi * frequency * time)) * volume * decay
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
