import SwiftUI

/// Présentation des fonctionnalités, affichée par `HIIT974App` tant que
/// `onboardingVersionSeen < currentVersion`. Les utilisateurs déjà installés n'ont jamais eu
/// cette clé : ils la voient aussi, sans code dédié.
struct OnboardingView: View {
    /// Monter ce numéro remontre l'onboarding à tout le monde au prochain lancement.
    static let currentVersion = 1

    /// « Passer » comme « C'est parti » : la persistance du « déjà vu » reste dans l'App.
    let onFinish: () -> Void
    @State private var selection = Self.initialPage

    private var isLastPage: Bool { selection == Self.pages.count - 1 }
    private var currentColor: Color { Self.pages[selection].color }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Self.pages.indices, id: \.self) { index in
                OnboardingPageView(page: Self.pages[index])
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        // Fond plein écran de la couleur de la page, comme `RunView` avec ses phases.
        .background {
            currentColor
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.45), value: selection)
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Spacer()
                // Texte simple : un fond de verre sur ces couleurs vives tourne au pastel,
                // et le blanc n'y est plus lisible.
                Button("Passer", action: onFinish)
                    .font(.body.weight(.semibold))
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            // Sur la dernière page « C'est parti » fait la même chose : on masque sans
            // retirer, pour ne pas faire sauter la mise en page.
            .opacity(isLastPage ? 0 : 1)
            .disabled(isLastPage)
            .accessibilityHidden(isLastPage)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                if isLastPage {
                    onFinish()
                } else {
                    withAnimation { selection += 1 }
                }
            } label: {
                // Blanc plein et couleur de page assombrie : le verre teinté tournait au
                // pastel sur le teal et le vert, et la couleur pure sur blanc y restait
                // sous 3:1 de contraste.
                Text(isLastPage ? "C'est parti" : "Suivant")
                    .font(.headline)
                    .foregroundStyle(currentColor.mix(with: .black, by: 0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.white)
            .controlSize(.large)
            .padding(.horizontal, 32)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
    }

    /// `-onboardingPage N` (DEBUG) : ouvre directement la page N, pour vérifier chaque page
    /// en capture sans avoir à balayer.
    private static var initialPage: Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "-onboardingPage"), flag + 1 < args.count,
           let page = Int(args[flag + 1]), pages.indices.contains(page - 1) {
            return page - 1
        }
        #endif
        return 0
    }
}

// MARK: - Pages

private struct OnboardingPage {
    enum Visual {
        /// Capture réelle de l'app (imageset synchronisé par la lane `screenshots`), avec en
        /// option un repère sur le bouton à retenir, en coordonnées 0…1 de la capture.
        case screenshot(String, highlight: CGRect?)
        /// Pour ce qui ne se capture pas, comme le son.
        case symbol(String)
    }

    let visual: Visual
    let color: Color
    let title: String
    let message: String
}

extension OnboardingView {
    /// Les couleurs reprennent celles des phases : la page 2 annonce justement que chaque
    /// phase a la sienne.
    ///
    /// Les repères sont mesurés sur les captures 1320×2868 de `fastlane/screenshots/fr-FR/` :
    /// si la mise en page d'un de ces écrans change, les recaler ici.
    fileprivate static let pages: [OnboardingPage] = [
        OnboardingPage(
            visual: .screenshot("onboarding-run",   // bouton pause/lecture
                                highlight: CGRect(x: 0.3977, y: 0.8319, width: 0.2045, height: 0.0941)),
            color: TimerEngine.Step.Phase.work.color,
            title: "Lisible à distance",
            message: "Pose ton iPhone par terre : chrono et exercice s'affichent en grand. Touche le bouton central pour lancer ou mettre en pause."),
        OnboardingPage(
            visual: .screenshot("onboarding-editor",   // ligne « Choisir les exercices »
                                highlight: CGRect(x: 0.0379, y: 0.8476, width: 0.9242, height: 0.0624)),
            color: TimerEngine.Step.Phase.prepare.color,
            title: "Six réglages, c'est tout",
            message: "Effort, repos, exercices, rounds… chaque phase a sa couleur. Nomme tes exercices depuis le catalogue ou à ta façon."),
        OnboardingPage(
            visual: .symbol("speaker.wave.3.fill"),
            color: TimerEngine.Step.Phase.rest.color,
            title: "Des signaux sans regarder",
            message: "Décompte 3-2-1, signal à mi-effort, bip aigu pour l'effort, grave pour la récup. Ta musique continue, juste atténuée. Garde l'app à l'écran : c'est là que les bips sonnent."),
        OnboardingPage(
            visual: .screenshot("onboarding-list",   // bouton +
                                highlight: CGRect(x: 0.8379, y: 0.0572, width: 0.1333, height: 0.0614)),
            color: TimerEngine.Step.Phase.reset.color,
            title: "Suggestions du chef",
            message: "Touche + pour créer ta séance, ou partir d'un Tabata, d'un HIIT Full Body… prêts en un tap."),
        OnboardingPage(
            visual: .screenshot("onboarding-history",   // onglet Historique
                                highlight: CGRect(x: 0.4939, y: 0.9107, width: 0.2053, height: 0.0690)),
            color: .green,   // le vert de « Séance terminée » dans RunView
            title: "Ton historique, chez toi",
            message: "Chaque séance terminée est enregistrée. Aucun compte, rien ne quitte ton iPhone."),
    ]
}

private struct OnboardingPageView: View {
    let page: OnboardingPage
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 28) {
            // En taille d'accessibilité, le texte a besoin de toute la hauteur : la
            // capture, illustrative, cède sa place.
            if !dynamicTypeSize.isAccessibilitySize {
                visual
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }

            ScrollView {
                VStack(spacing: 10) {
                    Text(page.title)
                        .font(.title.bold())
                    Text(page.message)
                        .font(.body)
                        .opacity(0.9)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.center, for: .alignment)
            .fixedSize(horizontal: false, vertical: !dynamicTypeSize.isAccessibilitySize)
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 56)   // laisse la place aux points de pagination
    }

    @ViewBuilder
    private var visual: some View {
        switch page.visual {
        case .screenshot(let name, let highlight):
            ScreenshotFrame(imageName: name, highlight: highlight, color: page.color)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 64, weight: .semibold))
                .symbolEffect(.variableColor.iterative)
                .frame(width: 140, height: 140)
                .glassEffect(.clear, in: Circle())
        }
    }
}

/// Capture dans un cadre façon iPhone. Le repère est posé dans le repère de l'image
/// affichée, donc reste en place quelle que soit la taille que lui laisse l'écran.
private struct ScreenshotFrame: View {
    let imageName: String
    let highlight: CGRect?
    let color: Color

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { proxy in
                    if let highlight {
                        PulsingHighlight(color: color)
                            .frame(width: highlight.width * proxy.size.width,
                                   height: highlight.height * proxy.size.height)
                            .position(x: highlight.midX * proxy.size.width,
                                      y: highlight.midY * proxy.size.height)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 28))
            .padding(5)
            .background(.white, in: .rect(cornerRadius: 33))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }
}

private struct PulsingHighlight: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            ring
        } else {
            ring.phaseAnimator([false, true]) { content, expanded in
                content
                    .scaleEffect(expanded ? 1.12 : 1)
                    .opacity(expanded ? 0.35 : 1)
            } animation: { _ in .easeInOut(duration: 0.8) }
        }
    }

    // Couleur de la page cerclée de blanc : la couleur ressort sur le fond clair de la
    // liste, le blanc sur le rouge de la séance.
    private var ring: some View {
        Capsule()
            .stroke(.white, lineWidth: 8)
            .overlay(Capsule().stroke(color, lineWidth: 4))
    }
}

#Preview {
    OnboardingView(onFinish: {})
}
