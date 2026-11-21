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

            // 朝のまとめ（出発・起床・準備の見込み）を横にめくるカードに（縦に長くしない）
            Section {
                let plan = first.map { DeparturePlan.make(eventStart: $0.start, travelMinutes: $0.event.travelMinutes, routine: r) }
                let wakes = model.autoWakeAlarms.filter { w in first.map { model.time.isSameDay(w.at, $0.start) } ?? false }
                CardCarousel(count: 3, height: 128) { i in
                    switch i {
                    case 0:
                        CarouselCard(title: "出発の目安", symbol: "figure.walk.departure", tint: .orange) {
                            if let f = first {
                                Text(plan?.leaveAt.map { "\(model.hm($0))に出発" } ?? "\(model.hm(f.start))に開始")
                                    .font(.title2.weight(.bold)).monospacedDigit()
                                Text("\(model.hm(f.start)) \(f.title)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                if plan?.leaveAt == nil { Text("予定に移動時間を入れると、出発の時刻を出します").font(.caption2).foregroundStyle(.tertiary) }
                            } else {
                                Text("この日は予定がありません").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    case 1:
                        CarouselCard(title: "起床アラーム", symbol: "alarm.fill", tint: .orange) {
                            if wakes.isEmpty {
                                Text(r.alarms.contains(where: \.enabled) ? "自分で決めたアラームで鳴らします" : "鳴らすアラームはありません")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    ForEach(wakes, id: \.key) { w in
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(model.hm(w.at)).font(.title2.weight(.bold)).monospacedDigit()
                                            Text(w.first ? "1つ目" : "起きる時刻").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Text("予定に合わせて自動（ゆとり30分）").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    default:
                        CarouselCard(title: "準備にかかる見込み", symbol: "timer", tint: .blue) {
                            Text(est.minutes > 0 ? "約\(est.minutes)分" : "—").font(.title2.weight(.bold)).monospacedDigit()
                            Text(est.unknown > 0 ? "時間の分からない工程が\(est.unknown)つ" : "工程 \(r.enabledSteps.count)つ")
                                .font(.subheadline).foregroundStyle(.secondary)
                            if let p = plan?.prepStartAt { Text("\(model.hm(p))までに準備を始める").font(.caption2).foregroundStyle(.tertiary) }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
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

            // 場所ごとの達成：横にめくるカード（輪が目標どおりの割合まで伸びる）
            Section {
                CardCarousel(count: max(1, b.areas.count), height: 118) { i in
                    if b.areas.indices.contains(i) {
                        let a = b.areas[i]
                        let v = b.areaAchievement(a, now: now, time: model.time)
                        CarouselCard(title: a.name, symbol: a.symbol, tint: .teal, action: { router.closeAll(); router.openTasks(.cleaning) }) {
                            HStack(spacing: 14) {
                                AchievementRing(value: v ?? 0, tint: .teal).frame(width: 58, height: 58)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.map { "\(Int(($0 * 100).rounded()))%" } ?? "—").font(.title2.weight(.bold)).monospacedDigit()
                                    Text("目標どおり・\(a.items.count)項目").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        CarouselCard(title: "場所", symbol: "house", tint: .teal) { Text("場所がありません").foregroundStyle(.secondary) }
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            } header: { Text("場所") }

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


/// 達成の輪（表示されたときに0から伸びる）
struct AchievementRing: View {
    var value: Double
    var tint: Color
    var lineWidth: CGFloat = 8
    @State private var shown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle().trim(from: 0, to: shown).stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .onAppear { withAnimation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.85).delay(0.1)) { shown = value } }
        .onChange(of: value) { _, v in withAnimation(.snappy) { shown = v } }
        .accessibilityHidden(true)
    }
}
