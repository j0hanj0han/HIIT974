import SwiftUI
import SwiftData

struct WorkoutEditorView: View {
    let existingWorkout: Workout?
    let onSave: (Workout) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name: String
    @State private var workSeconds: Int
    @State private var restSeconds: Int
    @State private var sets: Int
    @State private var rounds: Int
    @State private var resetSeconds: Int

    init(existingWorkout: Workout? = nil, onSave: @escaping (Workout) -> Void) {
        self.existingWorkout = existingWorkout
        self.onSave = onSave
        _name         = State(initialValue: existingWorkout?.name         ?? "")
        _workSeconds  = State(initialValue: existingWorkout?.workSeconds  ?? 20)
        _restSeconds  = State(initialValue: existingWorkout?.restSeconds  ?? 10)
        _sets         = State(initialValue: existingWorkout?.sets         ?? 8)
        _rounds       = State(initialValue: existingWorkout?.rounds       ?? 1)
        _resetSeconds = State(initialValue: existingWorkout?.resetSeconds ?? 0)
    }

    private var totalSeconds: Int {
        sets * (workSeconds + restSeconds) * rounds + max(0, rounds - 1) * resetSeconds
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ProportionBar(workSeconds: workSeconds, restSeconds: restSeconds,
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
                    ParamRow(icon: "bolt.fill",       color: .red,
                             title: "Travail",
                             value: durationLabel(workSeconds)) {
                        Stepper("", value: $workSeconds, in: 5...600, step: 5).labelsHidden()
                    }
                    ParamRow(icon: "pause.circle",    color: .blue,
                             title: "Repos",
                             value: durationLabel(restSeconds)) {
                        Stepper("", value: $restSeconds, in: 5...600, step: 5).labelsHidden()
                    }
                    ParamRow(icon: "number.circle",   color: .orange,
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
        }
    }

    private func save() {
        if let existing = existingWorkout {
            existing.name         = name
            existing.workSeconds  = workSeconds
            existing.restSeconds  = restSeconds
            existing.sets         = sets
            existing.rounds       = rounds
            existing.resetSeconds = resetSeconds
            onSave(existing)
        } else {
            onSave(Workout(name: name, workSeconds: workSeconds, restSeconds: restSeconds,
                           sets: sets, rounds: rounds, resetSeconds: resetSeconds))
        }
        dismiss()
    }
}

// MARK: - Proportion bar

struct ProportionBar: View {
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
        Double(sets * (workSeconds + restSeconds) * rounds + max(0, rounds - 1) * resetSeconds)
    }

    private var segments: [Seg] {
        var result: [Seg] = []
        var idx = 0
        for r in 0..<rounds {
            for _ in 0..<sets {
                result.append(Seg(id: idx, color: .red,  seconds: workSeconds)); idx += 1
                result.append(Seg(id: idx, color: .blue, seconds: restSeconds)); idx += 1
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
