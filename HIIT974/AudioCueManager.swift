@preconcurrency import AVFoundation
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
/// **Le timing des cues ne dépend pas du main thread.** Le décompte 3-2-1 et le bip de
/// transition qui le suit ne sont pas quatre sons qu'on déclenche à quatre instants : ce
/// sont les ``Cue`` de queue (`tailTo…`), **un seul buffer** où le rythme est gravé dans
/// les échantillons. Une fois la lecture lancée, le hardware les consomme à cadence fixe
/// quoi qu'il arrive au CPU — la dérive est physiquement impossible. Les mutations de
/// session partent par ailleurs sur ``sessionQueue`` et ne doivent **jamais** revenir sur
/// le main thread.
@MainActor
final class AudioCueManager {

    /// Décalage, en secondes, entre le début d'une queue de segment et la frontière.
    ///
    /// Le moteur déclenche la queue à `timeRemaining <= tailLead`, et la position `p` dans
    /// le buffer correspond exactement à `timeRemaining == tailLead - p`. C'est cette
    /// égalité qui permet de rattraper un tick en retard en entrant plus loin dans le
    /// buffer, plutôt qu'en décalant tout le rythme.
    nonisolated static let tailLead: TimeInterval = 4

    /// Vocabulaire sonore de l'app. Une tonalité distincte par événement, pour que la
    /// phase soit reconnaissable à l'oreille sans regarder l'écran : aigu = effort,
    /// grave = repos.
    ///
    /// `nonisolated` : c'est un type valeur sans état partagé, et les players se
    /// construisent sur `sessionQueue`, hors du main actor.
    nonisolated enum Cue: CaseIterable {
        case countdown      // un bip du décompte, pris tel quel dans les queues
        case halfway        // moitié d'une phase d'effort
        case startPrepare
        case startWork
        case startRest      // repos et récupération inter-rounds
        case finished

        // Queues de segment : décompte 3-2-1 **et** bip de transition dans un seul buffer.
        // Une variante par phase suivante, puisque c'est elle que le bip final annonce.
        case tailToPrepare
        case tailToWork
        case tailToRest
        case tailToFinish

        /// Séquence (fréquence Hz, durée s). Une fréquence nulle produit un silence.
        ///
        /// Une queue est le décompte commun suivi de son bip de transition — c'est cette
        /// composition qui définit le son, et ``tailClosing`` qui en isole la seule partie
        /// variable.
        var tones: [(frequency: Double, duration: Double)] {
            if let tailClosing { return Cue.countdownTones + tailClosing }
            switch self {
            case .countdown:    return [(880, 0.10)]
            case .halfway:      return [(660, 0.08), (0, 0.07), (660, 0.08)]
            case .startPrepare: return [(660, 0.60)]
            case .startWork:    return [(880, 0.60)]
            case .startRest:    return [(440, 0.60)]
            case .finished:     return [(660, 0.18), (880, 0.18), (1320, 0.30)]
            // Les quatre queues sont traitées par le `if let` ci-dessus : `tailClosing`
            // est non-nil pour elles, et pour elles seules.
            case .tailToPrepare, .tailToWork, .tailToRest, .tailToFinish: return []
            }
        }

        /// Pour une queue, ce qui suit le décompte : le bip qui annonce la phase à venir.
        /// `nil` pour tous les autres cues — c'est aussi ce qui identifie une queue.
        var tailClosing: [(frequency: Double, duration: Double)]? {
            switch self {
            case .tailToPrepare: Cue.startPrepare.tones
            case .tailToWork:    Cue.startWork.tones
            case .tailToRest:    Cue.startRest.tones
            case .tailToFinish:  Cue.finished.tones
            default:             nil
            }
        }

        /// Durée totale du buffer, en secondes.
        var duration: TimeInterval { tones.reduce(0) { $0 + $1.duration } }

        /// Nombre de bips du décompte. Avec ``AudioCueManager/tailLead``, il fixe toute la
        /// géométrie de la queue : le silence de calage vaut `tailLead - countdownBeeps`.
        /// Les deux doivent être lus ensemble — d'où le calcul plutôt que des littéraux.
        static let countdownBeeps = 3

        /// Le décompte : un silence de calage, puis un bip par seconde. Identique dans les
        /// quatre queues, donc rendu une seule fois par ``setupPlayers()``.
        ///
        /// L'espacement n'est pas quelque chose qu'on *demande* à une horloge, il est dans
        /// les échantillons. Le silence de tête laisse en prime au ducking le temps de
        /// s'installer avant le premier bip.
        static let countdownTones: [(frequency: Double, duration: Double)] = {
            let beep = Cue.countdown.tones[0]
            var tones: [(frequency: Double, duration: Double)] = [
                (0, AudioCueManager.tailLead - Double(countdownBeeps))
            ]
            for _ in 0..<countdownBeeps {
                tones.append(beep)
                tones.append((0, 1 - beep.duration))
            }
            return tones
        }()
    }

    // MARK: - Hooks

    /// Appelé quand la session audio a été reconstruite sous nos pieds — fin
    /// d'interruption (appel, Siri) ou changement de route (AirPods). La queue en cours a
    /// été coupée : le moteur doit la relancer, au bon endroit du buffer.
    var onSessionReset: (() -> Void)?

    // Pas de `deinit` : il tournerait `nonisolated` et ne pourrait pas toucher l'état
    // isolé MainActor. Le nettoyage passe par `deactivate()`, appelé par `RunView` en
    // `onDisappear` — tout futur site d'appel doit faire de même.
    private nonisolated let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoHIIT", category: "Audio")

    /// Les mutations d'`AVAudioSession` (`setCategory`, `setActive`) sont des IPC
    /// synchrones vers `mediaserverd`. Avec une autre app audio active (Spotify), elles
    /// peuvent bloquer plusieurs centaines de ms : sur le main thread elles gèleraient le
    /// `RunLoop`, donc le `Timer` de `TimerEngine`. Les commandes de lecture passent par
    /// la même file, pour la même raison **et** pour être sérialisées avec elles : un
    /// `stop()` demandé après un `play()` est ainsi garanti de l'annuler.
    private nonisolated let sessionQueue = DispatchQueue(
        label: (Bundle.main.bundleIdentifier ?? "TempoHIIT") + ".audio-session",
        qos: .userInitiated
    )

    private var players: [Cue: AVAudioPlayer] = [:]
    private var sessionObservers: [NSObjectProtocol] = []

    private var isDucking = false
    private var duckRelease: Task<Void, Never>?

    // MARK: - Lifecycle

    func configure() {
        #if DEBUG
        assertTailContract()
        #endif
        applySession(ducking: false)
        setupPlayers()
        startObservingSession()
    }

    #if DEBUG
    /// Le contrat entre le buffer et le moteur : la position `p` vaut
    /// `timeRemaining == tailLead - p`, donc le bip de transition doit démarrer **pile** à
    /// `tailLead`. Retoucher la géométrie du décompte sans relire
    /// `TimerEngine.startSegmentTailIfNeeded()` désalignerait tout le son sans que rien ne
    /// le signale — exactement la classe de bug que ce mécanisme corrige. Ici, ça casse.
    private func assertTailContract() {
        for cue in Cue.allCases {
            guard let closing = cue.tailClosing else { continue }
            let lead = cue.duration - closing.reduce(0) { $0 + $1.duration }
            assert(abs(lead - Self.tailLead) < 0.001,
                   "Queue \(cue) : transition à \(lead) s au lieu de \(Self.tailLead) s")
        }
    }
    #endif

    func deactivate() {
        stopObservingSession()
        duckRelease?.cancel()
        duckRelease = nil
        isDucking = false
        stopAll()
        players.removeAll()
        deactivateSession()
    }

    // MARK: - Audio cues

    /// Joue un cue, éventuellement en entrant dans le buffer `from` secondes après son
    /// début.
    ///
    /// Ce décalage est tout le rattrapage dont une queue de segment a besoin : un tick en
    /// retard déplace le point d'entrée, jamais le rythme des bips.
    func play(_ cue: Cue, from offset: TimeInterval = 0) {
        guard let ready = players[cue] else {
            // Fenêtre étroite entre `configure()` (ou une reconstruction de session) et la
            // fin de préparation des players. Un cue y est perdu, comme n'importe quel
            // autre son de l'app — mais il faut le savoir.
            logger.error("Cue joué avant que les players soient prêts (\(String(describing: cue), privacy: .public))")
            return
        }
        nonisolated(unsafe) let player = ready
        sessionQueue.async { [logger] in
            player.currentTime = max(0, offset)
            #if DEBUG
            // L'ancre : l'instant, sur l'horloge audio, où la queue *aurait* démarré si le
            // tick était tombé pile. Deux ancres consécutives doivent être séparées d'une
            // durée de segment exacte — c'est ce qui prouve que le rattrapage fonctionne.
            logger.notice("cue \(String(describing: cue), privacy: .public) ancré à \(player.deviceCurrentTime - offset, privacy: .public)")
            #endif
            if !player.play() {
                logger.error("AVAudioPlayer.play a échoué (\(String(describing: cue), privacy: .public))")
            }
        }
    }

    /// Coupe tout son en cours.
    ///
    /// **Obligatoire dès que le déroulé est interrompu** — pause, skip, previous, stop,
    /// reconstruction de session : une queue de segment dure quatre secondes et contient
    /// le bip de transition, elle continuerait sinon toute seule, séance arrêtée.
    func stopAll() {
        let all = Array(players.values)
        guard !all.isEmpty else { return }
        nonisolated(unsafe) let players = all
        sessionQueue.async {
            for player in players { player.stop() }
        }
    }

    // MARK: - Ducking

    /// Atténue la musique de l'utilisateur. Idempotent quant à la session : le garde
    /// `isDucking` évite de la reconfigurer si elle l'est déjà.
    ///
    /// À armer **avant** de lancer une queue de segment : l'IPC vers `mediaserverd` peut
    /// coûter des centaines de ms avec une app audio tierce active, et le silence de tête
    /// du buffer lui laisse justement le temps d'atterrir avant le premier bip.
    func beginDucking() {
        duckRelease?.cancel()
        duckRelease = nil
        guard !isDucking else { return }
        applySession(ducking: true)
        isDucking = true
    }

    /// Rend son volume à la musique après `delay` secondes.
    ///
    /// `delay` doit rester **supérieur à la durée du son en cours**, sinon
    /// `setActive(false)` le coupe net. Pour une queue de segment, cela veut dire couvrir
    /// tout le buffer — décompte et bip de transition compris.
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

    // MARK: - Interruptions et changements de route

    /// Une interruption (appel, Siri) désactive la session, et un changement de route
    /// (AirPods branchés ou débranchés) reconstruit la chaîne audio. Dans les deux cas les
    /// players deviennent muets sans que rien ne le signale — `play()` se contente de
    /// renvoyer `false`. On réarme donc la session, on reconstruit les players, et on
    /// prévient le moteur pour qu'il relance sa queue de segment.
    private func startObservingSession() {
        guard sessionObservers.isEmpty else { return }
        let center = NotificationCenter.default

        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })

        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        })
    }

    private func stopObservingSession() {
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        sessionObservers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            logger.notice("Session interrompue")
            stopAll()
            isDucking = false   // le système a désactivé la session sous nos pieds
        case .ended:
            logger.notice("Fin d'interruption : reconstruction de la session")
            rebuildSession()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
            logger.notice("Changement de route audio : reconstruction de la session")
            rebuildSession()
        default:
            break
        }
    }

    private func rebuildSession() {
        stopAll()
        isDucking = false
        applySession(ducking: false)
        players.removeAll()
        setupPlayers()
        onSessionReset?()
    }

    // MARK: - Private

    /// Applique l'état de session demandé, hors main thread. L'état d'*intention*
    /// (`isDucking`) reste, lui, sur le main actor : la file ne fait qu'exécuter.
    ///
    /// `.duckOthers` implique déjà `.mixWithOthers` : les deux options ne se combinent pas.
    private nonisolated func applySession(ducking: Bool) {
        sessionQueue.async { [logger] in
            // Trace le coût réel de l'IPC. Toujours active (et pas seulement en DEBUG) :
            // c'est la seule façon de mesurer ce que coûte `mediaserverd` sur le device
            // d'un utilisateur, via Console.app.
            let startedAt = ContinuousClock.now
            defer {
                let elapsed = startedAt.duration(to: .now)
                if elapsed > .milliseconds(50) {
                    logger.warning("AVAudioSession lente (ducking: \(ducking, privacy: .public)) : \(elapsed.milliseconds, privacy: .public) ms")
                }
            }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, options: ducking ? [.duckOthers] : [.mixWithOthers])
                try session.setActive(true)
            } catch {
                logger.error("AVAudioSession (ducking: \(ducking, privacy: .public)): \(error, privacy: .public)")
            }
        }
    }

    private nonisolated func deactivateSession() {
        sessionQueue.async { [logger] in
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                logger.error("AVAudioSession deactivate: \(error, privacy: .public)")
            }
        }
    }

    /// Le rendu WAV est du calcul pur et reste ici ; seuls `AVAudioPlayer(data:)` et
    /// `prepareToPlay()`, qui touchent le système audio, partent sur `sessionQueue`.
    ///
    /// Ce n'est pas qu'une question de démarrage : ``rebuildSession()`` rappelle cette
    /// méthode **en pleine séance** après une interruption ou un changement de route. Sur
    /// le main thread, préparer les players y gèlerait le `Timer` du moteur — exactement
    /// ce que tout ce mécanisme cherche à empêcher.
    private func setupPlayers() {
        guard players.isEmpty else { return }

        var cues = Cue.allCases
        #if !DEBUG
        // `.countdown` ne sert qu'à composer les queues : son gabarit est utilisé à la
        // compilation, mais il n'est joué seul que par le harnais de mesure. Inutile de lui
        // préparer un player en Release.
        cues.removeAll { $0 == .countdown }
        #endif

        sessionQueue.async { [weak self, logger] in
            // Le décompte est identique dans les quatre queues : on le rend une fois.
            let countdown = Self.renderSamples(tones: Cue.countdownTones)

            var built: [Cue: AVAudioPlayer] = [:]
            for cue in cues {
                let samples = cue.tailClosing.map { countdown + Self.renderSamples(tones: $0) }
                    ?? Self.renderSamples(tones: cue.tones)
                guard let data = Self.wav(from: samples) else { continue }
                do {
                    let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
                    player.prepareToPlay()
                    built[cue] = player
                } catch {
                    logger.error("AVAudioPlayer setup (\(String(describing: cue), privacy: .public)): \(error, privacy: .public)")
                }
            }
            nonisolated(unsafe) let ready = built
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.players = ready
                }
            }
        }
    }

    /// Synthétise une séquence de tons sinus en échantillons PCM 16-bit mono, avec une
    /// attaque courte et un fade-out sur le dernier quart de chaque ton pour éviter les
    /// clics.
    ///
    /// `nonisolated` : c'est du calcul pur, et il doit tourner sur `sessionQueue`.
    /// ``rebuildSession()`` le rejoue **en pleine séance** après une interruption ou un
    /// changement de route ; sur le main thread, presque un million d'échantillons y
    /// gèleraient le `Timer` du moteur — précisément ce que ce mécanisme évite.
    private nonisolated static func renderSamples(
        tones: [(frequency: Double, duration: Double)]
    ) -> [Int16] {
        let sampleRate = 44100
        var samples: [Int16] = []
        samples.reserveCapacity(tones.reduce(0) { $0 + Int($1.duration * Double(sampleRate)) })

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
        return samples
    }

    /// Emballe des échantillons dans un conteneur WAV PCM.
    ///
    /// Les échantillons sont copiés d'un bloc : un `Data.append` par échantillon coûtait,
    /// sur les ~940 000 que totalisent les queues, bien plus cher que la synthèse
    /// elle-même. iOS est little-endian, l'ordre des octets est donc déjà le bon.
    private nonisolated static func wav(from samples: [Int16]) -> Data? {
        guard !samples.isEmpty else { return nil }

        let sampleRate = 44100
        let dataSize = samples.count * 2
        var wav = Data()
        wav.reserveCapacity(44 + dataSize)

        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }

        wav.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + dataSize))
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        wav.append(contentsOf: "data".utf8); u32(UInt32(dataSize))
        samples.withUnsafeBufferPointer { wav.append(Data(buffer: $0)) }

        return wav
    }
}

private extension Duration {
    /// Millisecondes en `Double` — `Duration` n'est pas interpolable dans un `Logger`.
    nonisolated var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
