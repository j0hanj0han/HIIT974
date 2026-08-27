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
///
/// Toutes les mutations de session partent sur ``sessionQueue`` : elles ne doivent
/// **jamais** revenir sur le main thread, sous peine de geler le timer du moteur.
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
    private nonisolated let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoHIIT", category: "Audio")

    /// Les mutations d'`AVAudioSession` (`setCategory`, `setActive`) sont des IPC
    /// synchrones vers `mediaserverd`. Avec une autre app audio active (Spotify), elles
    /// peuvent bloquer plusieurs centaines de ms : sur le main thread elles gèleraient le
    /// `RunLoop`, donc le `Timer` 20 Hz de `TimerEngine`, et décaleraient les bips du
    /// décompte. On les sérialise ici — FIFO, donc le dernier état demandé par le main
    /// actor est bien le dernier appliqué.
    private nonisolated let sessionQueue = DispatchQueue(
        label: (Bundle.main.bundleIdentifier ?? "TempoHIIT") + ".audio-session",
        qos: .userInitiated
    )

    private var players: [Cue: AVAudioPlayer] = [:]

    private var isDucking = false
    private var duckRelease: Task<Void, Never>?

    // MARK: - Lifecycle

    func configure() {
        applySession(ducking: false)
        setupPlayers()
    }

    func deactivate() {
        duckRelease?.cancel()
        duckRelease = nil
        isDucking = false
        players.values.forEach { $0.stop() }
        players.removeAll()
        deactivateSession()
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
        applySession(ducking: true)
        isDucking = true
    }

    /// Rend son volume à la musique après `delay` secondes.
    ///
    /// Deux contraintes sur `delay` :
    /// - **supérieur à la durée du cue en cours**, sinon `setActive(false)` le coupe net ;
    /// - **supérieur à l'intervalle jusqu'au cue suivant**, quand des cues s'enchaînent
    ///   (le décompte, un bip par seconde). Sinon le relâchement tombe sur le
    ///   `beginDucking()` suivant et on paie deux reconfigurations de session dos à dos.
    ///
    /// Quand la marge est respectée, le `beginDucking()` suivant annule le relâchement en
    /// attente et l'atténuation est maintenue d'une traite sur toute la série de cues —
    /// cf. `TimerEngine.countdownDuckRelease`.
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
        applySession(ducking: false)
        isDucking = false
    }

    // MARK: - Private

    /// Applique l'état de session demandé, hors main thread. L'état d'*intention*
    /// (`isDucking`) reste, lui, sur le main actor : la file ne fait qu'exécuter.
    ///
    /// `.duckOthers` implique déjà `.mixWithOthers` : les deux options ne se combinent pas.
    private nonisolated func applySession(ducking: Bool) {
        sessionQueue.async { [logger] in
            #if DEBUG
            // Trace le coût réel de l'IPC : c'est ce blocage qui, sur le main thread,
            // gelait le timer et collait deux bips du décompte.
            let startedAt = ContinuousClock.now
            defer {
                let elapsed = startedAt.duration(to: .now)
                if elapsed > .milliseconds(50) {
                    logger.warning("AVAudioSession lente (ducking: \(ducking)) : \(elapsed)")
                }
            }
            #endif
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, options: ducking ? [.duckOthers] : [.mixWithOthers])
                try session.setActive(true)
            } catch {
                logger.error("AVAudioSession (ducking: \(ducking)): \(error)")
            }
        }
    }

    private nonisolated func deactivateSession() {
        sessionQueue.async { [logger] in
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                logger.error("AVAudioSession deactivate: \(error)")
            }
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
