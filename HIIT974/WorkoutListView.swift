import SwiftUI
import SwiftData

struct WorkoutListView: View {
    @Query(sort: \Workout.createdAt, order: .forward) private var workouts: [Workout]
    @Environment(\.modelContext) private var context
    @State private var activeSheet: SheetMode?
    #if DEBUG
    @State private var screenshotRunWorkout: Workout?
    #endif

    var body: some View {
        NavigationStack {
            Group {
                if workouts.isEmpty {
                    ContentUnavailableView(
                        "Aucune séance",
                        systemImage: "figure.run",
                        description: Text("Crée ta première séance avec le bouton +")
                    )
                } else {
                    List {
                        ForEach(workouts) { workout in
                            NavigationLink {
                                RunView(workout: workout)
                            } label: {
                                WorkoutRowView(workout: workout)
                            }
                            // Trois affordances pour l'édition : le swipe depuis le bord
                            // gauche seul était introuvable.
                            .swipeActions(edge: .trailing) {
                                deleteButton(for: workout)   // en 1er : conserve le full-swipe
                                editButton(for: workout).tint(.orange)
                            }
                            .swipeActions(edge: .leading) {
                                editButton(for: workout).tint(.orange)
                            }
                            .contextMenu {
                                editButton(for: workout)
                                deleteButton(for: workout)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Séances")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("", systemImage: "plus") { activeSheet = .create }
                }
            }
            .sheet(item: $activeSheet) { mode in
                switch mode {
                case .create:
                    WorkoutEditorView { newWorkout in context.insert(newWorkout) }
                case .edit(let workout):
                    WorkoutEditorView(existingWorkout: workout) { _ in }
                }
            }
            .onAppear {
                if workouts.isEmpty {
                    Workout.samples.forEach { context.insert($0) }
                }
                #if DEBUG
                // Deep-links capture d'écran.
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-screenshotRun") {
                    screenshotRunWorkout = workouts.first
                }
                if args.contains("-screenshotEditor") {
                    // Une séance existante plutôt qu'un formulaire vide : c'est le seul
                    // moyen de montrer la section des noms d'exercices renseignée.
                    activeSheet = workouts.first.map { .edit($0) } ?? .create
                }
                #endif
            }
            #if DEBUG
            .navigationDestination(item: $screenshotRunWorkout) { workout in
                RunView(workout: workout)
            }
            #endif
        }
    }

    // MARK: - Actions de ligne

    private func editButton(for workout: Workout) -> some View {
        Button { activeSheet = .edit(workout) } label: {
            Label("Modifier", systemImage: "pencil")
        }
    }

    private func deleteButton(for workout: Workout) -> some View {
        Button(role: .destructive) { context.delete(workout) } label: {
            Label("Supprimer", systemImage: "trash")
        }
    }
}

// MARK: - Sheet state

private enum SheetMode: Identifiable {
    case create
    case edit(Workout)

    var id: Int {
        switch self {
        case .create:       return 0
        case .edit(let w):  return w.persistentModelID.hashValue
        }
    }
}

// MARK: - Row

private struct WorkoutRowView: View {
    let workout: Workout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(workout.name).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            WorkoutMiniBar(workout: workout)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        let ex = "\(workout.sets) ex."
        let r  = "\(workout.rounds) round\(workout.rounds > 1 ? "s" : "")"
        let m  = workout.totalSeconds / 60
        let dur = m > 0 ? " · ~\(m) min" : ""
        return "\(ex) · \(r)\(dur)"
    }
}

private struct WorkoutMiniBar: View {
    let workout: Workout

    var body: some View {
        ProportionBar(
            prepareSeconds: 0,   // la mini-barre illustre le rythme d'un round
            workSeconds: workout.workSeconds,
            restSeconds: workout.restSeconds,
            sets: workout.sets,
            rounds: 1,
            resetSeconds: 0
        )
        .frame(height: 4)
    }
}

#Preview {
    WorkoutListView()
        .modelContainer(for: Workout.self, inMemory: true)
}
