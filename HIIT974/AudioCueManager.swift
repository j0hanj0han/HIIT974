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
    private var beepPlayer: AVAudioPlayer?

    // MARK: - Lifecycle

    func configure() {
        configureSession()
        setupBeepPlayer()
        setupRemoteControls()
    }

    func deactivate() {
        clearNowPlayingInfo()
        clearRemoteControls()
        beepPlayer?.stop()
        beepPlayer = nil
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
        guard let player = beepPlayer else { return }
        player.currentTime = 0
        player.play()
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

    private func setupBeepPlayer() {
        guard let data = makeBeepWAV() else { return }
        do {
            let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
            player.prepareToPlay()
            beepPlayer = player
        } catch {
            logger.error("AVAudioPlayer setup: \(error)")
        }
    }

    // Génère un bip sinus 880 Hz de 100 ms avec fade-out en WAV PCM 16-bit mono
    private func makeBeepWAV() -> Data? {
        let sampleRate = 44100
        let numSamples = sampleRate / 10
        let fadeStart  = numSamples * 3 / 4

        var samples = [Int16](repeating: 0, count: numSamples)
        for i in 0..<numSamples {
            var amp = sin(2 * .pi * 880.0 * Double(i) / Double(sampleRate)) * 0.55
            if i > fadeStart {
                amp *= Double(numSamples - i) / Double(numSamples - fadeStart)
            }
            samples[i] = Int16(clamping: Int(amp * Double(Int16.max)))
        }

        let dataSize = numSamples * 2
        var wav = Data()

        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }

        wav.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + dataSize))
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        wav.append(contentsOf: "data".utf8); u32(UInt32(dataSize))
        for s in samples { var x = s.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }

        return wav
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
