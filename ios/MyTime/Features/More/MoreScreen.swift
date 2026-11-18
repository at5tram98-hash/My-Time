import SwiftUI
import Charts
import MyTimeCore

/// その他タブ。「今日」でできることは置かない。
/// ここだけにあるもの：記録（連続日数・今週の作業・振り返り・操作履歴）、使い方、通知と外観、設定、このアプリについて
struct MoreScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @AppStorage(AccountKeys.name) private var accountName = ""
    @AppStorage(AccountKeys.school) private var accountSchool = ""

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.morePath) {
            let stats = weekStats()
            List {
                // アカウント（「設定」アプリの一番上と同じ形）
                Section {
                    NavigationLink { AccountView() } label: {
                        HStack(spacing: 14) {
                            Text(initials)
                                .font(.title2.weight(.semibold)).foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(accountName.isEmpty ? "名前を設定" : accountName).font(.title3.weight(.semibold))
                                Text(accountSchool.isEmpty ? "アカウント・自宅と学校・データ" : "\(accountSchool)・アカウント").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Section { header(stats) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                Section("記録") {
                    NavigationLink(value: MoreRoute.review) {
                        HStack(spacing: 12) {
                            icon("chart.bar.xaxis", .green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("振り返り")
                                Text("直近7日の作業時間・完了・余白").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            sparkline(stats.minutes)
                        }
                    }
                    NavigationLink { HistoryView() } label: { row("操作履歴", "clock.arrow.circlepath", .gray, "いつ何を変えたか") }
                }

                Section("計画") {
                    NavigationLink(value: MoreRoute.dayPlan) {
                        row("翌日計画", "list.clipboard.fill", .indigo, tomorrowPlanSummary)
                    }
                }

                Section("生活") {
                    NavigationLink(value: MoreRoute.morning) {
                        row("朝", "sunrise.fill", .orange, morningSummary)
                    }
                    NavigationLink(value: MoreRoute.cleaning) {
                        row("清掃", "bubbles.and.sparkles.fill", .teal, cleaningSummary)
                    }
                }

                Section("バイト") {
                    NavigationLink(value: MoreRoute.employers) {
                        row("勤務先と給与", "yensign.circle.fill", .green, model.employers.isEmpty ? "時給・交通費・締め日を登録" : "勤務先 \(model.employers.count)・給与の見込み")
                    }
                    NavigationLink { ShiftPendingView() } label: {
                        row("シフトの調整中", "hourglass", .orange, pendingSummary)
                    }
                }

                Section("カスタマイズ") {
                    NavigationLink(value: MoreRoute.specSettings) {
                        row("専門の種類", "square.stack.3d.up.fill", .blue, "種類ごとのアイコン・既定・テンプレート")
                    }
                    NavigationLink(value: MoreRoute.live) {
                        row("Live Activity", "platter.filled.top.iphone", .indigo, "ロック画面・ダイナミックアイランド")
                    }
                    NavigationLink { StudioListView() } label: {
                        row("Create Studio", "sparkles", .purple, model.studioTypes.isEmpty ? "自分専用の種類を作る" : "自分の種類 \(model.studioTypes.filter { $0.status != "hidden" }.count)個")
                    }
                }

                Section("使い方") {
                    NavigationLink { GestureGuideView() } label: { row("操作のしかた", "hand.draw.fill", .pink, "長押し・なぞる・スワイプでできること") }
                }

                Section("通知と表示") {
                    Toggle(isOn: Binding(get: { model.notificationsEnabled }, set: setNotify)) {
                        row("通知", "bell.badge.fill", .red, model.notificationsEnabled ? "予定の\(model.notifyMinutesBefore == 0 ? "開始時刻" : "\(model.notifyMinutesBefore)分前")に知らせる" : "オフ")
                    }
                    Picker(selection: Binding(get: { model.settings.theme }, set: { v in model.updateSettings { $0.theme = v } })) {
                        Text("自動").tag("system")
                        Text("ライト").tag("light")
                        Text("ダーク").tag("dark")
                    } label: { row("外観", "circle.lefthalf.filled", .indigo, nil) }
                }

                Section {
                    LabeledContent("バージョン", value: version)
                    LabeledContent("保存している予定", value: "\(model.events.count)件")
                    LabeledContent("保存しているタスク", value: "\(model.tasks.count)件")
                } header: {
                    Text("このアプリについて")
                } footer: {
                    Text("データはこの iPhone の中に保存されます。Web 版とは「設定 › データの移行」でやり取りできます。")
                }
            }
            .navigationTitle("その他")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: MoreRoute.settings) { Image(systemName: "gearshape") }
                        .accessibilityLabel("設定")
                }
            }
            .navigationDestination(for: MoreRoute.self) { r in
                switch r {
                case .review: ReviewScreen(embedded: true)
                case .settings: SettingsView(embedded: true)
                case .dayPlan: DayPlanView()
                case .morning: MorningHomeView()
                case .cleaning: CleaningHomeView()
                case .employers: EmployersView()
                case .payroll: PayrollView()
                case .specSettings: SpecSettingsListView()
                case .live: LiveActivitySettingsView()
                }
            }
        }
    }

    // MARK: 見出し（連続日数と今週の作業）

    private struct WeekStats { var minutes: [Int]; var streak: Int; var weekMinutes: Int; var weekDone: Int }

    private func header(_ s: WeekStats) -> some View {
        HStack(spacing: 10) {
            stat(s.streak > 0 ? "\(s.streak)日" : "-", "続けて記録", "flame.fill", .orange)
            stat(formatDuration(EpochMs(s.weekMinutes) * MINUTE), "今週の作業", "timer", .blue)
            stat("\(s.weekDone)件", "今週の完了", "checkmark.seal.fill", .green)
        }
        .padding(.vertical, 4)
    }

    private func stat(_ value: String, _ title: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            Text(value).font(.title3.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func sparkline(_ minutes: [Int]) -> some View {
        Chart(Array(minutes.enumerated()), id: \.offset) { i, m in
            BarMark(x: .value("日", i), y: .value("分", m)).foregroundStyle(Color.green.gradient).cornerRadius(2)
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .frame(width: 64, height: 26)
        .accessibilityHidden(true)
    }

    /// 直近7日の作業（分）・連続して作業か完了がある日数・今週（月曜から）の合計
    private func weekStats() -> WeekStats {
        let today = model.time.startOfDay(model.now)
        func worked(_ d0: EpochMs) -> Int {
            let d1 = model.time.addDays(d0, 1)
            var ms: EpochMs = 0
            for t in model.tasks { for iv in t.intervals { let s = max(iv.start, d0), e = min(iv.end ?? model.now, d1); if e > s { ms += e - s } } }
            return Int(ms / MINUTE)
        }
        func done(_ d0: EpochMs) -> Int {
            let d1 = model.time.addDays(d0, 1)
            return model.tasks.filter { t in
                guard let at = t.status == .done ? t.actualEnd : (t.checked ? t.checkedAt : nil) else { return false }
                return at >= d0 && at < d1
            }.count
        }
        let minutes = (0..<7).reversed().map { worked(model.time.addDays(today, -$0)) }
        var streak = 0
        // 今日まだ何もしていなくても、昨日まで続いていれば数える
        var d = worked(today) + done(today) > 0 ? today : model.time.addDays(today, -1)
        while streak < 365, worked(d) + done(d) > 0 { streak += 1; d = model.time.addDays(d, -1) }
        let monday = model.time.addDays(today, -((model.time.weekday(today) + 6) % 7))
        var wm = 0, wd = 0
        var x = monday
        while x <= today { wm += worked(x); wd += done(x); x = model.time.addDays(x, 1) }
        return WeekStats(minutes: minutes, streak: streak, weekMinutes: wm, weekDone: wd)
    }

    // MARK: 行

    private func icon(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// iPhone の「設定」と同じ、角丸の色つきアイコン＋名前＋小さな説明
    private var morningSummary: String {
        let m = model.morning
        if m.active != nil { return "準備の途中です" }
        let next = m.alarms.compactMap { $0.next(after: model.now, time: model.time) }.min()
        return next.map { "次のアラーム \(model.time.dayLabel($0)) \(model.hm($0))" } ?? "アラームと身支度の工程（\(m.enabledSteps.count)）"
    }

    private var cleaningSummary: String {
        let b = model.cleaning
        if b.active != nil { return "清掃の途中です" }
        let n = b.neglected(now: model.now, time: model.time).count
        return n > 0 ? "目標日を過ぎた箇所 \(n)" : "場所 \(b.areas.count)・\(b.history.count)回の記録"
    }

    private func row(_ title: String, _ symbol: String, _ tint: Color, _ detail: String?) -> some View {
        HStack(spacing: 12) {
            icon(symbol, tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }

    private func setNotify(_ on: Bool) {
        guard on else { model.setNotifications(enabled: false); return }
        Task { @MainActor in
            if await NotificationScheduler.requestAuthorization() {
                model.setNotifications(enabled: true)
            } else {
                model.errorMessage = "通知が許可されていません。iPhone の「設定 › 通知 › My Time」で許可してください。"
            }
        }
    }

    private var pendingSummary: String {
        let n = model.events.filter { isShiftPending($0) }.count
        return n == 0 ? "カレンダーで日を選んでまとめて設定" : "調整中のシフト \(n)件"
    }

    private var tomorrowPlanSummary: String {
        let d1 = model.time.addDays(model.time.startOfDay(model.now), 1)
        guard let p = model.dayPlan(d1) else { return "明日の計画を下書きして、承認で予定にする" }
        return p.isApproved ? "明日の計画は承認済み（\(p.items.count)件）" : "下書き \(p.items.count)件・まだ承認していません"
    }

    private var initials: String {
        let n = accountName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "?" : String(n.prefix(n.unicodeScalars.first.map { $0.value < 0x3000 } == true ? 2 : 1)).uppercased()
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(v)（\(b)）"
    }
}

/// 操作のしかた（タップ以外の操作をまとめて見られる）
struct GestureGuideView: View {
    private struct Item: Identifiable { var id: String { title }; var symbol: String; var title: String; var detail: String }

    private let sections: [(String, [Item])] = [
        ("今日・カレンダーの時刻軸", [
            Item(symbol: "hand.tap", title: "予定をタップ", detail: "カードが開き、編集・複製・ずらす・削除ができます"),
            Item(symbol: "hand.point.up.left.and.text", title: "空いている所を長押し→上下になぞる", detail: "その時間で新しく追加します（左は予定、右はタスク）"),
            Item(symbol: "arrow.up.and.down", title: "予定を長押し→上下になぞる", detail: "15分刻みで動かします。重なると赤い枠が出ます"),
            Item(symbol: "arrow.up.and.down.square", title: "上端・下端を長押し→なぞる", detail: "開始・終了だけを変えます"),
            Item(symbol: "hand.raised", title: "動かさずに長押し", detail: "開く・編集・複製・削除のメニュー"),
            Item(symbol: "arrow.left.and.right", title: "左右にスワイプ", detail: "前の日・次の日へ（今日の画面）"),
            Item(symbol: "arrow.up.left.and.arrow.down.right", title: "ピンチ", detail: "時刻軸を広げたり縮めたりします"),
        ]),
        ("タスク", [
            Item(symbol: "slider.horizontal.below.rectangle", title: "行を長押し→横になぞる", detail: "進み具合（実績）を記録します。100%で完了の確認"),
            Item(symbol: "arrow.right", title: "一覧で右へスワイプ", detail: "完了にします"),
            Item(symbol: "arrow.left", title: "一覧で左へスワイプ", detail: "削除・フラグ"),
            Item(symbol: "contextualmenu.and.cursorarrow", title: "一覧で長押し", detail: "開く・完了・フラグ・今日にする・削除"),
        ]),
        ("新しく追加", [
            Item(symbol: "slider.horizontal.3", title: "時間のバーをなぞる", detail: "中ほどで時間ごと移動、端で開始・終了を変更（5分刻み）"),
            Item(symbol: "calendar.day.timeline.left", title: "日付を左右になぞる", detail: "前の日・次の日にします（時刻はそのまま）"),
            Item(symbol: "return", title: "名前を入れて改行", detail: "そのまま追加します"),
            Item(symbol: "text.bubble", title: "文章で追加", detail: "「明日10時から1時間 歯医者」のように書くだけ"),
        ]),
        ("取り消し", [
            Item(symbol: "arrow.uturn.backward", title: "下に出るお知らせの「取り消す」", detail: "移動・削除・完了などを元に戻せます（5秒間）"),
        ]),
    ]

    var body: some View {
        List {
            ForEach(sections, id: \.0) { title, items in
                Section(title) {
                    ForEach(items) { it in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: it.symbol)
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.title).font(.body.weight(.medium))
                                Text(it.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle("操作のしかた")
        .navigationBarTitleDisplayMode(.inline)
    }
}
