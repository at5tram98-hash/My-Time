import Foundation
import UserNotifications
import MyTimeCore

/// 端末の通知（予定・出発・タスクの開始・確認・締切）。サーバーは使わず、この iPhone の中だけで予約する。
/// データが変わるたびに、これから7日分を予約し直す（iOS の上限 64 件より少ない 60 件まで）。
@MainActor
enum NotificationScheduler {
    static let prefix = "mytime."
    static let limit = 60

    struct Plan: Equatable {
        var id: String
        var title: String
        var body: String
        var at: EpochMs
        /// アラーム（時間に敏感な通知・集中モードでも届きやすい）
        var alarm = false
    }

    /// アラームを付けたタスクの鳴らす時刻（実行は開始、確認は確認の時刻）
    static func alarmTime(_ t: MTTask) -> EpochMs? {
        guard !t.isDone, t.extra?["alarm"]?.boolValue == true else { return nil }
        return t.kind == .check ? t.checkAt : t.plannedStart
    }

    /// 予約する内容（純粋な計算。テストしやすいよう分けている）
    static func plans(events: [EventOccurrence], tasks: [MTTask], minutesBefore: Int, now: EpochMs, time: DomainTime,
                      calendarKinds: [String: CalendarKind] = [:], employers: [String: String] = [:]) -> [Plan] {
        var out: [Plan] = []
        func left(_ m: Int) -> String { m <= 0 ? "まもなく" : m < 60 ? "あと\(m)分" : m % 60 == 0 ? "あと\(m / 60)時間" : "あと\(m / 60)時間\(m % 60)分" }
        for e in events where !e.event.allDay && e.start > now {
            let ev = e.event
            let kind = calendarKinds[ev.calendarId]
            let room = ev.classInfo?["room"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let place = ev.placeName.flatMap { $0.isEmpty ? nil : $0 }
            // 小テストの前の日の夜（20時）に知らせる
            if let q = ev.extra?["spec"]?["details"]?["quizAt"]?.intValue, time.isSameDay(q, e.start) {
                let eve = time.addDays(time.startOfDay(e.start), -1) + 20 * HOUR
                if eve > now {
                    let scope = ev.extra?["spec"]?["details"]?["quizScope"]?.stringValue.flatMap { $0.isEmpty ? nil : "範囲：\($0)" }
                    out.append(Plan(id: "quiz:\(e.id)", title: "明日は\(e.title)の小テスト", body: scope ?? "\(time.hm(e.start))〜の授業で実施", at: eve))
                }
            }
            if let tm = ev.travelMinutes, tm > 0 {
                // 出発：「〇〇へ出発まであと10分」／本文：開始の時刻・場所
                let leave = e.start - EpochMs(tm) * MINUTE
                var lines = ["\(time.hm(e.start))開始・移動\(tm)分"]
                if let place { lines.append("場所：\(place)") }
                out.append(Plan(id: "leave:\(e.id)", title: "\(e.title)へ出発まで\(left(minutesBefore))", body: lines.joined(separator: "\n"), at: leave - EpochMs(minutesBefore) * MINUTE))
                continue
            }
            var lines: [String] = []
            if kind == .class || ev.specType == .class {
                // 授業：「演習Ⅰまであと10分」／教室
                if let room { lines.append("教室：\(room)") }
                lines.append("\(time.hm(e.start))〜\(time.hm(e.end))")
                if let q = ev.extra?["spec"]?["details"]?["quizAt"]?.intValue, time.isSameDay(q, e.start) {
                    let scope = ev.extra?["spec"]?["details"]?["quizScope"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                    lines.append("小テストがあります" + (scope.map { "（\($0)）" } ?? ""))
                }
            } else if kind == .job || ev.specType == .shift {
                // バイト：「GU の勤務まであと10分」／勤務先・時間
                if let name = ev.employerId.flatMap({ employers[$0] }) { lines.append("勤務先：\(name)") }
                lines.append("勤務：\(time.hm(e.start))〜\(time.hm(e.end))")
                if ev.extra?["shiftPending"]?.boolValue == true { lines.append("シフトは調整中です") }
            } else {
                lines.append("\(time.hm(e.start))〜\(time.hm(e.end))")
                if let place { lines.append("場所：\(place)") }
                if ev.extra?["meetingUrl"]?.stringValue != nil { lines.append("オンライン") }
            }
            let what = (kind == .job || ev.specType == .shift) && !e.title.contains("勤務") ? "\(e.title)の勤務" : e.title
            out.append(Plan(id: "event:\(e.id)", title: minutesBefore == 0 ? "\(what)の時間です" : "\(what)まで\(left(minutesBefore))", body: lines.joined(separator: "\n"), at: e.start - EpochMs(minutesBefore) * MINUTE))
        }
        // アラーム：開始の時刻に、1分おきに3回
        for t in tasks {
            guard let at = alarmTime(t) else { continue }
            for i in 0..<3 {
                out.append(Plan(id: "alarm\(i):\(t.id)", title: t.title, body: i == 0 ? "\(time.hm(at))です" : "\(time.hm(at))開始・まだ始めていません", at: at + EpochMs(i) * MINUTE, alarm: true))
            }
        }
        for t in tasks where !t.isDone {
            if t.kind == .do, let s = t.plannedStart {
                var lines = ["\(time.hm(s))〜\(t.plannedEnd.map(time.hm) ?? "")"]
                if let m = t.estimateMinutes { lines.append("見積：\(m)分") }
                out.append(Plan(id: "task:\(t.id)", title: "\(t.title)を始める時間です", body: lines.joined(separator: "\n"), at: s))
            }
            if t.kind == .check, let c = t.checkAt {
                out.append(Plan(id: "check:\(t.id)", title: "\(t.title)を確認", body: "\(time.hm(c))", at: c))
            }
            if let d = t.deadline {
                out.append(Plan(id: "due:\(t.id)", title: "\(t.title)の締切まであと3時間", body: "締切：\(time.dayLabel(d)) \(time.hm(d))", at: d - 3 * HOUR))
            }
        }
        return out.filter { $0.at > now }.sorted { $0.at < $1.at }.prefix(limit).map { $0 }
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// これまでの予約を消して、予約し直す（My Time が作った予約だけ）
    static func reschedule(model: AppModel) async {
        let center = UNUserNotificationCenter.current()
        // チェックポイントは、これから7日分の回（繰り返しを含む）
        let cps = (0..<8).flatMap { model.checkpoints(on: model.time.addDays(model.time.startOfDay(model.now), $0)) }.filter { $0.at > model.now }
        await AlarmService.sync(model: model)
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let now = model.now
        let events = model.visibleEvents(from: now, to: model.time.addDays(now, 7))
        // 通知がオフでも、アラームを付けたタスクは鳴らす
        var all = plans(events: events, tasks: model.tasks, minutesBefore: model.notifyMinutesBefore, now: now, time: model.time,
                        calendarKinds: Dictionary(model.calendars.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a }),
                        employers: Dictionary(model.employers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        for c in cps {
            let name = c.title.isEmpty ? "チェックポイント" : c.title
            if let n = c.notifyBefore, c.at - EpochMs(n) * MINUTE > now {
                all.append(Plan(id: "cp:\(c.id)@\(c.at)", title: n == 0 ? "\(name)の時間です" : "\(name)まであと\(n)分", body: "\(model.hm(c.at))" + (c.notes.isEmpty ? "" : "\n\(c.notes)"), at: c.at - EpochMs(n) * MINUTE))
            }
            if c.alarm { all.append(Plan(id: "cpalarm:\(c.id)@\(c.at)", title: name, body: "\(model.hm(c.at))です", at: c.at, alarm: true)) }
        }
        // 本物のアラーム（AlarmKit）が使えるときは、アラームの通知は出さない（二重に鳴らさない）
        let systemAlarms = TaskAlarms.systemAlarmsActive
        // 朝のアラーム：AlarmKit が使えないときだけ、通知で代わりに知らせる（マナーモードでは鳴らないことがある）
        if !systemAlarms {
            for a in model.morning.alarms where a.enabled {
                var t = now
                for _ in 0..<7 {
                    guard let at = a.next(after: t, time: model.time), at < now + 7 * DAY else { break }
                    all.append(Plan(id: "morning:\(a.id)@\(at)", title: a.label.isEmpty ? "起床の時刻です" : a.label, body: "\(model.hm(at))・朝の準備を始めましょう", at: at, alarm: true))
                    t = at
                }
            }
        }
        for p in all where ((model.notificationsEnabled || p.id.hasPrefix("cp:")) && !p.alarm) || (p.alarm && !systemAlarms) {
            let content = UNMutableNotificationContent()
            content.title = p.title
            content.body = p.body
            content.sound = p.alarm ? .defaultCritical : .default
            if p.alarm { content.interruptionLevel = .timeSensitive }
            content.threadIdentifier = "mytime"
            let comps = model.time.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: model.time.date(p.at))
            let req = UNNotificationRequest(identifier: prefix + p.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(req)
        }
    }
}
