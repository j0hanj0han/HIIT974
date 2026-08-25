import SwiftUI
import SwiftData

struct WorkoutEditorView: View {
    let existingWorkout: Workout?
    let onSave: (Workout) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    /// Sert uniquement à alimenter les suggestions : les noms déjà employés ailleurs.
    @Query private var allWorkouts: [Workout]

    @State private var name: String
    @State private var prepareSeconds: Int
    @State private var workSeconds: Int
    @State private var restSeconds: Int
    @State private var sets: Int
    @State private var rounds: Int
    @State private var resetSeconds: Int
    @State private var exerciseNames: [String]
    @State private var namesExpanded: Bool

    init(existingWorkout: Workout? = nil, onSave: @escaping (Workout) -> Void) {
        self.existingWorkout = existingWorkout
        self.onSave = onSave
        _name           = State(initialValue: existingWorkout?.name           ?? "")
        _prepareSeconds = State(initialValue: existingWorkout?.prepareSeconds ?? 10)
        _workSeconds    = State(initialValue: existingWorkout?.workSeconds    ?? 20)
        _restSeconds    = State(initialValue: existingWorkout?.restSeconds    ?? 10)
        _sets           = State(initialValue: existingWorkout?.sets           ?? 8)
        _rounds         = State(initialValue: existingWorkout?.rounds         ?? 1)
        _resetSeconds   = State(initialValue: existingWorkout?.resetSeconds   ?? 0)
        _exerciseNames  = State(initialValue: existingWorkout?.exerciseNames  ?? [])

        // Repliée par défaut : on ne déplie que si la séance a déjà des noms à montrer.
        var hasNames = existingWorkout?.exerciseNames.contains { !$0.isEmpty } ?? false
        #if DEBUG
        // Capture « structure de la séance » : la liste dépliée déborderait en bas de
        // l'écran, coupée en plein milieu d'une ligne. La capture des noms, elle, a son
        // propre argument.
        if ProcessInfo.processInfo.arguments.contains("-screenshotEditor") { hasNames = false }
        #endif
        _namesExpanded = State(initialValue: hasNames)
    }

    private var personalNames: [String] {
        ExerciseCatalog.personalNames(in: allWorkouts)
    }

    /// Accès indexé sûr au tableau de noms.
    ///
    /// Le tableau est creux : il peut être plus court que `sets`. Plutôt que de le
    /// maintenir synchronisé dans un `onChange` — qui s'exécute *après* le recalcul du
    /// corps de la vue, laissant une fenêtre où `$exerciseNames[index]` planterait —
    /// on complète paresseusement à l'écriture.
    private func nameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { exerciseNames.indices.contains(index) ? exerciseNames[index] : "" },
            set: { newValue in
                if exerciseNames.count <= index {
                    exerciseNames.append(contentsOf:
                        Array(repeating: "", count: index + 1 - exerciseNames.count))
                }
                exerciseNames[index] = newValue
            }
        )
    }

    private var totalSeconds: Int {
        prepareSeconds
            + sets * (workSeconds + restSeconds) * rounds
            + max(0, rounds - 1) * resetSeconds
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    ProportionBar(prepareSeconds: prepareSeconds,
                                  workSeconds: workSeconds, restSeconds: restSeconds,
                                  sets: sets, rounds: rounds, resetSeconds: resetSeconds)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    HStack {
                        Text("Durée totale").foregroundStyle(.secondary)
                        Spacer()
                        Text(durationLabel(totalSeconds)).fontWeight(.medium)
                    }
                    .font(.subheadline)
                }

                Section {
                    TextField("Nom de la séance", text: $name)
                }

                Section {
                    ParamRow(icon: "figure.stand",    color: .orange,
                             title: "Préparation",
                             value: prepareSeconds == 0 ? "Aucune" : durationLabel(prepareSeconds)) {
                        Stepper("", value: $prepareSeconds, in: 0...60, step: 5).labelsHidden()
                    }
                    ParamRow(icon: "bolt.fill",       color: .red,
                             title: "Travail",
                             value: durationLabel(workSeconds)) {
                        Stepper("", value: $workSeconds, in: 5...600, step: 5).labelsHidden()
                    }
                    ParamRow(icon: "pause.circle",    color: .blue,
                             title: "Repos",
                             value: restSeconds == 0 ? "Aucun" : durationLabel(restSeconds)) {
                        Stepper("", value: $restSeconds, in: 0...600, step: 5).labelsHidden()
                    }
                    ParamRow(icon: "number.circle",   color: .indigo,
                             title: "Exercices",
                             value: "\(sets)") {
                        Stepper("", value: $sets, in: 1...30).labelsHidden()
                    }
                    ParamRow(icon: "arrow.clockwise", color: .purple,
                             title: "Rounds",
                             value: "\(rounds)×") {
                        Stepper("", value: $rounds, in: 1...20).labelsHidden()
                    }
                    ParamRow(icon: "timer",           color: .teal,
                             title: "Réinit. du round",
                             value: resetSeconds == 0 ? "Aucune" : durationLabel(resetSeconds)) {
                        Stepper("", value: $resetSeconds, in: 0...300, step: 5).labelsHidden()
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $namesExpanded) {
                        ForEach(0..<sets, id: \.self) { index in
                            ExerciseNameRow(index: index,
                                            name: nameBinding(index),
                                            personalNames: personalNames)
                        }
                    } label: {
                        Label("Nommer les exercices", systemImage: "text.badge.plus")
                    }
                } footer: {
                    Text("Facultatif. Un exercice nommé s'affiche à la place de « Effort » pendant la séance.")
                }
                .id(Self.namesSectionID)
            }
            .navigationTitle(existingWorkout != nil ? "Modifier" : "Nouvelle séance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Enregistrer") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .fontWeight(.semibold)
                }
            }
            #if DEBUG
            // Capture d'écran App Store : la section des noms est en bas du formulaire,
            // on la remonte pour qu'elle soit visible sans interaction. Sans cet argument
            // la capture montre le haut du formulaire, c'est-à-dire la structure de la séance.
            .onAppear {
                guard ProcessInfo.processInfo.arguments.contains("-screenshotEditorNames") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    proxy.scrollTo(Self.namesSectionID, anchor: .top)
                }
            }
            #endif
            }
        }
    }

    private static let namesSectionID = "exercise-names-section"

    /// Noms tels qu'ils seront persistés : bornés à `sets`, nettoyés, et sans entrées
    /// vides en fin de tableau (une séance sans aucun nom repart donc de `[]`).
    private var namesToPersist: [String] {
        var cleaned = exerciseNames.prefix(sets).map { $0.trimmingCharacters(in: .whitespaces) }
        while cleaned.last?.isEmpty == true { cleaned.removeLast() }
        return Array(cleaned)
    }

    private func save() {
        if let existing = existingWorkout {
            existing.name           = name
            existing.prepareSeconds = prepareSeconds
            existing.workSeconds    = workSeconds
            existing.restSeconds    = restSeconds
            existing.sets           = sets
            existing.rounds         = rounds
            existing.resetSeconds   = resetSeconds
            existing.exerciseNames  = namesToPersist
            onSave(existing)
        } else {
            onSave(Workout(name: name, prepareSeconds: prepareSeconds,
                           workSeconds: workSeconds, restSeconds: restSeconds,
                           sets: sets, rounds: rounds, resetSeconds: resetSeconds,
                           exerciseNames: namesToPersist))
        }
        dismiss()
    }
}

// MARK: - Exercise name row

/// Une ligne de nommage : saisie libre au clavier, ou choix dans le menu.
///
/// Les deux chemins écrivent dans le même binding — le nom tapé à la main devient donc
/// automatiquement une suggestion « Récents » pour les séances suivantes.
private struct ExerciseNameRow: View {
    let index: Int
    @Binding var name: String
    let personalNames: [String]

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            TextField("Exercice \(index + 1)", text: $name)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)

            Menu {
                if !personalNames.isEmpty {
                    Section("Récents") {
                        ForEach(personalNames, id: \.self) { suggestion in
                            Button(suggestion) { name = suggestion }
                        }
                    }
                }
                ForEach(ExerciseCatalog.categories) { category in
                    Menu {
                        ForEach(category.names, id: \.self) { suggestion in
                            Button(suggestion) { name = suggestion }
                        }
                    } label: {
                        Label(category.title, systemImage: category.systemImage)
                    }
                }
                if !name.isEmpty {
                    Section {
                        Button(role: .destructive) { name = "" } label: {
                            Label("Effacer le nom", systemImage: "xmark.circle")
                        }
                    }
                }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            // Sans style borderless, le menu capte le tap de toute la ligne et le champ
            // de saisie devient impossible à cibler.
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Proportion bar

struct ProportionBar: View {
    let prepareSeconds: Int
    let workSeconds: Int
    let restSeconds: Int
    let sets: Int
    let rounds: Int
    let resetSeconds: Int

    private struct Seg: Identifiable {
        let id: Int
        let color: Color
        let seconds: Int
    }

    private var total: Double {
        Double(prepareSeconds
               + sets * (workSeconds + restSeconds) * rounds
               + max(0, rounds - 1) * resetSeconds)
    }

    private var segments: [Seg] {
        var result: [Seg] = []
        var idx = 0
        if prepareSeconds > 0 {
            result.append(Seg(id: idx, color: .orange, seconds: prepareSeconds)); idx += 1
        }
        for r in 0..<rounds {
            for _ in 0..<sets {
                result.append(Seg(id: idx, color: .red,  seconds: workSeconds)); idx += 1
                if restSeconds > 0 {
                    result.append(Seg(id: idx, color: .blue, seconds: restSeconds)); idx += 1
                }
            }
            if r < rounds - 1 && resetSeconds > 0 {
                result.append(Seg(id: idx, color: .teal, seconds: resetSeconds)); idx += 1
            }
        }
        return result
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let t = max(1.0, total)
            HStack(spacing: 0) {
                ForEach(segments) { seg in
                    Rectangle()
                        .fill(seg.color)
                        .frame(width: w * CGFloat(seg.seconds) / CGFloat(t))
                }
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Param row

private struct ParamRow<Controls: View>: View {
    let icon: String
    let color: Color
    let title: String
    let value: String
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(color)
                    .frame(width: 30, height: 30)
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Text(title)
            Spacer()
            controls()
            Text(value)
                .foregroundStyle(color)
                .fontWeight(.semibold)
                .monospacedDigit()
                .frame(minWidth: 54, alignment: .trailing)
        }
    }
}

private func durationLabel(_ s: Int) -> String {
    if s == 0 { return "0 s" }
    if s < 60 { return "\(s) s" }
    let m = s / 60; let r = s % 60
    return r == 0 ? "\(m) min" : "\(m):\(String(format: "%02d", r))"
}

#Preview {
    WorkoutEditorView { _ in }
        .modelContainer(for: Workout.self, inMemory: true)
}
