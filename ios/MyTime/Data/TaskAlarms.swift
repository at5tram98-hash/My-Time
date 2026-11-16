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

    /// これから7日分のアラームをそろえる（要らなくなったものは取り消し、足りないものを予約）
    static func sync(tasks: [MTTask], now: EpochMs) async {
        #if canImport(AlarmKit)
        guard #available(iOS 26.0, *), AlarmManager.shared.authorizationState == .authorized else { return }
        let manager = AlarmManager.shared
        var wanted: [UUID: (MTTask, EpochMs)] = [:]
        for t in tasks {
            guard let at = NotificationScheduler.alarmTime(t), at > now, at < now + 7 * DAY else { continue }
            wanted[alarmID(taskId: t.id, at: at)] = (t, at)
        }
        let existing = Set(((try? manager.alarms) ?? []).map(\.id))
        for id in existing where wanted[id] == nil { try? manager.cancel(id: id) }
        for (id, item) in wanted where !existing.contains(id) {
            let (t, at) = item
            let alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: t.title),
                stopButton: AlarmButton(text: "止める", textColor: .white, systemImageName: "stop.circle.fill")
            )
            let attributes = AlarmAttributes<TaskAlarmMetadata>(
                presentation: AlarmPresentation(alert: alert),
                metadata: TaskAlarmMetadata(taskId: t.id),
                tintColor: .orange
            )
            let config = AlarmManager.AlarmConfiguration<TaskAlarmMetadata>.alarm(
                schedule: .fixed(Date(timeIntervalSince1970: TimeInterval(at) / 1000)),
                attributes: attributes
            )
            _ = try? await manager.schedule(id: id, configuration: config)
        }
        #endif
    }
}

#if canImport(AlarmKit)
/// アラームに付ける情報（どのタスクか）
struct TaskAlarmMetadata: AlarmMetadata {
    var taskId: String
}
#endif
