import Foundation
import MyTimeCore

/// 翌日計画。前の日に下書きし、「承認」すると本当の予定・タスクになる。
/// 承認した時点の計画は残し、当日の今日の画面の右端に灰色の「計画」として出す（実際と見比べる）。
/// 保存は設定の iosDayPlans（Web 版は知らない項目を無視する）：{ "2026-11-17": { status, approvedAt, items: [...] } }
struct PlanItem: Identifiable, Equatable, Hashable {
    enum Kind: String { case task, event }
    var id: String
    var kind: Kind
    var title: String
    var start: EpochMs
    var end: EpochMs
    /// 予定のときのカレンダー
    var calendarId: String?
    /// 承認で作った予定・タスクの ID
    var refId: String?

    init(id: String, kind: Kind, title: String, start: EpochMs, end: EpochMs, calendarId: String? = nil, refId: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.start = start; self.end = end; self.calendarId = calendarId; self.refId = refId
    }

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue, let s = v["start"]?.intValue, let e = v["end"]?.intValue else { return nil }
        self.id = id
        kind = Kind(rawValue: v["kind"]?.stringValue ?? "task") ?? .task
        title = v["title"]?.stringValue ?? ""
        start = s; end = e
        calendarId = v["calendarId"]?.stringValue
        refId = v["refId"]?.stringValue
    }

    var json: JSONValue {
        .object(["id": .string(id), "kind": .string(kind.rawValue), "title": .string(title), "start": .number(Double(start)), "end": .number(Double(end)),
                 "calendarId": calendarId.map { .string($0) } ?? .null, "refId": refId.map { .string($0) } ?? .null])
    }
}

struct DayPlan: Equatable {
    var items: [PlanItem] = []
    /// draft（下書き）/ approved（承認済み）
    var status = "draft"
    var approvedAt: EpochMs?

    var isApproved: Bool { status == "approved" }

    init(items: [PlanItem] = [], status: String = "draft", approvedAt: EpochMs? = nil) { self.items = items; self.status = status; self.approvedAt = approvedAt }

    init(_ v: JSONValue?) {
        items = (v?["items"]?.arrayValue ?? []).compactMap(PlanItem.init).sorted { $0.start < $1.start }
        status = v?["status"]?.stringValue ?? "draft"
        approvedAt = v?["approvedAt"]?.intValue
    }

    var json: JSONValue {
        .object(["status": .string(status), "approvedAt": approvedAt.map { .number(Double($0)) } ?? .null, "items": .array(items.map(\.json))])
    }
}

extension AppModel {
    static let plansKey = "iosDayPlans"

    func planKey(_ day: EpochMs) -> String {
        let c = time.calendar.dateComponents([.year, .month, .day], from: time.date(day))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// その日の計画（なければ nil）
    func dayPlan(_ day: EpochMs) -> DayPlan? {
        guard let v = settings.raw[Self.plansKey]?[planKey(day)] else { return nil }
        let p = DayPlan(v)
        return p.items.isEmpty && !p.isApproved ? nil : p
    }

    func saveDayPlan(_ day: EpochMs, _ plan: DayPlan?) {
        let key = planKey(day)
        updateSettings { s in
            var all = s.raw[Self.plansKey]?.objectValue ?? [:]
            all[key] = plan?.json
            // 古い計画（30日より前）は片づける
            let cutoff = planKey(time.addDays(time.startOfDay(now), -30))
            for k in all.keys where k < cutoff { all[k] = nil }
            s.raw = s.raw.merging(.object([Self.plansKey: .object(all)]))
        }
    }

    /// 承認：計画を本当の予定・タスクにする（計画そのものは灰色の「計画」として残す）。取り消しは iPhone を振る
    @discardableResult
    func approveDayPlan(_ day: EpochMs) -> Int {
        guard var plan = dayPlan(day), !plan.isApproved else { return 0 }
        let before = plan
        var created: [(PlanItem.Kind, String)] = []
        let ok = perform("計画を承認しました（\(plan.items.count)件）", undo: { [weak self] in
            guard let self else { return }
            for (k, id) in created { if k == .event { try self.repo.deleteEvent(id) } else { try self.repo.deleteTask(id) } }
            self.saveDayPlan(day, before)
        }) {
            for i in plan.items.indices {
                let it = plan.items[i]
                let name = it.title.trimmingCharacters(in: .whitespaces).isEmpty ? "（無題）" : it.title
                if it.kind == .event {
                    let e = MTEvent.make(title: name, calendarId: it.calendarId ?? calendars.first?.id ?? "cal-general", start: it.start, end: it.end, now: now, id: repo.newId())
                    try repo.saveEvent(e, isNew: true)
                    plan.items[i].refId = e.id
                    created.append((.event, e.id))
                } else {
                    var t = MTTask.make(title: name, now: now, id: repo.newId())
                    t.plannedStart = it.start; t.plannedEnd = it.end
                    try repo.saveTask(t, isNew: true)
                    plan.items[i].refId = t.id
                    created.append((.task, t.id))
                }
            }
        }
        guard ok else { return 0 }
        plan.status = "approved"
        plan.approvedAt = now
        saveDayPlan(day, plan)
        return plan.items.count
    }
}
