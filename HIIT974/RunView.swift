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
        .toolbar(.hidden, for: .tabBar)
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
            // Sans background audio, un écran qui s'éteint coupe tous les cues :
            // on maintient l'app éveillée le temps de la séance.
            UIApplication.shared.isIdleTimerDisabled = true
            let e = engine
            e.audioCue.configure()
            #if DEBUG
            // Démarre automatiquement pour la capture d'écran de la séance en cours,
            // en sautant la préparation : c'est une phase d'effort qu'on veut montrer.
            if ProcessInfo.processInfo.arguments.contains("-screenshotRun") {
                e.start()
                if e.currentStep?.phase == .prepare { e.skip() }
            }
            #endif
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
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
        // Tout l'écran est dimensionné pour être lu à distance : c'est le diamètre de
        // l'anneau qui fixe la taille du chrono, donc la distance de lecture. On prend
        // toute la largeur disponible, en se laissant plafonner par la hauteur sur les
        // petits écrans pour que les contrôles restent à l'image.
        GeometryReader { geo in
            // Le tracé de l'anneau déborde du frame de la moitié de son épaisseur : sans
            // l'inclure ici, le cercle vient mordre les bords de l'écran.
            let ringDiameter = min((geo.size.width - 28) / (1 + ringStrokeRatio),
                                   geo.size.height * 0.50)

            VStack(spacing: 0) {
                Spacer(minLength: 8)

                if let step = engine.currentStep {
                    VStack(spacing: 24) {
                        exerciseBadge(step)

                        ringTimer(diameter: ringDiameter)

                        countersRow
                    }
                    .id(engine.currentStepIndex)
                    .transition(.push(from: transitionEdge))
                    .animation(.easeInOut(duration: 0.25), value: engine.currentStepIndex)
                }

                Spacer(minLength: 8)

                nextStepRow.padding(.horizontal, 24)

                Spacer(minLength: 8)

                controlsRow.padding(.bottom, 44)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Exercise badge

    private func exerciseBadge(_ step: TimerEngine.Step) -> some View {
        Label(step.displayLabel, systemImage: step.phase.systemImage)
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .foregroundStyle(bgColor)
            // Un nom d'exercice peut être bien plus long qu'un libellé de
            // phase : on rétrécit plutôt que de tronquer.
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(.white, in: Capsule())
            .padding(.horizontal, 16)
    }

    // MARK: - Ring

    /// Épaisseur du tracé de l'anneau, en fraction de son diamètre.
    private let ringStrokeRatio: CGFloat = 0.06

    private func ringTimer(diameter: CGFloat) -> some View {
        let stroke = diameter * ringStrokeRatio
        // Le chrono est inscrit dans le cercle : il tient dans une corde, pas dans le
        // diamètre. 0,74 laisse le texte respirer sans mordre sur le tracé.
        let textWidth = diameter * 0.74

        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.22), lineWidth: stroke)
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.08), value: ringProgress)

            VStack(spacing: 2) {
                Text(timeString(engine.timeRemaining))
                    .font(.system(size: diameter * 0.32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    // Un segment de 10 min affiche cinq caractères au lieu de quatre :
                    // on rétrécit ce cas-là plutôt que de rapetisser tout le reste.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: textWidth)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.default, value: Int(engine.timeRemaining))

                if let step = engine.currentStep {
                    Text(step.phase.label)
                        .font(.system(size: diameter * 0.076, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: textWidth)
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private var ringProgress: Double {
        guard let step = engine.currentStep, step.durationSeconds > 0 else { return 0 }
        return max(0, min(1, engine.timeRemaining / Double(step.durationSeconds)))
    }

    // MARK: - Counters (round + set)

    private var countersRow: some View {
        HStack(spacing: 20) {
            if engine.totalRounds > 1 {
                Text("Round \(engine.currentRound) / \(engine.totalRounds)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
            }
            if let phase = engine.currentStep?.phase, phase != .reset, phase != .prepare {
                Text("Ex. \(engine.currentSetIndex) / \(engine.totalSets)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
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
                Text(next.displayLabel)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("·").foregroundStyle(.white.opacity(0.65))
                Text(segDurationLabel(next.durationSeconds))
                    .foregroundStyle(.white)
            } else {
                Text("Fin de séance").foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
        }
        .font(.system(size: 20, weight: .medium, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
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
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 120)).foregroundStyle(.white)
                .symbolEffect(.bounce, value: engine.state == .finished)
            Text("Séance terminée !")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(workout.name)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 24)
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
