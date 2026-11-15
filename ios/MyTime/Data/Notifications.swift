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
    }

    /// 予約する内容（純粋な計算。テストしやすいよう分けている）
    static func plans(events: [EventOccurrence], tasks: [MTTask], minutesBefore: Int, now: EpochMs, time: DomainTime) -> [Plan] {
        var out: [Plan] = []
        for e in events where !e.event.allDay && e.start > now {
            if let tm = e.event.travelMinutes, tm > 0 {
                let leave = e.start - EpochMs(tm) * MINUTE
                out.append(Plan(id: "leave:\(e.id)", title: "出発の時刻です", body: "\(e.title)（\(time.hm(e.start))から・移動\(tm)分）", at: leave - EpochMs(minutesBefore) * MINUTE))
            } else {
                out.append(Plan(id: "event:\(e.id)", title: e.title, body: "\(time.hm(e.start))から" + (e.event.placeName.map { "・\($0)" } ?? ""), at: e.start - EpochMs(minutesBefore) * MINUTE))
            }
        }
        for t in tasks where !t.isDone {
            if t.kind == .do, let s = t.plannedStart {
                out.append(Plan(id: "task:\(t.id)", title: "始める時刻です", body: "\(t.title)（\(time.hm(s))から）", at: s))
            }
            if t.kind == .check, let c = t.checkAt {
                out.append(Plan(id: "check:\(t.id)", title: "確認", body: t.title, at: c))
            }
            if let d = t.deadline {
                out.append(Plan(id: "due:\(t.id)", title: "締切まで3時間", body: "\(t.title)（\(time.dayLabel(d)) \(time.hm(d))）", at: d - 3 * HOUR))
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
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard model.notificationsEnabled else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let now = model.now
        let events = model.visibleEvents(from: now, to: model.time.addDays(now, 7))
        for p in plans(events: events, tasks: model.tasks, minutesBefore: model.notifyMinutesBefore, now: now, time: model.time) {
            let content = UNMutableNotificationContent()
            content.title = p.title
            content.body = p.body
            content.sound = .default
            content.threadIdentifier = "mytime"
            let comps = model.time.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: model.time.date(p.at))
            let req = UNNotificationRequest(identifier: prefix + p.id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(req)
        }
    }
}
