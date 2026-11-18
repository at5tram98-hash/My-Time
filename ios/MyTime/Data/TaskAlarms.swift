import Foundation
import SwiftUI
import CryptoKit
import MyTimeCore
#if canImport(AlarmKit)
import AlarmKit
#endif

/// タスクのアラーム。iOS 26 以降は時計アプリと同じ本物のアラーム（AlarmKit）で鳴らす：
/// マナーモードや集中モードでも鳴り、ロック画面・ダイナミックアイランドに「止める」が出る。
/// 使えないとき（許可なし・古い iOS）は、通知とアプリ内のアラーム画面で代わりに知らせる。
@MainActor
enum TaskAlarms {
    /// AlarmKit で鳴らせる状態か（このときは通知でのアラームとアプリ内の画面を出さない）
    static var systemAlarmsActive: Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return AlarmManager.shared.authorizationState == .authorized }
        #endif
        return false
    }

    /// アラームを使う許可を求める（アラームを初めてオンにしたとき）
    static func requestAuthorization() async -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: return true
            case .denied: return false
            default: return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
            }
        }
        #endif
        return false
    }

    /// タスクと時刻から決まる ID（同じものは何度予約し直しても同じ ID になる）
    static func alarmID(taskId: String, at: EpochMs) -> UUID {
        let d = Insecure.MD5.hash(data: Data("mytime-alarm:\(taskId)@\(at)".utf8))
        let b = Array(d)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// 朝のアラームの ID（時刻・曜日・音・スヌーズを変えたら別の ID になり、古いものは取り消される）
    static func morningAlarmID(_ a: MorningAlarm) -> UUID {
        let key = "mytime-morning:\(a.id)@\(a.hour):\(a.minute)|\(a.weekdays.sorted())|\(a.sound ?? "-")|\(a.snoozeMinutes)|\(a.label)"
        let b = Array(Insecure.MD5.hash(data: Data(key.utf8)))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// アラームをまとめて管理する（タスク・チェックポイント・朝の起床）。
/// AlarmKit に予約したものをアプリが知っている一覧と照らし合わせ、要らないものは取り消し、足りないものを予約する。
/// 何度呼んでも同じ ID なので重複しない。アプリの起動時と、データが変わるたびに呼ぶ。
@MainActor
enum AlarmService {
    static let sounds: [(name: String?, label: String)] = [(nil, "標準"), ("mt_chime.caf", "チャイム"), ("mt_beep.caf", "ビープ"), ("mt_soft.caf", "やわらか")]

    static func sync(model: AppModel) async {
        let cps = (0..<8).flatMap { model.checkpoints(on: model.time.addDays(model.time.startOfDay(model.now), $0)) }.filter { $0.at > model.now }
        await sync(tasks: model.tasks, checkpoints: cps, morning: model.morning, now: model.now, time: model.time)
    }

    /// 本物のアラーム（AlarmKit）として予約できたもの（通知で代わりに鳴らす必要がないもの）。
    /// 鍵：タスクは "task:ID@時刻"、チェックポイントは "cp:ID@時刻"、朝は "morning:ID"
    static private(set) var confirmed: Set<String> = []

    static func sync(tasks: [MTTask], checkpoints: [Checkpoint], morning: MorningRoutine, now: EpochMs, time: DomainTime) async {
        #if canImport(AlarmKit)
        guard #available(iOS 26.0, *), AlarmManager.shared.authorizationState == .authorized else { return }
        let manager = AlarmManager.shared
        enum Item { case once(MTTask, EpochMs), morning(MorningAlarm) }
        var wanted: [UUID: Item] = [:]
        for t in tasks {
            guard let at = NotificationScheduler.alarmTime(t), at > now, at < now + 7 * DAY else { continue }
            wanted[TaskAlarms.alarmID(taskId: t.id, at: at)] = .once(t, at)
        }
        for c in checkpoints where c.alarm && c.at > now && c.at < now + 7 * DAY {
            let t = MTTask.make(title: c.title.isEmpty ? "チェックポイント" : c.title, now: now, id: "cp-" + c.id)
            wanted[TaskAlarms.alarmID(taskId: t.id, at: c.at)] = .once(t, c.at)
        }
        // 朝：起床完了を押した日は、その日の残りのアラームを鳴らさない（翌日以降の分は次の照合で戻す）
        let woke = UserDefaults.standard.double(forKey: "morning.wokeDay")
        let wokeToday = woke > 0 && time.isSameDay(EpochMs(woke), now)
        for a in morning.alarms.prefix(MorningRoutine.maxAlarms) where a.enabled {
            if wokeToday, let next = a.next(after: now, time: time), time.isSameDay(next, now) { continue }
            wanted[TaskAlarms.morningAlarmID(a)] = .morning(a)
        }
        var keyOf: [UUID: String] = [:]
        for (id, item) in wanted {
            switch item {
            case .once(let t, let at): keyOf[id] = (t.id.hasPrefix("cp-") ? "cp:\(t.id.dropFirst(3))" : "task:\(t.id)") + "@\(at)"
            case .morning(let a): keyOf[id] = "morning:\(a.id)"
            }
        }
        let existing: Set<UUID>
        do { existing = Set(try manager.alarms.map(\.id)) } catch {
            Diagnostics.failure("alarm", error, context: "予約済みのアラームを読めませんでした")
            existing = []
        }
        for id in existing where wanted[id] == nil {
            do { try manager.cancel(id: id) } catch { Diagnostics.failure("alarm", error, context: "アラームの取り消し") }
        }
        var ok = Set(existing.filter { wanted[$0] != nil }.compactMap { keyOf[$0] })
        var failed = 0
        for (id, item) in wanted where !existing.contains(id) {
            switch item {
            case .once(let t, let at):
                let alert = AlarmPresentation.Alert(
                    title: LocalizedStringResource(stringLiteral: t.title),
                    stopButton: AlarmButton(text: "止める", textColor: .white, systemImageName: "stop.circle.fill")
                )
                let attributes = AlarmAttributes<TaskAlarmMetadata>(presentation: AlarmPresentation(alert: alert), metadata: TaskAlarmMetadata(taskId: t.id), tintColor: .orange)
                let config = AlarmManager.AlarmConfiguration<TaskAlarmMetadata>.alarm(schedule: .fixed(Date(timeIntervalSince1970: TimeInterval(at) / 1000)), attributes: attributes)
                do { _ = try await manager.schedule(id: id, configuration: config); if let k = keyOf[id] { ok.insert(k) } }
                catch { failed += 1; Diagnostics.failure("alarm", error, context: "アラームの予約（通知で代わりに知らせます）") }
            case .morning(let a):
                let snooze = a.snoozeMinutes > 0
                let alert = AlarmPresentation.Alert(
                    title: LocalizedStringResource(stringLiteral: a.label.isEmpty ? "起床" : a.label),
                    stopButton: AlarmButton(text: "止める", textColor: .white, systemImageName: "stop.circle.fill"),
                    secondaryButton: snooze ? AlarmButton(text: "スヌーズ", textColor: .white, systemImageName: "zzz") : nil,
                    secondaryButtonBehavior: snooze ? .countdown : nil
                )
                let attributes = AlarmAttributes<TaskAlarmMetadata>(presentation: AlarmPresentation(alert: alert), metadata: TaskAlarmMetadata(taskId: "morning-" + a.id), tintColor: .orange)
                let days = (a.weekdays.isEmpty ? Array(0...6) : a.weekdays).compactMap { Self.weekday($0) }
                let schedule = Alarm.Schedule.relative(.init(time: .init(hour: a.hour, minute: a.minute), repeats: .weekly(days)))
                let config = AlarmManager.AlarmConfiguration<TaskAlarmMetadata>(
                    countdownDuration: snooze ? Alarm.CountdownDuration(preAlert: nil, postAlert: TimeInterval(a.snoozeMinutes * 60)) : nil,
                    schedule: schedule, attributes: attributes,
                    sound: a.sound.map { .named($0) } ?? .default)
                do { _ = try await manager.schedule(id: id, configuration: config); if let k = keyOf[id] { ok.insert(k) } }
                catch { failed += 1; Diagnostics.failure("alarm", error, context: "アラームの予約（通知で代わりに知らせます）") }
            }
        }
        confirmed = ok
        Diagnostics.setCount("alarms", ok.count)
        if failed == 0 { Diagnostics.record("alarm", ok: true, "アラーム \(ok.count)件を予約") }
        #endif
    }

    /// 起床完了：今鳴っている朝のアラームを止め、今日の残りのアラームを取り消す
    static func markAwake(model: AppModel) async {
        UserDefaults.standard.set(Double(model.now), forKey: "morning.wokeDay")
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            for a in model.morning.alarms { try? AlarmManager.shared.stop(id: TaskAlarms.morningAlarmID(a)) }
        }
        #endif
        await sync(model: model)
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    static func weekday(_ d: Int) -> Locale.Weekday? {
        [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday][safe: d]
    }
    #endif

    /// アラームの許可の状態（画面の説明用）
    static var stateText: String {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: return "許可済み"
            case .denied: return "許可されていません"
            default: return "未設定"
            }
        }
        #endif
        return "この iOS では使えません（iOS 26 以降）"
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

#if canImport(AlarmKit)
/// アラームに付ける情報（どのタスクか）
struct TaskAlarmMetadata: AlarmMetadata {
    var taskId: String
}
#endif
