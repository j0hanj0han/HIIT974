import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Query(sort: \WorkoutRun.startedAt, order: .reverse) private var runs: [WorkoutRun]
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            Group {
                if runs.isEmpty {
                    ContentUnavailableView(
                        "Aucune séance enregistrée",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Lance une séance pour voir ton historique ici.")
                    )
                } else {
                    List {
                        Section {
                            ActivityChart(runs: runs)
                                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                            StatsRow(runs: runs)
                        }

                        Section("Séances") {
                            ForEach(runs) { run in
                                RunHistoryRow(run: run)
                            }
                            .onDelete { indexSet in
                                indexSet.forEach { context.delete(runs[$0]) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Historique")
        }
    }
}

// MARK: - Activity chart (7 derniers jours)

private struct ActivityChart: View {
    let runs: [WorkoutRun]

    private struct DayData: Identifiable {
        var id: Date { day }
        let day: Date
        let minutes: Int
    }

    private var data: [DayData] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: today) ?? today
            let mins = runs
                .filter { cal.isDate($0.startedAt, inSameDayAs: day) }
                .reduce(0) { $0 + $1.totalSeconds / 60 }
            return DayData(day: day, minutes: mins)
        }
    }

    var body: some View {
        Chart(data) { item in
            BarMark(
                x: .value("Jour", item.day, unit: .day),
                y: .value("Min", item.minutes)
            )
            .foregroundStyle(.blue.gradient)
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel("\(value.as(Int.self) ?? 0) min")
            }
        }
        .frame(height: 140)
    }
}

// MARK: - Stats summary

private struct StatsRow: View {
    let runs: [WorkoutRun]

    private var totalMinutes: Int { runs.reduce(0) { $0 + $1.totalSeconds } / 60 }

    var body: some View {
        HStack {
            StatCell(value: "\(runs.count)", label: "séances")
            Divider()
            StatCell(value: timeLabel(totalMinutes), label: "temps total")
        }
        .frame(height: 56)
    }

    private func timeLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

private struct StatCell: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - History row

private struct RunHistoryRow: View {
    let run: WorkoutRun

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(run.workoutName).font(.headline)
                Text(run.startedAt, style: .date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(durationLabel(run.totalSeconds))
                    .font(.subheadline.monospacedDigit())
                Text(run.startedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func durationLabel(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: WorkoutRun.self, inMemory: true)
}
