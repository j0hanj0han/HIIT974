import Foundation
import SwiftUI
import Observation

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
    private(set) var startedAt: Date?
    private(set) var beepCount: Int = 0

    let steps: [Step]
    let totalRounds: Int
    let totalSets: Int
    let audioCue = AudioCueManager()

    private var referenceDate: Date?
    private var referenceRemaining: TimeInterval
    nonisolated(unsafe) private var timer: Timer?
    private var lastBeepSecond = -1
    private var halfwayFired = false

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
    }

    deinit { timer?.invalidate() }

    // MARK: - Computed

    var currentStep: Step? { steps[safe: currentStepIndex] }
    var nextStep: Step?    { steps[safe: currentStepIndex + 1] }
    var currentRound: Int  { currentStep?.round ?? 1 }
    var currentSetIndex: Int { currentStep?.setIndex ?? 1 }

    // MARK: - Controls

    func start() {
        guard state == .idle, !steps.isEmpty else { return }
        currentStepIndex     = 0
        resetSegmentCues()
        referenceRemaining   = TimeInterval(steps[0].durationSeconds)
        timeRemaining        = referenceRemaining
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
        resetSegmentCues()
        beepCount            = 0
        referenceDate        = nil
        startedAt            = nil
        referenceRemaining   = TimeInterval(steps.first?.durationSeconds ?? 0)
        timeRemaining        = referenceRemaining
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
        resetSegmentCues()
        referenceRemaining   = TimeInterval(steps[currentStepIndex].durationSeconds)
        timeRemaining        = referenceRemaining
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
        var elapsed = Date().timeIntervalSince(ref)
        var segmentChanged = false

        // Fast-forward through any segments that fully elapsed (e.g. after app was backgrounded)
        while elapsed >= referenceRemaining {
            elapsed -= referenceRemaining
            let next = currentStepIndex + 1
            resetSegmentCues()
            if next < steps.count {
                currentStepIndex   = next
                referenceRemaining = TimeInterval(steps[next].durationSeconds)
                segmentChanged     = true
            } else {
                state         = .finished
                timeRemaining = 0
                referenceDate = nil
                cancelTimer()
                cueFinished()
                return
            }
        }

        timeRemaining = referenceRemaining - elapsed

        if segmentChanged {
            referenceDate = Date() - elapsed
            cueSegmentStart()
        }

        if !halfwayFired, let half = halfwayRemaining, timeRemaining <= half {
            halfwayFired = true
            // Un retour d'arrière-plan peut nous déposer bien après la moitié — dans le
            // segment courant comme dans un suivant. On désarme alors sans jouer : un
            // repère de mi-parcours en retard est pire que pas de repère du tout.
            if timeRemaining > half - 1 {
                beepCount += 1
                audioCue.beginDucking()
                audioCue.play(.halfway)
                audioCue.endDuckingAfter(0.8)
            }
        }

        let secondsLeft = Int(ceil(timeRemaining))
        if secondsLeft <= 3 && secondsLeft > 0 && secondsLeft != lastBeepSecond {
            lastBeepSecond = secondsLeft
            beepCount += 1
            audioCue.beginDucking()
            audioCue.play(.countdown)
            audioCue.endDuckingAfter(Self.countdownDuckRelease)
        }
    }

    // MARK: - Cues

    /// Délai de relâche du ducking après un bip du décompte.
    ///
    /// **Doit rester strictement supérieur à la seconde qui sépare deux bips.** À 1,0 s
    /// pile, le relâchement du bip N tombait exactement sur le bip N+1 (et 1 s vaut 20
    /// ticks ronds) : `releaseDucking()` reconfigurait la session juste avant que
    /// `beginDucking()` la reconfigure en sens inverse. Deux IPC vers `mediaserverd` dos à
    /// dos, à chaque seconde du décompte — pompage audible sur la musique, et bip joué
    /// avant que l'atténuation ne soit en place.
    ///
    /// Avec cette marge, le `beginDucking()` du bip suivant annule le relâchement en
    /// attente : l'atténuation tient d'une traite de T-3 jusqu'au bip de transition. Le
    /// relâchement ne s'exécute que si la chaîne s'interrompt — une pause en plein
    /// décompte, typiquement, où rendre la musique est le bon comportement.
    private static let countdownDuckRelease: TimeInterval = 1.5

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

    private func resetSegmentCues() {
        lastBeepSecond = -1
        halfwayFired   = false
    }

    /// Bip long de transition. Le ducking est relâché après la fin du bip (600 ms).
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
        resetSegmentCues()
        if next < steps.count {
            currentStepIndex   = next
            referenceRemaining = TimeInterval(steps[next].durationSeconds)
            timeRemaining      = referenceRemaining
            referenceDate      = Date()
            cueSegmentStart()
        } else {
            state         = .finished
            timeRemaining = 0
            cancelTimer()
            cueFinished()
        }
    }

    private func snapshotTimeRemaining() {
        guard let ref = referenceDate else { return }
        referenceRemaining = max(0, referenceRemaining - Date().timeIntervalSince(ref))
        timeRemaining      = referenceRemaining
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
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
