import SwiftUI
import SwiftData

struct RunView: View {
    let workout: Workout
    @State private var engine: TimerEngine
    @State private var runSaved = false
    @State private var transitionEdge: Edge = .trailing
    @Environment(\.modelContext) private var context

    @MainActor
    init(workout: Workout) {
        self.workout = workout
        _engine = State(initialValue: TimerEngine(workout: workout))
    }

    private var bgColor: Color {
        engine.state == .finished ? .green : (engine.currentStep?.phase.color ?? .blue)
    }

    var body: some View {
        ZStack {
            bgColor
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.45), value: engine.currentStepIndex)
                .animation(.easeInOut(duration: 0.45), value: engine.state == .finished)

            Group {
                if engine.state == .finished {
                    finishedView
                        .transition(.opacity.combined(with: .scale(scale: 0.93)))
                } else {
                    timerView
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: engine.state == .finished)
        }
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationBarBackButtonHidden(engine.state == .running || engine.state == .paused)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if engine.state == .running || engine.state == .paused {
                    Button { engine.stop() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: engine.currentStepIndex)
        .sensoryFeedback(.success, trigger: engine.state) { _, newState in newState == .finished }
        .sensoryFeedback(.impact(flexibility: .rigid), trigger: engine.beepCount)
        .onAppear {
            let e = engine
            e.audioCue.onPlayPause = { [weak e] in
                switch e?.state {
                case .idle:    e?.start()
                case .running: e?.pause()
                case .paused:  e?.resume()
                default: break
                }
            }
            e.audioCue.onStop = { [weak e] in e?.stop() }
            e.audioCue.onSkip = { [weak e] in e?.skip() }
            e.audioCue.onPrevious = { [weak e] in e?.previous() }
            e.audioCue.configure()
        }
        .onDisappear {
            if !runSaved, engine.state == .finished, let startedAt = engine.startedAt {
                runSaved = true
                context.insert(WorkoutRun(workoutName: workout.name, startedAt: startedAt, completedAt: Date()))
            }
            engine.stop()
            engine.audioCue.deactivate()
        }
        .onChange(of: engine.state) { _, newState in
            guard newState == .finished, !runSaved, let startedAt = engine.startedAt else { return }
            runSaved = true
            context.insert(WorkoutRun(workoutName: workout.name, startedAt: startedAt, completedAt: Date()))
        }
    }

    // MARK: - Timer view

    private var timerView: some View {
        VStack(spacing: 0) {
            Spacer()

            if let step = engine.currentStep {
                VStack(spacing: 28) {
                    Label(step.phase.label, systemImage: step.phase.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(bgColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.white, in: Capsule())

                    ringTimer

                    countersRow
                }
                .id(engine.currentStepIndex)
                .transition(.push(from: transitionEdge))
                .animation(.easeInOut(duration: 0.25), value: engine.currentStepIndex)
            }

            Spacer()

            nextStepRow.padding(.horizontal, 24)

            Spacer()

            controlsRow.padding(.bottom, 44)
        }
    }

    // MARK: - Ring

    private var ringTimer: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.22), lineWidth: 18)
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.08), value: ringProgress)

            VStack(spacing: 4) {
                Text(timeString(engine.timeRemaining))
                    .font(.system(size: 76, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.default, value: Int(engine.timeRemaining))

                if let step = engine.currentStep {
                    Text(step.phase.label)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: 270, height: 270)
    }

    private var ringProgress: Double {
        guard let step = engine.currentStep, step.durationSeconds > 0 else { return 0 }
        return max(0, min(1, engine.timeRemaining / Double(step.durationSeconds)))
    }

    // MARK: - Counters (round + set)

    private var countersRow: some View {
        HStack(spacing: 16) {
            if engine.totalRounds > 1 {
                Text("Round \(engine.currentRound) / \(engine.totalRounds)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
            if engine.currentStep?.phase != .reset {
                Text("Ex. \(engine.currentSetIndex) / \(engine.totalSets)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }

    // MARK: - Next step

    private var nextStepRow: some View {
        HStack(spacing: 6) {
            Text("Ensuite :")
                .foregroundStyle(.white.opacity(0.65))
            if let next = engine.nextStep {
                Image(systemName: next.phase.systemImage)
                    .foregroundStyle(.white.opacity(0.9))
                Text(next.phase.label)
                    .foregroundStyle(.white)
                Text("·").foregroundStyle(.white.opacity(0.65))
                Text(segDurationLabel(next.durationSeconds))
                    .foregroundStyle(.white)
            } else {
                Text("Fin de séance").foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
        }
        .font(.subheadline)
    }

    // MARK: - Controls

    private var controlsRow: some View {
        HStack(spacing: 40) {
            Button { transitionEdge = .leading; engine.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.title2).foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .disabled(engine.state == .idle)

            Button { primaryAction() } label: {
                Image(systemName: primaryIcon)
                    .font(.title).foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .glassEffect(.regular.interactive(), in: Circle())
            }

            Button { transitionEdge = .trailing; engine.skip() } label: {
                Image(systemName: "forward.fill")
                    .font(.title2).foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .disabled(engine.state == .idle)
        }
    }

    // MARK: - Finished

    private var finishedView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 90)).foregroundStyle(.white)
                .symbolEffect(.bounce, value: engine.state == .finished)
            Text("Séance terminée !")
                .font(.title).fontWeight(.bold).foregroundStyle(.white)
            Text(workout.name)
                .font(.title3).foregroundStyle(.white.opacity(0.8))
            Spacer()
        }
    }

    // MARK: - Helpers

    private var primaryIcon: String { engine.state == .running ? "pause.fill" : "play.fill" }

    private func primaryAction() {
        switch engine.state {
        case .idle:     engine.start()
        case .running:  engine.pause()
        case .paused:   engine.resume()
        case .finished: break
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = max(0, Int(ceil(t)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func segDurationLabel(_ s: Int) -> String {
        s < 60 ? "\(s) s" : (s % 60 == 0 ? "\(s / 60) min" : "\(s / 60)'\(s % 60)\"")
    }
}

#Preview {
    NavigationStack {
        RunView(workout: Workout.samples[0])
    }
}
