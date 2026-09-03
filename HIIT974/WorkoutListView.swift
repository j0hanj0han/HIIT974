import SwiftUI
import SwiftData

struct WorkoutListView: View {
    @Query(sort: \Workout.createdAt, order: .forward) private var workouts: [Workout]
    @Environment(\.modelContext) private var context
    @State private var activeSheet: SheetMode?
    /// Nettoyage des deux séances par défaut auto-insérées par les versions précédentes :
    /// ne doit se déclencher qu'une fois, pour ne jamais menacer une séance que
    /// l'utilisateur recréerait plus tard à l'identique d'une ancienne valeur par défaut.
    @AppStorage("legacySeedCleanupDone") private var legacySeedCleanupDone = false
    #if DEBUG
    @State private var screenshotRunWorkout: Workout?
    #endif

    /// Suggestions du catalogue pas encore reprises par l'utilisateur (comparaison du nom
    /// insensible à la casse et aux accents, même principe qu'`ExerciseCatalog`).
    private var visibleSuggestions: [WorkoutSuggestions.Suggestion] {
        let existing = Set(workouts.map { normalizedName($0.name) })
        return WorkoutSuggestions.catalog.filter { !existing.contains(normalizedName($0.name)) }
    }

    private func normalizedName(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    var body: some View {
        NavigationStack {
            Group {
                if workouts.isEmpty && visibleSuggestions.isEmpty {
                    ContentUnavailableView(
                        "Aucune séance",
                        systemImage: "figure.run",
                        description: Text("Crée ta première séance avec le bouton +")
                    )
                } else {
                    List {
                        if !visibleSuggestions.isEmpty {
                            NavigationLink {
                                WorkoutSuggestionsView(suggestions: visibleSuggestions) { suggestion in
                                    context.insert(suggestion.makeWorkout())
                                }
                            } label: {
                                Label("Suggestions du chef", systemImage: "fork.knife")
                                    .badge(visibleSuggestions.count)
                            }
                        }
                        if !workouts.isEmpty {
                            Section("Mes séances") {
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
                if !legacySeedCleanupDone {
                    for workout in workouts where WorkoutSuggestions.isLegacySeed(workout) {
                        context.delete(workout)
                    }
                    legacySeedCleanupDone = true
                }
                #if DEBUG
                // Deep-links capture d'écran.
                let args = ProcessInfo.processInfo.arguments
                let needsScreenshotData = args.contains("-screenshotRun")
                    || args.contains("-screenshotEditor")
                    || args.contains("-screenshotEditorNames")
                // Sans séance seedée par défaut, la liste peut être vide sur un simulateur
                // fraîchement installé : ces captures ont besoin d'une séance concrète.
                // On garde une référence directe à l'objet inséré plutôt que de relire
                // `workouts` (le @Query) juste après : son rafraîchissement n'est pas
                // garanti synchrone dans le même passage d'onAppear.
                var screenshotWorkout = workouts.first
                if needsScreenshotData && screenshotWorkout == nil {
                    let seeded = WorkoutSuggestions.catalog[0].makeWorkout()
                    context.insert(seeded)
                    screenshotWorkout = seeded
                }
                if args.contains("-screenshotRun") {
                    screenshotRunWorkout = screenshotWorkout
                }
                // Deux captures d'éditeur : la structure de la séance, puis la liste
                // des noms. Une séance existante plutôt qu'un formulaire vide, sinon les
                // paramètres et les noms seraient vides.
                if args.contains("-screenshotEditor") || args.contains("-screenshotEditorNames") {
                    activeSheet = screenshotWorkout.map { .edit($0) } ?? .create
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

    var id: String {
        switch self {
        case .create:       return "create"
        case .edit(let w):  return "edit-\(w.persistentModelID.hashValue)"
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
