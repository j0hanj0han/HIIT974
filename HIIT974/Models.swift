import SwiftUI
import SwiftData

@Model
final class Workout {
    var name: String
    var createdAt: Date
    var prepareSeconds: Int = 10
    var workSeconds: Int    = 20
    var restSeconds: Int    = 10
    var sets: Int           = 8
    var rounds: Int         = 1
    var resetSeconds: Int   = 0

    /// Noms des exercices, dans l'ordre des séries. Table de correspondance **creuse** :
    /// sa longueur est indépendante de `sets`, qui reste la source de vérité du nombre
    /// d'exercices. Une entrée vide ou manquante signifie « non nommé ».
    var exerciseNames: [String] = []

    init(name: String,
         prepareSeconds: Int = 10,
         workSeconds: Int    = 20,
         restSeconds: Int    = 10,
         sets: Int           = 8,
         rounds: Int         = 1,
         resetSeconds: Int   = 0,
         exerciseNames: [String] = []) {
        self.name           = name
        self.createdAt      = Date()
        self.prepareSeconds = prepareSeconds
        self.workSeconds    = workSeconds
        self.restSeconds    = restSeconds
        self.sets           = sets
        self.rounds         = rounds
        self.resetSeconds   = resetSeconds
        self.exerciseNames  = exerciseNames
    }
}

extension Workout {
    var totalSeconds: Int {
        prepareSeconds
            + sets * (workSeconds + restSeconds) * rounds
            + max(0, rounds - 1) * resetSeconds
    }

    /// Nom de l'exercice à la série donnée (1-based), ou `nil` s'il n'est pas nommé.
    func exerciseName(at setIndex: Int) -> String? {
        guard exerciseNames.indices.contains(setIndex - 1) else { return nil }
        let name = exerciseNames[setIndex - 1]
        return name.isEmpty ? nil : name
    }

    /// Nombre d'exercices effectivement nommés, dans la limite de `sets`.
    var namedExerciseCount: Int {
        (1...max(sets, 1)).count { exerciseName(at: $0) != nil }
    }

    static var samples: [Workout] {
        [
            Workout(name: "Tabata",
                    workSeconds: 20, restSeconds: 10,
                    sets: 8, rounds: 1, resetSeconds: 0,
                    exerciseNames: ["Burpees", "Mountain climbers", "Squat jump", "Pompes",
                                    "Jumping jacks", "Planche", "Fentes sautées", "Crunchs"]),
            Workout(name: "HIIT Full Body",
                    workSeconds: 40, restSeconds: 20,
                    sets: 5, rounds: 3, resetSeconds: 30),
        ]
    }
}
