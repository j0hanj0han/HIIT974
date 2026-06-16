import SwiftUI
import SwiftData

@main
struct HIIT974App: App {
    @State private var selection = 0

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selection) {
                Tab("Séances", systemImage: "figure.run", value: 0) {
                    WorkoutListView()
                }
                Tab("Historique", systemImage: "clock.arrow.circlepath", value: 1) {
                    HistoryView()
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .onAppear {
                #if DEBUG
                // Permet d'ouvrir directement un onglet pour les captures d'écran.
                if ProcessInfo.processInfo.arguments.contains("-screenshotHistory") {
                    selection = 1
                }
                #endif
            }
        }
        .modelContainer(for: [Workout.self, WorkoutRun.self])
    }
}
