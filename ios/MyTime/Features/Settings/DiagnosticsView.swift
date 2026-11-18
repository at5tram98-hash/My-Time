import SwiftUI
import UserNotifications
import MyTimeCore

/// 診断：権限・予約の件数・最後に成功した時刻・直近の失敗。個人の情報は出さない
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var notifyStatus: UNAuthorizationStatus = .notDetermined
    @State private var pendingNotifications = 0
    @State private var entries = Diagnostics.entries

    var body: some View {
        let c = Diagnostics.counts
        List {
            Section {
                permission("通知", ok: notifyStatus == .authorized || notifyStatus == .provisional, detail: statusText(notifyStatus))
                permission("アラーム（時計と同じ）", ok: AlarmService.stateText == "許可済み", detail: AlarmService.stateText)
                permission("ロック画面の表示（Live Activity）", ok: LiveActivityCoordinator.shared.activitiesEnabled,
                           detail: LiveActivityCoordinator.shared.activitiesEnabled ? "使えます" : "オフ")
                Button("設定アプリで許可を変える", systemImage: "gear") {
                    if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) }
                }
            } header: { Text("許可") } footer: { Text("許可されていない機能は動きません。アプリから勝手に許可することはできません。") }

            Section("予約") {
                LabeledContent("予約中の通知", value: "\(pendingNotifications)件")
                if let d = c["notificationsDropped"], d > 0 { LabeledContent("上限（64件）のため後で予約", value: "\(d)件") }
                LabeledContent("本物のアラーム", value: "\(c["alarms"] ?? 0)件")
                let r = LiveActivityCoordinator.shared.lastReport
                LabeledContent("ロック画面の表示", value: "表示 \(r.active)・予約 \(r.scheduled)")
                lastRow("通知", "notification")
                lastRow("アラーム", "alarm")
                lastRow("ロック画面", "live")
                lastRow("保存", "save")
            }

            Section {
                if entries.isEmpty { Text("記録はありません").foregroundStyle(.secondary) }
                ForEach(entries.prefix(40)) { e in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(e.ok ? Color.green : Color.orange)
                            .accessibilityLabel(e.ok ? "成功" : "失敗")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.message).font(.subheadline)
                            Text("\(areaName(e.area))・\(e.at.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("最近の記録") } footer: { Text("予定の名前など個人の情報は記録しません。") }

            Section {
                Button("記録を消す", role: .destructive) { Diagnostics.clear(); entries = [] }
            }
        }
        .navigationTitle("診断")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let center = UNUserNotificationCenter.current()
            notifyStatus = await center.notificationSettings().authorizationStatus
            pendingNotifications = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix("mytime.") }.count
            entries = Diagnostics.entries
        }
        .refreshable {
            await NotificationScheduler.reschedule(model: model)
            await LiveActivityCoordinator.shared.reconcile(model: model)
            pendingNotifications = await UNUserNotificationCenter.current().pendingNotificationRequests().filter { $0.identifier.hasPrefix("mytime.") }.count
            entries = Diagnostics.entries
        }
    }

    private func permission(_ title: String, ok: Bool, detail: String) -> some View {
        LabeledContent {
            Label(detail, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(ok ? Color.green : Color.orange)
        } label: { Text(title) }
    }

    @ViewBuilder
    private func lastRow(_ title: String, _ area: String) -> some View {
        if let f = Diagnostics.lastFailure(area), f.at > (Diagnostics.lastSuccess(area) ?? .distantPast) {
            LabeledContent("\(title)の最後", value: "失敗 \(f.at.formatted(date: .omitted, time: .shortened))").foregroundStyle(.orange)
        } else if let d = Diagnostics.lastSuccess(area) {
            LabeledContent("\(title)の最後", value: "成功 \(d.formatted(date: .omitted, time: .shortened))")
        }
    }

    private func statusText(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "許可済み"
        case .denied: return "許可されていません"
        case .provisional: return "仮の許可"
        case .ephemeral: return "一時的"
        default: return "未設定"
        }
    }

    private func areaName(_ a: String) -> String {
        ["save": "保存", "notification": "通知", "alarm": "アラーム", "live": "ロック画面", "cleanup": "自動削除", "link": "リンク"][a] ?? a
    }
}
