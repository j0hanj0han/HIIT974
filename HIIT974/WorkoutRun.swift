import Foundation
import SwiftData

@Model
final class WorkoutRun {
    var workoutName: String
    var startedAt: Date
    var completedAt: Date
    var totalSeconds: Int

    init(workoutName: String, startedAt: Date, completedAt: Date) {
        self.workoutName = workoutName
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.totalSeconds = Int(completedAt.timeIntervalSince(startedAt))
    }
}

#if DEBUG
extension WorkoutRun {
    /// Historique factice pour les captures d'écran App Store. Compilé uniquement en DEBUG :
    /// le build Release (soumission) n'en contient aucune trace.
    static func demoRuns(now: Date = Date()) -> [WorkoutRun] {
        let cal = Calendar.current
        // (jours avant aujourd'hui, heure de début, nom, durée en secondes)
        let plan: [(day: Int, hour: Int, name: String, seconds: Int)] = [
            (0, 7,  "Tabata",         240),
            (0, 18, "HIIT Full Body", 990),
            (1, 8,  "HIIT Full Body", 990),
            (2, 19, "Tabata",         240),
            (3, 7,  "Cardio Express", 600),
            (4, 18, "HIIT Full Body", 990),
            (4, 12, "Tabata",         240),
            (5, 9,  "Cardio Express", 600),
            (6, 8,  "Tabata",         240),
        ]
        return plan.map { item in
            let midnight = cal.startOfDay(for: cal.date(byAdding: .day, value: -item.day, to: now) ?? now)
            let start = cal.date(byAdding: .hour, value: item.hour, to: midnight) ?? midnight
            let end = start.addingTimeInterval(TimeInterval(item.seconds))
            return WorkoutRun(workoutName: item.name, startedAt: start, completedAt: end)
        }
    }
}
#endif
