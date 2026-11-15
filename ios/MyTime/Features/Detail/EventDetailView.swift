import SwiftUI
import MyTimeCore

/// 予定の詳細。繰り返し予定は「この回のみ」「すべて」を選んで削除できる
struct EventDetailView: View {
    /// 単発は予定 ID、繰り返しの回は `masterId@start`
    var occurrenceId: String
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        let parsed = parseOccurrenceId(occurrenceId)
        let masterId = parsed?.masterId ?? occurrenceId
        NavigationStack {
            if let ev = model.events.first(where: { $0.id == masterId }) {
                let start = parsed.map { p in ev.exceptions.first { $0.originalStart == p.originalStart }?.start ?? p.originalStart } ?? ev.start
                let end = start + (ev.end - ev.start)
                List {
                    Section {
                        HStack(spacing: 14) {
                            SpecBadge(type: ev.specType, isEvent: true, size: 44)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ev.title).font(.title3.weight(.semibold))
                                if let def = ev.specType.flatMap({ SPEC_BY_ID[$0] }) { Text(def.name).font(.caption).foregroundStyle(def.tint) }
                                Text(ev.allDay ? "\(model.time.dayLabel(start)) 終日" : "\(model.time.dayLabel(start)) \(model.hm(start))〜\(model.hm(end))")
                                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Section {
                        if let cal = model.calendar(ev.calendarId) {
                            LabeledContent("カレンダー") { Label(cal.name, systemImage: "circle.fill").foregroundStyle(Color(hex: cal.color)) }
                        }
                        if let r = ev.recurrence { LabeledContent("繰り返し", value: recurrenceText(r)) }
                        if let place = ev.placeName { LabeledContent("場所", value: place) }
                        if let m = ev.travelMinutes { LabeledContent("移動", value: "\(m)分前に出発") }
                        if let emp = model.employer(ev.employerId) { LabeledContent("勤務先", value: emp.name) }
                        if ev.specType == .shift, let wage = ev.extra?["spec"]?["details"]?["hourlyWage"]?.doubleValue,
                           let pay = shiftPay(start: start, end: end, hourlyWage: wage, breakMinutes: Int(ev.extra?["spec"]?["details"]?["breakMinutes"]?.intValue ?? 0)) {
                            LabeledContent("見込みの給与", value: yen(pay.pay))
                        }
                    }
                    if !ev.notes.isEmpty { Section("メモ") { Text(ev.notes) } }
                    Section {
                        Button("削除", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                }
                .navigationTitle("予定")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("編集") { router.open(.editor(EditorSeed(kind: .event, eventId: ev.id))) }
                    }
                }
                .confirmationDialog(ev.recurrence == nil ? "「\(ev.title)」を削除しますか？" : "繰り返しの予定です", isPresented: $confirmDelete, titleVisibility: .visible) {
                    if let p = parsed, ev.recurrence != nil {
                        Button("この回のみ削除", role: .destructive) {
                            if model.perform("この回を削除しました", { try model.repo.cancelOccurrence(masterId: p.masterId, originalStart: p.originalStart) }) { dismiss() }
                        }
                    }
                    Button(ev.recurrence == nil ? "削除" : "すべての回を削除", role: .destructive) {
                        let snapshot = ev
                        if model.perform("削除しました", undo: { try model.repo.saveEvent(snapshot, isNew: true) }, { try model.repo.deleteEvent(ev.id) }) { dismiss() }
                    }
                }
            } else {
                ContentUnavailableView("予定が見つかりません", systemImage: "calendar.badge.exclamationmark")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func recurrenceText(_ r: RecurrenceRule) -> String {
        let unit = r.freq == .daily ? "日" : r.freq == .weekly ? "週" : "か月"
        var s = r.interval == 1 ? "毎\(unit == "か月" ? "月" : unit)" : "\(r.interval)\(unit)ごと"
        if let w = r.byWeekday, !w.isEmpty { s += "（" + w.sorted().map { DomainTime.weekdayJa[$0] }.joined(separator: "・") + "）" }
        if let u = r.until { s += "・\(model.time.dayLabel(u))まで" }
        return s
    }
}
