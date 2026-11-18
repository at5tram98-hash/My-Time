import SwiftUI
import Charts
import MyTimeCore

/// 振り返り。直近7日の作業時間・完了数・余白（実績のある値だけを出す）
struct ReviewScreen: View {
    @Environment(AppModel.self) private var model

    struct DayStat: Identifiable {
        var id: EpochMs { day }
        var day: EpochMs
        var workedMinutes: Int
        var done: Int
        var free: Double
    }

    /// その他タブの中に入れるとき
    var embedded = false

    var body: some View {
        OptionalNavigationStack(embedded: embedded) {
            let stats = makeStats()
            let prev = makeStats(offsetDays: 7)
            let total = stats.reduce(0) { $0 + $1.workedMinutes }
            let prevTotal = prev.reduce(0) { $0 + $1.workedMinutes }
            let done = stats.reduce(0) { $0 + $1.done }
            let best = stats.max { $0.workedMinutes < $1.workedMinutes }
            List {
                Section {
                    HStack {
                        metric("作業した時間", formatDuration(EpochMs(total) * MINUTE), "timer")
                        Divider()
                        metric("完了", "\(done)件", "checkmark.seal")
                    }
                    .padding(.vertical, 6)
                    // 先週との比べ（増えた・減った）
                    if prevTotal > 0 || total > 0 {
                        let diff = total - prevTotal
                        Label(diff == 0 ? "先週と同じ" : "先週より\(formatDuration(EpochMs(abs(diff)) * MINUTE))\(diff > 0 ? "多い" : "少ない")",
                              systemImage: diff > 0 ? "arrow.up.right" : diff < 0 ? "arrow.down.right" : "equal")
                            .font(.subheadline)
                            .foregroundStyle(diff > 0 ? .green : diff < 0 ? .orange : .secondary)
                    }
                    LabeledContent("1日あたり", value: formatDuration(EpochMs(total / 7) * MINUTE))
                    if let best, best.workedMinutes > 0 {
                        LabeledContent("いちばん進んだ日", value: "\(model.time.dayLabel(best.day))（\(formatDuration(EpochMs(best.workedMinutes) * MINUTE))）")
                    }
                    LabeledContent("予定に使った時間", value: formatDuration(eventMinutes() * MINUTE))
                } header: { Text("直近7日") }

                Section("作業した時間（分）") {
                    Chart(stats) { s in
                        BarMark(x: .value("日", model.time.date(s.day), unit: .day), y: .value("分", s.workedMinutes))
                            .foregroundStyle(Color.accentColor.gradient)
                            .cornerRadius(4)
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                    .frame(height: 180)
                    .accessibilityLabel("直近7日の作業時間")
                }
                Section("余白（予定もタスクも入っていない割合）") {
                    Chart(stats) { s in
                        LineMark(x: .value("日", model.time.date(s.day), unit: .day), y: .value("余白", s.free * 100))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("日", model.time.date(s.day), unit: .day), y: .value("余白", s.free * 100))
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                    .frame(height: 160)
                    .foregroundStyle(.green)
                }
                Section("完了したタスク") {
                    let recent = model.analysisTasks.filter { t in t.isDone && (t.actualEnd ?? t.checkedAt ?? 0) >= model.time.addDays(model.time.startOfDay(model.now), -6) }
                        .sorted { ($0.actualEnd ?? $0.checkedAt ?? 0) > ($1.actualEnd ?? $1.checkedAt ?? 0) }
                    if recent.isEmpty {
                        Text("まだありません").foregroundStyle(.secondary)
                    } else {
                        ForEach(recent, id: \.id) { TaskRow(task: $0) }
                    }
                }
            }
            .navigationTitle("振り返り")
            .toolbar { if !embedded { MainToolbar() } }
        }
    }

    private func metric(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 直近7日の予定（終日を除く）の合計（分）
    private func eventMinutes() -> EpochMs {
        let today = model.time.startOfDay(model.now)
        let from = model.time.addDays(today, -6), to = model.time.addDays(today, 1)
        return model.visibleEvents(from: from, to: to, includeArchived: true).filter { !$0.event.allDay }
            .reduce(0) { $0 + max(0, min($1.end, to) - max($1.start, from)) } / MINUTE
    }

    private func makeStats(offsetDays: Int = 0) -> [DayStat] {
        let today = model.time.addDays(model.time.startOfDay(model.now), -offsetDays)
        let occ = model.visibleEvents(from: model.time.addDays(today, -7), to: model.time.addDays(today, 1), includeArchived: true)
        let busy = busyItems(events: occ, tasks: model.analysisTasks)
        return (0..<7).reversed().map { i in
            let d0 = model.time.addDays(today, -i), d1 = model.time.addDays(d0, 1)
            var worked: EpochMs = 0
            for t in model.analysisTasks {
                for iv in t.intervals {
                    let s = max(iv.start, d0), e = min(iv.end ?? model.now, d1)
                    if e > s { worked += e - s }
                }
            }
            let done = model.analysisTasks.filter { t in
                guard let at = t.status == .done ? t.actualEnd : (t.checked ? t.checkedAt : nil) else { return false }
                return at >= d0 && at < d1
            }.count
            return DayStat(day: d0, workedMinutes: Int(worked / MINUTE), done: done, free: freeRatio(day: d0, busy: busy, fromHour: model.settings.suggestFromHour, toHour: model.settings.suggestToHour, time: model.time))
        }
    }
}
