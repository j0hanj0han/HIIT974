import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class TimerEngine {

    // MARK: - Step (modèle interne léger, pas SwiftData)

    struct Step {
        enum Phase {
            case work, rest, reset

            var color: Color {
                switch self { case .work: .red; case .rest: .blue; case .reset: .teal }
            }
            var systemImage: String {
                switch self { case .work: "bolt.fill"; case .rest: "pause.circle"; case .reset: "arrow.clockwise" }
            }
            var label: String {
                switch self { case .work: "Effort"; case .rest: "Repos"; case .reset: "Récupération" }
            }
        }

        let phase: Phase
        let durationSeconds: Int
        let round: Int      // 1-based
        let setIndex: Int   // 1-based ; 0 pour les steps reset
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

    private let workoutName: String
    private var referenceDate: Date?
    private var referenceRemaining: TimeInterval
    nonisolated(unsafe) private var timer: Timer?
    private var lastBeepSecond = -1
    private var lastNowPlayingSecond = -1

    init(workout: Workout) {
        var built: [Step] = []
        for r in 0..<max(workout.rounds, 1) {
            for s in 0..<max(workout.sets, 1) {
                built.append(Step(phase: .work,  durationSeconds: workout.workSeconds, round: r + 1, setIndex: s + 1))
                built.append(Step(phase: .rest,  durationSeconds: workout.restSeconds, round: r + 1, setIndex: s + 1))
            }
            if r < workout.rounds - 1 && workout.resetSeconds > 0 {
                built.append(Step(phase: .reset, durationSeconds: workout.resetSeconds, round: r + 1, setIndex: 0))
            }
        }
        steps        = built
        workoutName  = workout.name
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
        lastBeepSecond       = -1
        lastNowPlayingSecond = -1
        referenceRemaining   = TimeInterval(steps[0].durationSeconds)
        timeRemaining        = referenceRemaining
        referenceDate        = Date()
        startedAt            = Date()
        state                = .running
        scheduleTimer()
        audioCue.announceSegmentStart(steps[0].phase.label)
        refreshNowPlaying(isPlaying: true)
    }

    func pause() {
        guard state == .running else { return }
        snapshotTimeRemaining()
        state = .paused
        cancelTimer()
        refreshNowPlaying(isPlaying: false)
    }

    func resume() {
        guard state == .paused else { return }
        referenceDate = Date()
        state         = .running
        scheduleTimer()
        refreshNowPlaying(isPlaying: true)
    }

    func stop() {
        cancelTimer()
        audioCue.clearNowPlayingInfo()
        state                = .idle
        currentStepIndex     = 0
        lastBeepSecond       = -1
        lastNowPlayingSecond = -1
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
        lastBeepSecond       = -1
        lastNowPlayingSecond = -1
        referenceRemaining   = TimeInterval(steps[currentStepIndex].durationSeconds)
        timeRemaining        = referenceRemaining
        referenceDate        = Date()
        audioCue.announceSegmentStart(steps[currentStepIndex].phase.label)
        refreshNowPlaying(isPlaying: true)

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
            lastBeepSecond       = -1
            lastNowPlayingSecond = -1
            if next < steps.count {
                currentStepIndex   = next
                referenceRemaining = TimeInterval(steps[next].durationSeconds)
                segmentChanged     = true
            } else {
                state         = .finished
                timeRemaining = 0
                referenceDate = nil
                cancelTimer()
                audioCue.announceFinished()
                return
            }
        }

        if segmentChanged {
            referenceDate = Date() - elapsed
            audioCue.announceSegmentStart(steps[currentStepIndex].phase.label)
            refreshNowPlaying(isPlaying: true)
        }

        timeRemaining = referenceRemaining - elapsed

        let secondsLeft = Int(ceil(timeRemaining))
        if secondsLeft <= 3 && secondsLeft > 0 && secondsLeft != lastBeepSecond {
            lastBeepSecond = secondsLeft
            beepCount += 1
            audioCue.playBeep()
        }

        let secondsElapsed = Int(elapsed)
        if secondsElapsed != lastNowPlayingSecond {
            lastNowPlayingSecond = secondsElapsed
            refreshNowPlaying(isPlaying: true)
        }
    }

    private func advance() {
        let next = currentStepIndex + 1
        lastBeepSecond       = -1
        lastNowPlayingSecond = -1
        if next < steps.count {
            currentStepIndex   = next
            referenceRemaining = TimeInterval(steps[next].durationSeconds)
            timeRemaining      = referenceRemaining
            referenceDate      = Date()
            audioCue.announceSegmentStart(steps[next].phase.label)
            refreshNowPlaying(isPlaying: true)
        } else {
            state         = .finished
            timeRemaining = 0
            cancelTimer()
            audioCue.announceFinished()
        }
    }

    private func snapshotTimeRemaining() {
        guard let ref = referenceDate else { return }
        referenceRemaining = max(0, referenceRemaining - Date().timeIntervalSince(ref))
        timeRemaining      = referenceRemaining
        referenceDate      = nil
    }

    private func refreshNowPlaying(isPlaying: Bool) {
        guard let step = currentStep else { return }
        let dur     = Double(step.durationSeconds)
        let elapsed = max(0, dur - timeRemaining)
        audioCue.updateNowPlaying(
            workoutName: workoutName,
            segmentLabel: step.phase.label,
            segmentElapsed: elapsed,
            segmentDuration: dur,
            isPlaying: isPlaying
        )
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
