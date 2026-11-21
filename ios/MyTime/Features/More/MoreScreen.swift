import SwiftUI
import Charts
import MyTimeCore

/// その他タブ。「今日」でできることは置かない。
/// ここだけにあるもの：記録（連続日数・今週の作業・振り返り・操作履歴）、使い方、通知と外観、設定、このアプリについて
struct MoreScreen: View {
    @AppStorage("clock.showSeconds") private var showSeconds = true
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @AppStorage(AccountKeys.name) private var accountName = ""
    @AppStorage(AccountKeys.school) private var accountSchool = ""

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.morePath) {
            let stats = weekStats()
            List {
                // 振り返り（アカウントは上のバーへ移し、ここを広げてグラフを出す）
                Section { header(stats) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                Section {
                    ReviewDashboard(minutes: stats.minutes)
                    NavigationLink(value: MoreRoute.review) {
                        Label("くわしい振り返り", systemImage: "chart.bar.xaxis")
                    }
                    NavigationLink { HistoryView() } label: { Label("操作履歴", systemImage: "clock.arrow.circlepath") }
                } header: { Text("振り返り") }

                Section("計画") {
                    NavigationLink(value: MoreRoute.dayPlan) {
                        row("翌日計画", "list.clipboard.fill", .indigo, tomorrowPlanSummary)
                    }
                }

                Section("勤務先") {
                    NavigationLink(value: MoreRoute.employers) {
                        row("勤務先と給与", "yensign.circle.fill", .green, model.employers.isEmpty ? "時給・交通費・締め日を登録" : "勤務先 \(model.employers.count)・給与の見込み")
                    }
                    NavigationLink { ShiftPendingView() } label: {
                        row("シフトの調整中", "hourglass", .orange, pendingSummary)
                    }
                }

                Section("表示と種類") {
                    NavigationLink(value: MoreRoute.specSettings) {
                        row("種類ごとの設定", "square.stack.3d.up.fill", .blue, "授業・バイト・試験など種類ごとの見た目と既定")
                    }
                    NavigationLink(value: MoreRoute.live) {
                        row("ロック画面の表示", "platter.filled.top.iphone", .indigo, "Live Activity・ダイナミックアイランドに出すもの")
                    }
                    NavigationLink { StudioListView() } label: {
                        row("Create Studio", "sparkles", .purple, model.studioTypes.isEmpty ? "自分専用の種類を作る" : "自分の種類 \(model.studioTypes.filter { $0.status != "hidden" }.count)個")
                    }
                }

                Section("使い方") {
                    NavigationLink { GestureGuideView() } label: { row("操作のしかた", "hand.draw.fill", .pink, "長押し・なぞる・スワイプでできること") }
                }

                Section("データ") {
                    NavigationLink { ChatGPTTransferView() } label: {
                        row("ChatGPT", "bubble.left.and.text.bubble.right.fill", Color(hex: "#10A37F"),
                            !model.chatGPT.proposals.isEmpty ? "確認が必要 \(model.chatGPT.proposals.count)件"
                            : model.chatGPT.connected ? "つながっています・変更はすぐ反映" : "話しかけて予定を編集・TimeTree からコピー")
                    }
                    NavigationLink(value: MoreRoute.autoDelete) {
                        row("自動削除", "trash.slash.fill", .red, model.autoDeletePrefs.enabled ? "終わって\(model.autoDeletePrefs.days)日後に削除" : "オフ")
                    }
                    NavigationLink { DiagnosticsView() } label: {
                        row("診断", "stethoscope", .gray, "許可・予約の件数・最近の失敗")
                    }
                }

                Section("通知・アラーム・表示") {
                    Toggle(isOn: Binding(get: { model.notificationsEnabled }, set: setNotify)) {
                        row("通知", "bell.badge.fill", .red, model.notificationsEnabled ? "予定の\(model.notifyMinutesBefore == 0 ? "開始時刻" : "\(model.notifyMinutesBefore)分前")に知らせる" : "オフ")
                    }
                    Toggle(isOn: $showSeconds.animation(Motion.pop)) {
                        row("秒を表示", "clock.badge", .gray, "画面の上（時計の下）に小さく。iOS の時計そのものは変えられません")
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
                    Text("データはこの iPhone の中だけに保存されます（自動の同期はまだありません）。Web 版とは「設定 › データの移行」で手動でやり取りできます。")
                }
            }
            .navigationTitle("その他")
            .toolbar {
                // アカウント（名前の頭文字の丸）：押すとアカウント・自宅と学校・データ
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { AccountView() } label: {
                        Text(initials)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                    }
                    .accessibilityLabel("アカウント")
                }
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
                case .employers: EmployersView()
                case .payroll: PayrollView()
                case .specSettings: SpecSettingsListView()
                case .live: LiveActivitySettingsView()
                case .autoDelete: AutoDeleteView()
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
            for t in model.analysisTasks { for iv in t.intervals { let s = max(iv.start, d0), e = min(iv.end ?? model.now, d1); if e > s { ms += e - s } } }
            return Int(ms / MINUTE)
        }
        func done(_ d0: EpochMs) -> Int {
            let d1 = model.time.addDays(d0, 1)
            return model.analysisTasks.filter { t in
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


// MARK: - 振り返りのグラフ（その他の画面に広げて出す）

/// 直近7日の作業時間の棒（下から伸びる）・今週の予定の時間の内訳（ドーナツ）・今週のタスクの達成（輪）
struct ReviewDashboard: View {
    var minutes: [Int]
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false
    @State private var page = 0

    private struct Slice: Identifiable { var id: String { name }; var name: String; var minutes: Int; var color: Color }

    var body: some View {
        let slices = weekSlices()
        let rate = completion()
        VStack(alignment: .leading, spacing: 12) {
            // 3つのグラフを横にめくる（カルーセル）
            TabView(selection: $page) {
                barCard.tag(0)
                donutCard(slices).tag(1)
                ringCard(rate).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 196)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(i == page ? Color.primary.opacity(0.6) : Color.primary.opacity(0.18))
                        .frame(width: i == page ? 16 : 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: page)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 6)
        .onAppear {
            grown = false
            withAnimation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.8).delay(0.15)) { grown = true }
        }
        .sensoryFeedback(.selection, trigger: page)
    }

    private var barCard: some View {
        let today = model.time.startOfDay(model.now)
        let rows = minutes.enumerated().map { (i, m) in (day: model.time.addDays(today, i - (minutes.count - 1)), m: m) }
        let total = minutes.reduce(0, +)
        return VStack(alignment: .leading, spacing: 6) {
            Text("作業した時間").font(.subheadline.weight(.semibold))
            Text(formatDuration(EpochMs(total) * MINUTE) + "・直近7日").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Chart(rows, id: \.day) { r in
                BarMark(x: .value("日", model.time.date(r.day), unit: .day), y: .value("分", grown ? r.m : 0))
                    .foregroundStyle(model.time.isSameDay(r.day, model.now) ? AnyShapeStyle(Color.green.gradient) : AnyShapeStyle(Color.green.opacity(0.45).gradient))
                    .cornerRadius(4)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
            .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine(); AxisValueLabel() } }
            .overlay {
                if total == 0 {
                    Label("タスクを始めると、ここに作業した時間が出ます", systemImage: "play.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("直近7日の作業時間")
        }
        .padding(.horizontal, 4)
    }

    private func donutCard(_ slices: [Slice]) -> some View {
        let total = slices.reduce(0) { $0 + $1.minutes }
        return VStack(alignment: .leading, spacing: 6) {
            Text("今週の予定の時間").font(.subheadline.weight(.semibold))
            if total == 0 {
                Text("今週はまだ予定がありません").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                HStack(spacing: 14) {
                    Chart(slices) { s in
                        SectorMark(angle: .value("分", grown ? s.minutes : 0), innerRadius: .ratio(0.62), angularInset: 1.5)
                            .foregroundStyle(s.color.gradient)
                            .cornerRadius(3)
                    }
                    .chartLegend(.hidden)
                    .frame(width: 130, height: 130)
                    .overlay {
                        VStack(spacing: 0) {
                            Text(formatDuration(EpochMs(total) * MINUTE)).font(.subheadline.weight(.bold)).monospacedDigit()
                            Text("合計").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(slices.prefix(5)) { s in
                            HStack(spacing: 6) {
                                Circle().fill(s.color).frame(width: 8, height: 8)
                                Text(s.name).font(.caption).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(Int((Double(s.minutes) / Double(total) * 100).rounded()))%").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private func ringCard(_ rate: (done: Int, total: Int)) -> some View {
        let v = rate.total == 0 ? 0 : Double(rate.done) / Double(rate.total)
        return VStack(alignment: .leading, spacing: 6) {
            Text("今週のタスク").font(.subheadline.weight(.semibold))
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Color.blue.opacity(0.15), lineWidth: 14)
                    Circle().trim(from: 0, to: grown ? v : 0)
                        .stroke(Color.blue.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(Int((v * 100).rounded()))%").font(.title2.weight(.bold)).monospacedDigit().contentTransition(.numericText())
                        Text("達成").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("済んだ", value: "\(rate.done)件")
                    LabeledContent("今週の予定", value: "\(rate.total)件")
                    Text(v >= 0.8 ? "よいペースです" : v >= 0.5 ? "あと少し" : rate.total == 0 ? "今週のタスクはありません" : "これから巻き返せます")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    /// 今週（月曜から）の自分の予定の時間を、種類ごとに
    private func weekSlices() -> [Slice] {
        let today = model.time.startOfDay(model.now)
        let monday = model.time.addDays(today, -((model.time.weekday(today) + 6) % 7))
        var by: [String: (Int, Color)] = [:]
        for o in model.myEvents(from: monday, to: model.time.addDays(monday, 7)) where !o.event.allDay {
            let name = o.event.specType.flatMap { SPEC_BY_ID[$0]?.name } ?? "そのほか"
            let c = o.event.specType.map { model.specTint($0) } ?? Color.gray
            let m = Int((o.end - o.start) / MINUTE)
            by[name] = ((by[name]?.0 ?? 0) + m, c)
        }
        return by.map { Slice(name: $0.key, minutes: $0.value.0, color: $0.value.1) }.sorted { $0.minutes > $1.minutes }
    }

    /// 今週（月曜から）に予定していたタスクのうち、済んだ数
    private func completion() -> (done: Int, total: Int) {
        let today = model.time.startOfDay(model.now)
        let monday = model.time.addDays(today, -((model.time.weekday(today) + 6) % 7))
        let end = model.time.addDays(monday, 7)
        let xs = model.tasks.filter { t in
            guard let a = taskAnchor(t) ?? t.onDay else { return false }
            return a >= monday && a < end
        }
        return (xs.filter(\.isDone).count, xs.count)
    }
}
