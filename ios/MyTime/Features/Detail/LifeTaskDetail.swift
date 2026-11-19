import SwiftUI
import MyTimeCore

// MARK: - 種類ごとのタスクの詳細（朝・清掃）
//
// 進み具合の輪・実績の％・遅れ・作業した時間は出さない（朝や清掃には合わない）。
// その種類でいま知りたいことだけを、上から順に：
// - 朝：何時からか（一番初めの予定の2時間前）・出発の目安・工程の一覧と見込みの時間・起床アラーム
// - 清掃：やっていない場所（目標日を過ぎた順）・場所ごとの達成・前回の清掃

/// 朝のタスクの詳細
struct MorningTaskDetail: View {
    var task: MTTask
    var onDelete: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let r = model.morning
        let est = r.estimate()
        let first = firstEvent
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "sunrise.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Color.orange.gradient))
                    Text(task.title).font(.title2.weight(.bold))
                    if let s = task.plannedStart {
                        Text("\(model.time.dayLabel(s)) \(model.hm(s))〜\(task.plannedEnd.map(model.hm) ?? "")").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if task.isAutoMorning, let f = first {
                        Label("\(model.hm(f.start))の「\(f.title)」の2時間前に自動で置きました", systemImage: "wand.and.stars")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)

            Section {
                BigActionButton(title: r.active != nil ? "朝の準備を続ける" : task.isDone ? "もう一度始める" : "朝の準備を始める",
                                symbol: r.active != nil ? "arrow.forward.circle.fill" : "play.fill", tint: .orange, prominent: true) {
                    model.startTask(task, router: router)
                }
                .disabled(r.enabledSteps.isEmpty)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            // 実行中：今の工程と、何工程目か（％ではなく工程の数で）
            if let a = r.active, let c = a.current {
                Section("いま") {
                    HStack {
                        Text(c.name).font(.headline)
                        Spacer()
                        Text("\(a.index + 1) / \(a.steps.count)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.orange)
                    }
                    if let n = a.next { LabeledContent("次", value: n.name) }
                }
            }

            // 出発の目安（その日の一番初めの予定）
            if let f = first {
                let plan = DeparturePlan.make(eventStart: f.start, travelMinutes: f.event.travelMinutes, routine: r)
                Section("出発の目安") {
                    LabeledContent("最初の予定", value: "\(model.hm(f.start)) \(f.title)")
                    if let leave = plan.leaveAt {
                        LabeledContent("家を出る", value: model.hm(leave)).monospacedDigit()
                        if let p = plan.prepStartAt { LabeledContent("準備を始める", value: model.hm(p)).monospacedDigit() }
                    } else {
                        Text("予定に移動時間を入れると、家を出る時刻を出します。").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            // 工程（見込みの時間つき）
            Section {
                ForEach(r.enabledSteps) { s in
                    HStack {
                        Text(s.name)
                        Spacer()
                        if let a = r.average(stepId: s.id) {
                            Text("約\(max(1, Int((a.ms + MINUTE / 2) / MINUTE)))分").foregroundStyle(.secondary).monospacedDigit()
                        } else if let p = s.plannedMinutes {
                            Text("目安\(p)分").foregroundStyle(.tertiary).monospacedDigit()
                        }
                    }
                    .font(.subheadline)
                }
                Button("工程とアラームを編集", systemImage: "slider.horizontal.3") { router.closeAll(); router.openTasks(.morning) }
            } header: {
                Text("工程（\(r.enabledSteps.count)）")
            } footer: {
                Text(est.minutes > 0 ? "見込み 約\(est.minutes)分" + (est.unknown > 0 ? "（時間の分からない工程が\(est.unknown)つ）" : "") : "工程を1回通すと、かかった時間から見込みを出します。")
            }

            if !r.alarms.isEmpty {
                Section("起床アラーム") {
                    ForEach(r.alarms) { a in
                        HStack {
                            Text(String(format: "%d:%02d", a.hour, a.minute)).font(.title3.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(a.enabled ? .primary : .tertiary)
                            Text(a.label.isEmpty ? "アラーム" : a.label).font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: a.enabled ? "alarm.fill" : "alarm").foregroundStyle(a.enabled ? .orange : .secondary)
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive, action: onDelete) { Text("この朝を外す").frame(maxWidth: .infinity) }
            } footer: {
                if task.isAutoMorning { Text("外した日は、自動で置き直しません。") }
            }
        }
    }

    /// この朝の日の一番初めの予定（自分・時刻あり・取り消していない）
    private var firstEvent: EventOccurrence? {
        let base = task.plannedStart ?? model.now
        let d0 = model.time.startOfDay(base)
        return model.visibleEvents(from: d0, to: model.time.addDays(d0, 1))
            .filter { !$0.event.allDay && $0.event.calendarId == MTCalendar.selfId && $0.start >= base }
            .min { $0.start < $1.start }
    }
}

/// 清掃のタスクの詳細
struct CleaningTaskDetail: View {
    var task: MTTask
    var onDelete: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        let b = model.cleaning
        let now = model.now
        let neglected = b.neglected(now: now, time: model.time)
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 32, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Color.teal.gradient))
                    Text(task.title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
                    if let s = task.plannedStart {
                        Text("\(model.time.dayLabel(s)) \(model.hm(s))〜\(task.plannedEnd.map(model.hm) ?? "")").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .listRowBackground(Color.clear)

            Section {
                BigActionButton(title: b.active != nil ? "清掃を続ける" : "清掃を始める",
                                symbol: b.active != nil ? "arrow.forward.circle.fill" : "play.fill", tint: .teal, prominent: true) {
                    model.startTask(task, router: router)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            // やっていない場所（目標日を過ぎた順。上から5つ）
            Section {
                if neglected.isEmpty {
                    Label("どの場所も目標どおりです", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    ForEach(0..<min(5, neglected.count), id: \.self) { i in
                        let n = neglected[i]
                        HStack(spacing: 12) {
                            Image(systemName: n.area.symbol).foregroundStyle(.teal).frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n.item.name)
                                Text(n.area.name).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(n.overdue.map { "\($0)日過ぎ" } ?? "まだ一度も").font(.caption.weight(.semibold))
                                .foregroundStyle(n.overdue == nil ? Color.secondary : Color.orange)
                        }
                    }
                }
            } header: { Text("今日やるとよい所") }

            // 場所ごとの達成（目標どおりの割合）
            Section("場所") {
                ForEach(b.areas) { a in
                    HStack(spacing: 12) {
                        Image(systemName: a.symbol).foregroundStyle(.teal).frame(width: 24)
                        Text(a.name)
                        Spacer()
                        if let v = b.areaAchievement(a, now: now, time: model.time) {
                            Gauge(value: v) { EmptyView() }
                                .gaugeStyle(.accessoryCircularCapacity).tint(.teal).scaleEffect(0.55).frame(width: 30, height: 30)
                        }
                    }
                }
                Button("場所と項目を編集", systemImage: "slider.horizontal.3") { router.closeAll(); router.openTasks(.cleaning) }
            }

            if let last = b.history.first {
                Section("前回") {
                    LabeledContent("日にち", value: "\(model.time.dayLabel(last.startedAt)) \(model.hm(last.startedAt))")
                    let st = last.statuses(in: b.areas).map(\.status)
                    let c = CleaningSession.completion(st)
                    if c.total > 0 { LabeledContent("できた所", value: "\(c.done) / \(c.total)").monospacedDigit() }
                }
            }

            Section {
                Button(role: .destructive, action: onDelete) { Text("このタスクを削除").frame(maxWidth: .infinity) }
            }
        }
    }
}
