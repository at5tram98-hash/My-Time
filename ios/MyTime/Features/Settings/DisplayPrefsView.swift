import SwiftUI
import MyTimeCore

/// 表示と動き：画面の見え方・押したときの反応・朝とアラームの決まりを、自分に合わせて選ぶ
struct DisplayPrefsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.tapSpeed) private var tapSpeed = 1
    @AppStorage(Prefs.tabMinimize) private var tabMinimize = true
    @AppStorage(Prefs.travelBuffer) private var travelBuffer = 20
    @AppStorage(Prefs.wakeMargin) private var wakeMargin = 30
    @AppStorage(Prefs.wakeLead) private var wakeLead = 15
    @AppStorage(Prefs.morningLead) private var morningLead = 120
    @AppStorage(Prefs.tickerOn) private var tickerOn = true
    @AppStorage(Prefs.tickerSeconds) private var tickerSeconds = 5
    @AppStorage(Prefs.otherPeople) private var otherPeople = "faint"
    @AppStorage(Prefs.weekFromToday) private var weekFromToday = true
    @AppStorage("calendar.monthRowHeight2") private var monthRow: Double = 128
    @State private var changed = 0

    var body: some View {
        Form {
            Section {
                Picker(selection: $tapSpeed) {
                    Text("はやい").tag(0); Text("ふつう").tag(1); Text("ゆっくり").tag(2)
                } label: { row("押して開く速さ", "hand.tap.fill", .blue) }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                Text(["軽く触れるだけで開きます", "少し押してから離すと開きます（おすすめ）", "しっかり押したときだけ開きます（誤って開きにくい）"][tapSpeed])
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(isOn: $tabMinimize) { row("下へ送るとタブバーを小さく", "rectangle.bottomthird.inset.filled", .gray) }
            } header: { Text("操作") } footer: { Text("タブバーの変更は、アプリを開き直すと反映されます。") }

            Section {
                Picker(selection: $otherPeople) {
                    Text("うすく").tag("faint"); Text("ふつう").tag("normal"); Text("出さない").tag("hidden")
                } label: { row("ほかの人の予定", "person.2.fill", .pink) }
                Picker(selection: $monthRow) {
                    Text("コンパクト").tag(56.0); Text("スタック").tag(96.0); Text("詳細").tag(128.0)
                } label: { row("月の表示", "calendar", .red) }
                Toggle(isOn: $weekFromToday) { row("週の表示は今日から", "calendar.badge.clock", .orange) }
            } header: { Text("カレンダー") } footer: { Text(weekFromToday ? "週の表示を開くと、今日が一番左に来ます。" : "週の表示を開くと、その週の日曜が一番左に来ます。") }

            Section {
                Toggle(isOn: $tickerOn.animation()) { row("お知らせの行", "text.line.first.and.arrowtriangle.forward", .teal) }
                if tickerOn {
                    Picker(selection: $tickerSeconds) {
                        Text("5秒").tag(5); Text("8秒").tag(8); Text("15秒").tag(15)
                    } label: { Text("切り替わる間隔") }
                }
            } header: { Text("今日") } footer: { Text("今日の上のカードの下に、出発・遅れ・このあとの予定などを順に出します。") }

            Section {
                Picker(selection: $morningLead) {
                    Text("1時間前").tag(60); Text("1時間半前").tag(90); Text("2時間前").tag(120); Text("2時間半前").tag(150)
                } label: { row("朝を置く時刻", "sunrise.fill", .orange) }
                Picker(selection: $wakeMargin) {
                    Text("15分").tag(15); Text("30分").tag(30); Text("45分").tag(45); Text("1時間").tag(60)
                } label: { row("起きてからのゆとり", "bed.double.fill", .indigo) }
                Picker(selection: $wakeLead) {
                    Text("10分前").tag(10); Text("15分前").tag(15); Text("20分前").tag(20); Text("30分前").tag(30)
                } label: { row("1つ目の起床アラーム", "alarm.fill", .orange) }
                Picker(selection: $travelBuffer) {
                    Text("なし").tag(0); Text("10分").tag(10); Text("20分").tag(20); Text("30分").tag(30)
                } label: { row("移動時間の余裕", "tram.fill", .green) }
            } header: { Text("朝とアラーム") } footer: {
                Text("起きる時刻＝最初の予定 − 移動時間 − 準備の見込み − ゆとり。移動時間は Apple マップの所要時間に余裕を足して入れます。")
            }
        }
        .navigationTitle("表示と動き")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: [wakeMargin, wakeLead, morningLead]) { _, _ in
            Prefs.apply()
            model.autoPlaceMornings()
            model.scheduleNotifications()
            changed += 1
        }
        .onChange(of: otherPeople) { _, _ in model.reload(); changed += 1 }
        .sensoryFeedback(.selection, trigger: changed)
    }

    private func row(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 12) {
            RowIcon(symbol: symbol, tint: tint)
            Text(title)
        }
    }
}
