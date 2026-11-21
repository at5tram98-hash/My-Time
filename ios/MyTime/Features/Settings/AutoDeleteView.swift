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

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let plan = AutoCleanup.plan(model: model, prefs: AutoDeletePrefs.enabledCopy(p), now: model.now)
        let total = plan.events.count + plan.tasks.count + plan.checkpoints.count
        Form {
            // 1. どうなるのか（流れの図）：終わる → N日後に見えなくなる → 1か月後に完全に削除
            Section {
                flow
                    .listRowInsets(EdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12))
            } footer: {
                Text("繰り返しの予定は削除しません。見えなくなってから1か月の間は、下の「保管中」から元に戻せます。")
            }

            // 2. オン・オフと日数
            Section {
                Toggle(isOn: bind(\.enabled)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("終わったものを自動で片づける")
                        Text(p.enabled ? "アプリを開いたときに片づけます" : "いまはオフ（何も削除しません）")
                            .font(.caption).foregroundStyle(p.enabled ? .green : .secondary)
                    }
                }
                .tint(.green)
                if p.enabled {
                    GlassSlider(value: bind(\.days), steps: [2, 3, 5, 7, 10, 14, 21, 30], label: { "\($0)日後" },
                                tint: .orange, symbol: "calendar.badge.minus", title: "終わってから")
                    Toggle(isOn: bind(\.includeUnfinishedTasks)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("やり残したタスクも片づける")
                            Text("完了していなくても、予定の日を過ぎたタスクを対象にします").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("設定") }

            // 3. 次に片づくもの（大きな数と内訳）
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(total)").font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text("件").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(p.enabled ? "次に片づくもの" : "オンにすると片づくもの").font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    chip("予定", plan.events.count, "calendar", .red)
                    chip("タスク", plan.tasks.count, "checklist", .blue)
                    chip("チェックポイント", plan.checkpoints.count, "flag.checkered", .orange)
                }
                Button(role: .destructive) { confirmRun = true } label: {
                    Label("いま片づける", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .disabled(total == 0)
            }

            // 4. 保管中（元に戻せるもの）
            Section {
                LabeledContent("予定", value: "\(model.archivedEvents.count)件")
                LabeledContent("タスク", value: "\(model.archivedTasks.count)件")
                if !model.archivedEvents.isEmpty || !model.archivedTasks.isEmpty {
                    Button("すべて元に戻す", systemImage: "arrow.uturn.backward") { AutoCleanup.restoreAll(model: model) }
                }
            } header: { Text("保管中（1か月）") } footer: {
                Text("片づけた予定・タスクは画面には出ませんが、振り返りのために1か月だけ iPhone の中に残し、そのあと完全に削除します。チェックポイントはすぐに完全に削除します。")
            }
        }
        .navigationTitle("自動削除")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: done)
        .onAppear { withAnimation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) { appeared = true } }
        .alert("いま片づけますか？", isPresented: $confirmRun) {
            Button("片づける", role: .destructive) {
                var x = p; x.enabled = true
                let before = model.autoDeletePrefs
                model.saveAutoDeletePrefs(x)
                AutoCleanup.run(model: model)
                model.saveAutoDeletePrefs(before.enabled ? x : before)
                done += 1
            }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("予定 \(plan.events.count)件・タスク \(plan.tasks.count)件は1か月だけ保管します（元に戻せます）。チェックポイント \(plan.checkpoints.count)件は完全に削除します。") }
    }

    /// 流れの図（3つの段。線が左から伸びて、段が順に浮かぶ）
    private var flow: some View {
        HStack(alignment: .top, spacing: 0) {
            step("checkmark.circle.fill", .green, "終わる", "予定・タスク", 0)
            arrow(1)
            step("eye.slash.fill", .orange, p.enabled ? "\(p.days)日後" : "—", "画面から消える", 1)
            arrow(2)
            step("trash.fill", .red, "1か月後", "完全に削除", 2)
        }
        .opacity(p.enabled ? 1 : 0.45)
        .saturation(p.enabled ? 1 : 0)
        .animation(.snappy, value: p.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(p.enabled ? "終わってから\(p.days)日後に画面から消え、1か月後に完全に削除します" : "自動削除はオフです")
    }

    private func step(_ symbol: String, _ tint: Color, _ title: String, _ sub: String, _ i: Int) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(tint.gradient))
                .scaleEffect(appeared ? 1 : 0.4)
                .opacity(appeared ? 1 : 0)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.7).delay(0.12 * Double(i)), value: appeared)
            Text(title).font(.subheadline.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
            Text(sub).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func arrow(_ i: Int) -> some View {
        GeometryReader { g in
            Capsule().fill(Color(.separator))
                .frame(width: appeared ? g.size.width : 0, height: 2)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35).delay(0.1 * Double(i)), value: appeared)
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(width: 26, height: 46)
    }

    private func chip(_ title: String, _ n: Int, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
            Text("\(n)").font(.headline).monospacedDigit().contentTransition(.numericText())
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.tertiarySystemFill)))
    }

    private func row(_ title: String, _ n: Int, _ symbol: String) -> some View {
        LabeledContent { Text("\(n)件").monospacedDigit().contentTransition(.numericText()) } label: { Label(title, systemImage: symbol) }
    }
}

extension AutoDeletePrefs {
    /// 件数の見積もり用（オフでもオンにしたときの件数を出す）
    static func enabledCopy(_ p: AutoDeletePrefs) -> AutoDeletePrefs { var x = p; x.enabled = true; return x }
}
