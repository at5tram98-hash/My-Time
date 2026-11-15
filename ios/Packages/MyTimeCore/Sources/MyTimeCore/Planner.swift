import Foundation

// Web 版 planner.ts の一部（次の行動・空き時間・余白）。提案と検知の全体は段階的に移植する。

public struct BusyItem: Sendable, Equatable {
    public var id: String
    public var title: String
    public var start: EpochMs
    public var end: EpochMs
    public var fixed: Bool
}

/// 時間を使うもの（予定・時刻のあるタスク・移動のバッファ）。完了したタスクは含めない
public func busyItems(events: [EventOccurrence], tasks: [MTTask]) -> [BusyItem] {
    var out: [BusyItem] = []
    for e in events where !e.event.allDay {
        out.append(BusyItem(id: "event:\(e.id)", title: e.title, start: e.start, end: e.end, fixed: true))
        if let tm = e.event.travelMinutes, tm > 0 { out.append(BusyItem(id: "buffer:\(e.id)", title: "移動", start: e.start - EpochMs(tm) * MINUTE, end: e.start, fixed: true)) }
    }
    for t in tasks where t.kind == .do && t.status != .done {
        if let s = t.plannedStart, let e = t.plannedEnd { out.append(BusyItem(id: "task:\(t.id)", title: t.title, start: s, end: e, fixed: false)) }
    }
    return out.sorted { $0.start < $1.start }
}

/// 区間の和（重なりを二重に数えない）。分で返す
public func unionMinutes(_ items: [BusyItem], from: EpochMs, to: EpochMs) -> Int {
    let xs = items.map { (max(from, $0.start), min(to, $0.end)) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
    var total: EpochMs = 0
    var cur: (EpochMs, EpochMs)?
    for x in xs {
        if let c = cur, x.0 <= c.1 { cur = (c.0, max(c.1, x.1)) } else { if let c = cur { total += c.1 - c.0 }; cur = x }
    }
    if let c = cur { total += c.1 - c.0 }
    return Int(total / MINUTE)
}

/// 活動時間帯（既定7〜23時）の余白
public func freeRatio(day: EpochMs, busy: [BusyItem], fromHour: Int = 7, toHour: Int = 23, time: DomainTime = .current) -> Double {
    let win = (toHour - fromHour) * 60
    guard win > 0 else { return 0 }
    let used = unionMinutes(busy, from: time.at(day: day, hour: fromHour), to: time.at(day: day, hour: toHour))
    return Double(win - used) / Double(win)
}

public struct NextAction: Equatable, Sendable {
    public enum Kind: String, Sendable { case `continue`, start, leave, event, plan, free }
    public var kind: Kind
    public var title: String
    public var detail: String
    public var taskId: String?
    public var eventId: String?
    public var at: EpochMs?
}

/// 今やること（Web 版 nextAction と同じ優先順位）
public func nextAction(events: [EventOccurrence], tasks: [MTTask], now: EpochMs, time: DomainTime = .current) -> NextAction {
    if let r = tasks.first(where: { $0.kind == .do && $0.status == .running }) {
        return NextAction(kind: .continue, title: r.title, detail: "実行中", taskId: r.id)
    }
    let due = tasks.filter { $0.kind == .do && $0.status == .notStarted && $0.plannedStart != nil && ($0.plannedEnd ?? 0) > now && $0.plannedStart! <= now + 30 * MINUTE }.min { $0.plannedStart! < $1.plannedStart! }
    let ev = events.filter { !$0.event.allDay && $0.start > now && $0.start < now + 3 * HOUR }.min { $0.start < $1.start }
    if let ev, let tm = ev.event.travelMinutes, tm > 0 {
        let leave = ev.start - EpochMs(tm) * MINUTE
        if leave - now <= 30 * MINUTE && (due == nil || leave <= due!.plannedStart!) {
            return NextAction(kind: .leave, title: ev.title, detail: leave <= now ? "出発の時刻です" : "\(time.hm(leave))に出発（移動\(tm)分）", eventId: ev.id, at: leave)
        }
    }
    if let due { return NextAction(kind: .start, title: due.title, detail: due.plannedStart! <= now ? "\(time.hm(due.plannedStart!))開始の予定" : "\(time.hm(due.plannedStart!))から", taskId: due.id, at: due.plannedStart) }
    if let cur = events.first(where: { !$0.event.allDay && $0.start <= now && $0.end > now }) {
        return NextAction(kind: .event, title: cur.title, detail: "\(time.hm(cur.end))まで", eventId: cur.id, at: cur.end)
    }
    let dayEnd = time.addDays(time.startOfDay(now), 1)
    let upTask = tasks.filter { $0.kind == .do && $0.status == .notStarted && ($0.plannedStart ?? 0) > now && ($0.plannedStart ?? .max) < dayEnd }.min { $0.plannedStart! < $1.plannedStart! }
    var cands: [NextAction] = []
    if let upTask { cands.append(NextAction(kind: .start, title: upTask.title, detail: "\(time.hm(upTask.plannedStart!))から", taskId: upTask.id, at: upTask.plannedStart)) }
    if let ev { cands.append(NextAction(kind: .event, title: ev.title, detail: "\(time.hm(ev.start))から", eventId: ev.id, at: ev.start)) }
    if let c = cands.min(by: { ($0.at ?? 0) < ($1.at ?? 0) }) { return c }
    if let inbox = tasks.filter({ !$0.isDone && $0.kind == .do && $0.plannedStart == nil }).min(by: { ($0.deadline ?? .max) < ($1.deadline ?? .max) }) {
        return NextAction(kind: .plan, title: inbox.title, detail: inbox.deadline.map { "期限 \(time.dayLabel($0))・時間を決めましょう" } ?? "いつやるか決めていません", taskId: inbox.id)
    }
    return NextAction(kind: .free, title: "この後の予定はありません", detail: "自由に過ごせる時間です")
}
