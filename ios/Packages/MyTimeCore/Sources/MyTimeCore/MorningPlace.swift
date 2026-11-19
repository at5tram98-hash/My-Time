import Foundation

/// 朝の自動配置：その日の一番初めの予定（自分・時刻あり・取り消していない）の2時間前に「朝の準備」を置く。
/// 置いたタスクには `extra.autoMorning = "yyyy-MM-dd"` を付け、予定が動けば付いて動き、予定が無くなれば外す。
/// 始めた・済んだ朝のタスクは動かさない。
public enum MorningPlace {
    public static let leadMinutes = 120
    public static let title = "朝の準備"

    /// その日の朝を置く時刻（置かないときは nil）。朝4時より前・正午より後になるときは置かない
    public static func start(day: EpochMs, occurrences: [EventOccurrence], selfCalendarId: String, time: DomainTime) -> EpochMs? {
        let end = time.addDays(day, 1)
        let first = occurrences
            .filter { $0.start >= day && $0.start < end && !$0.event.allDay && !$0.isStruck && $0.event.calendarId == selfCalendarId }
            .map(\.start).min()
        guard let f = first else { return nil }
        let s = f - EpochMs(leadMinutes) * MINUTE
        let m = time.minutesOfDay(s)
        guard time.isSameDay(s, day), m >= 4 * 60, m <= 12 * 60 else { return nil }
        return s
    }
}

public extension Repository {
    /// 指定した日々の朝を置き直す。戻り値は変えた数
    @discardableResult
    func placeMornings(days: [EpochMs], occurrences: [EventOccurrence], minutes: Int, now: EpochMs, time: DomainTime, skip: Set<String> = []) throws -> Int {
        let fmt = DateFormatter()
        fmt.calendar = time.calendar; fmt.timeZone = time.calendar.timeZone; fmt.dateFormat = "yyyy-MM-dd"
        let len = EpochMs(max(15, min(minutes, MorningPlace.leadMinutes))) * MINUTE
        var changed = 0
        let existing = tasks().filter { $0.extra?["autoMorning"]?.stringValue != nil }
        for day in days {
            let key = fmt.string(from: time.date(day))
            if skip.contains(key) { continue }
            let mine = existing.filter { $0.extra?["autoMorning"]?.stringValue == key }
            let at = MorningPlace.start(day: day, occurrences: occurrences, selfCalendarId: MTCalendar.selfId, time: time)
            // 始めた・済んだものは触らない
            if mine.contains(where: { $0.status != .notStarted || $0.extra?["archivedAt"]?.intValue != nil }) { continue }
            if let at {
                if var t = mine.first {
                    if t.plannedStart != at || t.plannedEnd != at + len {
                        t.plannedStart = at; t.plannedEnd = at + len; t.estimateMinutes = Int(len / MINUTE)
                        try saveTask(t, isNew: false); changed += 1
                    }
                    for extra in mine.dropFirst() { try deleteTask(extra.id); changed += 1 }
                } else {
                    var t = MTTask.make(title: MorningPlace.title, now: now)
                    t.icon = "sunrise.fill"
                    t.calendarId = MTCalendar.selfId
                    t.plannedStart = at; t.plannedEnd = at + len; t.estimateMinutes = Int(len / MINUTE)
                    t.extra = .object(["spec": .object(["type": "morning".json]), "autoMorning": key.json])
                    try saveTask(t, isNew: true); changed += 1
                }
            } else {
                for t in mine { try deleteTask(t.id); changed += 1 }
            }
        }
        return changed
    }
}

public extension MorningPlace {
    /// 自動で置いた朝のタスクの日付（yyyy-MM-dd）
    static func dayKey(_ t: MTTask) -> String? { t.extra?["autoMorning"]?.stringValue }
}
