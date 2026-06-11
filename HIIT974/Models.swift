import SwiftUI
import SwiftData

@Model
final class Workout {
    var name: String
    var createdAt: Date
    var workSeconds: Int  = 20
    var restSeconds: Int  = 10
    var sets: Int         = 8
    var rounds: Int       = 1
    var resetSeconds: Int = 0

    init(name: String,
         workSeconds: Int  = 20,
         restSeconds: Int  = 10,
         sets: Int         = 8,
         rounds: Int       = 1,
         resetSeconds: Int = 0) {
        self.name         = name
        self.createdAt    = Date()
        self.workSeconds  = workSeconds
        self.restSeconds  = restSeconds
        self.sets         = sets
        self.rounds       = rounds
        self.resetSeconds = resetSeconds
    }
}

extension Workout {
    var totalSeconds: Int {
        sets * (workSeconds + restSeconds) * rounds
            + max(0, rounds - 1) * resetSeconds
    }

    static var samples: [Workout] {
        [
            Workout(name: "Tabata",
                    workSeconds: 20, restSeconds: 10,
                    sets: 8, rounds: 1, resetSeconds: 0),
            Workout(name: "HIIT Full Body",
                    workSeconds: 40, restSeconds: 20,
                    sets: 5, rounds: 3, resetSeconds: 30),
        ]
    }
}
