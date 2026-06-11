import AVFoundation
import MediaPlayer
import os

final class AudioCueManager {

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoHIIT", category: "Audio")

    // Callbacks câblés depuis RunView → lock screen transport controls
    var onPlayPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onSkip: (() -> Void)?
    var onPrevious: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var beepBuffer: AVAudioPCMBuffer?

    // MARK: - Lifecycle

    func configure() {
        configureSession()
        setupAudioEngine()
        setupRemoteControls()
    }

    func deactivate() {
        clearNowPlayingInfo()
        clearRemoteControls()
        audioEngine?.stop()
        audioEngine = nil
        playerNode  = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Audio cues

    func announceSegmentStart(_ label: String) {
        synthesizer.stopSpeaking(at: .word)
        let utterance = AVSpeechUtterance(string: label)
        utterance.voice = AVSpeechSynthesisVoice(language: "fr-FR")
        utterance.rate = 0.52
        utterance.volume = 0.9
        synthesizer.speak(utterance)
    }

    func playBeep() {
        guard let player = playerNode, let buffer = beepBuffer else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func announceFinished() {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "Séance terminée")
        utterance.voice = AVSpeechSynthesisVoice(language: "fr-FR")
        utterance.rate = 0.48
        synthesizer.speak(utterance)
    }

    func updateNowPlaying(workoutName: String, segmentLabel: String,
                          segmentElapsed: Double, segmentDuration: Double,
                          isPlaying: Bool) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: segmentLabel,
            MPMediaItemPropertyArtist: workoutName,
            MPMediaItemPropertyPlaybackDuration: segmentDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: segmentElapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }

    // MARK: - Private

    private func configureSession() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, options: .mixWithOthers)
            try s.setActive(true)
        } catch {
            logger.error("AVAudioSession: \(error)")
        }
    }

    private func setupAudioEngine() {
        guard audioEngine == nil else { return }

        let eng = AVAudioEngine()
        let player = AVAudioPlayerNode()
        eng.attach(player)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return }
        eng.connect(player, to: eng.mainMixerNode, format: format)

        // Génère un bip sinus 880 Hz de 100ms avec fade-out
        let sampleRate = 44100.0
        let frameCount = AVAudioFrameCount(sampleRate * 0.1)
        if let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
           let channelData = buf.floatChannelData {
            buf.frameLength = frameCount
            let data = channelData[0]
            let fadeStart = Int(Double(frameCount) * 0.75)
            for i in 0..<Int(frameCount) {
                var s = sin(2 * Double.pi * 880 * Double(i) / sampleRate) * 0.55
                if i > fadeStart {
                    s *= Double(Int(frameCount) - i) / Double(Int(frameCount) - fadeStart)
                }
                data[i] = Float(s)
            }
            beepBuffer = buf
        }

        do {
            try eng.start()
            player.play()
            audioEngine = eng
            playerNode = player
        } catch {
            logger.error("AVAudioEngine: \(error)")
        }
    }

    private func clearRemoteControls() {
        let cc = MPRemoteCommandCenter.shared()
        [cc.playCommand, cc.pauseCommand, cc.stopCommand, cc.nextTrackCommand,
         cc.previousTrackCommand].forEach {
            $0.removeTarget(nil)
            $0.isEnabled = false
        }
    }

    private func setupRemoteControls() {
        clearRemoteControls()
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.isEnabled = true
        cc.pauseCommand.isEnabled = true
        cc.stopCommand.isEnabled = true
        cc.nextTrackCommand.isEnabled = true
        cc.previousTrackCommand.isEnabled = true

        cc.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onPlayPause?() }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onPlayPause?() }
            return .success
        }
        cc.stopCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onStop?() }
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onSkip?() }
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.onPrevious?() }
            return .success
        }
    }

    func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
