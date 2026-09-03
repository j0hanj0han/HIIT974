import SwiftUI

/// Écran du « dossier » Suggestions, atteint depuis `WorkoutListView` : les propositions du
/// catalogue n'encombrent pas l'accueil, où les séances de l'utilisateur restent la priorité.
struct WorkoutSuggestionsView: View {
    let suggestions: [WorkoutSuggestions.Suggestion]
    /// Tap sur la ligne (n'importe où) : ajoute directement la séance à la liste. Pas
    /// d'éditeur dans cet écran — la personnalisation se fait après coup, comme pour
    /// n'importe quelle séance, via le bouton « Modifier » de l'accueil.
    let onAdd: (WorkoutSuggestions.Suggestion) -> Void

    var body: some View {
        List(suggestions) { suggestion in
            Button {
                onAdd(suggestion)
            } label: {
                SuggestionRowView(suggestion: suggestion)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Suggestions du chef")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SuggestionRowView: View {
    let suggestion: WorkoutSuggestions.Suggestion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: suggestion.systemImage)
                    .foregroundStyle(Color.accentColor)
                Text(suggestion.name).font(.headline)
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            Text(suggestion.subtitle).font(.subheadline).foregroundStyle(.secondary)
            ProportionBar(
                prepareSeconds: 0,   // illustre le rythme d'un round, comme WorkoutMiniBar
                workSeconds: suggestion.workSeconds,
                restSeconds: suggestion.restSeconds,
                sets: suggestion.sets,
                rounds: 1,
                resetSeconds: 0
            )
            .frame(height: 4)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        WorkoutSuggestionsView(suggestions: WorkoutSuggestions.catalog, onAdd: { _ in })
    }
}
