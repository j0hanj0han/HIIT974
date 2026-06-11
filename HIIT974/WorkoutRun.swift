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
