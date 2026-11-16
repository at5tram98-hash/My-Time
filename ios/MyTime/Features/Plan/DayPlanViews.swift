import SwiftUI
import MyTimeCore

// MARK: 翌日の計画（その他から開く）

/// 明日の計画を、今日の画面と同じ時刻軸で下書きし、「承認」で本当の予定・タスクにする
struct DayPlanView: View {
    @Environment(AppModel.self) private var model
    @State private var day: EpochMs = 0
    @State private var editing: PlanItem?
    @State private var confirmApprove = false
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

            PlanBoard(day: day, plan: plan, editable: !plan.isApproved,
                      onCreate: { s, e in editing = PlanItem(id: model.repo.newId(), kind: .task, title: "", start: s, end: e) },
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
        .alert("この計画を承認しますか？", isPresented: $confirmApprove) {
            Button("承認して予定にする") {
                if model.approveDayPlan(day) > 0 { approvedFeedback += 1 }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("\(model.dayTitle(day))に、予定\(plan.items.filter { $0.kind == .event }.count)件・タスク\(plan.items.filter { $0.kind == .task }.count)件を入れます。計画はその日の今日の画面に灰色の「計画」として残ります。")
        }
        .sensoryFeedback(.success, trigger: approvedFeedback)
    }

    private func bottomBar(_ plan: DayPlan) -> some View {
        VStack(spacing: 6) {
            if plan.isApproved {
                Label("承認済み。予定・タスクは今日の画面で動かせます", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            } else {
                Button { confirmApprove = true } label: {
                    Label(plan.items.isEmpty ? "計画を入れると承認できます" : "承認して予定にする（\(plan.items.count)件）", systemImage: "checkmark.seal")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(plan.items.isEmpty ? AnyShapeStyle(Color.gray.opacity(0.4)) : AnyShapeStyle(Color.green.gradient)))
                }
                .buttonStyle(PressableStyle())
                .disabled(plan.items.isEmpty)
                Text("空いている所を長押ししてなぞると追加、計画を長押しして上下になぞると移動").font(.caption2).foregroundStyle(.secondary)
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
    var onCreate: (EpochMs, EpochMs) -> Void
    var onTap: (PlanItem) -> Void
    var onChange: (PlanItem) -> Void

    @Environment(AppModel.self) private var model
    @State private var hourHeight: CGFloat = 56
    @State private var creating: (lo: Int, hi: Int)?
    @State private var createTick = 0
    static let gutter: CGFloat = 46
    static let snap = 15

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    grid
                    GeometryReader { geo in
                        let w = geo.size.width - Self.gutter - 8
                        ZStack(alignment: .topLeading) {
                            emptyArea(width: w)
                            // その日にすでにある本当の予定（うすく。重ならないよう見ながら計画できる）
                            ForEach(existing, id: \.id) { o in
                                let top = y(o.start), h = max(16, y(o.end) - y(o.start))
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color(hex: model.eventColor(o.event)).opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: model.eventColor(o.event)).opacity(0.06)))
                                    .overlay(alignment: .topLeading) {
                                        Text(o.title).font(.caption2).foregroundStyle(.secondary).padding(4).lineLimit(1)
                                    }
                                    .frame(width: w, height: h)
                                    .offset(x: Self.gutter, y: top)
                                    .allowsHitTesting(false)
                            }
                            ForEach(plan.items) { item in
                                PlanBlock(item: item, hourHeight: hourHeight, editable: editable, onTap: { onTap(item) }, onChange: onChange)
                                    .frame(width: w * 0.86, height: max(22, y(item.end) - y(item.start) - 2))
                                    .offset(x: Self.gutter + w * 0.14, y: y(item.start) + 1)
                            }
                            if let c = creating {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.18))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                                    .overlay(alignment: .topLeading) {
                                        Text("\(hm(c.lo))〜\(hm(c.hi))").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).padding(6)
                                    }
                                    .frame(width: w * 0.86, height: CGFloat(c.hi - c.lo) / 60 * hourHeight)
                                    .offset(x: Self.gutter + w * 0.14, y: CGFloat(c.lo) / 60 * hourHeight)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .frame(height: hourHeight * 24 + 8)
            }
            .onAppear { proxy.scrollTo("h7", anchor: .top) }
            .sensoryFeedback(.impact(weight: .medium), trigger: createTick)
        }
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
            .gesture(
                LongPressGesture(minimumDuration: 0.4)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { v in
                        guard editable, case .second(true, let d?) = v else { return }
                        let anchor = Int(d.startLocation.y / hourHeight * 60) / Self.snap * Self.snap
                        // すでに計画がある時刻では作らない（計画の移動と取り合わない）
                        let at = day + EpochMs(anchor) * MINUTE
                        if creating == nil, plan.items.contains(where: { $0.start <= at && at < $0.end }) { return }
                        let cur = Int((d.location.y / hourHeight * 60 / CGFloat(Self.snap)).rounded()) * Self.snap
                        let moved = abs(d.translation.height) > 6
                        let end = !moved ? anchor + 60 : max(cur, anchor + Self.snap)
                        if creating == nil { createTick += 1 }
                        withAnimation(.interactiveSpring()) { creating = (max(0, min(anchor, end)), min(24 * 60, max(anchor, end))) }
                    }
                    .onEnded { _ in
                        guard let c = creating else { return }
                        creating = nil
                        onCreate(day + EpochMs(c.lo) * MINUTE, day + EpochMs(c.hi) * MINUTE)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("計画の時刻軸")
            .accessibilityAction(named: "計画を追加") { if editable { onCreate(day + 9 * HOUR, day + 10 * HOUR) } }
    }
}

/// 計画の1つ。タップで編集、長押し→上下で移動、下端をなぞって長さ
struct PlanBlock: View {
    var item: PlanItem
    var hourHeight: CGFloat
    var editable: Bool
    var onTap: () -> Void
    var onChange: (PlanItem) -> Void
    @Environment(AppModel.self) private var model
    @GestureState private var moveDy: CGFloat = 0
    @GestureState private var resizeDy: CGFloat = 0
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
                    .gesture(DragGesture(minimumDistance: 2)
                        .updating($resizeDy) { v, st, _ in st = v.translation.height }
                        .onEnded { v in
                            var c = item; c.end = max(item.start + 15 * MINUTE, item.end + step(v.translation.height)); onChange(c)
                        })
                    .accessibilityHidden(true)
            }
        }
        .offset(y: CGFloat(dMove) / CGFloat(HOUR) * hourHeight)
        .scaleEffect(moveDy != 0 ? 1.03 : 1)
        .shadow(color: .black.opacity(moveDy != 0 || resizeDy != 0 ? 0.18 : 0), radius: 8, y: 3)
        .zIndex(moveDy != 0 ? 10 : 0)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .highPriorityGesture(LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($moveDy) { v, st, _ in if case .second(true, let d?) = v { st = d.translation.height } }
            .onChanged { v in if case .second(true, nil) = v { picked += 1 } }
            .onEnded { v in
                guard case .second(true, let d?) = v else { return }
                let delta = step(d.translation.height)
                guard delta != 0 else { return }
                var c = item; c.start += delta; c.end += delta; onChange(c)
            }, including: editable ? .all : .subviews)
        .sensoryFeedback(.impact(weight: .medium), trigger: picked)
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
