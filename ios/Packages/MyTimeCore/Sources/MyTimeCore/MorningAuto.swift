import Foundation

// MARK: - 朝の自動配置
//
// その日の最初の（時刻のある・取り消していない）予定の2時間前に「朝の準備」のタスクを置く。
// - 自動で置いたタスクは `extra.autoMorning = { day, placedAt }`。予定が動けば朝もついていく
// - 自分で動かした・始めた・終えた朝は、それ以上動かさない（placedAt と今の開始が違えば手で動かしたと見なす）
// - 自分で朝のタスクを入れている日、朝を削除した日（設定の `autoMorningSkip`）は置かない
// - 予定がなくなった日は、まだ始めていない自動の朝を外す

public enum MorningAuto {
    /// 最初の予定の何分前に始めるか
    public static let leadMinutes = 120
    /// これより早い時刻には置かない（最初の予定が深夜・早朝のとき）
    public static let earliestHour = 4

    /// その日の最初の時刻のある予定の開始（終日・取り消しを除く。その日に始まるものだけ）
    public static func anchor(day: EpochMs, events: [EventOccurrence], time: DomainTime = .current) -> EpochMs? {
        let d0 = time.startOfDay(day), d1 = time.addDays(d0, 1)
        return events.filter { !$0.event.allDay && !$0.isStruck && $0.start >= d0 && $0.start < d1 }.map(\.start).min()
    }

    /// 朝の時間（開始＝最初の予定の2時間前。長さは工程の見込み、15〜120分）。早すぎる時は nil
    public static func slot(anchor: EpochMs, minutes: Int, day: EpochMs, time: DomainTime = .current) -> (start: EpochMs, end: EpochMs)? {
        let s = anchor - EpochMs(leadMinutes) * MINUTE
        guard s >= time.startOfDay(day) + EpochMs(earliestHour) * HOUR else { return nil }
        let len = EpochMs(max(15, min(120, minutes))) * MINUTE
        return (s, min(s + len, anchor))
    }

    static func dayKey(_ t: MTTask) -> EpochMs? { t.extra?["autoMorning"]?["day"]?.intValue }
    static func placedAt(_ t: MTTask) -> EpochMs? { t.extra?["autoMorning"]?["placedAt"]?.intValue }
}

public extension MTTask {
    /// 自動で置いた朝か
    var isAutoMorning: Bool { extra?["autoMorning"] != nil }
}

public extension Repository {
    /// 朝を削除した日は、その日はもう自動で置かない
    func skipAutoMorning(day: EpochMs, time: DomainTime = .current) {
        let d0 = time.startOfDay(day)
        updateSettings { s in
            var xs = (s.raw["autoMorningSkip"]?.arrayValue ?? []).compactMap(\.intValue).filter { $0 >= d0 - 30 * DAY }
            if !xs.contains(d0) { xs.append(d0) }
            s.raw = s.raw.merging(.object(["autoMorningSkip": .array(xs.map { .number(Double($0)) })]))
        }
    }

    func isAutoMorningSkipped(day: EpochMs, time: DomainTime = .current) -> Bool {
        let d0 = time.startOfDay(day)
        return (settings().raw["autoMorningSkip"]?.arrayValue ?? []).contains { $0.intValue == d0 }
    }

    /// その日の朝を置き直す。置いた・動かした・外したタスクを返す（何もしなければ nil）
    @discardableResult
    func autoPlaceMorning(day: EpochMs, events: [EventOccurrence], minutes: Int, time: DomainTime = .current) throws -> MTTask? {
        let d0 = time.startOfDay(day), d1 = time.addDays(d0, 1)
        let all = tasks()
        let autos = all.filter { $0.isAutoMorning && MorningAuto.dayKey($0) == d0 }
        // 自分で入れた朝がその日にあれば、自動では置かない
        let manual = all.contains { t in
            t.specType == .morning && !t.isAutoMorning && (t.plannedStart.map { $0 >= d0 && $0 < d1 } ?? false)
        }
        let target = manual || isAutoMorningSkipped(day: d0, time: time) ? nil
            : MorningAuto.anchor(day: d0, events: events, time: time).flatMap { MorningAuto.slot(anchor: $0, minutes: minutes, day: d0, time: time) }

        if let auto = autos.first {
            // 始めた・終えた・手で動かした朝はそのまま
            guard auto.status == .notStarted, auto.plannedStart == MorningAuto.placedAt(auto) else { return nil }
            guard let target else {
                try deleteTask(auto.id, byUser: false)
                return auto
            }
            guard auto.plannedStart != target.start || auto.plannedEnd != target.end else { return nil }
            var t = auto
            t.plannedStart = target.start
            t.plannedEnd = target.end
            t.extra = (t.extra ?? .object([:])).merging(.object(["autoMorning": .object(["day": .number(Double(d0)), "placedAt": .number(Double(target.start))])]))
            try saveTask(t, isNew: false)
            return t
        }
        guard let target else { return nil }
        var t = MTTask.make(title: "朝の準備", now: clock(), id: newId(), timeZone: time.calendar.timeZone.identifier)
        t.icon = "sun"
        t.plannedStart = target.start
        t.plannedEnd = target.end
        t.extra = .object([
            "spec": .object(["type": .string(SpecTypeId.morning.rawValue), "details": .object([:])]),
            "autoMorning": .object(["day": .number(Double(d0)), "placedAt": .number(Double(target.start))]),
        ])
        try saveTask(t, isNew: true)
        return t
    }
}

// MARK: - 起床アラームの自動設定（2つまで）
//
// 家を出る時刻（最初の予定 − 移動時間。移動が無ければ予定の開始）から、朝の準備の見込みを引いた時刻を「起きる時刻」にする。
// 1つ目はその10分前、2つ目は起きる時刻ちょうど。自動のアラームは名前を「自動」で始め、次の朝の曜日だけで鳴らす。

public extension MorningAuto {
    static let autoLabelPrefix = "自動"
        /// 起きてから準備を始めるまでの余裕（分）。ゆとりを持って30分
    static let wakeMargin = 30
    /// 1つ目のアラームは起きる時刻の何分前か
    static let firstAlarmLead = 15

    /// 起きる時刻（その日の0時からの分）。早すぎる・遅すぎる（4時より前・12時より後）は nil
    static func wakeMinute(firstStart: EpochMs, travelMinutes: Int?, prepMinutes: Int, day: EpochMs, time: DomainTime = .current) -> Int? {
        let leave = firstStart - EpochMs(max(0, travelMinutes ?? 0)) * MINUTE
        let wake = leave - EpochMs(max(15, prepMinutes) + wakeMargin) * MINUTE
        guard time.isSameDay(wake, day) else { return nil }
        let m = time.minutesOfDay(wake) / 5 * 5
        return (4 * 60...12 * 60).contains(m) ? m : nil
    }

    /// 自動のアラームを入れ替えた並び（自分で作ったアラームはそのまま。合わせて最大3つ）
    static func applyWakeAlarms(_ routine: MorningRoutine, wakeMinute: Int?, weekday: Int) -> MorningRoutine {
        var r = routine
        let manual = r.alarms.filter { !$0.label.hasPrefix(autoLabelPrefix) }
        var autos: [MorningAlarm] = []
        if let w = wakeMinute {
            let first = max(0, w - 10)
            autos = [
                MorningAlarm(id: "auto-wake-1", hour: first / 60, minute: first % 60, weekdays: [weekday], snoozeMinutes: 5, label: "\(autoLabelPrefix)・1つ目"),
                MorningAlarm(id: "auto-wake-2", hour: w / 60, minute: w % 60, weekdays: [weekday], snoozeMinutes: 5, label: "\(autoLabelPrefix)・起きる時刻"),
            ]
            // 前のアラームの音・オンオフの選び方は引き継ぐ
            for i in autos.indices {
                if let old = r.alarms.first(where: { $0.id == autos[i].id }) { autos[i].sound = old.sound; autos[i].enabled = old.enabled }
            }
        }
        // 自動のアラームを先に（2つは必ず入るように、自分のアラームは後ろ。合わせて3つまで）
        r.alarms = autos + manual.prefix(max(0, MorningRoutine.maxAlarms - autos.count))
        return r
    }

    /// 自動に切り替えたとき：自分で作ったアラームはオフにして残す（消さない。あとでオンにもできる）
    static func turnOffManualAlarms(_ routine: MorningRoutine) -> MorningRoutine {
        var r = routine
        for i in r.alarms.indices where !r.alarms[i].label.hasPrefix(autoLabelPrefix) { r.alarms[i].enabled = false }
        return r
    }
}


// MARK: - 起床アラームの自動（これから7日分。1回ずつのアラーム）
//
// 起きる時刻 = 最初の予定 − 移動時間 − 準備の見込み − 余裕30分。
// 1つ目は起きる時刻の15分前、2つ目は起きる時刻ちょうど。予定が変わるたびに計算し直して、予約を入れ替える。
// 曜日ごとのくり返しにしないので、アプリを開かなくても毎朝その日の予定に合った時刻で鳴る。

public struct WakeAlarm: Equatable, Hashable, Sendable {
    /// 予約の鍵（その日・何番目か・時刻。時刻が変われば別の鍵になり、古い予約は取り消される）
    public var key: String
    public var at: EpochMs
    public var label: String
    public var day: EpochMs
    public var first: Bool
}

public extension MorningAuto {
    /// 7日分の自動の起床アラーム。firstOf は、その日の最初の予定（開始と移動時間の分）を返す
    static func wakeAlarms(days: Int = 7, now: EpochMs, prepMinutes: Int, time: DomainTime = .current,
                           firstOf: (EpochMs) -> (start: EpochMs, travel: Int?)?) -> [WakeAlarm] {
        var out: [WakeAlarm] = []
        let today = time.startOfDay(now)
        for i in 0..<days {
            let d = time.addDays(today, i)
            guard let f = firstOf(d), let m = wakeMinute(firstStart: f.start, travelMinutes: f.travel, prepMinutes: prepMinutes, day: d, time: time) else { continue }
            let wake = d + EpochMs(m) * MINUTE
            let early = wake - EpochMs(firstAlarmLead) * MINUTE
            if early > now { out.append(WakeAlarm(key: "wake1@\(early)", at: early, label: "起床（1つ目）", day: d, first: true)) }
            if wake > now { out.append(WakeAlarm(key: "wake2@\(wake)", at: wake, label: "起床", day: d, first: false)) }
        }
        return out
    }

    /// 自動で置いていた古い形（曜日くり返しの「自動」アラーム）を外す
    static func removeLegacyAutoAlarms(_ routine: MorningRoutine) -> MorningRoutine {
        var r = routine
        r.alarms.removeAll { $0.label.hasPrefix(autoLabelPrefix) }
        return r
    }
}
