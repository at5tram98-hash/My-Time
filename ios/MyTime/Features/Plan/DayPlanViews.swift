import SwiftUI
import MyTimeCore

// MARK: 翌日の計画（その他から開く）

/// 明日の計画を、今日の画面と同じ時刻軸で下書きし、「承認」で本当の予定・タスクにする
struct DayPlanView: View {
    @Environment(AppModel.self) private var model
    @State private var day: EpochMs = 0
    @State private var editing: PlanItem?
    @State private var approvedFeedback = 0

    var body: some View {
        let plan = model.dayPlan(day) ?? DayPlan()
        VStack(spacing: 0) {
            // 日付（左右になぞる・矢印で変える）と状態
            VStack(spacing: 6) {
                DaySwipeRow(date: Binding(get: { model.time.date(day) }, set: { day = model.time.startOfDay(model.time.ms($0)) }),
                            onShift: { n in day = model.time.addDays(day, n) })
                HStack(spacing: 6) {
                    StatusPill(text: plan.isApproved ? "承認済み" : plan.items.isEmpty ? "まだ計画がありません" : "下書き・\(plan.items.count)件",
                               color: plan.isApproved ? .green : plan.items.isEmpty ? .secondary : .orange,
                               symbol: plan.isApproved ? "checkmark.seal.fill" : "pencil")
                    if plan.isApproved, let at = plan.approvedAt {
                        Text("\(model.time.dayLabel(at)) \(model.hm(at))に承認").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            Divider()

            HStack(spacing: 0) {
                Color.clear.frame(width: PlanBoard.gutter, height: 1)
                Label("予定 \(plan.items.filter { $0.kind == .event }.count)", systemImage: "calendar").frame(maxWidth: .infinity, alignment: .leading)
                Label("タスク \(plan.items.filter { $0.kind == .task }.count)", systemImage: "checklist").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .frame(height: 22)
            .padding(.vertical, 4).padding(.horizontal, 4)
            Divider()
            PlanBoard(day: day, plan: plan, editable: !plan.isApproved,
                      onCreate: { kind, s, e in editing = PlanItem(id: model.repo.newId(), kind: kind, title: "", start: s, end: e, calendarId: kind == .event ? model.calendars.first?.id : nil) },
                      onTap: { editing = $0 },
                      onChange: { item in update(plan) { p in if let i = p.items.firstIndex(where: { $0.id == item.id }) { p.items[i] = item } } })
        }
        .safeAreaInset(edge: .bottom) { bottomBar(plan) }
        .navigationTitle("翌日の計画")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !plan.isApproved {
                ToolbarItem(placement: .primaryAction) {
                    Button { addAtNextFreeHour(plan) } label: { Image(systemName: "plus") }.accessibilityLabel("計画を追加")
                }
            }
        }
        .onAppear { if day == 0 { day = model.time.addDays(model.time.startOfDay(model.now), 1) } }
        .sheet(item: $editing) { item in
            PlanItemEditor(item: item, isNew: !plan.items.contains { $0.id == item.id }, locked: plan.isApproved) { result in
                update(plan) { p in
                    p.items.removeAll { $0.id == item.id }
                    if let result { p.items.append(result) }
                }
            }
            .environment(model)
        }
        .sensoryFeedback(.success, trigger: approvedFeedback)
    }

    private func bottomBar(_ plan: DayPlan) -> some View {
        VStack(spacing: 6) {
            if plan.isApproved {
                Label("承認済み。予定・タスクは今日の画面で動かせます", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            } else {
                SlideToConfirm(title: plan.items.isEmpty ? "計画を入れると承認できます" : "スライドして承認（\(plan.items.count)件）",
                               symbol: "checkmark.seal.fill", tint: .green, enabled: !plan.items.isEmpty) {
                    if model.approveDayPlan(day) > 0 { approvedFeedback += 1 }
                }
                Text("左の予定・右のタスクの空いている所を長押ししてなぞると追加。承認すると本当の予定・タスクになります").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private func update(_ plan: DayPlan, _ change: (inout DayPlan) -> Void) {
        var p = plan
        change(&p)
        p.items.sort { $0.start < $1.start }
        model.saveDayPlan(day, p.items.isEmpty && !p.isApproved ? nil : p)
    }

    /// 右上の＋：最後の計画のあと（なければ9時）に1時間
    private func addAtNextFreeHour(_ plan: DayPlan) {
        let s = plan.items.map(\.end).max() ?? (day + 9 * HOUR)
        editing = PlanItem(id: model.repo.newId(), kind: .task, title: "", start: s, end: s + HOUR)
    }
}

// MARK: 計画の時刻軸（今日の画面と同じ操作）

struct PlanBoard: View {
    var day: EpochMs
    var plan: DayPlan
    var editable: Bool
    var onCreate: (PlanItem.Kind, EpochMs, EpochMs) -> Void
    var onTap: (PlanItem) -> Void
    var onChange: (PlanItem) -> Void

    @Environment(AppModel.self) private var model
    @State private var hourHeight: CGFloat = 56
    @State private var creating: (lane: Int, lo: Int, hi: Int)?
    @State private var blockDragging = false
    @State private var createTick = 0
    static let gutter: CGFloat = 46
    static let snap = 15

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    grid
                    GeometryReader { geo in
                        let w = geo.size.width - Self.gutter - 4
                        let lw = w / 2
                        ZStack(alignment: .topLeading) {
                            emptyArea(width: w)
                            Rectangle().fill(Color(.separator)).frame(width: 0.5, height: hourHeight * 24).offset(x: Self.gutter + lw).allowsHitTesting(false)
                            // その日にすでにある本当の予定（左のレーンに点線で）
                            ForEach(existing, id: \.id) { o in
                                let top = y(o.start), h = max(16, y(o.end) - y(o.start))
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color(hex: model.eventColor(o.event)).opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: model.eventColor(o.event)).opacity(0.06)))
                                    .overlay(alignment: .topLeading) {
                                        Text(o.title).font(.caption2).foregroundStyle(.secondary).padding(4).lineLimit(1)
                                    }
                                    .frame(width: lw - 4, height: h)
                                    .offset(x: Self.gutter + 2, y: top)
                                    .allowsHitTesting(false)
                            }
                            ForEach(placed) { p in
                                PlanBlock(item: p.item, hourHeight: hourHeight, editable: editable, onTap: { onTap(p.item) }, onChange: onChange, onDragging: { blockDragging = $0 })
                                    .frame(width: max(20, (lw - 4) / CGFloat(p.columns) - 2), height: max(22, y(p.item.end) - y(p.item.start) - 2))
                                    .offset(x: Self.gutter + (p.item.kind == .event ? 0 : lw) + 2 + (lw - 4) / CGFloat(p.columns) * CGFloat(p.column), y: y(p.item.start) + 1)
                            }
                            if let c = creating {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.18))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                                    .overlay(alignment: .topLeading) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(c.lane == 0 ? "予定" : "タスク").font(.caption2.weight(.bold))
                                            Text("\(hm(c.lo))〜\(hm(c.hi))").font(.caption.weight(.semibold))
                                        }
                                        .foregroundStyle(Color.accentColor).padding(6)
                                    }
                                    .frame(width: lw - 4, height: CGFloat(c.hi - c.lo) / 60 * hourHeight)
                                    .offset(x: Self.gutter + CGFloat(c.lane) * lw + 2, y: CGFloat(c.lo) / 60 * hourHeight)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .frame(height: hourHeight * 24 + 8)
            }
            .scrollDisabled(creating != nil || blockDragging)
            // 計画の最初（なければ7時）へ。表示が整ってから動かす
            .task(id: day) {
                try? await Task.sleep(for: .milliseconds(150))
                let first = plan.items.map(\.start).min().map { Int(($0 - day) / HOUR) } ?? 8
                proxy.scrollTo("h\(max(0, min(23, first - 1)))", anchor: .top)
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: createTick)
        }
    }

    struct Placed: Identifiable { var id: String { item.id }; var item: PlanItem; var column: Int; var columns: Int }

    /// レーンごとに、重なる計画を横に並べる
    private var placed: [Placed] {
        var out: [Placed] = []
        for kind in [PlanItem.Kind.event, .task] {
            let list = plan.items.filter { $0.kind == kind }
            let lay = Dictionary(layoutDay(list.map { TimedItem(id: $0.id, start: $0.start, end: $0.end) }, day: day, time: model.time).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for it in list { let p = lay[it.id]; out.append(Placed(item: it, column: p?.column ?? 0, columns: max(1, p?.columns ?? 1))) }
        }
        return out
    }

    private func updateCreating(start: CGPoint, current: CGPoint, moved: Bool, width: CGFloat) {
        guard editable else { return }
        let lane = start.x >= Self.gutter + width / 2 ? 1 : 0
        let anchor = Int(start.y / hourHeight * 60) / Self.snap * Self.snap
        let at = day + EpochMs(anchor) * MINUTE
        let laneKind: PlanItem.Kind = lane == 0 ? .event : .task
        // すでに計画がある時刻では作らない（計画の移動と取り合わない）
        if creating == nil, plan.items.contains(where: { $0.kind == laneKind && $0.start <= at && at < $0.end }) { return }
        let cur = Int((current.y / hourHeight * 60 / CGFloat(Self.snap)).rounded()) * Self.snap
        let end = !moved ? anchor + 60 : max(cur, anchor + Self.snap)
        if creating == nil { createTick += 1 }
        withAnimation(.interactiveSpring()) { creating = (creating?.lane ?? lane, max(0, min(anchor, end)), min(24 * 60, max(anchor, end))) }
    }

    private var existing: [EventOccurrence] {
        model.visibleEvents(from: day, to: model.time.addDays(day, 1)).filter { o in !o.event.allDay && !plan.items.contains(where: { p in p.refId == o.masterId }) }
    }

    private func y(_ t: EpochMs) -> CGFloat { CGFloat(t - day) / CGFloat(HOUR) * hourHeight }
    private func hm(_ m: Int) -> String { String(format: "%d:%02d", m / 60, m % 60) }

    private var grid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(h):00").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: Self.gutter - 8, alignment: .trailing).offset(y: -6).opacity(h == 0 ? 0 : 1)
                    Rectangle().fill(Color(.separator).opacity(0.6)).frame(height: 0.5)
                }
                .frame(height: hourHeight, alignment: .top)
                .id("h\(h)")
            }
        }
        .accessibilityHidden(true)
    }

    /// 空白の長押し→上下になぞって長さを決める→離すと作成画面
    private func emptyArea(width: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: Self.gutter + width, height: hourHeight * 24)
            // 長押し→上下になぞって範囲を決める（UIKit のジェスチャー：上下のスクロールを邪魔しない）
            .overlay {
                PressDragRecognizer(
                    minimumDuration: 0.4,
                    onBegan: { p in updateCreating(start: p, current: p, moved: false, width: width) },
                    onChanged: { p, t in updateCreating(start: CGPoint(x: p.x - t.width, y: p.y - t.height), current: p, moved: abs(t.height) > 6, width: width) },
                    onEnded: { _, _ in
                        guard let c = creating else { return }
                        creating = nil
                        onCreate(c.lane == 0 ? .event : .task, day + EpochMs(c.lo) * MINUTE, day + EpochMs(c.hi) * MINUTE)
                    },
                    onCancelled: { creating = nil }
                )
            }
            .accessibilityElement()
            .accessibilityLabel("計画の時刻軸")
            .accessibilityAction(named: "タスクの計画を追加") { if editable { onCreate(.task, day + 9 * HOUR, day + 10 * HOUR) } }
            .accessibilityAction(named: "予定の計画を追加") { if editable { onCreate(.event, day + 9 * HOUR, day + 10 * HOUR) } }
    }
}

/// 計画の1つ。タップで編集、長押し→上下で移動、下端をなぞって長さ
struct PlanBlock: View {
    var item: PlanItem
    var hourHeight: CGFloat
    var editable: Bool
    var onTap: () -> Void
    var onChange: (PlanItem) -> Void
    var onDragging: (Bool) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @State private var moveDy: CGFloat = 0
    @State private var resizeDy: CGFloat = 0
    @State private var picked = 0

    private func step(_ dy: CGFloat) -> EpochMs { EpochMs((dy / hourHeight * 60 / 15).rounded()) * 15 * MINUTE }

    var body: some View {
        let tint: Color = item.kind == .event ? Color(hex: model.calendar(item.calendarId)?.color ?? "#5E5CE6") : .accentColor
        let dMove = step(moveDy), dResize = step(resizeDy)
        let s = item.start + dMove, e = max(item.start + 15 * MINUTE, item.end + dMove + dResize)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: item.kind == .event ? "calendar" : "checklist").imageScale(.small)
                Text(item.title.isEmpty ? "（無題）" : item.title).lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            Text("\(model.hm(s))〜\(model.hm(e))").font(.caption2).monospacedDigit().opacity(0.85)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(item.kind == .event ? Color.white : tint)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(item.kind == .event ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.14))))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(item.kind == .event ? 0 : 0.6), lineWidth: 1))
        .overlay(alignment: .bottom) {
            if editable {
                Capsule().fill(item.kind == .event ? Color.white.opacity(0.8) : tint).frame(width: 26, height: 4).padding(.bottom, 3)
                    .frame(maxWidth: .infinity, minHeight: 14, alignment: .bottom)
                    .contentShape(Rectangle())
                    .overlay {
                        PressDragRecognizer(
                            minimumDuration: 0.15,
                            onChanged: { _, t in resizeDy = t.height },
                            onEnded: { _, t in
                                resizeDy = 0
                                var c = item; c.end = max(item.start + 15 * MINUTE, item.end + step(t.height)); onChange(c)
                            },
                            onCancelled: { resizeDy = 0 }
                        )
                    }
                    .accessibilityHidden(true)
            }
        }
        .offset(y: CGFloat(dMove) / CGFloat(HOUR) * hourHeight)
        .scaleEffect(moveDy != 0 ? 1.03 : 1)
        .shadow(color: .black.opacity(moveDy != 0 || resizeDy != 0 ? 0.18 : 0), radius: 8, y: 3)
        .zIndex(moveDy != 0 ? 10 : 0)
        .contentShape(Rectangle())
        // タップで編集、長押し→上下で移動（UIKit のジェスチャー：上下のスクロールを邪魔しない）
        .overlay {
            PressDragRecognizer(
                minimumDuration: 0.35,
                onTap: onTap,
                onBegan: editable ? { _ in picked += 1 } : nil,
                onChanged: editable ? { _, t in moveDy = t.height == 0 ? 0.0001 : t.height } : nil,
                onEnded: editable ? { _, t in
                    moveDy = 0
                    let delta = step(t.height)
                    guard delta != 0 else { return }
                    var c = item; c.start += delta; c.end += delta; onChange(c)
                } : nil,
                onCancelled: { moveDy = 0 }
            )
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: picked)
        .onChange(of: moveDy != 0 || resizeDy != 0) { _, a in onDragging(a) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("計画 \(item.title)、\(model.hm(item.start))〜\(model.hm(item.end))")
        .accessibilityAction(named: "15分遅らせる") { if editable { var c = item; c.start += 15 * MINUTE; c.end += 15 * MINUTE; onChange(c) } }
        .accessibilityAction(named: "15分早める") { if editable { var c = item; c.start -= 15 * MINUTE; c.end -= 15 * MINUTE; onChange(c) } }
    }
}

// MARK: 計画の1つを編集

struct PlanItemEditor: View {
    @State var item: PlanItem
    var isNew: Bool
    var locked: Bool
    /// nil は削除
    var onDone: (PlanItem?) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("やること・予定の名前", text: $item.title).font(.title3.weight(.medium)).focused($focused)
                        .submitLabel(.done).onSubmit { if !item.title.isEmpty { done() } }
                    Picker("種類", selection: $item.kind) {
                        Label("タスク", systemImage: "checklist").tag(PlanItem.Kind.task)
                        Label("予定", systemImage: "calendar").tag(PlanItem.Kind.event)
                    }
                    .pickerStyle(.segmented)
                }
                .disabled(locked)
                Section {
                    TimeRangeBar(start: Binding(get: { model.time.date(item.start) }, set: { item.start = model.time.ms($0) }),
                                 end: Binding(get: { model.time.date(item.end) }, set: { item.end = model.time.ms($0) }))
                    LabeledContent("時間", value: "\(model.hm(item.start))〜\(model.hm(item.end))")
                    if item.kind == .event {
                        Picker("カレンダー", selection: Binding(get: { item.calendarId ?? model.calendars.first?.id ?? "" }, set: { item.calendarId = $0 })) {
                            ForEach(model.calendars, id: \.id) { c in Text(c.name).tag(c.id) }
                        }
                    }
                }
                .disabled(locked)
                if !isNew && !locked {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: { Text("計画から外す").frame(maxWidth: .infinity) }
                    }
                }
                if locked {
                    Section { Label("承認済みの計画は変えられません。予定・タスクは今日の画面で動かせます。", systemImage: "lock.fill").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(isNew ? "計画を追加" : "計画")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(locked ? "閉じる" : "キャンセル") { dismiss() } }
                if !locked {
                    ToolbarItem(placement: .confirmationAction) { Button(isNew ? "追加" : "完了", action: done).fontWeight(.semibold) }
                }
            }
            .alert("計画から外しますか？", isPresented: $confirmDelete) {
                Button("外す", role: .destructive) { onDone(nil); dismiss() }
                Button("キャンセル", role: .cancel) {}
            }
            .onAppear { if isNew { focused = true } }
        }
        .presentationDetents([.medium, .large])
    }

    private func done() {
        if item.end <= item.start { item.end = item.start + 30 * MINUTE }
        onDone(item)
        dismiss()
    }
}
