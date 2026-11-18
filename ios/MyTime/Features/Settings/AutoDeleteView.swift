import SwiftUI
import MyTimeCore

/// 自動削除の設定。終わってから決めた日数がたったものを片づける
struct AutoDeleteView: View {
    @Environment(AppModel.self) private var model
    /// 保存している設定を直接読み書きする（画面が作り直されても戻らない）
    private var p: AutoDeletePrefs { model.autoDeletePrefs }
    private func bind<T>(_ k: WritableKeyPath<AutoDeletePrefs, T>) -> Binding<T> {
        Binding(get: { model.autoDeletePrefs[keyPath: k] }, set: { v in
            var x = model.autoDeletePrefs
            x[keyPath: k] = v
            withAnimation(Motion.pop) { model.saveAutoDeletePrefs(x) }
        })
    }
    @State private var confirmRun = false
    @State private var done = 0

    var body: some View {
        let plan = AutoCleanup.plan(model: model, prefs: AutoDeletePrefs.enabledCopy(p), now: model.now)
        Form {
            Section {
                Toggle(isOn: bind(\.enabled)) {
                    Label("自動で削除する", systemImage: "trash.slash")
                }
                .tint(.red)
                if p.enabled {
                    GlassSlider(value: bind(\.days), steps: [1, 2, 3, 5, 7, 10, 14, 21, 30], label: { "\($0)日後" },
                                tint: .red, symbol: "calendar.badge.minus", title: "終わってから")
                    Toggle("終わっていないタスクも削除", isOn: bind(\.includeUnfinishedTasks))
                }
            } footer: {
                Text("アプリを開いたときに、終わった予定・タスク・チェックポイントを削除します。繰り返しの予定は削除しません。")
            }

            Section {
                row("予定", plan.events.count, "calendar")
                row("タスク", plan.tasks.count, "checklist")
                row("チェックポイント", plan.checkpoints.count, "flag.checkered")
                Button(role: .destructive) { confirmRun = true } label: {
                    Label("いま削除する", systemImage: "trash")
                }
                .disabled(plan.events.isEmpty && plan.tasks.isEmpty && plan.checkpoints.isEmpty)
            } header: { Text(p.enabled ? "次に削除されるもの" : "オンにすると削除されるもの") }

            Section {
                LabeledContent("中に残している予定", value: "\(model.archivedEvents.count)件")
                LabeledContent("中に残しているタスク", value: "\(model.archivedTasks.count)件")
                if !model.archivedEvents.isEmpty || !model.archivedTasks.isEmpty {
                    Button("すべて元に戻す", systemImage: "arrow.uturn.backward") { AutoCleanup.restoreAll(model: model) }
                }
            } header: { Text("分析のための保存") } footer: {
                Text("削除した予定・タスクは画面には出ませんが、振り返りの分析のために1か月は iPhone の中に残し、その後に完全に削除します。チェックポイントはすぐに完全に削除します。")
            }
        }
        .navigationTitle("自動削除")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: done)
        .alert("いま削除しますか？", isPresented: $confirmRun) {
            Button("削除", role: .destructive) {
                var x = p; x.enabled = true
                let before = model.autoDeletePrefs
                model.saveAutoDeletePrefs(x)
                AutoCleanup.run(model: model)
                model.saveAutoDeletePrefs(before.enabled ? x : before)
                done += 1
            }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("予定 \(plan.events.count)件・タスク \(plan.tasks.count)件は1か月だけ中に残ります（元に戻せます）。チェックポイント \(plan.checkpoints.count)件は完全に削除します。") }
    }

    private func row(_ title: String, _ n: Int, _ symbol: String) -> some View {
        LabeledContent { Text("\(n)件").monospacedDigit().contentTransition(.numericText()) } label: { Label(title, systemImage: symbol) }
    }
}

extension AutoDeletePrefs {
    /// 件数の見積もり用（オフでもオンにしたときの件数を出す）
    static func enabledCopy(_ p: AutoDeletePrefs) -> AutoDeletePrefs { var x = p; x.enabled = true; return x }
}
