import Foundation

/// Séances suggérées, proposées (jamais imposées) dans `WorkoutListView`.
///
/// Même esprit qu'`ExerciseCatalog` : volontairement sans SwiftData, une constante — aucune
/// entité à migrer, aucun écran de gestion. L'utilisateur choisit d'ajouter une suggestion,
/// qui devient alors une séance normale (persistée) comme n'importe quelle autre.
enum WorkoutSuggestions {

    struct Suggestion: Identifiable {
        let id: String
        let name: String
        let systemImage: String
        let subtitle: String
        let prepareSeconds: Int
        let workSeconds: Int
        let restSeconds: Int
        let sets: Int
        let rounds: Int
        let resetSeconds: Int
        let exerciseNames: [String]
    }

    static let catalog: [Suggestion] = [
        Suggestion(id: "tabata", name: "Tabata", systemImage: "bolt.fill",
                   subtitle: "8 exercices · 20 s effort / 10 s repos",
                   prepareSeconds: 10, workSeconds: 20, restSeconds: 10,
                   sets: 8, rounds: 1, resetSeconds: 0,
                   exerciseNames: ["Burpees", "Mountain climbers", "Squat jump", "Pompes",
                                   "Jumping jacks", "Planche", "Fentes sautées", "Crunchs"]),
        Suggestion(id: "hiit-full-body", name: "HIIT Full Body", systemImage: "figure.mixed.cardio",
                   subtitle: "5 exercices · 3 rounds · 40 s effort / 20 s repos",
                   prepareSeconds: 10, workSeconds: 40, restSeconds: 20,
                   sets: 5, rounds: 3, resetSeconds: 30,
                   exerciseNames: ["Squats", "Pompes", "Fentes alternées", "Gainage", "Mountain climbers"]),
        Suggestion(id: "cardio-debutant", name: "Cardio Débutant", systemImage: "figure.walk",
                   subtitle: "6 exercices · 2 rounds · efforts courts, repos généreux",
                   prepareSeconds: 15, workSeconds: 20, restSeconds: 20,
                   sets: 6, rounds: 2, resetSeconds: 30,
                   exerciseNames: ["Marche sur place", "Talons-fesses", "Genoux montants",
                                   "Pas chassés", "Squats", "Jumping jacks doux"]),
        Suggestion(id: "emom-express", name: "EMOM Express", systemImage: "timer",
                   subtitle: "6 exercices · 4 rounds · rythme soutenu, sans repos entre efforts",
                   prepareSeconds: 10, workSeconds: 30, restSeconds: 0,
                   sets: 6, rounds: 4, resetSeconds: 20,
                   exerciseNames: ["Burpees", "Squat jump", "Fentes sautées", "Pompes surélevées",
                                   "Mountain climbers", "Jumping jacks"]),
        Suggestion(id: "gainage-intense", name: "Gainage Intense", systemImage: "figure.core.training",
                   subtitle: "5 exercices · 2 rounds · isométrie longue, peu de rounds",
                   prepareSeconds: 10, workSeconds: 45, restSeconds: 15,
                   sets: 5, rounds: 2, resetSeconds: 20,
                   exerciseNames: ["Planche", "Planche latérale", "Hollow hold", "Superman", "Crunchs"]),
    ]

    // MARK: - Nettoyage ponctuel des anciennes séances par défaut

    /// Signature exacte des deux séances auto-insérées par les versions précédentes
    /// (avant le remplacement du seed forcé par ce catalogue de suggestions).
    ///
    /// Délibérément séparée de `catalog` ci-dessus, avec ses propres valeurs dupliquées
    /// plutôt que dérivées de `catalog[0]`/`catalog[1]` : si le catalogue affiché évolue un
    /// jour (ex. quelqu'un ajuste les paramètres de « Tabata »), cette signature ne doit
    /// jamais bouger avec lui — sans quoi le nettoyage ponctuel se remettrait à supprimer
    /// des séances que des utilisateurs auraient légitimement recréées à l'identique de
    /// l'ancien défaut.
    private struct LegacySignature {
        let name: String
        let prepareSeconds: Int
        let workSeconds: Int
        let restSeconds: Int
        let sets: Int
        let rounds: Int
        let resetSeconds: Int
        let exerciseNames: [String]

        func matches(_ workout: Workout) -> Bool {
            workout.name == name
                && workout.prepareSeconds == prepareSeconds
                && workout.workSeconds == workSeconds
                && workout.restSeconds == restSeconds
                && workout.sets == sets
                && workout.rounds == rounds
                && workout.resetSeconds == resetSeconds
                && workout.exerciseNames == exerciseNames
        }
    }

    private static let legacySeeds: [LegacySignature] = [
        LegacySignature(name: "Tabata", prepareSeconds: 10, workSeconds: 20, restSeconds: 10,
                         sets: 8, rounds: 1, resetSeconds: 0,
                         exerciseNames: ["Burpees", "Mountain climbers", "Squat jump", "Pompes",
                                         "Jumping jacks", "Planche", "Fentes sautées", "Crunchs"]),
        LegacySignature(name: "HIIT Full Body", prepareSeconds: 10, workSeconds: 40, restSeconds: 20,
                         sets: 5, rounds: 3, resetSeconds: 30, exerciseNames: []),
    ]

    /// `true` si `workout` correspond exactement (nom + tous les paramètres) à l'une des
    /// deux anciennes séances par défaut, jamais modifiée par l'utilisateur.
    static func isLegacySeed(_ workout: Workout) -> Bool {
        legacySeeds.contains { $0.matches(workout) }
    }
}

extension WorkoutSuggestions.Suggestion {
    /// Construit une séance persistable directement depuis la suggestion, sans passer par
    /// l'éditeur. Centralise le mapping champ à champ pour n'avoir qu'un seul endroit à
    /// corriger si `Suggestion` ou `Workout` évolue.
    func makeWorkout() -> Workout {
        Workout(name: name, prepareSeconds: prepareSeconds, workSeconds: workSeconds,
                restSeconds: restSeconds, sets: sets, rounds: rounds, resetSeconds: resetSeconds,
                exerciseNames: exerciseNames)
    }
}
