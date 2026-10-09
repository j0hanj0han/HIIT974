import SwiftUI
import SwiftData
import os

@main
struct HIIT974App: App {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TempoHIIT",
                                       category: "Storage")

    @State private var selection = 0
    /// Absente chez les utilisateurs d'avant la 1.7, donc à 0 : ils voient l'onboarding
    /// comme les nouveaux.
    @AppStorage("onboardingVersionSeen") private var onboardingVersionSeen = 0
    private let container: ModelContainer

    init() {
        container = Self.makeContainer()
        #if DEBUG
        // Rejoue l'onboarding comme au premier lancement, sans réinstaller.
        if ProcessInfo.processInfo.arguments.contains("-showOnboarding") {
            UserDefaults.standard.removeObject(forKey: "onboardingVersionSeen")
        }
        #endif
    }

    private var needsOnboarding: Bool {
        #if DEBUG
        // Le script de captures part d'un simulateur vierge : l'onboarding recouvrirait
        // tous les écrans.
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-screenshot") }) {
            return false
        }
        #endif
        return onboardingVersionSeen < OnboardingView.currentVersion
    }

    var body: some Scene {
        WindowGroup {
            // Bascule à la racine plutôt qu'un `fullScreenCover` : pas d'animation de montée
            // au lancement, ni la liste entrevue en dessous.
            Group {
                if needsOnboarding {
                    OnboardingView { onboardingVersionSeen = OnboardingView.currentVersion }
                        .transition(.opacity)
                } else {
                    mainTabs
                        .transition(.opacity)
                }
            }
            // Explicite plutôt qu'un `withAnimation` autour de l'écriture `@AppStorage`,
            // dont la transaction n'est pas garantie jusqu'à la bascule.
            .animation(.easeInOut(duration: 0.35), value: needsOnboarding)
        }
        .modelContainer(container)
    }

    private var mainTabs: some View {
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
