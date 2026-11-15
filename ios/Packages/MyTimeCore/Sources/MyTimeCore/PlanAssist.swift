import Foundation

// Web 版 planner.ts の「計画の支援」部分の移植。
// - 提案は「変更前→変更後」の差分（PlanChange）を返すだけ。保存はユーザーが承認したときに Repository.applyProposal が行う。
// - 時間が決まった予定は動かさない。動かす候補はタスクと作業枠（日時付きサブタスク）だけ。

public struct PlanOptions: Sendable, Equatable {
    public var fromHour: Int
    public var toHour: Int
    public var stepMin: Int
    public init(fromHour: Int = 7, toHour: Int = 23, stepMin: Int = 15) { self.fromHour = fromHour; self.toHour = toHour; self.stepMin = stepMin }
    public static let `default` = PlanOptions()
}

public struct TimeSlot: Sendable, Equatable {
    public var start: EpochMs
    public var end: EpochMs
    public init(start: EpochMs, end: EpochMs) { self.start = start; self.end = end }
}

func overlaps(_ a: (EpochMs, EpochMs), _ b: (EpochMs, EpochMs)) -> Bool { a.0 < b.1 && b.0 < a.1 }

/// 1日の活動時間帯の空き。after より前は使わない
public func freeSlots(day: EpochMs, busy: [TimeSlot], opts: PlanOptions = .default, after: EpochMs = 0, minMinutes: Int = 15, time: DomainTime = .current) -> [TimeSlot] {
    let d0 = time.startOfDay(day)
    let step = EpochMs(opts.stepMin) * MINUTE
    var from = max(time.at(day: d0, hour: opts.fromHour), after)
    from = d0 + ((from - d0 + step - 1) / step) * step
    let to = opts.toHour >= 24 ? time.addDays(d0, 1) : time.at(day: d0, hour: opts.toHour)
    guard from < to else { return [] }
    let xs = busy.filter { $0.end > from && $0.start < to }.sorted { $0.start < $1.start }
    var out: [TimeSlot] = []
    var cur = from
    for b in xs {
        if b.start > cur { out.append(TimeSlot(start: cur, end: b.start)) }
        cur = max(cur, b.end)
    }
    if cur < to { out.append(TimeSlot(start: cur, end: to)) }
    return out.filter { $0.end - $0.start >= EpochMs(minMinutes) * MINUTE }
}

/// 長さ minutes の空き枠を from 以降・until 以前に count 個まで探す（同じ空きに詰め込まず、次の空きへ）
public func findSlots(minutes: Int, busy: [TimeSlot], from: EpochMs, until: EpochMs, count: Int = 1, opts: PlanOptions = .default, time: DomainTime = .current) -> [TimeSlot] {
    var out: [TimeSlot] = []
    var taken = busy
    let dur = EpochMs(minutes) * MINUTE
    var day = time.startOfDay(from)
    while day < until && out.count < count {
        for s in freeSlots(day: day, busy: taken, opts: opts, after: from, time: time) {
            if s.start + dur <= s.end && s.start + dur <= until {
                let slot = TimeSlot(start: s.start, end: s.start + dur)
                out.append(slot); taken.append(slot)
            }
            if out.count >= count { break }
        }
        day = time.addDays(day, 1)
    }
    return out
}

public extension BusyItem { var slot: TimeSlot { TimeSlot(start: start, end: end) } }
public extension Array where Element == BusyItem { var slots: [TimeSlot] { map(\.slot) } }

// MARK: - 変更の提案

public struct PlanChange: Sendable, Equatable, Identifiable {
    public enum Entity: String, Sendable { case task, event, subtask }
    public var entity: Entity
    public var id: String
    public var title: String
    public var before: (start: EpochMs?, end: EpochMs?)
    public var after: (start: EpochMs?, end: EpochMs?)
    public init(entity: Entity, id: String, title: String, before: (start: EpochMs?, end: EpochMs?), after: (start: EpochMs?, end: EpochMs?)) {
        self.entity = entity; self.id = id; self.title = title; self.before = before; self.after = after
    }
    public static func == (a: PlanChange, b: PlanChange) -> Bool {
        a.entity == b.entity && a.id == b.id && a.before.start == b.before.start && a.before.end == b.before.end && a.after.start == b.after.start && a.after.end == b.after.end
    }
}

public struct NewSession: Sendable, Equatable {
    public var taskId: String
    public var title: String
    public var start: EpochMs
    public var end: EpochMs
}

public struct Proposal: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// なぜこの提案か
    public var reason: String
    public var changes: [PlanChange]
    /// 作業枠（日時付きサブタスク）の追加
    public var sessions: [NewSession] = []
    /// 期限を過ぎる・重なりが残るなどの注意
    public var warnings: [String] = []
    public var alternatives: [Proposal] = []
    public init(id: String, title: String, reason: String, changes: [PlanChange], sessions: [NewSession] = [], warnings: [String] = [], alternatives: [Proposal] = []) {
        self.id = id; self.title = title; self.reason = reason; self.changes = changes; self.sessions = sessions; self.warnings = warnings; self.alternatives = alternatives
    }
}

func taskChange(_ t: MTTask, _ start: EpochMs?, _ end: EpochMs?) -> PlanChange {
    PlanChange(entity: .task, id: t.id, title: t.title, before: (t.plannedStart, t.plannedEnd), after: (start, end))
}

func md(_ t: EpochMs, _ time: DomainTime = .current) -> String {
    let c = time.calendar.dateComponents([.month, .day], from: time.date(t))
    return "\(c.month ?? 0)/\(c.day ?? 0) \(time.hm(t))"
}

func deadlineWarning(_ t: MTTask, _ end: EpochMs?, _ time: DomainTime) -> [String] {
    guard let dl = t.deadline, let end, end > dl else { return [] }
    return ["「\(t.title)」の期限（\(md(dl, time))）より後になります。期限は変更しません"]
}

/// できなかったタスクを別の枠へ（期限は動かさない）。候補を複数返す
public func postponeOptions(_ task: MTTask, busy: [BusyItem], now: EpochMs, opts: PlanOptions = .default, time: DomainTime = .current) -> [Proposal] {
    let minutes: Int = {
        if let s = task.plannedStart, let e = task.plannedEnd { return Int((e - s) / MINUTE) }
        return task.estimateMinutes ?? 30
    }()
    let others = busy.filter { !($0.kind == .task && $0.refId == task.id) }.slots
    var out: [Proposal] = []
    let today0 = time.startOfDay(now)
    if let later = findSlots(minutes: minutes, busy: others, from: now, until: time.addDays(today0, 1), opts: opts, time: time).first {
        out.append(Proposal(id: "postpone:\(task.id):later", title: "今日の\(time.hm(later.start))から", reason: "今日の空き時間のうち、いちばん早い\(minutes)分の枠です", changes: [taskChange(task, later.start, later.end)], warnings: deadlineWarning(task, later.end, time)))
    }
    let tomorrow = time.addDays(today0, 1)
    var sameTime: TimeSlot?
    if let ps = task.plannedStart {
        let s = time.at(day: tomorrow, hour: 0, minute: time.minutesOfDay(ps))
        sameTime = TimeSlot(start: s, end: s + EpochMs(minutes) * MINUTE)
    }
    var tmr: TimeSlot?
    var tmrSame = false
    if let st = sameTime, !others.contains(where: { overlaps(($0.start, $0.end), (st.start, st.end)) }) { tmr = st; tmrSame = true }
    else { tmr = findSlots(minutes: minutes, busy: others, from: tomorrow, until: time.addDays(tomorrow, 1), opts: opts, time: time).first }
    if let tmr {
        out.append(Proposal(id: "postpone:\(task.id):tomorrow", title: "明日の\(time.hm(tmr.start))から", reason: tmrSame ? "明日の同じ時刻が空いています" : "明日の空き時間のうち、いちばん早い枠です", changes: [taskChange(task, tmr.start, tmr.end)], warnings: deadlineWarning(task, tmr.end, time)))
    }
    out.append(Proposal(id: "postpone:\(task.id):inbox", title: "日時を外して「未割当」へ", reason: "いつやるかを後で決めます（期限はそのまま）", changes: [taskChange(task, nil, nil)]))
    return out
}

/// 作業時間を複数の作業枠（日時付きサブタスク）に分けて、期限までの空きに置く
public func sessionsProposal(_ task: MTTask, totalMinutes: Int, sessionMinutes: Int, busy: [BusyItem], now: EpochMs, until: EpochMs?, opts: PlanOptions = .default, time: DomainTime = .current) -> Proposal? {
    guard totalMinutes > 0, sessionMinutes > 0 else { return nil }
    let n = max(1, Int(ceil(Double(totalMinutes) / Double(sessionMinutes))))
    let limit = until ?? time.addDays(time.startOfDay(now), 14)
    let per = Int(ceil(Double(totalMinutes) / Double(n) / 15)) * 15
    let slots = findSlots(minutes: per, busy: busy.slots, from: now, until: limit, count: n, opts: opts, time: time)
    guard !slots.isEmpty else { return nil }
    let names = sessionNames(n)
    return Proposal(
        id: "sessions:\(task.id)", title: "\(per)分×\(slots.count)回に分けて置く",
        reason: "残り\(totalMinutes)分を\(until.map { "期限（\(md($0, time))）までの" } ?? "2週間以内の")空き時間に、間を空けて置きます",
        changes: [],
        sessions: slots.enumerated().map { NewSession(taskId: task.id, title: names[safe: $0.offset] ?? "作業\($0.offset + 1)", start: $0.element.start, end: $0.element.end) },
        warnings: slots.count < n ? ["期限までに置けた作業枠は\(slots.count)/\(n)回です。残りは手動で決めてください"] : []
    )
}

func sessionNames(_ n: Int) -> [String] {
    n == 1 ? ["作業"] : (0..<n).map { $0 == 0 ? "着手" : $0 == n - 1 ? "見直し" : "続き\($0)" }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// 1日の再計画。終わっていない・過ぎた・重なったタスクを、今より後の空きに順番に置き直す（予定は固定）
public func replanDay(_ day: EpochMs, events: [EventOccurrence], tasks: [MTTask], subtasks: [MTSubtask], now: EpochMs, filter: ((MTTask) -> Bool)? = nil, opts: PlanOptions = .default, time: DomainTime = .current) -> Proposal {
    let d0 = time.startOfDay(day), d1 = time.addDays(d0, 1)
    let target = tasks
        .filter { $0.kind == .do && $0.status == .notStarted && $0.plannedStart != nil && $0.plannedEnd != nil && $0.plannedStart! < d1 && $0.plannedEnd! > d0 }
        .filter { filter?($0) ?? true }
        .sorted { $0.plannedStart! < $1.plannedStart! }
    let busy = busyItems(events: events, tasks: tasks, subtasks: subtasks)
    let fixed = busy.filter(\.fixed)
    let keep = busy.filter { b in !b.fixed && !target.contains { b.kind == .task && b.refId == $0.id } }
    let need: (MTTask) -> Bool = { t in
        t.plannedEnd! <= now || t.plannedStart! < now || fixed.contains { overlaps(($0.start, $0.end), (t.plannedStart!, t.plannedEnd!)) } || filter != nil
    }
    let moving = target.filter(need)
    var placed = (fixed + keep).slots
    var changes: [PlanChange] = []
    var warnings: [String] = []
    let startFrom = max(now, d0)
    for t in moving {
        let minutes = Int((t.plannedEnd! - t.plannedStart!) / MINUTE)
        guard let slot = findSlots(minutes: minutes, busy: placed, from: startFrom, until: d1, opts: opts, time: time).first
                ?? findSlots(minutes: minutes, busy: placed, from: d1, until: time.addDays(d1, 1), opts: opts, time: time).first else {
            warnings.append("「\(t.title)」を置ける空きが今日・明日にありません"); continue
        }
        placed.append(slot)
        changes.append(taskChange(t, slot.start, slot.end))
        warnings += deadlineWarning(t, slot.end, time)
    }
    var alts: [Proposal] = []
    if !moving.isEmpty {
        var p2 = (fixed + keep).slots
        var ch: [PlanChange] = []
        for t in moving {
            let minutes = Int((t.plannedEnd! - t.plannedStart!) / MINUTE)
            if let s = findSlots(minutes: minutes, busy: p2, from: d1, until: time.addDays(d1, 1), opts: opts, time: time).first { p2.append(s); ch.append(taskChange(t, s.start, s.end)) }
        }
        if !ch.isEmpty {
            alts.append(Proposal(id: "replan:\(d0):tomorrow", title: "明日に回す", reason: "今日は予定どおりの時間を空けておき、明日の空きに置きます", changes: ch,
                                 warnings: moving.flatMap { t in deadlineWarning(t, ch.first { $0.id == t.id }?.after.end, time) }))
        }
    }
    return Proposal(id: "replan:\(d0)", title: changes.isEmpty ? "置き直すタスクはありません" : "\(changes.count)件を空き時間に置き直す",
                    reason: "時間の決まった予定は動かさず、終わっていないタスクを今より後の空きに順番に置きます", changes: changes, warnings: warnings, alternatives: alts)
}

/// 指定した分だけずらす差分と、つながっている準備タスク・重なりの影響
public func shiftProposal(entity: PlanChange.Entity, id: String, title: String, start: EpochMs, end: EpochMs, deltaMin: Int, tasks: [MTTask], busy: [BusyItem]) -> Proposal {
    let d = EpochMs(deltaMin) * MINUTE
    var changes = [PlanChange(entity: entity, id: id, title: title, before: (start, end), after: (start + d, end + d))]
    if entity == .event {
        for t in tasks where t.sourceEventId == id && t.plannedStart != nil && t.plannedEnd != nil && t.status == .notStarted {
            changes.append(taskChange(t, t.plannedStart! + d, t.plannedEnd! + d))
        }
    }
    let moved = Set(changes.map(\.id))
    var hits: [String] = []
    for c in changes {
        for b in busy where !moved.contains(b.refId) && b.kind != .buffer && overlaps((b.start, b.end), (c.after.start!, c.after.end!)) && !hits.contains(b.title) { hits.append(b.title) }
    }
    return Proposal(id: "shift:\(id):\(deltaMin)", title: deltaMin > 0 ? "\(deltaMin)分遅らせる" : "\(-deltaMin)分早める",
                    reason: changes.count > 1 ? "つながっている準備\(changes.count - 1)件も同じだけ動かします" : "対象だけを動かします", changes: changes,
                    warnings: hits.map { "「\($0)」と重なります" })
}

/// 予定の前に並べる準備：開始（移動を引いた時刻）の直前から逆に並べる
public func prepBefore(eventStart: EpochMs, travelMinutes: Int?, items: [(title: String, minutes: Int)]) -> [(title: String, start: EpochMs, end: EpochMs)] {
    var end = eventStart - EpochMs(travelMinutes ?? 0) * MINUTE
    var out: [(title: String, start: EpochMs, end: EpochMs)] = []
    for it in items.reversed() {
        let start = end - EpochMs(it.minutes) * MINUTE
        out.insert((it.title, start, end), at: 0)
        end = start
    }
    return out
}

// MARK: - 問題の検知

public struct PlanIssue: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case overlap, duplicate, travel, lateRisk, deadline, unplanned, overload, dependency }
    public enum Severity: Int, Sendable, Comparable { case alert = 0, warn = 1, info = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public var id: String
    public var kind: Kind
    public var severity: Severity
    public var title: String
    public var reason: String
    /// 根拠が確かか（移動時間が未入力などは false）
    public var confident: Bool
    public var taskIds: [String]
    public var eventIds: [String]
    public var proposals: [Proposal]
}

public func detectIssues(events: [EventOccurrence], tasks: [MTTask], subtasks: [MTSubtask], now: EpochMs, from: EpochMs, to: EpochMs, opts: PlanOptions = .default, time: DomainTime = .current) -> [PlanIssue] {
    var out: [PlanIssue] = []
    let busy = busyItems(events: events, tasks: tasks, subtasks: subtasks)
    let evs = events.filter { !$0.event.allDay && $0.end > from && $0.start < to && $0.end > now - 6 * HOUR }.sorted { $0.start < $1.start }

    // 二重登録
    var dupKeys = Set<String>()
    for i in evs.indices {
        for j in (i + 1)..<evs.count {
            let a = evs[i], b = evs[j]
            if b.start > a.end { break }
            let sameTime = a.start == b.start && a.end == b.end
            let shiftA = a.event.specType == .shift, shiftB = b.event.specType == .shift
            let wp = { (e: EventOccurrence) in e.event.employerId ?? e.event.extra?["spec"]?["details"]?["workplace"]?.stringValue }
            let sameShift = shiftA && shiftB && overlaps((a.start, a.end), (b.start, b.end)) && wp(a) == wp(b)
            if (sameTime && a.title.trimmingCharacters(in: .whitespaces) == b.title.trimmingCharacters(in: .whitespaces)) || sameShift {
                let k = [a.id, b.id].sorted().joined(separator: "|")
                if dupKeys.contains(k) { continue }
                dupKeys.insert(k)
                out.append(PlanIssue(id: "dup:\(k)", kind: .duplicate, severity: .warn, title: "「\(a.title)」が二重に登録されている可能性",
                                     reason: sameShift ? "同じ勤務先の勤務が同じ時間に2件あります（給与の見込みは1回分だけ数えます）" : "同じタイトル・同じ時間の予定が2件あります",
                                     confident: true, taskIds: [], eventIds: [a.id, b.id], proposals: []))
            }
        }
    }
    // 予定どうしの重なり（自動では動かさない）
    for i in evs.indices {
        for j in (i + 1)..<evs.count {
            let a = evs[i], b = evs[j]
            if b.start >= a.end { break }
            let k = [a.id, b.id].sorted().joined(separator: "|")
            if dupKeys.contains(k) { continue }
            out.append(PlanIssue(id: "ovl:\(k)", kind: .overlap, severity: .warn, title: "「\(a.title)」と「\(b.title)」が重なっています",
                                 reason: "\(time.hm(b.start))〜\(time.hm(min(a.end, b.end)))が重なります。時間の決まった予定は自動で動かしません",
                                 confident: true, taskIds: [], eventIds: [a.id, b.id], proposals: []))
        }
    }
    // タスクと予定の重なり → タスクだけを空きへ動かす提案
    for t in tasks where t.kind == .do && t.status == .notStarted {
        guard let s = t.plannedStart, let e = t.plannedEnd, e > now, s < to, e > from else { continue }
        guard let hit = evs.first(where: { $0.id != t.eventId && overlaps(($0.start, $0.end), (s, e)) }) else { continue }
        let minutes = Int((e - s) / MINUTE)
        let others = busy.filter { !($0.kind == .task && $0.refId == t.id) }.slots
        let slots = findSlots(minutes: minutes, busy: others, from: max(now, time.startOfDay(s)), until: time.addDays(time.startOfDay(s), 2), count: 2, opts: opts, time: time)
        out.append(PlanIssue(id: "tovl:\(t.id)", kind: .overlap, severity: .warn, title: "「\(t.title)」が「\(hit.title)」と重なっています",
                             reason: "予定の時間にはタスクを進めにくいため、空き時間への移動を提案します", confident: true, taskIds: [t.id], eventIds: [hit.id],
                             proposals: slots.enumerated().map { i, sl in
                                 Proposal(id: "tovl:\(t.id):\(i)", title: "\(md(sl.start, time))〜\(time.hm(sl.end))へ移す", reason: i == 0 ? "重ならない最初の空きです" : "別の候補です",
                                          changes: [taskChange(t, sl.start, sl.end)], warnings: deadlineWarning(t, sl.end, time))
                             }))
    }
    // 移動時間の不足
    if evs.count > 1 {
        for i in 1..<evs.count {
            let prev = evs[i - 1], next = evs[i]
            if next.start <= now || next.start < prev.end { continue }
            let gap = Int((next.start - prev.end) / MINUTE)
            if gap > 180 { continue }
            let pa = prev.event.placeName ?? "", pb = next.event.placeName ?? ""
            if let travel = next.event.travelMinutes, travel > gap {
                out.append(PlanIssue(id: "travel:\(prev.id):\(next.id)", kind: .travel, severity: .alert, title: "「\(next.title)」に間に合わない恐れ",
                                     reason: "「\(prev.title)」の終了から\(gap)分しかありません（移動に\(travel)分）", confident: true, taskIds: [], eventIds: [prev.id, next.id], proposals: []))
            } else if next.event.travelMinutes == nil, !pa.isEmpty, !pb.isEmpty, pa != pb, gap < 60 {
                out.append(PlanIssue(id: "travel?:\(prev.id):\(next.id)", kind: .travel, severity: .info, title: "「\(next.title)」までの移動時間が未入力",
                                     reason: "場所が「\(pa)」から「\(pb)」に変わり、間が\(gap)分です。経路が分からないため確かではありません", confident: false, taskIds: [], eventIds: [next.id], proposals: []))
            }
        }
    }
    // 遅れているタスクが次の予定にかかる
    for t in tasks where t.kind == .do && t.status == .running {
        let subs = subtasks.filter { $0.taskId == t.id }
        let eta = estimateEnd(t, subtasks: subs, now: now)
        var end: EpochMs?
        if case .estimate(let at) = eta { end = at } else if delayInfo(t, now: now).delayed { end = now }
        guard let end else { continue }
        if let next = evs.first(where: { $0.start > now && $0.start < end + EpochMs($0.event.travelMinutes ?? 0) * MINUTE }) {
            let isEst: Bool = { if case .estimate = eta { return true }; return false }()
            out.append(PlanIssue(id: "late:\(t.id):\(next.id)", kind: .lateRisk, severity: .warn, title: "「\(t.title)」が「\(next.title)」にかかりそう",
                                 reason: isEst ? "実績から見た終了の見込みは\(time.hm(end))です" : "予定の終了を過ぎて続いています", confident: isEst, taskIds: [t.id], eventIds: [next.id], proposals: []))
        }
    }
    // 期限に対して時間が足りない・まだ作業時間を決めていない
    for t in tasks where !t.isDone {
        guard let dl = t.deadline, dl > now, dl <= to + 14 * DAY, let est = t.estimateMinutes else { continue }
        let rem = max(0, est - Int(workedMs(t, at: now) / MINUTE))
        if rem == 0 { continue }
        var planned = 0
        if let s = t.plannedStart, let e = t.plannedEnd, e > now { planned += Int((e - max(now, s)) / MINUTE) }
        for s in subtasks where s.taskId == t.id && !s.done {
            if let a = s.plannedStart, let b = s.plannedEnd, b > now { planned += Int((b - max(now, a)) / MINUTE) }
        }
        let days = max(1, Int(ceil(Double(dl - time.startOfDay(now)) / Double(DAY))))
        let free = (0..<days).flatMap { freeSlots(day: time.addDays(time.startOfDay(now), $0), busy: busy.slots, opts: opts, after: now, time: time) }
            .filter { $0.start < dl }.reduce(0) { $0 + Int((min($1.end, dl) - $1.start) / MINUTE) }
        let needMore = rem - planned
        if needMore <= 0 { continue }
        let p = sessionsProposal(t, totalMinutes: needMore, sessionMinutes: min(60, needMore), busy: busy, now: now, until: dl, opts: opts, time: time)
        if free + planned < rem {
            out.append(PlanIssue(id: "dl:\(t.id)", kind: .deadline, severity: .alert, title: "「\(t.title)」は期限までに時間が足りない見込み",
                                 reason: "残りの作業\(rem)分（見込み）に対し、期限までの空きは約\(free)分です。期限は変えません", confident: false, taskIds: [t.id], eventIds: [], proposals: p.map { [$0] } ?? []))
        } else if dl - now < 3 * DAY {
            out.append(PlanIssue(id: "plan:\(t.id)", kind: .unplanned, severity: .warn, title: "「\(t.title)」の作業時間がまだ決まっていません",
                                 reason: "期限（\(md(dl, time))）まで\(Int(ceil(Double(dl - now) / Double(DAY))))日、残り\(needMore)分（見込み）を空き時間に置けます", confident: true, taskIds: [t.id], eventIds: [], proposals: p.map { [$0] } ?? []))
        }
    }
    // 前のタスクが終わっていない
    let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    for t in tasks where !t.isDone {
        let deps = (t.extra?["dependsOn"]?.arrayValue ?? []).compactMap { $0.stringValue }.compactMap { byId[$0] }.filter { !$0.isDone }
        guard !deps.isEmpty, let s = t.plannedStart, s < to, s >= from else { continue }
        out.append(PlanIssue(id: "dep:\(t.id)", kind: .dependency, severity: .info, title: "「\(t.title)」の前に終えるタスクがあります",
                             reason: deps.map { "「\($0.title)」" }.joined(separator: "、") + "が未完了です", confident: true, taskIds: [t.id] + deps.map(\.id), eventIds: [], proposals: []))
    }
    // 詰め込み（活動時間の85%超）
    var d = time.startOfDay(from)
    while d < to {
        let win = (opts.toHour - opts.fromHour) * 60
        let dayEnd = opts.toHour >= 24 ? time.addDays(d, 1) : time.at(day: d, hour: opts.toHour)
        let used = unionMinutes(busy, from: time.at(day: d, hour: opts.fromHour), to: dayEnd)
        if win > 0, Double(used) / Double(win) > 0.85 {
            let c = time.calendar.dateComponents([.month, .day], from: time.date(d))
            out.append(PlanIssue(id: "load:\(d)", kind: .overload, severity: .info, title: "\(c.month ?? 0)/\(c.day ?? 0)は予定が詰まっています",
                                 reason: "\(opts.fromHour)〜\(opts.toHour)時の\(Int((Double(used) / Double(win) * 100).rounded()))%が埋まっています。休む時間も残しましょう", confident: true, taskIds: [], eventIds: [], proposals: []))
        }
        d = time.addDays(d, 1)
    }
    return out.enumerated().sorted { ($0.element.severity, $0.offset) < ($1.element.severity, $1.offset) }.map(\.element)
}
