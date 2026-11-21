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
        /// 小見出し（「10分後に開始」など。純正カレンダーと同じく、いつのことかをここに）
        var subtitle: String = ""
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
        // 文の決まり（純正のカレンダー・リマインダーにならう）：
        // タイトル＝予定・タスクの名前（句点なし）／小見出し＝いつのことか／本文＝時刻・場所などの短い要約（句点なし）
        func soon(_ m: Int, _ verb: String) -> String { m <= 0 ? "まもなく\(verb)" : m < 60 ? "\(m)分後に\(verb)" : m % 60 == 0 ? "\(m / 60)時間後に\(verb)" : "\(m / 60)時間\(m % 60)分後に\(verb)" }
        func range(_ a: EpochMs, _ b: EpochMs) -> String { "\(time.hm(a))〜\(time.hm(b))" }
        for e in events where !e.event.allDay && e.start > now {
            let ev = e.event
            let kind = calendarKinds[ev.calendarId]
            let room = ev.classInfo?["room"]?.stringValue.flatMap { $0.isEmpty ? nil : compactRoom($0) }
            let place = ev.placeName.flatMap { $0.isEmpty ? nil : $0 }
            let isClass = kind == .class || ev.specType == .class
            let isShift = kind == .job || ev.specType == .shift
            // 小テストの前の日の夜（20時）に知らせる
            if let q = ev.extra?["spec"]?["details"]?["quizAt"]?.intValue, time.isSameDay(q, e.start) {
                let eve = time.addDays(time.startOfDay(e.start), -1) + 20 * HOUR
                if eve > now {
                    let scope = ev.extra?["spec"]?["details"]?["quizScope"]?.stringValue.flatMap { $0.isEmpty ? nil : "範囲 \($0)" }
                    out.append(Plan(id: "quiz:\(e.id)", title: "\(e.title)の小テスト", body: [range(e.start, e.end), scope].compactMap { $0 }.joined(separator: "・"), at: eve, subtitle: "明日の授業で実施"))
                }
            }
            // どこで（教室・場所・オンライン）
            let whereText: String? = isClass ? room : place ?? (ev.extra?["meetingUrl"]?.stringValue != nil ? "オンライン" : nil)
            if let tm = ev.travelMinutes, tm > 0 {
                // 出発：純正の「出発時刻」と同じく、出発のときに知らせる
                let leave = e.start - EpochMs(tm) * MINUTE
                out.append(Plan(id: "leave:\(e.id)", title: e.title,
                                body: ["\(time.hm(e.start))に開始", "移動\(tm)分", whereText].compactMap { $0 }.joined(separator: "・"),
                                at: leave - EpochMs(minutesBefore) * MINUTE,
                                subtitle: minutesBefore == 0 ? "出発の時刻です" : soon(minutesBefore, "出発")))
                continue
            }
            var parts = [range(e.start, e.end)]
            if let w = whereText { parts.append(w) }
            if isShift {
                if let name = ev.employerId.flatMap({ employers[$0] }), !e.title.contains(name) { parts.append(name) }
                if ev.extra?["shiftPending"]?.boolValue == true { parts.append("シフト調整中") }
            }
            if isClass, let q = ev.extra?["spec"]?["details"]?["quizAt"]?.intValue, time.isSameDay(q, e.start) {
                parts.append("小テストあり")
            }
            let what = isShift && !e.title.contains("勤務") ? "\(e.title)の勤務" : e.title
            out.append(Plan(id: "event:\(e.id)", title: what, body: parts.joined(separator: "・"),
                            at: e.start - EpochMs(minutesBefore) * MINUTE,
                            subtitle: minutesBefore == 0 ? "開始の時刻です" : soon(minutesBefore, "開始")))
        }
        // アラーム：開始の時刻に、1分おきに3回
        for t in tasks {
            guard let at = alarmTime(t) else { continue }
            for i in 0..<3 {
                out.append(Plan(id: "alarm\(i):\(t.id)", title: t.title,
                                body: i == 0 ? (t.kind == .check ? "確認の時刻です" : "開始の時刻です") : "まだ始めていません",
                                at: at + EpochMs(i) * MINUTE, alarm: true, subtitle: time.hm(at)))
            }
        }
        for t in tasks where !t.isDone {
            if t.kind == .do, let s = t.plannedStart {
                var parts = [t.plannedEnd.map { range(s, $0) } ?? time.hm(s)]
                if let m = t.estimateMinutes { parts.append("見積\(m)分") }
                out.append(Plan(id: "task:\(t.id)", title: t.title, body: parts.joined(separator: "・"), at: s, subtitle: "開始の時刻です"))
            }
            if t.kind == .check, let c = t.checkAt {
                out.append(Plan(id: "check:\(t.id)", title: t.title, body: t.notes.isEmpty ? time.hm(c) : t.notes, at: c, subtitle: "確認の時刻です"))
            }
            if let d = t.deadline {
                out.append(Plan(id: "due:\(t.id)", title: t.title, body: "締切 \(time.dayLabel(d)) \(time.hm(d))", at: d - 3 * HOUR, subtitle: "締切まであと3時間"))
            }
        }
        return out.filter { $0.at > now }.sorted { $0.at < $1.at }.prefix(limit).map { $0 }
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// 通知を押したときに開く画面（mytime://…）
    static func link(for id: String) -> String {
        let body = id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        let target = body.split(separator: "@").first.map(String.init) ?? body
        if id.hasPrefix("event:") || id.hasPrefix("leave:") || id.hasPrefix("quiz:") { return "mytime://event/\(body)" }
        if id.hasPrefix("cp:") || id.hasPrefix("cpalarm:") { return "mytime://checkpoint/\(target)" }
        if id.hasPrefix("morning:") { return "mytime://morning" }
        return "mytime://task/\(target)"
    }

    /// 予約し直しは順番に1つずつ（同時に走ると、消した通知が戻ったり二重になったりする）
    private static var chain: Task<Void, Never>?

    /// これまでの予約を消して、予約し直す（My Time が作った予約だけ）
    static func reschedule(model: AppModel) async {
        let prev = chain
        let next = Task { @MainActor in
            await prev?.value
            await rescheduleNow(model: model)
        }
        chain = next
        await next.value
    }

    private static func rescheduleNow(model: AppModel) async {
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
                all.append(Plan(id: "cp:\(c.id)@\(c.at)", title: name, body: c.notes.isEmpty ? model.hm(c.at) : "\(model.hm(c.at))・\(c.notes)", at: c.at - EpochMs(n) * MINUTE, subtitle: n == 0 ? "時刻になりました" : "\(n)分後"))
            }
            if c.alarm { all.append(Plan(id: "cpalarm:\(c.id)@\(c.at)", title: name, body: c.notes.isEmpty ? "チェックポイント" : c.notes, at: c.at, alarm: true, subtitle: model.hm(c.at))) }
        }
        // 朝のアラーム：本物のアラーム（AlarmKit）で予約できなかったときだけ、通知で代わりに知らせる
        // （通知はマナーモード・集中モードで鳴らないことがあり、目覚ましと同じではない）
        do {
            for a in model.morning.alarms where a.enabled && !AlarmService.confirmed.contains("morning:\(a.id)") {
                var t = now
                for _ in 0..<7 {
                    guard let at = a.next(after: t, time: model.time), at < now + 7 * DAY else { break }
                    all.append(Plan(id: "morning:\(a.id)@\(at)", title: "起床", body: "朝の準備を始める時刻です", at: at, alarm: true, subtitle: model.hm(at)))
                    t = at
                }
            }
        }
        // アラームの通知は、本物のアラームとして予約できなかったものだけ（二重に鳴らさない）
        func coveredByAlarm(_ p: Plan) -> Bool {
            let c = AlarmService.confirmed
            if p.id.hasPrefix("alarm"), let tid = p.id.split(separator: ":", maxSplits: 1).last,
               let t = model.tasks.first(where: { $0.id == tid }), let at = alarmTime(t) { return c.contains("task:\(t.id)@\(at)") }
            if p.id.hasPrefix("cpalarm:") { return c.contains("cp:" + p.id.dropFirst("cpalarm:".count)) }
            if p.id.hasPrefix("morning:"), let aid = p.id.dropFirst("morning:".count).split(separator: "@").first { return c.contains("morning:\(aid)") }
            return false
        }
        var chosen = all.filter { p in p.alarm ? !coveredByAlarm(p) : (model.notificationsEnabled || p.id.hasPrefix("cp:")) }
        // iOS が一度に予約できる通知は64件まで。起床・アラーム → チェックポイント → 予定の順で、近いものから
        func rank(_ p: Plan) -> Int { p.alarm ? 0 : p.id.hasPrefix("cp:") ? 1 : p.id.hasPrefix("quiz:") ? 2 : 3 }
        chosen.sort { (rank($0), $0.at) < (rank($1), $1.at) }
        let dropped = max(0, chosen.count - 60)
        chosen = Array(chosen.prefix(60))
        var okCount = 0, failCount = 0
        for p in chosen {
            let content = UNMutableNotificationContent()
            content.title = p.title
            if !p.subtitle.isEmpty { content.subtitle = p.subtitle }
            content.body = p.body
            // 重要な通知（Critical Alerts）の許可は持っていないので使わない。アラームの代わりは「時間厳守」の通知
            content.sound = .default
            if p.alarm { content.interruptionLevel = .timeSensitive }
            content.threadIdentifier = "mytime"
            content.userInfo = ["link": link(for: p.id)]
            let comps = model.time.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: model.time.date(p.at))
            let req = UNNotificationRequest(identifier: prefix + p.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            do { try await center.add(req); okCount += 1 } catch { failCount += 1; Diagnostics.failure("notification", error, context: "通知の予約") }
        }
        Diagnostics.setCount("notifications", okCount)
        Diagnostics.setCount("notificationsDropped", dropped)
        if failCount == 0 { Diagnostics.record("notification", ok: true, "通知 \(okCount)件を予約" + (dropped > 0 ? "（上限のため \(dropped)件は後で予約）" : "")) }
    }
}
