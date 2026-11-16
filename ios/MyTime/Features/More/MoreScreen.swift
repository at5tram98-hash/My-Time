import SwiftUI
import MyTimeCore

/// その他タブ。iPhone の「設定」アプリのように、色つきのアイコンと短い説明で並べる。
/// 上：今日のまとめ。続いて：便利な機能・記録・表示・データ・このアプリについて
struct MoreScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.morePath) {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let now = model.time.ms(ctx.date)
                List {
                    Section { summary(now: now) }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

                    Section("便利な機能") {
                        action("文章で追加", "text.bubble.fill", .blue, detail: "「明日10時 歯医者」のように書くだけ") { router.open(.quickAdd) }
                        action("計画の支援", "wand.and.stars", .purple, detail: "重なり・詰め込み・期限を確かめる") { router.open(.planAssist) }
                        action("未割当のタスク", "tray.fill", .indigo, badge: model.inbox.count, detail: "時間を決めていないタスク") { router.open(.inbox) }
                    }

                    Section("記録") {
                        link(.review, "振り返り", "chart.bar.xaxis", .green, detail: "直近7日の作業時間・完了・余白")
                        NavigationLink { HistoryView() } label: { row("操作履歴", "clock.arrow.circlepath", .gray, detail: "いつ何を変えたか") }
                    }

                    Section("表示") {
                        Picker(selection: Binding(get: { model.settings.theme }, set: { v in model.updateSettings { $0.theme = v } })) {
                            Text("自動").tag("system")
                            Text("ライト").tag("light")
                            Text("ダーク").tag("dark")
                        } label: { row("外観", "circle.lefthalf.filled", .black, detail: nil) }
                        Picker(selection: Binding(get: { model.settings.laneFocus }, set: { v in model.updateSettings { $0.laneFocus = v } })) {
                            Text("同じ幅").tag("both")
                            Text("予定を広く").tag("main")
                            Text("タスクを広く").tag("detail")
                        } label: { row("今日のレーン", "rectangle.split.2x1", .orange, detail: nil) }
                    }

                    Section {
                        link(.settings, "設定", "gearshape.fill", .gray, detail: "通知・活動時間・データの移行・書き出し")
                    }

                    Section {
                        LabeledContent("バージョン", value: version)
                        LabeledContent("予定", value: "\(model.events.count)件")
                        LabeledContent("タスク", value: "\(model.tasks.count)件")
                    } header: {
                        Text("このアプリについて")
                    } footer: {
                        Text("データはこの iPhone の中に保存されます。Web 版とは「設定 › データの移行」でやり取りできます。")
                    }
                }
            }
            .navigationTitle("その他")
            .navigationDestination(for: MoreRoute.self) { r in
                switch r {
                case .review: ReviewScreen(embedded: true)
                case .settings: SettingsView(embedded: true)
                }
            }
        }
    }

    // MARK: 今日のまとめ

    private func summary(now: EpochMs) -> some View {
        let d0 = model.time.startOfDay(now), d1 = model.time.addDays(d0, 1)
        let today = tasksForDay(model.tasks, day: d0, time: model.time)
        let done = today.filter(\.isDone).count
        let events = model.visibleEvents(from: d0, to: d1).filter { !$0.event.allDay && $0.end > now }.count
        let weekEvents = model.visibleEvents(from: d0, to: model.time.addDays(d0, 7)).count
        return VStack(alignment: .leading, spacing: 12) {
            Text(model.dayTitle(d0)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 6)
            HStack(spacing: 10) {
                tile("今日のタスク", today.isEmpty ? "0" : "\(done)/\(today.count)", "checklist", .blue) { router.open(.dayTasks(d0)) }
                tile("この後の予定", "\(events)", "calendar", .red) { router.tab = .today }
                tile("今週の予定", "\(weekEvents)", "calendar.badge.clock", .orange) { router.tab = .calendar }
            }
        }
        .padding(.vertical, 4)
    }

    private func tile(_ title: String, _ value: String, _ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Text(value).font(.title2.weight(.bold)).monospacedDigit().contentTransition(.numericText())
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) \(value)")
    }

    // MARK: 行

    /// iPhone の「設定」と同じ、角丸の色つきアイコン＋名前＋小さな説明
    private func row(_ title: String, _ symbol: String, _ tint: Color, badge: Int = 0, detail: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if badge > 0 {
                Text("\(badge)").font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
                    .accessibilityLabel("\(badge)件")
            }
        }
    }

    private func action(_ title: String, _ symbol: String, _ tint: Color, badge: Int = 0, detail: String?, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack {
                row(title, symbol, tint, badge: badge, detail: detail)
                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func link(_ r: MoreRoute, _ title: String, _ symbol: String, _ tint: Color, detail: String?) -> some View {
        NavigationLink(value: r) { row(title, symbol, tint, detail: detail) }
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(v)（\(b)）"
    }
}
