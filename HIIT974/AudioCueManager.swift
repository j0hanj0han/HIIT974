import AVFoundation
import os

/// Cues audibles de la séance : décompte, signal de mi-parcours et transitions de phase.
///
/// L'app ne déclare **pas** `UIBackgroundModes: audio` : ces cues sont produits
/// uniquement en avant-plan. La session reste en `.playback` pour passer outre le
/// bouton silencieux et en `.mixWithOthers` pour se superposer à la musique de
/// l'utilisateur sans l'interrompre.
///
/// Pendant la fenêtre de cues (décompte, mi-parcours, transition), la session bascule
/// temporairement en `.duckOthers` : la musique est atténuée le temps qu'on se fasse
/// entendre, puis revient à pleine puissance. Aucune synthèse vocale — tout le
/// vocabulaire est sonore, cf. ``Cue``.
@MainActor
final class AudioCueManager {

    /// Vocabulaire sonore de l'app. Une tonalité distincte par événement, pour que la
    /// phase soit reconnaissable à l'oreille sans regarder l'écran : aigu = effort,
    /// grave = repos.
    enum Cue: CaseIterable {
        case countdown      // 3-2-1 avant la fin d'un segment
        case halfway        // moitié d'une phase d'effort
        case startPrepare
        case startWork
        case startRest      // repos et récupération inter-rounds
        case finished

        /// Séquence (fréquence Hz, durée s). Une fréquence nulle produit un silence.
        var tones: [(frequency: Double, duration: Double)] {
            switch self {
            case .countdown:    [(880, 0.10)]
            case .halfway:      [(660, 0.08), (0, 0.07), (660, 0.08)]
            case .startPrepare: [(660, 0.60)]
            case .startWork:    [(880, 0.60)]
            case .startRest:    [(440, 0.60)]
            case .finished:     [(660, 0.18), (880, 0.18), (1320, 0.30)]
            }
        }
    }

    // Pas de `deinit` : il tournerait `nonisolated` et ne pourrait pas toucher l'état
    // isolé MainActor. Le nettoyage passe par `deactivate()`, appelé par `RunView` en
    // `onDisappear` — tout futur site d'appel doit faire de même.
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoHIIT", category: "Audio")

    private var players: [Cue: AVAudioPlayer] = [:]

    private var isDucking = false
    private var duckRelease: Task<Void, Never>?

    // MARK: - Lifecycle

    func configure() {
        configureSession(ducking: false)
        setupPlayers()
    }

    func deactivate() {
        duckRelease?.cancel()
        duckRelease = nil
        isDucking = false
        players.values.forEach { $0.stop() }
        players.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Audio cues

    func play(_ cue: Cue) {
        guard let player = players[cue] else { return }
        player.currentTime = 0
        player.play()
    }

    // MARK: - Ducking

    /// Atténue la musique de l'utilisateur. Idempotent : appelable à chaque bip du
    /// décompte sans reconfigurer la session à chaque fois.
    func beginDucking() {
        duckRelease?.cancel()
        duckRelease = nil
        guard !isDucking else { return }
        configureSession(ducking: true)
        isDucking = true
    }

    /// Rend son volume à la musique après `delay` secondes. Le délai doit rester
    /// supérieur à la durée du cue en cours : `setActive(false)` coupe net la lecture.
    func endDuckingAfter(_ delay: TimeInterval) {
        duckRelease?.cancel()
        duckRelease = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.releaseDucking()
        }
    }

    /// Changer les options d'une session déjà active suffit à relâcher l'atténuation :
    /// pas de `setActive(false)` ici, qui rendrait le hardware audio aux autres apps juste
    /// avant qu'on le redemande. Si un test sur device montrait que la musique reste
    /// atténuée, le repli serait d'ajouter `setActive(false, .notifyOthersOnDeactivation)`
    /// avant la reconfiguration.
    private func releaseDucking() {
        duckRelease = nil
        guard isDucking else { return }
        configureSession(ducking: false)
        isDucking = false
    }

    // MARK: - Private

    /// `.duckOthers` implique déjà `.mixWithOthers` : les deux options ne se combinent pas.
    private func configureSession(ducking: Bool) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: ducking ? [.duckOthers] : [.mixWithOthers])
            try session.setActive(true)
        } catch {
            logger.error("AVAudioSession: \(error)")
        }
    }

    private func setupPlayers() {
        guard players.isEmpty else { return }
        for cue in Cue.allCases {
            guard let data = makeWAV(tones: cue.tones) else { continue }
            do {
                let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
                player.prepareToPlay()
                players[cue] = player
            } catch {
                logger.error("AVAudioPlayer setup (\(String(describing: cue))): \(error)")
            }
        }
    }

    // Rend une séquence de tons sinus en WAV PCM 16-bit mono, avec une attaque courte
    // et un fade-out sur le dernier quart de chaque ton pour éviter les clics.
    private func makeWAV(tones: [(frequency: Double, duration: Double)]) -> Data? {
        let sampleRate = 44100
        var samples: [Int16] = []

        for tone in tones {
            let count = Int(tone.duration * Double(sampleRate))
            guard count > 0 else { continue }
            guard tone.frequency > 0 else {
                samples.append(contentsOf: [Int16](repeating: 0, count: count))
                continue
            }

            let attack    = min(count / 8, sampleRate / 250)   // ≤ 4 ms
            let fadeStart = count * 3 / 4

            for i in 0..<count {
                var amp = sin(2 * .pi * tone.frequency * Double(i) / Double(sampleRate)) * 0.55
                if attack > 0, i < attack { amp *= Double(i) / Double(attack) }
                if i > fadeStart          { amp *= Double(count - i) / Double(count - fadeStart) }
                samples.append(Int16(clamping: Int(amp * Double(Int16.max))))
            }
        }

        guard !samples.isEmpty else { return nil }

        let dataSize = samples.count * 2
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
}
