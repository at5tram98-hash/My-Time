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
