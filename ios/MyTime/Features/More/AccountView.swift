import SwiftUI
import MyTimeCore

/// アカウントの設定。名前・学校・学年、自宅と学校の住所（場所の候補に出る）、ログインと同期の状態、この端末のデータ
struct AccountView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AccountKeys.name) private var name = ""
    @AppStorage(AccountKeys.school) private var school = ""
    @AppStorage(AccountKeys.grade) private var grade = ""
    @AppStorage(AccountKeys.home) private var home = ""
    @AppStorage(AccountKeys.schoolAddress) private var schoolAddress = ""
    @State private var showSignInInfo = false

    var body: some View {
        Form {
            Section {
                labeled("名前", "person.fill", .blue) { TextField("名前", text: $name).multilineTextAlignment(.trailing).textContentType(.name) }
                labeled("学校", "graduationcap.fill", .indigo) { TextField("学校名", text: $school).multilineTextAlignment(.trailing).textContentType(.organizationName) }
                Picker(selection: $grade) {
                    Text("未設定").tag("")
                    ForEach(["中学1年", "中学2年", "中学3年", "高校1年", "高校2年", "高校3年", "大学1年", "大学2年", "大学3年", "大学4年", "大学院", "社会人"], id: \.self) { Text($0).tag($0) }
                } label: { rowLabel("学年", "number", .teal) }
            } header: { Text("プロフィール") } footer: { Text("この iPhone の中だけに保存します。") }

            Section {
                labeled("自宅", "house.fill", .orange) { TextField("住所", text: $home).multilineTextAlignment(.trailing).textContentType(.fullStreetAddress) }
                labeled(school.isEmpty ? "学校" : school, "building.columns.fill", .indigo) { TextField("住所", text: $schoolAddress).multilineTextAlignment(.trailing).textContentType(.fullStreetAddress) }
            } header: { Text("よく行く場所") } footer: { Text("予定の「場所と移動」で、最初に候補として出ます。") }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark").font(.title).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Google アカウント").font(.body.weight(.semibold))
                        Text("ログインしていません").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Button { showSignInInfo = true } label: { Label("Google でログイン", systemImage: "arrow.right.circle") }
            } header: { Text("ログインと同期") } footer: {
                Text("同期の準備として、変更は Web 版と同じ形で \(model.outboxPending) 件たまっています。今は「設定 › データの移行」で Web 版とやり取りできます。")
            }

            Section("この端末のデータ") {
                LabeledContent("予定", value: "\(model.events.count)件")
                LabeledContent("タスク", value: "\(model.tasks.count)件")
                LabeledContent("カレンダー", value: "\(model.calendars.count)個")
                LabeledContent("保存した場所", value: "\(model.settings.placeHistory.count)件")
            }
        }
        .navigationTitle("アカウント")
        .navigationBarTitleDisplayMode(.inline)
        .alert("iOS 版ではまだログインできません", isPresented: $showSignInInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Google ログインとクラウド同期は準備中です（秘密の鍵と本番のサーバーの設定が必要なため、確認してから進めます）。それまではデータはこの iPhone に保存されます。")
        }
    }

    private func rowLabel(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 12) { RowIcon(symbol: symbol, tint: tint); Text(title) }
    }

    private func labeled<C: View>(_ title: String, _ symbol: String, _ tint: Color, @ViewBuilder _ field: () -> C) -> some View {
        HStack(spacing: 12) {
            RowIcon(symbol: symbol, tint: tint)
            Text(title).fixedSize()
            field()
        }
    }
}
