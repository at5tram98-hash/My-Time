import Foundation

// Web 版 packages/domain（time・progress・taskMachine・agenda・layout・recurrence）の移植。
// 同じ入力で同じ結果になるよう、関数の意味と名前をそろえている。

public let MINUTE: EpochMs = 60_000
public let HOUR: EpochMs = 60 * MINUTE
public let DAY: EpochMs = 24 * HOUR

// MARK: - 時刻（暦計算は端末のタイムゾーン。夏時間・月末でも Calendar で正しく求める）

public struct DomainTime: Sendable {
    public var calendar: Calendar
    public init(timeZone: TimeZone = .current) {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "ja_JP")
        calendar = c
    }
    public static let current = DomainTime()

    public func date(_ t: EpochMs) -> Date { Date(timeIntervalSince1970: Double(t) / 1000) }
    public func ms(_ d: Date) -> EpochMs { EpochMs((d.timeIntervalSince1970 * 1000).rounded()) }

    public func startOfDay(_ t: EpochMs) -> EpochMs { ms(calendar.startOfDay(for: date(t))) }
    public func addDays(_ t: EpochMs, _ n: Int) -> EpochMs { ms(calendar.date(byAdding: .day, value: n, to: date(t))!) }
    public func addMonths(_ t: EpochMs, _ n: Int) -> EpochMs { ms(calendar.date(byAdding: .month, value: n, to: date(t))!) }
    /// 0 = 日曜
    public func weekday(_ t: EpochMs) -> Int { calendar.component(.weekday, from: date(t)) - 1 }
    public func isSameDay(_ a: EpochMs, _ b: EpochMs) -> Bool { startOfDay(a) == startOfDay(b) }
    public func minutesOfDay(_ t: EpochMs) -> Int { Int((t - startOfDay(t)) / MINUTE) }
    public func at(day: EpochMs, hour: Int, minute: Int = 0) -> EpochMs {
        let c = calendar.dateComponents([.year, .month, .day], from: date(day))
        return ms(calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day, hour: hour, minute: minute))!)
    }
    public func hm(_ t: EpochMs) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date(t))
        return "\(c.hour ?? 0):\(String(format: "%02d", c.minute ?? 0))"
    }
    /// 「11月15日(日)」
    public func dayLabel(_ t: EpochMs) -> String {
        let c = calendar.dateComponents([.month, .day], from: date(t))
        return "\(c.month ?? 0)月\(c.day ?? 0)日(\(Self.weekdayJa[weekday(t)]))"
    }
    public static let weekdayJa = ["日", "月", "火", "水", "木", "金", "土"]

    public func overlapsDay(_ start: EpochMs, _ end: EpochMs, day: EpochMs) -> Bool {
        let d0 = startOfDay(day), d1 = addDays(d0, 1)
        return start < d1 && max(end, start + 1) > d0
    }
}

public func formatDuration(_ ms: EpochMs) -> String {
    let m = Int(ms / MINUTE)
    return m >= 60 ? "\(m / 60)時間\(m % 60 > 0 ? "\(m % 60)分" : "")" : "\(m)分"
}

// MARK: - 進捗（理想・実績・予測）

private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

/// 予定時間に対する理想進捗。予定がなければ nil
public func idealProgress(_ t: MTTask, now: EpochMs) -> Double? {
    guard let s = t.plannedStart, let e = t.plannedEnd, e > s else { return nil }
    return clamp01(Double(now - s) / Double(e - s))
}

/// 累積作業時間（実行中の区間は now まで）
public func workedMs(_ t: MTTask, at: EpochMs) -> EpochMs {
    var sum: EpochMs = 0
    for iv in t.intervals {
        let end = iv.end ?? at
        let s = min(iv.start, at), e = min(end, at)
        if e > s { sum += e - s }
    }
    return sum
}

public enum ProgressSource: String, Sendable { case subtasks, manual, none }

public struct ActualProgress: Equatable, Sendable {
    public var value: Double?
    public var source: ProgressSource
    public var sampleAt: EpochMs?
}

/// 実績進捗。サブタスクを持つ親はサブタスクだけが根拠
public func actualProgress(_ t: MTTask, subtasks: [MTSubtask]) -> ActualProgress {
    if t.status == .done { return ActualProgress(value: 1, source: subtasks.isEmpty ? .manual : .subtasks, sampleAt: t.actualEnd) }
    if !subtasks.isEmpty {
        let done = subtasks.filter(\.done)
        let last = done.compactMap(\.completedAt).max()
        return ActualProgress(value: Double(done.count) / Double(subtasks.count), source: .subtasks, sampleAt: last)
    }
    if let m = t.manualProgress { return ActualProgress(value: m.value, source: .manual, sampleAt: m.at) }
    return ActualProgress(value: nil, source: .none, sampleAt: nil)
}

public func canScrubProgress(_ t: MTTask, subtasks: [MTSubtask]) -> Bool { t.kind == .do && t.status != .done && subtasks.isEmpty }

public enum Eta: Equatable, Sendable {
    case estimate(EpochMs)
    case unavailable(String)
}

/// 実績の根拠が十分にあるときだけ予測終了を返す（値を作らない）
public func estimateEnd(_ t: MTTask, subtasks: [MTSubtask], now: EpochMs) -> Eta {
    guard t.kind == .do else { return .unavailable("未算出") }
    if t.status == .done { return .unavailable("—") }
    guard t.status == .running else { return .unavailable("未算出") }
    let ap = actualProgress(t, subtasks: subtasks)
    guard let v = ap.value, let at = ap.sampleAt, v > 0 else { return .unavailable("未算出") }
    if v >= 1 { return .unavailable("—") }
    let workedAtSample = ap.source == .manual && t.manualProgress != nil ? EpochMs(t.manualProgress!.workedMsAtSample) : workedMs(t, at: at)
    if workedAtSample < 2 * MINUTE { return .unavailable("算出中") }
    let remaining = Double(workedAtSample) / v - Double(workedMs(t, at: now))
    if remaining <= 0 { return .unavailable("算出中") }
    return .estimate(now + EpochMs(remaining))
}

public struct DelayInfo: Equatable, Sendable { public var delayed: Bool; public var overMinutes: Int }

public func delayInfo(_ t: MTTask, now: EpochMs) -> DelayInfo {
    guard t.kind == .do, t.status != .done, let e = t.plannedEnd, now > e else { return DelayInfo(delayed: false, overMinutes: 0) }
    return DelayInfo(delayed: true, overMinutes: max(1, Int((now - e) / MINUTE)))
}

// MARK: - 状態機械（Web 版 taskMachine.ts と同じ遷移）

public enum TaskAction: String, Sendable { case start, pause, resume, finish, undoFinish, undoStart }

public struct TaskTransitionError: Error, CustomStringConvertible, Equatable {
    public let action: String
    public let status: TaskStatus
    public var description: String { "操作「\(action)」は状態「\(status.rawValue)」では実行できません" }
}

public struct TaskTransition: Sendable {
    public var task: MTTask
    public var action: String
    public var from: TaskStatus
    public var to: TaskStatus
    public var at: EpochMs
    public var detail: [String: JSONValue]
}

public func availableActions(_ t: MTTask) -> [TaskAction] {
    guard t.kind == .do else { return [] }
    switch t.status {
    case .notStarted: return [.start]
    case .running: return t.intervals.count == 1 && !t.pausedEver ? [.pause, .finish, .undoStart] : [.pause, .finish]
    case .paused: return [.resume, .finish]
    case .done: return [.undoFinish]
    }
}

private func closeOpen(_ t: MTTask, _ at: EpochMs) -> [WorkInterval] {
    t.intervals.map { $0.end == nil ? WorkInterval(start: $0.start, end: max($0.start, at)) : $0 }
}

/// 未開始→実行中↔一時停止→完了、と取り消し。完了の取り消しは一時停止に戻す（取り消しまでの時間を作業時間にしない）
public func applyTaskAction(_ t: MTTask, _ action: TaskAction, at: EpochMs) throws -> TaskTransition {
    guard t.kind == .do, availableActions(t).contains(action) else { throw TaskTransitionError(action: action.rawValue, status: t.status) }
    var n = t
    switch action {
    case .start:
        n.status = .running; n.intervals.append(WorkInterval(start: at, end: nil)); n.actualStart = t.actualStart ?? at; n.actualEnd = nil
    case .pause:
        n.status = .paused; n.intervals = closeOpen(t, at); n.pausedEver = true
    case .resume:
        n.status = .running; n.intervals.append(WorkInterval(start: at, end: nil))
    case .finish:
        n.status = .done; n.intervals = closeOpen(t, at); n.actualEnd = at
    case .undoFinish:
        n.status = .paused; n.actualEnd = nil
    case .undoStart:
        n.status = .notStarted; n.intervals = []; n.actualStart = nil; n.actualEnd = nil; n.manualProgress = nil
    }
    n.updatedAt = at
    return TaskTransition(task: n, action: action.rawValue, from: t.status, to: n.status, at: at, detail: [:])
}

public func recordManualProgress(_ t: MTTask, subtasks: [MTSubtask], value: Double, at: EpochMs) throws -> TaskTransition {
    guard t.kind == .do, t.status != .done, subtasks.isEmpty else { throw TaskTransitionError(action: "progress", status: t.status) }
    let v = (clamp01(value) * 100).rounded() / 100
    var n = t
    n.manualProgress = ProgressSample(value: v, at: at, workedMsAtSample: Double(workedMs(t, at: at)))
    n.updatedAt = at
    return TaskTransition(task: n, action: "progress", from: t.status, to: t.status, at: at, detail: ["value": .number(v), "previous": t.manualProgress.map { .number($0.value) } ?? .null])
}

public func toggleCheck(_ t: MTTask, at: EpochMs) throws -> TaskTransition {
    guard t.kind == .check else { throw TaskTransitionError(action: "check", status: t.status) }
    var n = t
    n.checked = !t.checked; n.checkedAt = n.checked ? at : nil; n.status = n.checked ? .done : .notStarted; n.updatedAt = at
    return TaskTransition(task: n, action: n.checked ? "check" : "uncheck", from: t.status, to: n.status, at: at, detail: [:])
}

public func canAddSubtask(_ t: MTTask) -> Bool { t.eventId == nil && t.kind == .do }

// MARK: - 1日の一覧・時間軸

public func taskAnchor(_ t: MTTask) -> EpochMs? { t.kind == .check ? t.checkAt : t.plannedStart }

/// 指定日に時刻指定されたタスク（時刻順）
public func tasksForDay(_ tasks: [MTTask], day: EpochMs, time: DomainTime = .current) -> [MTTask] {
    let d0 = time.startOfDay(day), d1 = time.addDays(d0, 1)
    return tasks.filter { t in
        if t.kind == .check { guard let c = t.checkAt else { return false }; return c >= d0 && c < d1 }
        guard let s = t.plannedStart else { return false }
        return time.overlapsDay(s, t.plannedEnd ?? s, day: d0)
    }.sorted { (taskAnchor($0) ?? 0, $0.createdAt) < (taskAnchor($1) ?? 0, $1.createdAt) }
}

/// 今日の一覧の並び（実行中→一時停止→これから→過ぎた未着手→完了）
public func orderHomeTasks(_ tasks: [MTTask], now: EpochMs) -> [MTTask] {
    func rank(_ t: MTTask) -> Int {
        if t.isDone { return 4 }
        if t.status == .running { return 0 }
        if t.status == .paused { return 1 }
        return (taskAnchor(t) ?? now) >= now ? 2 : 3
    }
    return tasks.sorted { (rank($0), taskAnchor($0) ?? 0, $0.createdAt, $0.id) < (rank($1), taskAnchor($1) ?? 0, $1.createdAt, $1.id) }
}

public struct TimedItem: Sendable, Equatable {
    public var id: String
    public var start: EpochMs
    public var end: EpochMs
    public init(id: String, start: EpochMs, end: EpochMs) { self.id = id; self.start = start; self.end = end }
}

public struct PlacedItem: Sendable, Equatable {
    public var id: String
    /// 日の 0:00 からの分
    public var top: Int
    public var height: Int
    public var column: Int
    public var columns: Int
    public var clippedStart: Bool
    public var clippedEnd: Bool
}

/// 1日の列に並べる。重なるものは横に分ける（Web 版 layoutDay と同じクラスター方式）
public func layoutDay(_ items: [TimedItem], day: EpochMs, minMinutes: Int = 15, time: DomainTime = .current) -> [PlacedItem] {
    let d0 = time.startOfDay(day), d1 = time.addDays(d0, 1)
    let visible = items.filter { $0.start < d1 && max($0.end, $0.start + MINUTE) > d0 }
        .map { it -> (TimedItem, EpochMs, EpochMs, Bool, Bool) in
            let e = max(it.end, it.start + EpochMs(minMinutes) * MINUTE)
            return (it, max(it.start, d0), min(e, d1), it.start < d0, e > d1)
        }
        .sorted { ($0.1, -$0.2) < ($1.1, -$1.2) }
    var result: [PlacedItem] = []
    var cluster: [(TimedItem, EpochMs, EpochMs, Bool, Bool)] = []
    var clusterEnd = EpochMs.min
    func flush() {
        var colEnds: [EpochMs] = []
        var assigned: [(Int, (TimedItem, EpochMs, EpochMs, Bool, Bool))] = []
        for c in cluster {
            if let col = colEnds.firstIndex(where: { $0 <= c.1 }) { colEnds[col] = c.2; assigned.append((col, c)) }
            else { colEnds.append(c.2); assigned.append((colEnds.count - 1, c)) }
        }
        for (col, c) in assigned {
            result.append(PlacedItem(id: c.0.id, top: Int((c.1 - d0) / MINUTE), height: max(minMinutes, Int((c.2 - c.1) / MINUTE)), column: col, columns: colEnds.count, clippedStart: c.3, clippedEnd: c.4))
        }
        cluster = []; clusterEnd = .min
    }
    for v in visible {
        if v.1 >= clusterEnd && !cluster.isEmpty { flush() }
        cluster.append(v); clusterEnd = max(clusterEnd, v.2)
    }
    if !cluster.isEmpty { flush() }
    return result
}

public func overlaps(_ a: TimedItem, _ b: TimedItem) -> Bool { a.start < b.end && b.start < a.end }

// MARK: - 繰り返し（Web 版 recurrence.ts と同じ展開・同じ ID）

public func ruleStarts(_ ev: MTEvent, from: EpochMs, to: EpochMs, time: DomainTime = .current) -> [EpochMs] {
    guard let r = ev.recurrence else { return ev.start < to && ev.end > from ? [ev.start] : [] }
    let dur = ev.end - ev.start
    var out: [EpochMs] = []
    let interval = max(1, r.interval)
    func push(_ s: EpochMs) -> Bool {
        if let u = r.until, s > u { return false }
        if s + dur > from && s < to { out.append(s) }
        return s < to
    }
    if r.freq == .weekly {
        let baseWd = time.weekday(ev.start)
        let days = ((r.byWeekday?.isEmpty == false) ? r.byWeekday! : [baseWd]).sorted()
        let weekStart = time.addDays(ev.start, -baseWd)
        var w = 0
        outer: while w < 3660 {
            for wd in days {
                let s = time.addDays(weekStart, w * 7 + wd)
                if s < ev.start { continue }
                if !push(s) { break outer }
            }
            if let u = r.until, time.addDays(weekStart, w * 7) > u { break }
            w += interval
        }
        return out
    }
    for i in 0..<3660 {
        let s = r.freq == .daily ? time.addDays(ev.start, i * interval) : time.addMonths(ev.start, i * interval)
        if !push(s) { break }
    }
    return out
}

public func expandEvent(_ ev: MTEvent, from: EpochMs, to: EpochMs, time: DomainTime = .current) -> [EventOccurrence] {
    guard ev.recurrence != nil else {
        return ev.start < to && ev.end > from ? [EventOccurrence(id: ev.id, masterId: ev.id, originalStart: nil, event: ev, start: ev.start, end: ev.end, title: ev.title)] : []
    }
    var byStart: [EpochMs: RecurrenceException] = [:]
    for x in ev.exceptions { byStart[x.originalStart] = x }
    let dur = ev.end - ev.start
    return ruleStarts(ev, from: from - 7 * DAY, to: to + 7 * DAY, time: time).compactMap { s in
        let x = byStart[s]
        if let x, x.kind == .cancelled || x.kind == .archived { return nil }
        let start = x?.start ?? s, end = x?.end ?? s + dur
        guard start < to && end > from else { return nil }
        return EventOccurrence(id: "\(ev.id)@\(s)", masterId: ev.id, originalStart: s, event: ev, start: start, end: end, title: x?.title ?? ev.title)
    }
}

public func expandAll(_ events: [MTEvent], from: EpochMs, to: EpochMs, time: DomainTime = .current) -> [EventOccurrence] {
    events.flatMap { expandEvent($0, from: from, to: to, time: time) }.sorted { $0.start < $1.start }
}

public func parseOccurrenceId(_ id: String) -> (masterId: String, originalStart: EpochMs)? {
    guard let at = id.lastIndex(of: "@"), let s = EpochMs(id[id.index(after: at)...]) else { return nil }
    return (String(id[..<at]), s)
}

// MARK: - 取り消し（削除せずに灰色で「取り消し」と出す）
//
// 繰り返しでない予定：`extra.struck = true`。繰り返しの予定：その回だけなら例外（override）に `struck: true`、
// すべての回なら元の予定の `extra.struck`。Web 版は知らない項目を残したまま無視する（予定はそのまま見える）。

public extension MTEvent {
    var isStruckAll: Bool { extra?["struck"]?.boolValue == true }
}

public extension EventOccurrence {
    /// この回が取り消されているか
    var isStruck: Bool {
        if event.isStruckAll { return true }
        guard let s = originalStart else { return false }
        return event.exceptions.first { $0.originalStart == s }?.raw["struck"]?.boolValue == true
    }
}
