import SwiftUI
import SwiftData

@main
struct HIIT974App: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Séances", systemImage: "figure.run") {
                    WorkoutListView()
                }
                Tab("Historique", systemImage: "clock.arrow.circlepath") {
                    HistoryView()
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
        }
        .modelContainer(for: [Workout.self, WorkoutRun.self])
    }
}
