import SwiftUI
import MyTimeCore

// MARK: - 朝のホーム（アラーム・工程・出発の目安）

struct MorningHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var running = false
    @State private var editingAlarm: MorningAlarm?
    @State private var addingStep = false
    @State private var newStepName = ""
    @State private var newStepGroup = "顔"
    @State private var awake = 0
    @AppStorage(AppModel.autoWakeKey) private var autoWake = true

    var body: some View {
        let r = model.morning
        List {
            Section {
                Button { start() } label: {
                    Label(r.active != nil ? "朝の準備を続ける" : "朝の準備を始める", systemImage: r.active != nil ? "arrow.forward.circle.fill" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(.white)
                        .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .disabled(r.enabledSteps.isEmpty)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                Text("押すと工程を1つずつ案内します。ロック画面とダイナミックアイランドからも「完了」できます。")
            }

            departureSection(r)

            Section {
                // 予定に合わせて自動で（最初の予定 − 移動 − 準備の見込み − ゆとり30分。毎朝2つ）
                Toggle(isOn: Binding(get: { autoWake }, set: { v in
                    autoWake = v
                    if v { model.saveMorning(MorningAuto.turnOffManualAlarms(model.morning), message: "自動の起床アラームにしました") }
                    model.scheduleNotifications()
                })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("予定に合わせて自動で鳴らす")
                        Text("最初の予定・移動・準備の見込みから、ゆとりを30分とって2回").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.orange)
                if autoWake {
                    let wakes = model.autoWakeAlarms.filter { !$0.first }.prefix(4)
                    if wakes.isEmpty {
                        Label("これから7日間は、朝に予定がありません", systemImage: "moon.zzz")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(Array(wakes), id: \.key) { w in
                        HStack {
                            Text(model.time.dayLabel(w.day)).font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(model.hm(w.at - 15 * MINUTE))・\(model.hm(w.at))")
                                .font(.title3.weight(.semibold)).monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                ForEach(r.alarms) { a in
                    Button { editingAlarm = a } label: { alarmRow(a) }
                        .buttonStyle(.plain)
                        .swipeActions { Button("削除", systemImage: "trash", role: .destructive) { deleteAlarm(a) } }
                }
                if r.alarms.count < MorningRoutine.maxAlarms {
                    Button("アラームを追加", systemImage: "plus.circle.fill") {
                        let last = r.alarms.last
                        let m = (last.map { $0.hour * 60 + $0.minute + 5 } ?? 7 * 60)
                        editingAlarm = MorningAlarm(hour: (m / 60) % 24, minute: m % 60, label: "第\(r.alarms.count + 1)アラーム")
                    }
                }
                if !r.alarms.isEmpty {
                    Button { Task { await AlarmService.markAwake(model: model); awake += 1 } } label: {
                        Label("起床完了（今日の残りのアラームを止める）", systemImage: "sun.max.fill")
                    }
                }
            } header: {
                Text("起床アラーム（最大3つ）")
            } footer: {
                Text(alarmFooter)
            }

            Section {
                ForEach(r.steps) { s in
                    NavigationLink { MorningStepEditor(stepId: s.id) } label: { stepRow(s, routine: r) }
                        // 右へなぞると、その工程を今朝から使う・使わない（削除はしない）
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                var x = model.morning
                                if let i = x.steps.firstIndex(where: { $0.id == s.id }) { x.steps[i].enabled.toggle() }
                                model.saveMorning(x, message: s.enabled ? "「\(s.name)」を使わないようにしました" : "「\(s.name)」を使うようにしました")
                            } label: { Label(s.enabled ? "使わない" : "使う", systemImage: s.enabled ? "pause.circle" : "play.circle") }
                            .tint(s.enabled ? .gray : .orange)
                        }
                }
                .onMove { from, to in
                    var x = model.morning
                    x.steps.move(fromOffsets: from, toOffset: to)
                    model.saveMorning(x, message: "工程を並べ替えました")
                }
                .onDelete { idx in
                    var x = model.morning
                    x.steps.remove(atOffsets: idx)
                    model.saveMorning(x, message: "工程を削除しました")
                }
                Button("工程を追加", systemImage: "plus") { newStepName = ""; addingStep = true }
            } header: {
                HStack {
                    Text("工程（\(r.enabledSteps.count)）")
                    Spacer()
                    EditButton().font(.caption).textCase(nil)
                }
            } footer: {
                Text("「編集」で並べ替え（ドラッグ）、左へなぞって削除。オフにした工程は飛ばします。平均は実際に計った時間だけで出し、目安は実測として扱いません。")
            }

            if !r.history.isEmpty {
                Section("最近の朝") {
                    let recent = Array(r.history.prefix(7))
                    let maxMs = max(1, recent.map { $0.elapsed(now: $0.finishedAt ?? 0) }.max() ?? 1)
                    ForEach(recent) { run in
                        let ms = run.elapsed(now: run.finishedAt ?? run.startedAt)
                        HStack(spacing: 10) {
                            Text(model.time.dayLabel(run.startedAt)).font(.caption).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                            GeometryReader { g in
                                Capsule().fill(Color.orange.gradient).frame(width: max(6, g.size.width * CGFloat(ms) / CGFloat(maxMs)))
                            }
                            .frame(height: 8)
                            Text(formatSeconds(ms)).font(.caption.weight(.semibold)).monospacedDigit().frame(width: 64, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section {
                GlassSlider(value: Binding(get: { r.bufferMinutes }, set: { v in var x = model.morning; x.bufferMinutes = v; model.saveMorning(x) }),
                            steps: Array(stride(from: 0, through: 60, by: 5)), label: { $0 == 0 ? "ちょうど" : "\($0)分前" },
                            tint: .orange, symbol: "door.left.hand.open", title: "準備を終える（出発の）")
            }
        }
        .navigationTitle("朝")
        .navigationDestination(isPresented: $running) { MorningRunView() }
        .sheet(item: $editingAlarm) { a in MorningAlarmEditor(alarm: a).environment(model) }
        .alert("工程を追加", isPresented: $addingStep) {
            TextField("例：ヘアオイル", text: $newStepName)
            Button("顔に追加") { addStep("顔") }
            Button("髪に追加") { addStep("髪") }
            Button("その他に追加") { addStep("その他") }
            Button("キャンセル", role: .cancel) {}
        }
        .sensoryFeedback(.success, trigger: awake)
    }

    private var alarmFooter: String {
        let st = AlarmService.stateText
        if st == "許可済み" { return "時計アプリと同じアラーム（AlarmKit）で鳴らします。マナーモードでも鳴り、スヌーズできます。起床アラームは曜日ごとにくり返し予約します（タスクのアラームは7日先までを予約し、アプリを開くたびに足します）。" }
        return "アラームの許可：\(st)。許可が無いときは通知で代わりに知らせますが、通知は目覚ましのアラームと同じではありません（マナーモード・集中モードでは鳴らないことがあります）。"
    }

    @ViewBuilder
    private func departureSection(_ r: MorningRoutine) -> some View {
        let now = model.now
        let next = model.visibleEvents(from: now, to: now + 30 * HOUR).filter { !$0.event.allDay && $0.start > now }.min { $0.start < $1.start }
        let est = r.estimate()
        Section {
            if let n = next {
                let plan = DeparturePlan.make(eventStart: n.start, travelMinutes: n.event.travelMinutes, routine: r)
                LabeledContent("次の予定", value: "\(model.time.isSameDay(n.start, now) ? "" : model.time.dayLabel(n.start) + " ")\(model.hm(n.start)) \(n.title)")
                if let leave = plan.leaveAt, let prep = plan.prepStartAt {
                    LabeledContent("出発の目安", value: model.hm(leave))
                    LabeledContent("準備を始める目安", value: model.hm(prep)).fontWeight(.semibold)
                } else {
                    Label("移動時間が未入力のため、出発時刻は決めていません（予定の「場所と移動」で入れられます）", systemImage: "questionmark.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("30時間以内に予定はありません").foregroundStyle(.secondary)
            }
            LabeledContent("準備にかかる見込み", value: "\(est.minutes)分")
            if est.unknown > 0 {
                Text("\(est.unknown)工程は実測も目安も無いため0分で数えています").font(.caption).foregroundStyle(.orange)
            }
        } header: { Text("出発の目安") } footer: {
            Text("実測 \(est.measured)工程・目安 \(est.planned)工程から計算します。")
        }
    }

    private func alarmRow(_ a: MorningAlarm) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%d:%02d", a.hour, a.minute)).font(.system(size: 34, weight: .light, design: .rounded)).monospacedDigit()
                    .foregroundStyle(a.enabled ? Color.primary : Color.secondary)
                Text((a.label.isEmpty ? "アラーム" : a.label) + "・" + (a.weekdays.isEmpty ? "毎日" : a.weekdays.map { DomainTime.weekdayJa[$0] }.joined()) + (a.snoozeMinutes > 0 ? "・スヌーズ\(a.snoozeMinutes)分" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                if let n = a.next(after: model.now, time: model.time) {
                    Label(nextText(n), systemImage: "alarm").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                } else {
                    Text("オフ（鳴りません）").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .opacity(a.enabled ? 1 : 0.55)
            .animation(Motion.pop, value: a.enabled)
            Spacer()
            Toggle("", isOn: Binding(get: { a.enabled }, set: { v in
                var x = model.morning
                if let i = x.alarms.firstIndex(where: { $0.id == a.id }) { x.alarms[i].enabled = v }
                model.saveMorning(x)
            }))
            .labelsHidden()
            .tint(.orange)
        }
        .foregroundStyle(.primary)
    }

    /// 「今日 7:00」「明日 7:00」「11月20日(金) 7:00」
    private func nextText(_ n: EpochMs) -> String {
        let t = model.time
        let d = t.isSameDay(n, model.now) ? "今日" : t.isSameDay(n, t.addDays(model.now, 1)) ? "明日" : t.dayLabel(n)
        return "次は\(d) \(model.hm(n))"
    }

    private func stepRow(_ s: MorningStep, routine: MorningRoutine) -> some View {
        HStack(spacing: 10) {
            Text(s.group).font(.caption2.weight(.bold)).foregroundStyle(.orange)
                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.orange.opacity(0.14)))
            Text(s.name).foregroundStyle(s.enabled ? .primary : .secondary).strikethrough(!s.enabled)
            Spacer()
            if let a = routine.average(stepId: s.id) {
                Text("平均 \(formatSeconds(a.ms))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            } else if let p = s.plannedMinutes {
                Text("目安 \(p)分").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func start() {
        var x = model.morning
        if x.active == nil {
            x.active = MorningRun(startedAt: model.now, steps: x.enabledSteps)
            model.saveMorning(x)
        }
        running = true
    }

    private func addStep(_ group: String) {
        var x = model.morning
        let name = newStepName.trimmingCharacters(in: .whitespaces)
        x.steps.append(MorningStep(name: name.isEmpty ? "新しい工程" : name, group: group))
        model.saveMorning(x, message: "工程を追加しました")
    }

    private func deleteAlarm(_ a: MorningAlarm) {
        var x = model.morning
        x.alarms.removeAll { $0.id == a.id }
        model.saveMorning(x, message: "アラームを削除しました")
    }
}

func formatSeconds(_ ms: EpochMs) -> String {
    let s = Int(ms / 1000)
    return s < 60 ? "\(s)秒" : "\(s / 60)分\(s % 60 == 0 ? "" : "\(s % 60)秒")"
}

// MARK: - アラームの編集

struct MorningAlarmEditor: View {
    @State var alarm: MorningAlarm
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let isNew = !model.morning.alarms.contains { $0.id == alarm.id }
        NavigationStack {
            Form {
                Section {
                    DatePicker("時刻", selection: Binding(get: {
                        Calendar.current.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: Date()) ?? Date()
                    }, set: { d in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                        alarm.hour = c.hour ?? 7; alarm.minute = c.minute ?? 0
                    }), displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                Section("繰り返し（選ばなければ毎日）") { WeekdayChips(selection: $alarm.weekdays) }
                Section {
                    TextField("ラベル", text: $alarm.label)
                    Picker("サウンド", selection: $alarm.sound) {
                        ForEach(AlarmService.sounds, id: \.label) { s in Text(s.label).tag(s.name) }
                    }
                    Button("音を試しに聞く", systemImage: "speaker.wave.2") { SoundPreview.play(alarm.sound) }
                    GlassSlider(value: $alarm.snoozeMinutes, steps: [0, 3, 5, 9, 10, 15], label: { $0 == 0 ? "なし" : "\($0)分" },
                                tint: .orange, symbol: "zzz", title: "スヌーズ")
                    Toggle("オン", isOn: $alarm.enabled).tint(.orange)
                }
                if !isNew {
                    Section {
                        Button("アラームを削除", role: .destructive) {
                            var x = model.morning
                            x.alarms.removeAll { $0.id == alarm.id }
                            model.saveMorning(x, message: "アラームを削除しました")
                            dismiss()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(isNew ? "アラームを追加" : "アラームを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save(isNew: isNew) }.fontWeight(.semibold) }
            }
        }
    }

    private func save(isNew: Bool) {
        var x = model.morning
        if let i = x.alarms.firstIndex(where: { $0.id == alarm.id }) { x.alarms[i] = alarm }
        else if !x.addAlarm(alarm) { model.errorMessage = "アラームは3つまでです"; return }
        model.saveMorning(x, message: isNew ? "アラームを追加しました" : "アラームを変更しました")
        Task {
            if await !TaskAlarms.requestAuthorization() { _ = await NotificationScheduler.requestAuthorization() }
            await AlarmService.sync(model: model)
            model.scheduleNotifications()
        }
        dismiss()
    }
}

// MARK: - 工程の編集

struct MorningStepEditor: View {
    var stepId: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let r = model.morning
        if let i = r.steps.firstIndex(where: { $0.id == stepId }) {
            let s = r.steps[i]
            Form {
                Section {
                    TextField("工程の名前", text: Binding(get: { s.name }, set: { v in update { $0.steps[i].name = v } }))
                    Picker("まとまり", selection: Binding(get: { s.group }, set: { v in update { $0.steps[i].group = v } })) {
                        ForEach(Array(Set(["顔", "髪", "その他", s.group])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("この工程を行う", isOn: Binding(get: { s.enabled }, set: { v in update { $0.steps[i].enabled = v } })).tint(.orange)
                }
                Section {
                    GlassSlider(value: Binding(get: { s.plannedMinutes ?? 0 }, set: { v in update { $0.steps[i].plannedMinutes = v == 0 ? nil : v } }),
                                steps: [0, 1, 2, 3, 4, 5, 7, 10, 12, 15, 20, 25, 30, 45, 60], label: { $0 == 0 ? "未設定" : "\($0)分" },
                                tint: .orange, symbol: "timer", title: "目安の時間")
                    if let a = r.average(stepId: s.id) {
                        LabeledContent("実測の平均", value: "\(formatSeconds(a.ms))（\(a.count)回）")
                    } else {
                        LabeledContent("実測の平均", value: "まだ記録がありません")
                    }
                } footer: { Text("出発の目安は実測の平均を優先し、記録が無いときだけ目安を使います。") }
            }
            .navigationTitle(s.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("工程が見つかりません", systemImage: "questionmark")
        }
    }

    private func update(_ f: (inout MorningRoutine) -> Void) {
        var x = model.morning
        f(&x)
        model.saveMorning(x)
    }
}

// MARK: - 実行中の朝

struct MorningRunView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var feedback = 0
    @State private var finished: MorningRun?
    @State private var confirmQuit = false

    var body: some View {
        let r = model.morning
        Group {
            if let run = r.active, run.finishedAt == nil, let cur = run.current {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let now = model.time.ms(ctx.date)
                    VStack(spacing: 20) {
                        VStack(spacing: 6) {
                            Text("全\(run.steps.count)工程中 \(run.index + 1)工程目").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            ProgressView(value: Double(run.doneCount), total: Double(run.steps.count)).tint(.orange)
                                .animation(Motion.value, value: run.doneCount)
                        }
                        Spacer(minLength: 0)
                        VStack(spacing: 8) {
                            Text("現在").font(.caption.weight(.bold)).foregroundStyle(.orange)
                            Text(cur.name).font(.system(size: 40, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                                .minimumScaleFactor(0.5).lineLimit(2)
                                .contentTransition(.opacity)
                                .id(cur.id)
                                .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                            Text(clock(run.stepElapsed(now: now))).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
                                .foregroundStyle(run.isPaused ? .secondary : .primary)
                            if let a = r.average(stepId: cur.id) { Text("いつもは \(formatSeconds(a.ms))").font(.caption).foregroundStyle(.secondary) }
                        }
                        if let n = run.next {
                            Label("次：\(n.name)", systemImage: "arrow.turn.down.right").font(.headline).foregroundStyle(.secondary)
                        }
                        // 今日の持ち物（あれば）：準備の途中で確かめられる
                        let bring = BelongingsList.items(model: model).filter { $0.when.map { model.time.isSameDay($0, now) } ?? true }
                        let left = bring.reduce(0) { $0 + $1.items.filter { !$0.done }.count }
                        if !bring.isEmpty {
                            NavigationLink { BelongingsView() } label: {
                                Label(left == 0 ? "今日の持ち物はそろっています" : "今日の持ち物 あと\(left)個", systemImage: "bag.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Capsule().fill(Color.brown.opacity(0.14)))
                                    .foregroundStyle(left == 0 ? Color.green : Color.brown)
                            }
                        }
                        Spacer(minLength: 0)
                        Text("左へなぞると完了・右へなぞると前の工程").font(.caption2).foregroundStyle(.tertiary)
                        Text("準備の経過 \(clock(run.elapsed(now: now)))" + (run.isPaused ? "（一時停止中）" : "")).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        Button { act { $0.complete(now: model.now) } } label: {
                            Label("完了", systemImage: "checkmark").font(.title3.weight(.bold))
                                .symbolEffect(.bounce, value: run.index)
                                .frame(maxWidth: .infinity, minHeight: 60)
                                .foregroundStyle(.white)
                                .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                        HStack(spacing: 10) {
                            small("戻る", "chevron.backward", disabled: run.index == 0) { act { $0.back(now: model.now) } }
                            small(run.isPaused ? "再開" : "一時停止", run.isPaused ? "play.fill" : "pause.fill") {
                                act { run in run.isPaused ? run.resume(now: model.now) : run.pause(now: model.now) }
                            }
                            small("スキップ", "forward.end.fill") { act { $0.complete(now: model.now, skipped: true) } }
                        }
                    }
                    .padding()
                    // 画面のどこでも：左へなぞると完了、右へなぞると前の工程へ（ボタンを探さなくてよい）
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 40).onEnded { v in
                        guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                        if v.translation.width < 0 { act { $0.complete(now: model.now) } }
                        else if run.index > 0 { act { $0.back(now: model.now) } }
                    })
                    .background(alignment: .top) {
                        // 進むほど上から暖かい色が広がる（朝日のイメージ）
                        LinearGradient(colors: [Color.orange.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 120 + 380 * CGFloat(run.doneCount) / CGFloat(max(1, run.steps.count)))
                            .ignoresSafeArea()
                            .animation(Motion.value, value: run.doneCount)
                            .allowsHitTesting(false)
                    }
                    .animation(reduceMotion ? nil : .snappy, value: run.index)
                }
            } else if let f = finished ?? r.history.first(where: { $0.finishedAt != nil && r.active == nil }) {
                summary(f)
            } else {
                ContentUnavailableView("朝の準備は終わりました", systemImage: "sun.max", description: Text("朝の画面から始められます。"))
            }
        }
        .navigationTitle("朝の準備")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if r.active != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("やめる", role: .destructive) { confirmQuit = true }
                }
            }
        }
        .alert("朝の準備をやめますか？", isPresented: $confirmQuit) {
            Button("やめる（記録しない）", role: .destructive) {
                var x = model.morning
                x.active = nil
                model.saveMorning(x, message: "朝の準備をやめました")
                dismiss()
            }
            Button("続ける", role: .cancel) {}
        }
        .sensoryFeedback(.success, trigger: feedback)
    }

    private func act(_ f: (inout MorningRun) -> Void) {
        var x = model.morning
        guard var run = x.active else { return }
        f(&run)
        x.active = run
        if run.finishedAt != nil {
            finished = run
            x.finishActive()
        }
        model.saveMorning(x)
        feedback += 1
    }

    private func small(_ title: String, _ symbol: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func clock(_ ms: EpochMs) -> String {
        let s = Int(ms / 1000)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func summary(_ f: MorningRun) -> some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "sun.max.fill").font(.system(size: 48)).foregroundStyle(.orange)
                        .symbolEffect(.bounce, options: .nonRepeating, value: f.id)
                        .transition(.scale.combined(with: .opacity))
                    Text("準備ができました").font(.title3.weight(.bold))
                    let total = f.elapsed(now: f.finishedAt ?? model.now)
                    Text("合計 \(formatSeconds(total))").foregroundStyle(.secondary)
                    // 実測の平均からの見込みとの差（実測が無い工程があるときは比べない）
                    let est = model.morning.estimate()
                    if est.unknown == 0 && est.planned == 0 && est.minutes > 0 {
                        let diff = Int(total / MINUTE) - est.minutes
                        Text(diff == 0 ? "いつもどおり" : diff > 0 ? "いつもより\(diff)分長い" : "いつもより\(-diff)分短い")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(diff > 0 ? .orange : .green)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            Section("工程ごと") {
                ForEach(f.records, id: \.stepId) { rec in
                    LabeledContent(rec.name, value: rec.skipped ? "スキップ" : formatSeconds(rec.ms))
                }
            }
            Section { Button("閉じる") { dismiss() } }
        }
    }
}
