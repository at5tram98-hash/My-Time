import Foundation

// MARK: - 清掃
//
// 保存は設定の `iosCleaning`（場所・箇所・履歴・進行中の清掃）。Web 版は知らない項目を無視する。

public enum CleaningStatus: String, Codable, CaseIterable, Sendable {
    /// 今回清掃した
    case yes
    /// 対象だが、まだ清掃していない
    case no
    /// 今回は清掃しない（完了率の分母に入れない）
    case skip
    public var label: String { self == .yes ? "Yes" : self == .no ? "No" : "対象外" }
}

/// 「times 回 / every unit」（例：週2回 = times 2, every 1, week。月1回 = 1, 1, month。3日に1回 = 1, 3, day）
public struct CleanFrequency: Codable, Hashable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case day, week, month
        public var label: String { self == .day ? "日" : self == .week ? "週" : "か月" }
    }
    public var times: Int
    public var every: Int
    public var unit: Unit
    public init(times: Int = 1, every: Int = 1, unit: Unit) { self.times = max(1, times); self.every = max(1, every); self.unit = unit }

    public var label: String {
        if times == 1 {
            if every == 1 { return unit == .day ? "毎日" : unit == .week ? "週1回" : "月1回" }
            return "\(every)\(unit.label)に1回"
        }
        return every == 1 ? "\(unit == .day ? "1日" : unit == .week ? "週" : "月")\(times)回" : "\(every)\(unit.label)に\(times)回"
    }

    public static let daily = CleanFrequency(unit: .day)
    public static let weekly = CleanFrequency(unit: .week)
    public static let monthly = CleanFrequency(unit: .month)

    /// 前回から次の目標日（1回の間隔）。月の単位で1回のときは暦の月で数える
    public func next(after last: EpochMs, time: DomainTime = .current) -> EpochMs {
        let day = time.startOfDay(last)
        switch unit {
        case .month where times == 1: return time.addMonths(day, every)
        case .month: return time.addDays(day, max(1, (every * 30) / times))
        case .week: return time.addDays(day, max(1, (every * 7) / times))
        case .day: return time.addDays(day, max(1, every / times))
        }
    }
}

public struct CleaningItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var frequency: CleanFrequency?
    public var lastDone: EpochMs?
    public init(id: String = UUID().uuidString, name: String, frequency: CleanFrequency? = nil, lastDone: EpochMs? = nil) { self.id = id; self.name = name; self.frequency = frequency; self.lastDone = lastDone }

    public func nextDue(time: DomainTime = .current) -> EpochMs? {
        guard let f = frequency, let l = lastDone else { return nil }
        return f.next(after: l, time: time)
    }

    /// 目標日を過ぎている日数（未記録で頻度があれば「まだ一度も」として nil）
    public func overdueDays(now: EpochMs, time: DomainTime = .current) -> Int? {
        guard let due = nextDue(time: time) else { return nil }
        let d = Int((time.startOfDay(now) - due) / DAY)
        return d > 0 ? d : 0
    }
}

public struct CleaningArea: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var symbol: String
    public var items: [CleaningItem]
    public init(id: String = UUID().uuidString, name: String, symbol: String, items: [CleaningItem]) { self.id = id; self.name = name; self.symbol = symbol; self.items = items }
}

public struct CleaningSession: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var startedAt: EpochMs
    public var endedAt: EpochMs?
    /// 今回清掃する場所
    public var areaIds: [String]
    /// 箇所ごとの状態（選んだ場所の箇所で、まだ選んでいないものは No として数える）
    public var results: [String: CleaningStatus]
    /// 箇所の名前（履歴を後から見るとき、箇所が改名・削除されても分かるように）
    public var names: [String: String]
    public init(id: String = UUID().uuidString, startedAt: EpochMs, areaIds: [String], results: [String: CleaningStatus] = [:], names: [String: String] = [:]) {
        self.id = id; self.startedAt = startedAt; self.areaIds = areaIds; self.results = results; self.names = names
    }

    /// 選んだ場所の箇所の状態（未選択は No）
    public func statuses(in areas: [CleaningArea]) -> [(item: CleaningItem, status: CleaningStatus)] {
        areas.filter { areaIds.contains($0.id) }.flatMap { $0.items }.map { ($0, results[$0.id] ?? .no) }
    }

    /// 完了率：Yes ÷（Yes + No）。対象外は分母に入れない。対象が無ければ nil
    public static func completion(_ statuses: [CleaningStatus]) -> (done: Int, total: Int, ratio: Double?) {
        let done = statuses.filter { $0 == .yes }.count
        let total = statuses.filter { $0 != .skip }.count
        return (done, total, total == 0 ? nil : Double(done) / Double(total))
    }
}

public struct CleaningBook: Codable, Hashable, Sendable {
    public var areas: [CleaningArea]
    public var history: [CleaningSession]
    public var active: CleaningSession?
    public init(areas: [CleaningArea], history: [CleaningSession] = [], active: CleaningSession? = nil) { self.areas = areas; self.history = history; self.active = active }

    /// 初期テンプレート（あとで自由に追加・削除・並べ替え・改名できる）
    public static func template() -> CleaningBook {
        func area(_ id: String, _ name: String, _ symbol: String, _ items: [(String, CleanFrequency?)]) -> CleaningArea {
            CleaningArea(id: id, name: name, symbol: symbol, items: items.enumerated().map { i, x in CleaningItem(id: "\(id)-\(i)", name: x.0, frequency: x.1) })
        }
        return CleaningBook(areas: [
            area("bath", "浴室", "bathtub.fill", [("浴槽", .daily), ("床", .weekly), ("排水口", CleanFrequency(times: 2, unit: .week)), ("鏡", .weekly), ("壁", .monthly)]),
            area("toilet", "トイレ", "toilet.fill", [("便器", CleanFrequency(times: 2, unit: .week)), ("床", .weekly), ("便座", CleanFrequency(times: 2, unit: .week)), ("洗面部分", .weekly)]),
            area("kitchen", "キッチン", "fork.knife", [("シンク", .daily), ("コンロ", .weekly), ("作業台", .daily), ("排水口", CleanFrequency(times: 2, unit: .week))]),
            area("room", "部屋", "bed.double.fill", [("床", .weekly), ("机", .weekly), ("棚", .monthly), ("窓", .monthly), ("ゴミ箱", .weekly)]),
        ])
    }

    /// 清掃を終える：Yes の箇所は前回清掃日を更新し、履歴に保存する（同じセッションを二度終えても重複しない）
    public mutating func finish(at now: EpochMs) -> CleaningSession? {
        guard var s = active else { return nil }
        s.endedAt = now
        for ai in areas.indices where s.areaIds.contains(areas[ai].id) {
            for ii in areas[ai].items.indices {
                let item = areas[ai].items[ii]
                s.names[item.id] = "\(areas[ai].name)・\(item.name)"
                if s.results[item.id] == nil { s.results[item.id] = .no }
                if s.results[item.id] == .yes { areas[ai].items[ii].lastDone = now }
            }
        }
        history.removeAll { $0.id == s.id }
        history.insert(s, at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        active = nil
        return s
    }

    /// 箇所の履歴（新しい順の、清掃した日）
    public func doneDates(itemId: String) -> [EpochMs] {
        history.compactMap { s in s.results[itemId] == .yes ? s.endedAt : nil }
    }

    /// 場所ごとの達成率：頻度のある箇所のうち、目標日を過ぎていない割合
    public func areaAchievement(_ area: CleaningArea, now: EpochMs, time: DomainTime = .current) -> Double? {
        let targets = area.items.filter { $0.frequency != nil }
        guard !targets.isEmpty else { return nil }
        let ok = targets.filter { i in (i.overdueDays(now: now, time: time) ?? 1) == 0 && i.lastDone != nil }.count
        return Double(ok) / Double(targets.count)
    }

    /// 長いあいだ清掃していない箇所（目標日を過ぎた日数が多い順。一度もない箇所も含む）
    public func neglected(now: EpochMs, time: DomainTime = .current) -> [(area: CleaningArea, item: CleaningItem, overdue: Int?)] {
        areas.flatMap { a in a.items.map { (a, $0) } }
            .filter { _, i in i.frequency != nil && (i.lastDone == nil || (i.overdueDays(now: now, time: time) ?? 0) > 0) }
            .map { a, i in (a, i, i.lastDone == nil ? nil : i.overdueDays(now: now, time: time)) }
            .sorted { ($0.overdue ?? .max) > ($1.overdue ?? .max) }
    }
}

// MARK: - 朝
//
// 保存は設定の `iosMorning`（アラーム・工程・履歴・進行中の朝）。

public struct MorningAlarm: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var enabled: Bool
    public var hour: Int
    public var minute: Int
    /// 0=日〜6=土。空なら毎日
    public var weekdays: [Int]
    /// アラーム音（アプリに入れた音の名前。nil はシステムの標準）
    public var sound: String?
    /// スヌーズの分（0 はスヌーズなし）
    public var snoozeMinutes: Int
    public var label: String
    public init(id: String = UUID().uuidString, enabled: Bool = true, hour: Int, minute: Int, weekdays: [Int] = [], sound: String? = nil, snoozeMinutes: Int = 5, label: String = "") {
        self.id = id; self.enabled = enabled; self.hour = hour; self.minute = minute; self.weekdays = weekdays; self.sound = sound; self.snoozeMinutes = snoozeMinutes; self.label = label
    }

    /// now より後の次の鳴る時刻
    public func next(after now: EpochMs, time: DomainTime = .current) -> EpochMs? {
        guard enabled else { return nil }
        var day = time.startOfDay(now)
        for _ in 0..<8 {
            let at = time.at(day: day, hour: hour, minute: minute)
            if at > now && (weekdays.isEmpty || weekdays.contains(time.weekday(day))) { return at }
            day = time.addDays(day, 1)
        }
        return nil
    }
}

public struct MorningStep: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// 「顔」「髪」などのまとまり
    public var group: String
    /// 自分で決めた目安（分）。実測が無いときに使うが、実測としては扱わない
    public var plannedMinutes: Int?
    public var enabled: Bool
    public init(id: String = UUID().uuidString, name: String, group: String, plannedMinutes: Int? = nil, enabled: Bool = true) {
        self.id = id; self.name = name; self.group = group; self.plannedMinutes = plannedMinutes; self.enabled = enabled
    }
}

public struct MorningStepRecord: Codable, Hashable, Sendable {
    public var stepId: String
    public var name: String
    public var ms: EpochMs
    public var skipped: Bool
    public init(stepId: String, name: String, ms: EpochMs, skipped: Bool) { self.stepId = stepId; self.name = name; self.ms = ms; self.skipped = skipped }
}

/// 実行中の朝（アプリを閉じても続きから）
public struct MorningRun: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var startedAt: EpochMs
    /// この朝の工程（開始したときの並び。途中で設定を変えても崩れない）
    public var steps: [MorningStep]
    public var index: Int
    public var stepStartedAt: EpochMs
    public var pausedAt: EpochMs?
    /// これまでの一時停止の合計（全体）と、今の工程の一時停止
    public var pausedTotal: EpochMs
    public var stepPaused: EpochMs
    public var records: [MorningStepRecord]
    public var finishedAt: EpochMs?

    public init(id: String = UUID().uuidString, startedAt: EpochMs, steps: [MorningStep]) {
        self.id = id; self.startedAt = startedAt; self.steps = steps; index = 0; stepStartedAt = startedAt
        pausedAt = nil; pausedTotal = 0; stepPaused = 0; records = []; finishedAt = nil
    }

    public var current: MorningStep? { steps.indices.contains(index) ? steps[index] : nil }
    public var next: MorningStep? { steps.indices.contains(index + 1) ? steps[index + 1] : nil }
    public var doneCount: Int { min(index, steps.count) }
    public var isPaused: Bool { pausedAt != nil }

    /// 準備の経過（一時停止を除く）
    public func elapsed(now: EpochMs) -> EpochMs { max(0, (finishedAt ?? pausedAt ?? now) - startedAt - pausedTotal) }
    public func stepElapsed(now: EpochMs) -> EpochMs { max(0, (pausedAt ?? now) - stepStartedAt - stepPaused) }

    public mutating func complete(now: EpochMs, skipped: Bool = false) {
        guard let s = current, finishedAt == nil else { return }
        if isPaused { resume(now: now) }
        records.removeAll { $0.stepId == s.id }
        records.append(MorningStepRecord(stepId: s.id, name: s.name, ms: skipped ? 0 : stepElapsed(now: now), skipped: skipped))
        index += 1
        stepStartedAt = now
        stepPaused = 0
        if index >= steps.count { finishedAt = now }
    }

    public mutating func back(now: EpochMs) {
        guard index > 0 else { return }
        if isPaused { resume(now: now) }
        if finishedAt != nil { finishedAt = nil }
        index -= 1
        let id = steps[index].id
        records.removeAll { $0.stepId == id }
        stepStartedAt = now
        stepPaused = 0
    }

    public mutating func pause(now: EpochMs) { if pausedAt == nil && finishedAt == nil { pausedAt = now } }
    public mutating func resume(now: EpochMs) {
        guard let p = pausedAt else { return }
        pausedTotal += now - p
        stepPaused += now - p
        pausedAt = nil
    }
}

public struct MorningRoutine: Codable, Hashable, Sendable {
    public var alarms: [MorningAlarm]
    public var steps: [MorningStep]
    public var history: [MorningRun]
    public var active: MorningRun?
    /// 出発の何分前に準備を終えたいか（余裕）
    public var bufferMinutes: Int
    public static let maxAlarms = 3

    public init(alarms: [MorningAlarm] = [], steps: [MorningStep], history: [MorningRun] = [], active: MorningRun? = nil, bufferMinutes: Int = 0) {
        self.alarms = alarms; self.steps = steps; self.history = history; self.active = active; self.bufferMinutes = bufferMinutes
    }

    /// 初期の工程（顔9・髪2）
    public static func template() -> MorningRoutine {
        let face = ["コンタクト", "洗顔", "化粧水・乳液", "下地（日焼け止め）", "BBクリーム・PF", "メイクキープパウダー", "ノーズシャドウ", "HR（ハイライト）", "涙袋マーカー"]
        let hair = ["AR（アイロン）", "WSPR（ワックス・スプレー）"]
        return MorningRoutine(steps: face.enumerated().map { MorningStep(id: "face-\($0)", name: $1, group: "顔") }
                              + hair.enumerated().map { MorningStep(id: "hair-\($0)", name: $1, group: "髪") })
    }

    public var enabledSteps: [MorningStep] { steps.filter(\.enabled) }

    /// 工程の並べ替え（from の工程を to の位置へ）
    public mutating func moveStep(from: Int, to: Int) {
        guard steps.indices.contains(from) else { return }
        let s = steps.remove(at: from)
        steps.insert(s, at: max(0, min(steps.count, to)))
    }

    /// アラームを足す（最大3つ）
    @discardableResult
    public mutating func addAlarm(_ a: MorningAlarm) -> Bool {
        guard alarms.count < Self.maxAlarms else { return false }
        alarms.append(a)
        return true
    }

    /// 工程ごとの平均（実測のみ。スキップした回は数えない）。記録が無ければ nil
    public func average(stepId: String) -> (ms: EpochMs, count: Int)? {
        let xs = history.flatMap(\.records).filter { $0.stepId == stepId && !$0.skipped && $0.ms > 0 }.map(\.ms)
        guard !xs.isEmpty else { return nil }
        return (xs.reduce(0, +) / EpochMs(xs.count), xs.count)
    }

    /// 準備にかかる見込み：実測の平均があればそれ、無ければ自分で決めた目安。どちらも無い工程は「未確認」として数を返す
    public func estimate() -> (minutes: Int, measured: Int, planned: Int, unknown: Int) {
        var total: EpochMs = 0, measured = 0, planned = 0, unknown = 0
        for s in enabledSteps {
            if let a = average(stepId: s.id) { total += a.ms; measured += 1 }
            else if let p = s.plannedMinutes { total += EpochMs(p) * MINUTE; planned += 1 }
            else { unknown += 1 }
        }
        return (Int((total + MINUTE / 2) / MINUTE), measured, planned, unknown)
    }

    public mutating func finishActive() {
        guard let r = active, r.finishedAt != nil else { return }
        history.removeAll { $0.id == r.id }
        history.insert(r, at: 0)
        if history.count > 60 { history.removeLast(history.count - 60) }
        active = nil
    }
}

/// 出発の目安。移動時間が分からないときは出発時刻を決めない（根拠のない時刻を出さない）
public struct DeparturePlan: Equatable, Sendable {
    public var eventStart: EpochMs
    public var leaveAt: EpochMs?
    public var prepStartAt: EpochMs?
    public var prepMinutes: Int
    /// 移動時間が未入力
    public var travelUnknown: Bool
    /// 準備の時間に目安も実測も無い工程がある
    public var unknownSteps: Int

    public static func make(eventStart: EpochMs, travelMinutes: Int?, routine: MorningRoutine) -> DeparturePlan {
        let est = routine.estimate()
        guard let travel = travelMinutes, travel > 0 else {
            return DeparturePlan(eventStart: eventStart, leaveAt: nil, prepStartAt: nil, prepMinutes: est.minutes, travelUnknown: true, unknownSteps: est.unknown)
        }
        let leave = eventStart - EpochMs(travel) * MINUTE
        let prep = leave - EpochMs(est.minutes + routine.bufferMinutes) * MINUTE
        return DeparturePlan(eventStart: eventStart, leaveAt: leave, prepStartAt: prep, prepMinutes: est.minutes, travelUnknown: false, unknownSteps: est.unknown)
    }
}

// MARK: - Live Activity の候補と優先度
//
// 端末が実際にどれをダイナミックアイランドに出すかは OS が決める。ここで決めるのは
// 「アプリとしてどれを始めるか・どれを先に並べるか」（表示優先度）だけ。

public enum LiveKind: String, Codable, CaseIterable, Sendable {
    case morning, cleaning, study, shift, classNext, transit, task, checkpoint
    public var label: String {
        switch self {
        case .morning: return "朝の準備"
        case .cleaning: return "清掃"
        case .study: return "勉強"
        case .shift: return "バイト"
        case .classNext: return "次の授業"
        case .transit: return "移動・出発"
        case .task: return "実行中のタスク"
        case .checkpoint: return "チェックポイント"
        }
    }
    /// 既定の重要度（大きいほど先）。自分で進めているもの＞時刻の決まった用事＞その他
    public var basePriority: Int {
        switch self {
        case .morning: return 90
        case .cleaning: return 80
        case .shift: return 75
        case .classNext: return 70
        case .transit: return 72
        case .study: return 60
        case .task: return 50
        case .checkpoint: return 40
        }
    }
}

public struct LiveCandidate: Equatable, Sendable, Identifiable {
    /// 元の予定・タスクから決まる ID（同じものは同じ ID。二重に始めない）
    public var id: String
    public var kind: LiveKind
    /// 表示を始める時刻（含む）と終える時刻（含まない）
    public var showFrom: EpochMs
    public var showUntil: EpochMs
    /// 予定の開始（並べ替えに使う）
    public var start: EpochMs
    public var priority: Int
    public init(id: String, kind: LiveKind, showFrom: EpochMs, showUntil: EpochMs, start: EpochMs, priority: Int? = nil) {
        self.id = id; self.kind = kind; self.showFrom = showFrom; self.showUntil = showUntil; self.start = start; self.priority = priority ?? kind.basePriority
    }
    public func isLive(at now: EpochMs) -> Bool { showFrom <= now && now < showUntil }
}

public enum LivePlanner {
    /// いま出すもの（重要度→開始の早い順）。無効にした種類は除く。limit 件まで
    public static func select(_ cands: [LiveCandidate], now: EpochMs, disabled: Set<LiveKind> = [], limit: Int = 2) -> [LiveCandidate] {
        Array(cands.filter { !disabled.contains($0.kind) && $0.isLive(at: now) }
            .sorted { ($0.priority, -$0.start) > ($1.priority, -$1.start) }
            .prefix(limit))
    }

    /// これから始まるもの（予約開始に使う。同じ ID は1つ）
    public static func upcoming(_ cands: [LiveCandidate], now: EpochMs, disabled: Set<LiveKind> = [], within: EpochMs) -> [LiveCandidate] {
        cands.filter { !disabled.contains($0.kind) && $0.showFrom > now && $0.showFrom < now + within }.sorted { $0.showFrom < $1.showFrom }
    }

    /// 次の授業：まだ終わっていない授業のうち、開始の早いもの（休講＝削除・取り消した回は occurrences に含まれない）
    public static func nextClass(_ occ: [EventOccurrence], isClass: (MTEvent) -> Bool, now: EpochMs, endAfterStartMinutes: Int) -> EventOccurrence? {
        occ.filter { isClass($0.event) && !$0.event.allDay && $0.start + EpochMs(endAfterStartMinutes) * MINUTE > now }
            .min { $0.start < $1.start }
    }
}

// MARK: - 自動削除のきまり

public enum AutoDeleteRules {
    /// 中に残す日数（分析のため）
    public static let retentionDays = 30

    /// タスクの終わり（完了した時刻・予定の終わり・締切のうち分かるもの）
    public static func taskEnd(_ t: MTTask) -> EpochMs? {
        if t.isDone { return t.actualEnd ?? t.checkedAt ?? t.plannedEnd ?? t.updatedAt }
        return t.plannedEnd ?? t.deadline
    }

    /// 終わってから days 日たった予定（繰り返しは除く）
    public static func expiredEvents(_ events: [MTEvent], now: EpochMs, days: Int) -> [String] {
        let cutoff = now - DAY * EpochMs(max(2, days))
        return events.filter { $0.recurrence == nil && $0.end < cutoff }.map(\.id)
    }

    public static func expiredTasks(_ tasks: [MTTask], now: EpochMs, days: Int, includeUnfinished: Bool) -> [String] {
        let cutoff = now - DAY * EpochMs(max(2, days))
        return tasks.filter { t in
            guard let end = taskEnd(t) else { return false }
            return end < cutoff && (t.isDone || includeUnfinished)
        }.map(\.id)
    }

    /// 片づけてから30日たったもの（完全に削除する）
    public static func purgeable(archivedAt: [String: EpochMs], now: EpochMs) -> [String] {
        archivedAt.filter { $0.value < now - DAY * EpochMs(retentionDays) }.map(\.key).sorted()
    }
}
