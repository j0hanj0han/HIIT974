import SwiftUI
import SwiftData
import os

@main
struct HIIT974App: App {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoHIIT",
                                       category: "Storage")

    @State private var selection = 0
    private let container: ModelContainer

    init() {
        container = Self.makeContainer()
    }

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
        .modelContainer(container)
    }

    // MARK: - Store

    /// Ouvre le store SwiftData. Ajouter un attribut doté d'une valeur par défaut relève de
    /// la migration légère inférée, mais l'app est en production : avec l'initialiseur de
    /// commodité `.modelContainer(for:)`, un échec d'inférence fait *trapper au lancement*,
    /// sans recours pour l'utilisateur. En dernier ressort on met le store défaillant de côté
    /// et on repart sur un store neuf — perdre l'historique reste préférable à une app qui ne
    /// démarre plus.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([Workout.self, WorkoutRun.self])
        let configuration = ModelConfiguration(schema: schema)

        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            logger.error("Ouverture du store impossible, bascule sur un store neuf : \(error)")
            archiveStore(at: configuration.url)
        }

        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            logger.fault("Store neuf impossible, bascule en mémoire : \(error)")
            // Un store en mémoire ne peut pas échouer ; si c'est le cas, il n'y a plus d'app.
            return try! ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
        }
    }

    /// Déplace le store et ses fichiers auxiliaires (`-shm`, `-wal`) à côté, horodatés.
    private static func archiveStore(at url: URL) {
        let fileManager = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")

        for suffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            do {
                try fileManager.moveItem(at: source, to: source.appendingPathExtension("broken-\(stamp)"))
            } catch {
                logger.error("Archivage de \(source.lastPathComponent) impossible : \(error)")
            }
        }
    }
}
