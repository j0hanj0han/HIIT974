import Foundation
import SwiftUI
import Observation
import os

@MainActor
@Observable
final class TimerEngine {

    // MARK: - Step (modèle interne léger, pas SwiftData)

    struct Step {
        enum Phase {
            case prepare, work, rest, reset

            var color: Color {
                switch self {
                case .prepare: .orange; case .work: .red; case .rest: .blue; case .reset: .teal
                }
            }
            var systemImage: String {
                switch self {
                case .prepare: "figure.stand"; case .work: "bolt.fill"
                case .rest: "pause.circle";    case .reset: "arrow.clockwise"
                }
            }
            var label: String {
                switch self {
                case .prepare: "Préparation"; case .work: "Effort"
                case .rest: "Repos";          case .reset: "Récupération"
                }
            }
            /// Bip long joué au démarrage de la phase. Aigu = effort, grave = récupération.
            var startCue: AudioCueManager.Cue {
                switch self {
                case .prepare:      .startPrepare
                case .work:         .startWork
                case .rest, .reset: .startRest
                }
            }
        }

        let phase: Phase
        let durationSeconds: Int
        let round: Int              // 1-based
        let setIndex: Int           // 1-based ; 0 pour les steps reset
        let exerciseName: String?   // nom personnalisé, phases d'effort uniquement

        /// Ce que l'écran de séance affiche pour ce step : le nom de l'exercice quand il
        /// est renseigné, le libellé de phase sinon. Toute l'UI passe par là, pour éviter
        /// d'éparpiller le repli dans les vues.
        var displayLabel: String { exerciseName ?? phase.label }
    }

    // MARK: - TimerState

    enum TimerState { case idle, running, paused, finished }

    // MARK: - Published state

    private(set) var state: TimerState = .idle
    private(set) var currentStepIndex: Int = 0
    private(set) var timeRemaining: TimeInterval
    /// Secondes affichées par le chrono, arrondies vers le haut.
    ///
    /// Existe pour que le `Text` du chrono — énorme depuis la v1.4, donc coûteux à
    /// remettre en page — ne soit invalidé qu'une fois par seconde, alors que
    /// ``timeRemaining`` change 20 fois par seconde pour l'anneau.
    private(set) var displayedSeconds: Int
    private(set) var startedAt: Date?
    private(set) var beepCount: Int = 0

    let steps: [Step]
    let totalRounds: Int
    let totalSets: Int
    let audioCue = AudioCueManager()

    private nonisolated let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoHIIT", category: "Timer")

    private var referenceDate: Date?
    private var referenceRemaining: TimeInterval
    private var timer: Timer?
    private var halfwayFired = false

    // MARK: - Queue de segment

    /// La queue de segment (décompte 3-2-1 **et** bip de transition) a-t-elle été lancée ?
    /// C'est un seul son de quatre secondes, donc un seul drapeau.
    private var tailStarted = false
    /// Dernière seconde du décompte franchie, pour le retour haptique.
    private var lastBeepSecond = -1

    init(workout: Workout) {
        var built: [Step] = []
        if workout.prepareSeconds > 0 {
            built.append(Step(phase: .prepare, durationSeconds: workout.prepareSeconds,
                              round: 1, setIndex: 0, exerciseName: nil))
        }
        for r in 0..<max(workout.rounds, 1) {
            for s in 0..<max(workout.sets, 1) {
                // Les noms sont attachés à la série, donc identiques d'un round à l'autre.
                built.append(Step(phase: .work, durationSeconds: workout.workSeconds,
                                  round: r + 1, setIndex: s + 1,
                                  exerciseName: workout.exerciseName(at: s + 1)))
                // Repos à 0 s : on n'insère aucun step, sinon un segment de durée nulle
                // ferait défiler deux index en un seul tick et jouerait un cue fantôme.
                if workout.restSeconds > 0 {
                    built.append(Step(phase: .rest, durationSeconds: workout.restSeconds,
                                      round: r + 1, setIndex: s + 1, exerciseName: nil))
                }
            }
            if r < workout.rounds - 1 && workout.resetSeconds > 0 {
                built.append(Step(phase: .reset, durationSeconds: workout.resetSeconds,
                                  round: r + 1, setIndex: 0, exerciseName: nil))
            }
        }
        steps        = built
        totalRounds  = workout.rounds
        totalSets    = workout.sets

        let initial = TimeInterval(built.first?.durationSeconds ?? 0)
        timeRemaining      = initial
        referenceRemaining = initial
        displayedSeconds   = max(0, Int(ceil(initial)))

        // Une interruption ou un changement de route coupe la queue en cours : il faut
        // la relancer, au bon endroit du buffer.
        audioCue.onSessionReset = { [weak self] in self?.markTailInterrupted() }
    }

    /// `isolated` : le `Timer` est ordonnancé sur la `RunLoop` du main thread, donc
    /// `invalidate()` doit y être appelé. Le `nonisolated(unsafe)` que portait la
    /// propriété avant se contentait de faire taire l'isolation — et le compilateur
    /// signalait qu'il n'avait « aucun effet ».
    isolated deinit { timer?.invalidate() }

    // MARK: - Computed

    var currentStep: Step? { steps[safe: currentStepIndex] }
    var nextStep: Step?    { steps[safe: currentStepIndex + 1] }
    var currentRound: Int  { currentStep?.round ?? 1 }
    var currentSetIndex: Int { currentStep?.setIndex ?? 1 }

    // MARK: - Controls

    func start() {
        guard state == .idle, !steps.isEmpty else { return }
        currentStepIndex     = 0
        interruptCues()
        referenceRemaining   = TimeInterval(steps[0].durationSeconds)
        setTimeRemaining(referenceRemaining)
        referenceDate        = Date()
        startedAt            = Date()
        state                = .running
        scheduleTimer()
        cueSegmentStart()
    }

    func pause() {
        guard state == .running else { return }
        snapshotTimeRemaining()
        state = .paused
        cancelTimer()
        // Une queue dure quatre secondes et ne connaît pas la pause : sans coupure
        // explicite, elle continuerait toute seule, séance arrêtée.
        interruptCues()
        audioCue.endDuckingAfter(0.3)
    }

    func resume() {
        guard state == .paused else { return }
        referenceDate = Date()
        state         = .running
        scheduleTimer()
    }

    func stop() {
        cancelTimer()
        state                = .idle
        currentStepIndex     = 0
        interruptCues()
        halfwayFired         = false
        beepCount            = 0
        referenceDate        = nil
        startedAt            = nil
        referenceRemaining   = TimeInterval(steps.first?.durationSeconds ?? 0)
        setTimeRemaining(referenceRemaining)
        audioCue.endDuckingAfter(0.3)
    }

    func skip() {
        guard state == .running || state == .paused else { return }
        let wasPaused = state == .paused
        advance()
        if wasPaused, state != .finished {
            state = .paused
            cancelTimer()
        }
    }

    func previous() {
        guard state == .running || state == .paused else { return }
        let wasPaused = state == .paused

        let elapsed = Double(steps[currentStepIndex].durationSeconds) - timeRemaining
        if elapsed < 3.0, currentStepIndex > 0 {
            currentStepIndex -= 1
        }
        interruptCues()
        resetSegmentCues()
        referenceRemaining   = TimeInterval(steps[currentStepIndex].durationSeconds)
        setTimeRemaining(referenceRemaining)
        referenceDate        = Date()
        cueSegmentStart()

        if wasPaused {
            state = .paused
            cancelTimer()
        }
    }

    // MARK: - Private

    private func tick() {
        guard state == .running, let ref = referenceDate else { return }
        stressMainThreadIfRequested()

        var elapsed = Date().timeIntervalSince(ref)
        var segmentChanged = false
        // Le bip de transition de la frontière franchie fait-il partie d'une queue déjà
        // lancée ? Si oui il est en train de sortir : le rejouer le doublerait.
        var transitionAlreadyPlaying = false

        // Fast-forward through any segments that fully elapsed (e.g. after app was backgrounded)
        while elapsed >= referenceRemaining {
            elapsed -= referenceRemaining
            // La queue contient déjà le bip de transition, qui est en train de sortir :
            // le rejouer le doublerait.
            transitionAlreadyPlaying = tailStarted
            let next = currentStepIndex + 1
            resetSegmentCues()
            if next < steps.count {
                currentStepIndex   = next
                referenceRemaining = TimeInterval(steps[next].durationSeconds)
                segmentChanged     = true
            } else {
                state         = .finished
                setTimeRemaining(0)
                referenceDate = nil
                cancelTimer()
                if !transitionAlreadyPlaying { cueFinished() }
                return
            }
        }

        setTimeRemaining(referenceRemaining - elapsed)

        if segmentChanged {
            referenceDate = Date() - elapsed
            if !transitionAlreadyPlaying { cueSegmentStart() }
        }

        cueHalfwayIfNeeded()
        startSegmentTailIfNeeded()
        pulseHapticOnCountdown()
    }

    private func setTimeRemaining(_ value: TimeInterval) {
        timeRemaining = value
        let shown = max(0, Int(ceil(value)))
        if shown != displayedSeconds { displayedSeconds = shown }
    }

    // MARK: - Cues

    /// Secondes restantes auxquelles jouer le signal de mi-parcours. `nil` hors phase
    /// d'effort, ou quand la moitié tomberait dans le décompte des 3 dernières secondes.
    ///
    /// L'invariant `half > 3` évite que le bip de mi-parcours et celui du décompte se
    /// chevauchent sur un segment très court. Les steppers de `WorkoutEditorView` (pas de
    /// 5 s, minimum 5 s) rendent le cas quasi inatteignable — le garde reste nécessaire si
    /// ces bornes changent un jour.
    private var halfwayRemaining: TimeInterval? {
        guard let step = currentStep, step.phase == .work else { return nil }
        let half = Double(step.durationSeconds) / 2
        return half > 3 ? half : nil
    }

    private func cueHalfwayIfNeeded() {
        guard !halfwayFired, let half = halfwayRemaining, timeRemaining <= half else { return }
        halfwayFired = true
        // Un retour d'arrière-plan peut nous déposer bien après la moitié — dans le
        // segment courant comme dans un suivant. On désarme alors sans jouer : un
        // repère de mi-parcours en retard est pire que pas de repère du tout.
        guard timeRemaining > half - 1 else { return }
        beepCount += 1
        audioCue.beginDucking()
        audioCue.play(.halfway)
        audioCue.endDuckingAfter(0.8)
    }

    /// Lance la queue du segment : le décompte 3-2-1 et le bip de transition, en un seul
    /// son de quatre secondes.
    ///
    /// C'est ici que le timing quitte le main thread. Le tick ne décide plus *quand* sonne
    /// chaque bip — il ne fait que lancer le buffer, et leur espacement est déjà gravé
    /// dedans. Sa seule responsabilité est le point d'entrée : s'il arrive en retard, on
    /// entre d'autant plus loin dans le buffer, ce qui replace les bips au bon endroit au
    /// lieu de décaler tout le rythme. La position `p` du buffer vaut toujours
    /// `timeRemaining == tailLead - p`.
    private func startSegmentTailIfNeeded() {
        #if DEBUG
        // Harnais de mesure uniquement, cf. `usesTickCountdown`.
        if Self.usesTickCountdown { return }
        #endif
        guard state == .running, !tailStarted,
              timeRemaining <= AudioCueManager.tailLead, timeRemaining > 0 else { return }
        tailStarted = true

        // Armé avant la lecture : sur `sessionQueue` la reconfiguration passe donc en
        // premier, et le silence de tête du buffer lui laisse le temps d'atterrir.
        audioCue.beginDucking()
        audioCue.play(tailCue, from: AudioCueManager.tailLead - timeRemaining)
        // Couvre tout ce qui reste du buffer, bip de transition compris.
        audioCue.endDuckingAfter(timeRemaining + 1.0)
    }

    /// La queue annonce la phase suivante : c'est elle qui choisit la variante.
    private var tailCue: AudioCueManager.Cue {
        switch nextStep?.phase {
        case .prepare:      .tailToPrepare
        case .work:         .tailToWork
        case .rest, .reset: .tailToRest
        case nil:           .tailToFinish
        }
    }

    /// Le retour haptique suit le décompte, mais reste piloté par le tick : une vibration
    /// décalée de quelques dizaines de ms ne se remarque pas. C'est bien le son, et lui
    /// seul, qu'il fallait affranchir du main thread.
    private func pulseHapticOnCountdown() {
        // `displayedSeconds` est ce que le chrono affiche, mis à jour juste avant dans le
        // même tick : le retour haptique suit donc exactement ce que l'utilisateur voit,
        // et l'arrondi n'est défini qu'à un seul endroit.
        let secondsLeft = displayedSeconds
        guard secondsLeft <= 3, secondsLeft > 0, secondsLeft != lastBeepSecond else { return }
        lastBeepSecond = secondsLeft
        beepCount += 1
        #if DEBUG
        if Self.usesTickCountdown {
            audioCue.beginDucking()
            audioCue.play(.countdown)
            audioCue.endDuckingAfter(1.5)
        }
        #endif
    }

    /// Remet à zéro les drapeaux de cue d'un segment, **sans** toucher aux cues déjà
    /// joués : sur une frontière de segment normale, le bip de transition est justement
    /// en train de sortir et le couper le tronquerait.
    private func resetSegmentCues() {
        tailStarted    = false
        halfwayFired   = false
        lastBeepSecond = -1
    }

    /// Coupe le son en cours, queue comprise. Pour les ruptures du déroulé —
    /// pause, stop, skip, previous — où un cue en vol n'a plus lieu d'être.
    private func interruptCues() {
        audioCue.stopAll()
        resetSegmentCues()
    }

    /// Une interruption système ou un changement de route a coupé la queue en cours : on
    /// redevient « non lancé » et le prochain tick la relance, en entrant dans le buffer à
    /// la position qui correspond au temps restant. `halfwayFired` et `lastBeepSecond`
    /// restent attachés au segment courant et ne sont surtout pas réarmés.
    private func markTailInterrupted() {
        tailStarted = false
    }

    /// Bip long de transition, joué immédiatement. N'est utilisé que quand la frontière
    /// n'est pas couverte par une queue : démarrage, skip, previous.
    private func cueSegmentStart() {
        guard let phase = currentStep?.phase else { return }
        audioCue.beginDucking()
        audioCue.play(phase.startCue)
        audioCue.endDuckingAfter(1.0)
    }

    private func cueFinished() {
        audioCue.beginDucking()
        audioCue.play(.finished)
        audioCue.endDuckingAfter(1.5)
    }

    private func advance() {
        let next = currentStepIndex + 1
        interruptCues()
        if next < steps.count {
            currentStepIndex   = next
            referenceRemaining = TimeInterval(steps[next].durationSeconds)
            setTimeRemaining(referenceRemaining)
            referenceDate      = Date()
            cueSegmentStart()
        } else {
            state         = .finished
            setTimeRemaining(0)
            cancelTimer()
            cueFinished()
        }
    }

    private func snapshotTimeRemaining() {
        guard let ref = referenceDate else { return }
        referenceRemaining = max(0, referenceRemaining - Date().timeIntervalSince(ref))
        setTimeRemaining(referenceRemaining)
        referenceDate      = nil
    }

    private func scheduleTimer() {
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func cancelTimer() { timer?.invalidate(); timer = nil }

    // MARK: - Reproduction du bug

    #if DEBUG
    /// Bloque volontairement le main thread, sur l'argument de lancement `-audioStress`.
    ///
    /// Le bug des « secondes collées » ne se reproduit que sur un device lent avec une app
    /// audio tierce active — impossible à tenir sous la main. Ceci le rend déterministe
    /// n'importe où : avec le décompte piloté par le tick (`-audioTickCountdown`), les bips
    /// se collent ; avec la queue pré-rendue, ils restent à une seconde
    /// d'écart.
    ///
    /// La période est volontairement **désaccordée** de la seconde du décompte : à 1,0 s
    /// pile le blocage se cale sur les bips et les décale tous pareil, ce qui ne montre
    /// rien. À 1,3 s il précesse et finit par tomber dans toutes les phases possibles.
    private static let stressesMainThread = ProcessInfo.processInfo.arguments.contains("-audioStress")

    /// `-audioTickCountdown` rejoue l'ancien comportement : un bip par tick qui franchit
    /// la seconde, au lieu de la queue pré-rendue. C'est **uniquement un harnais de
    /// mesure** — aucune condition de production ne mène là, contrairement à la v1.5
    /// intermédiaire qui en faisait un repli. Il sert à rejouer le bug et le fix dans le
    /// même build, avec la même sonde.
    private static let usesTickCountdown = ProcessInfo.processInfo.arguments.contains("-audioTickCountdown")
    private static let stressPeriod: TimeInterval = 1.3
    private static let stressDuration: TimeInterval = 0.6
    private var lastStressAt: Date?

    private func stressMainThreadIfRequested() {
        guard Self.stressesMainThread else { return }
        let now = Date()
        if let last = lastStressAt, now.timeIntervalSince(last) < Self.stressPeriod { return }
        lastStressAt = now
        Thread.sleep(forTimeInterval: Self.stressDuration)
    }
    #else
    private func stressMainThreadIfRequested() {}
    #endif
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
