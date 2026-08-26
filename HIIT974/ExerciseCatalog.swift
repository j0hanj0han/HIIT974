import Foundation

/// Suggestions de noms d'exercices proposées dans l'éditeur.
///
/// Volontairement sans SwiftData : le catalogue intégré est une constante, et les noms
/// personnels sont recalculés à la volée depuis les séances existantes. Aucune entité à
/// migrer, aucun écran de gestion, aucune déduplication à arbitrer en base — au prix
/// assumé qu'un nom disparaisse des suggestions quand plus aucune séance ne l'utilise.
enum ExerciseCatalog {

    struct Category: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let names: [String]
    }

    static let categories: [Category] = [
        Category(id: "cardio", title: "Cardio", systemImage: "figure.run", names: [
            "Burpees",
            "Jumping jacks",
            "Montées de genoux",
            "Talons-fesses",
            "Corde à sauter",
            "Sprint sur place",
            "Squat jump",
            "Fentes sautées",
            "Skaters",
        ]),
        Category(id: "upper", title: "Haut du corps", systemImage: "figure.strengthtraining.traditional", names: [
            "Pompes",
            "Pompes diamant",
            "Pompes inclinées",
            "Dips",
            "Tractions",
            "Rowing élastique",
            "Développé épaules",
            "Curl biceps",
        ]),
        Category(id: "lower", title: "Bas du corps", systemImage: "figure.strengthtraining.functional", names: [
            "Squats",
            "Squat sumo",
            "Squat bulgare",
            "Fentes avant",
            "Fentes arrière",
            "Chaise",
            "Hip thrust",
            "Montées sur banc",
            "Mollets debout",
        ]),
        Category(id: "core", title: "Gainage", systemImage: "figure.core.training", names: [
            "Planche",
            "Planche latérale",
            "Mountain climbers",
            "Crunchs",
            "Relevés de jambes",
            "Russian twist",
            "Superman",
            "Hollow hold",
        ]),
        Category(id: "mobility", title: "Mobilité", systemImage: "figure.flexibility", names: [
            "Étirement quadriceps",
            "Étirement ischios",
            "Rotations d'épaules",
            "Chat-vache",
            "Fente basse",
            "Rotation du buste",
            "Respiration",
            "Marche sur place",
        ]),
    ]

    /// Noms déjà utilisés dans les séances, hors catalogue intégré, les plus fréquents
    /// d'abord. C'est ce qui rend un nom saisi à la main réutilisable dans les séances
    /// suivantes, sans jamais avoir à le « créer » explicitement.
    static func personalNames(in workouts: [Workout], limit: Int = 8) -> [String] {
        var tally: [String: (display: String, count: Int)] = [:]

        for workout in workouts {
            for rawName in workout.exerciseNames {
                let name = rawName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }

                let key = normalizedKey(name)
                guard !builtInKeys.contains(key) else { continue }

                // La première graphie rencontrée fait foi : « burpees » et « Burpees »
                // comptent pour une seule suggestion.
                if let seen = tally[key] {
                    tally[key] = (seen.display, seen.count + 1)
                } else {
                    tally[key] = (name, 1)
                }
            }
        }

        return tally.values
            .sorted { left, right in
                left.count == right.count
                    ? left.display.localizedStandardCompare(right.display) == .orderedAscending
                    : left.count > right.count
            }
            .prefix(limit)
            .map(\.display)
    }

    // MARK: - Déduplication

    /// Clé de comparaison insensible à la casse et aux accents.
    ///
    /// `nonisolated` parce qu'elle sert à initialiser `builtInKeys`, dont l'évaluation
    /// paresseuse n'a aucune raison de se produire sur le main actor.
    nonisolated private static func normalizedKey(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    private static let builtInKeys: Set<String> = Set(
        categories.flatMap(\.names).map(normalizedKey)
    )
}
