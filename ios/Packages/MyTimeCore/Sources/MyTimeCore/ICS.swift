import Foundation

// ICS（iCalendar）書き出し。Apple・Google カレンダーなどに読み込める形式。
// 予定（繰り返しは RRULE、取り消した回は EXDATE）と、時刻を決めたタスクを書き出す。読み込みは行わない。

public func exportICS(events: [MTEvent], tasks: [MTTask], now: EpochMs) -> String {
    var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//My Time//iOS//JA", "CALSCALE:GREGORIAN", "X-WR-CALNAME:My Time"]
    let stamp = icsUTC(now)
    for e in events.sorted(by: { $0.start < $1.start }) {
        lines.append("BEGIN:VEVENT")
        lines.append("UID:\(e.id)@mytime")
        lines.append("DTSTAMP:\(stamp)")
        if e.allDay {
            lines.append("DTSTART;VALUE=DATE:\(icsDate(e.start, e.timeZone))")
            lines.append("DTEND;VALUE=DATE:\(icsDate(e.end, e.timeZone))")
        } else {
            lines.append("DTSTART:\(icsUTC(e.start))")
            lines.append("DTEND:\(icsUTC(e.end))")
        }
        lines.append("SUMMARY:\(icsEscape(e.title))")
        if !e.notes.isEmpty { lines.append("DESCRIPTION:\(icsEscape(e.notes))") }
        if let place = e.placeName, !place.isEmpty { lines.append("LOCATION:\(icsEscape(place))") }
        if let r = e.recurrence {
            var rule = "RRULE:FREQ=\(r.freq.rawValue.uppercased());INTERVAL=\(max(1, r.interval))"
            if r.freq == .weekly, let wd = r.byWeekday, !wd.isEmpty { rule += ";BYDAY=" + wd.sorted().map { ["SU", "MO", "TU", "WE", "TH", "FR", "SA"][($0 % 7 + 7) % 7] }.joined(separator: ",") }
            if let u = r.until { rule += ";UNTIL=\(icsUTC(u))" }
            lines.append(rule)
            for x in e.exceptions where x.kind == .cancelled { lines.append("EXDATE:\(icsUTC(x.originalStart))") }
        }
        lines.append("END:VEVENT")
    }
    for t in tasks where t.kind == .do && t.plannedStart != nil && t.plannedEnd != nil {
        lines.append("BEGIN:VEVENT")
        lines.append("UID:task-\(t.id)@mytime")
        lines.append("DTSTAMP:\(stamp)")
        lines.append("DTSTART:\(icsUTC(t.plannedStart!))")
        lines.append("DTEND:\(icsUTC(t.plannedEnd!))")
        lines.append("SUMMARY:\(icsEscape((t.isDone ? "✓ " : "") + t.title))")
        lines.append("CATEGORIES:タスク")
        lines.append("END:VEVENT")
    }
    lines.append("END:VCALENDAR")
    return lines.map(icsFold).joined(separator: "\r\n") + "\r\n"
}

func icsUTC(_ t: EpochMs) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f.string(from: Date(timeIntervalSince1970: Double(t) / 1000))
}

func icsDate(_ t: EpochMs, _ tz: String) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: tz) ?? .current
    f.dateFormat = "yyyyMMdd"
    return f.string(from: Date(timeIntervalSince1970: Double(t) / 1000))
}

func icsEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
}

/// 75バイトを超える行は折り返す（UTF-8 の文字の途中では切らない）
func icsFold(_ line: String) -> String {
    var out: [String] = []
    var cur = ""
    var bytes = 0
    for ch in line {
        let n = String(ch).utf8.count
        if bytes + n > (out.isEmpty ? 75 : 74) { out.append(cur); cur = ""; bytes = 0 }
        cur.append(ch); bytes += n
    }
    out.append(cur)
    return out.enumerated().map { $0.offset == 0 ? $0.element : " " + $0.element }.joined(separator: "\r\n")
}
