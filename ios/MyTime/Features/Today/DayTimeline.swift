import SwiftUI
import MyTimeCore

/// 1日の時刻軸。`mainFraction` を渡すと左（予定）と右（タスク）のレーンに分ける。nil なら1列（カレンダーの日表示）。
///
/// Web 版の時間軸と同じ操作：
/// - 空白を長押し → 指で上下になぞって範囲を選び、離すと作成画面（左のレーン＝予定、右のレーン＝タスク）
/// - 予定・タスクを長押し → 上下に動かすと15分刻みで移動（離したときだけ保存。他と重なると赤く示す）
/// - 予定・タスクの上端・下端を長押し → 上下に動かすと開始・終了だけを15分刻みで変更
/// - 予定・タスクを長押しして動かさずに離す → 操作メニュー（開く・編集・複製・削除）
/// - 繰り返し予定を動かしたときは「この回のみ」を確認してから変更（ほかの回は変えない）
/// - 縦スクロールとピンチ（時刻の間隔の拡大・縮小）はこの領域の中だけ。赤い線と時刻は今日だけ。
struct DayTimeline: View {
    static let gutter: CGFloat = 44
    static let snap: EpochMs = 15
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var day: EpochMs
    var now: EpochMs
    var events: [EventOccurrence]
    var tasks: [MTTask]
    var mainFraction: CGFloat?

    @State private var hourHeight: CGFloat = 56
    @State private var pinchBase: CGFloat?
    /// 空白の長押しで作る新規の仮範囲（分）
    @State private var creating: Creating?
    @State private var createFeedback = 0
    @State private var createSnap = 0
    /// 動かさない長押しで開くメニュー
    @State private var menuFor: Block?
    /// 繰り返しの1回を変えるときの確認待ち
    @State private var pendingOccurrence: PendingOccurrence?
    @State private var confirmDelete: Block?

    struct Creating: Equatable {
        var lane: Int
        var anchorMin: Int
        var curMin: Int
        var lo: Int { min(anchorMin, curMin) }
        var hi: Int { max(anchorMin, curMin) }
    }

    struct PendingOccurrence: Identifiable {
        var id: String { block.id }
        var block: Block
        var start: EpochMs
        var end: EpochMs
        var verb: String
    }

    struct Block: Identifiable, Equatable {
        enum Kind { case event, task, check, session }
        var id: String
        var kind: Kind
        /// 予定は回の ID（`master@start`）、タスク・確認はタスク ID、作業枠は親のタスク ID
        var refId: String
        var title: String
        var start: EpochMs
        var end: EpochMs
        /// 遅れて現在まで延ばして見せているときも、伸縮は本来の終了から
        var plannedEnd: EpochMs
        var color: Color
        var symbol: String
        var lane: Int
        var placed: PlacedItem
        var faded: Bool
        var running: Bool
        var movable: Bool { kind == .event || kind == .task }
        static func == (a: Block, b: Block) -> Bool { a.id == b.id && a.start == b.start && a.end == b.end && a.placed == b.placed && a.faded == b.faded && a.running == b.running && a.title == b.title }
    }

    var body: some View {
        let blocks = makeBlocks()
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    grid
                    GeometryReader { geo in
                        let width = geo.size.width - Self.gutter
                        ZStack(alignment: .topLeading) {
                            emptyArea(width: width)
                            if let f = mainFraction {
                                Rectangle().fill(Color(.separator)).frame(width: 0.5, height: hourHeight * 24).offset(x: Self.gutter + width * f).allowsHitTesting(false)
                            }
                            ForEach(blocks) { b in
                                TimelineBlock(
                                    block: b, hourHeight: hourHeight,
                                    conflicts: { s, e in blocks.contains { o in o.id != b.id && o.lane == b.lane && !o.faded && o.kind != .session && o.start < e && s < o.end } },
                                    onMove: { move(b, to: $0) },
                                    onResize: { s, e in resize(b, start: s, end: e) },
                                    onTap: { open(b) },
                                    // 動かさずに長押し：カードを開く（編集・複製・ずらす・削除はカードから）
                                    onMenu: { open(b) }
                                )
                                .frame(width: max(8, laneWidth(b.lane, width) / CGFloat(b.placed.columns) - 3), height: max(18, CGFloat(b.placed.height) / 60 * hourHeight - 2))
                                .offset(x: Self.gutter + laneX(b.lane, width) + laneWidth(b.lane, width) * CGFloat(b.placed.column) / CGFloat(b.placed.columns) + 1, y: CGFloat(b.placed.top) / 60 * hourHeight + 1)
                            }
                            if let c = creating { creatingGhost(c, width: width) }
                            if model.time.isSameDay(day, now) { nowLine(width: geo.size.width) }
                        }
                    }
                }
                .frame(height: hourHeight * 24 + 8)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                let h = model.time.isSameDay(day, now) ? model.time.minutesOfDay(now) / 60 : 8
                proxy.scrollTo("h\(max(0, h - 1))", anchor: .top)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        let base = pinchBase ?? hourHeight
                        pinchBase = base
                        hourHeight = min(150, max(28, base * v.magnification))
                    }
                    .onEnded { _ in pinchBase = nil }
            )
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: createFeedback)
        .sensoryFeedback(.selection, trigger: createSnap)
        // 確認は画面の中央に（吹き出しの矢印がずれない）
        .alert("繰り返しの予定です", isPresented: Binding(get: { pendingOccurrence != nil }, set: { if !$0 { pendingOccurrence = nil } }), presenting: pendingOccurrence) { p in
            Button("この回のみ\(p.verb)") { commitOccurrence(p) }
            Button("キャンセル", role: .cancel) { pendingOccurrence = nil }
        } message: { p in
            Text("\(model.hm(p.start))〜\(model.hm(p.end))に\(p.verb)します。ほかの回は変わりません。")
        }
    }

    // MARK: 背景（時刻の目盛り・現在線）

    private var grid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(h):00").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: Self.gutter - 8, alignment: .trailing)
                        .offset(y: -6)
                        .opacity(h == 0 ? 0 : 1)
                    Rectangle().fill(Color(.separator).opacity(0.6)).frame(height: 0.5)
                }
                .frame(height: hourHeight, alignment: .top)
                .id("h\(h)")
            }
        }
        .accessibilityHidden(true)
    }

    private func nowLine(width: CGFloat) -> some View {
        let y = CGFloat(model.time.minutesOfDay(now)) / 60 * hourHeight
        return ZStack(alignment: .leading) {
            Rectangle().fill(Color.red).frame(height: 1.5).padding(.leading, Self.gutter)
            Text(model.hm(now)).font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(Color.red))
                .frame(width: Self.gutter, alignment: .trailing)
        }
        .frame(width: width, alignment: .leading)
        .offset(y: y - 8)
        .allowsHitTesting(false)
        .accessibilityLabel("現在 \(model.hm(now))")
    }

    private func laneX(_ lane: Int, _ width: CGFloat) -> CGFloat {
        guard let f = mainFraction else { return 0 }
        return lane == 0 ? 0 : width * f
    }
    private func laneWidth(_ lane: Int, _ width: CGFloat) -> CGFloat {
        guard let f = mainFraction else { return width }
        return lane == 0 ? width * f : width * (1 - f)
    }

    // MARK: 空白の長押しで作成

    private func minute(atY y: CGFloat) -> Int {
        Int(max(0, min(24 * 60, y / hourHeight * 60)))
    }

    /// 予定・タスクのない所。長押しで仮の範囲が現れ、なぞって長さを決め、離すと作成画面へ
    private func emptyArea(width: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: Self.gutter + width, height: hourHeight * 24)
            .gesture(
                LongPressGesture(minimumDuration: 0.45)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        guard case .second(true, let d?) = value else { return }
                        let x = d.startLocation.x - Self.gutter
                        let lane = mainFraction.map { x >= width * $0 ? 1 : 0 } ?? 0
                        let anchor = minute(atY: d.startLocation.y) / Int(Self.snap) * Int(Self.snap)
                        let m = Int((Double(minute(atY: d.location.y)) / Double(Self.snap)).rounded()) * Int(Self.snap)
                        let moved = abs(d.translation.height) > 6
                        let cur = !moved ? anchor + 60 : (m <= anchor ? min(m, anchor - Int(Self.snap)) : max(m, anchor + Int(Self.snap)))
                        let next = Creating(lane: lane, anchorMin: anchor, curMin: max(0, min(24 * 60, cur)))
                        if creating == nil { createFeedback += 1 }
                        if creating?.curMin != next.curMin { createSnap += 1 }
                        if reduceMotion { creating = next } else { withAnimation(.interactiveSpring()) { creating = next } }
                    }
                    .onEnded { _ in
                        guard let c = creating else { return }
                        creating = nil
                        let d0 = model.time.startOfDay(day)
                        let s = d0 + EpochMs(c.lo) * MINUTE, e = d0 + EpochMs(c.hi) * MINUTE
                        let kind: EditorSeed.Kind = mainFraction != nil && c.lane == 1 ? .task : .event
                        router.open(.editor(EditorSeed(kind: kind, start: s, end: e)))
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("時間軸の空き")
            .accessibilityHint("長押しして上下になぞると、その時間で新しく追加できます")
            .accessibilityAction(named: "この日に予定を追加") {
                let d0 = model.time.startOfDay(day)
                let s = model.time.isSameDay(day, now) ? ((now / (15 * MINUTE)) + 1) * 15 * MINUTE : d0 + 9 * HOUR
                router.open(.editor(EditorSeed(kind: .event, start: s, end: s + HOUR)))
            }
    }

    private func creatingGhost(_ c: Creating, width: CGFloat) -> some View {
        let d0 = model.time.startOfDay(day)
        let isTask = mainFraction != nil && c.lane == 1
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return VStack(alignment: .leading, spacing: 1) {
            Text(isTask ? "新しいタスク" : "新しい予定").font(.caption.weight(.semibold))
            Text("\(model.hm(d0 + EpochMs(c.lo) * MINUTE))〜\(model.hm(d0 + EpochMs(c.hi) * MINUTE))").font(.caption2).monospacedDigit()
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(width: max(8, laneWidth(c.lane, width) - 3), height: max(18, CGFloat(c.hi - c.lo) / 60 * hourHeight - 2), alignment: .topLeading)
        .background(shape.fill(Color.accentColor.opacity(0.18)))
        .overlay(shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
        .offset(x: Self.gutter + laneX(c.lane, width) + 1, y: CGFloat(c.lo) / 60 * hourHeight + 1)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: 予定・タスク・確認・作業枠の配置

    private func makeBlocks() -> [Block] {
        let d0 = model.time.startOfDay(day), d1 = model.time.addDays(d0, 1)
        /// 配置前の下書き（配置は layoutDay がレーンごとに決める）
        struct Draft { var item: TimedItem; var make: (PlacedItem) -> Block }
        var mains: [Draft] = []
        var details: [Draft] = []
        func add(_ lane: Int, _ d: Draft) { if lane == 0 { mains.append(d) } else { details.append(d) } }
        let taskLane = mainFraction == nil ? 0 : 1
        for e in events where !e.event.allDay && e.start < d1 && e.end > d0 {
            let color = Color(hex: model.eventColor(e.event))
            let symbol = e.event.specType.flatMap { SPEC_BY_ID[$0]?.symbol } ?? "calendar"
            let id = "event:\(e.id)"
            add(0, Draft(item: TimedItem(id: id, start: e.start, end: e.end)) { p in
                Block(id: id, kind: .event, refId: e.id, title: e.title, start: e.start, end: e.end, plannedEnd: e.end, color: color, symbol: symbol, lane: 0, placed: p, faded: false, running: false)
            })
        }
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in tasks {
            if t.kind == .do, let s = t.plannedStart, let e = t.plannedEnd, s < d1, e > d0 {
                let end = delayInfo(t, now: now).delayed ? max(e, now) : e
                let id = "task:\(t.id)"
                add(taskLane, Draft(item: TimedItem(id: id, start: s, end: end)) { p in
                    Block(id: id, kind: .task, refId: t.id, title: t.title, start: s, end: end, plannedEnd: e, color: .accentColor, symbol: IconMap.symbol(t.icon), lane: taskLane, placed: p, faded: t.status == .done, running: t.status == .running)
                })
            } else if t.kind == .check, let c = t.checkAt, c >= d0, c < d1 {
                let id = "check:\(t.id)"
                add(taskLane, Draft(item: TimedItem(id: id, start: c, end: c + 15 * MINUTE)) { p in
                    Block(id: id, kind: .check, refId: t.id, title: t.title, start: c, end: c + 15 * MINUTE, plannedEnd: c + 15 * MINUTE, color: .checkTask, symbol: "checkmark.circle", lane: taskLane, placed: p, faded: t.checked, running: false)
                })
            }
        }
        // 作業枠：日時を決めたサブタスク（タップで親のタスクを開く。動かすのは親の詳細から）
        for s in model.subtasks {
            guard let st = s.plannedStart, let en = s.plannedEnd, st < d1, en > d0, let parent = byId[s.taskId] else { continue }
            let id = "session:\(s.id)"
            add(taskLane, Draft(item: TimedItem(id: id, start: st, end: en)) { p in
                Block(id: id, kind: .session, refId: parent.id, title: "\(parent.title)・\(s.title)", start: st, end: en, plannedEnd: en, color: .accentColor, symbol: "square.stack", lane: taskLane, placed: p, faded: s.done || parent.status == .done, running: false)
            })
        }
        func place(_ list: [Draft]) -> [Block] {
            let placed = Dictionary(layoutDay(list.map(\.item), day: d0, time: model.time).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return list.compactMap { d in placed[d.item.id].map(d.make) }
        }
        return place(mains) + place(details)
    }

    // MARK: 操作

    private func open(_ b: Block) {
        switch b.kind {
        case .event: router.open(.event(b.refId))
        case .task, .check, .session: router.open(.task(b.refId))
        }
    }

    private func move(_ b: Block, to newStart: EpochMs) {
        let len = b.plannedEnd - b.start
        switch b.kind {
        case .event:
            if parseOccurrenceId(b.refId) != nil {
                pendingOccurrence = PendingOccurrence(block: b, start: newStart, end: newStart + len, verb: "移動")
                return
            }
            let old = b.start
            model.perform("\(model.hm(newStart))に移動しました", undo: { try model.repo.moveEvent(b.refId, newStart: old) }) { try model.repo.moveEvent(b.refId, newStart: newStart) }
        case .task:
            let old = b.start
            model.perform("\(model.hm(newStart))に移動しました", undo: { try model.repo.moveTask(b.refId, newStart: old) }) { try model.repo.moveTask(b.refId, newStart: newStart) }
        case .check, .session:
            break
        }
    }

    private func resize(_ b: Block, start: EpochMs, end: EpochMs) {
        let msg = "\(model.hm(start))〜\(model.hm(end))にしました"
        let oldStart = b.start, oldEnd = b.plannedEnd
        switch b.kind {
        case .event:
            if parseOccurrenceId(b.refId) != nil {
                pendingOccurrence = PendingOccurrence(block: b, start: start, end: end, verb: "変更")
                return
            }
            model.perform(msg, undo: { try model.repo.resizeEvent(b.refId, start: oldStart, end: oldEnd) }) { try model.repo.resizeEvent(b.refId, start: start, end: end) }
        case .task:
            model.perform(msg, undo: { try model.repo.resizeTask(b.refId, start: oldStart, end: oldEnd) }) { try model.repo.resizeTask(b.refId, start: start, end: end) }
        case .check, .session:
            break
        }
    }

    private func commitOccurrence(_ p: PendingOccurrence) {
        pendingOccurrence = nil
        guard let o = parseOccurrenceId(p.block.refId), let snapshot = model.events.first(where: { $0.id == o.masterId }) else { return }
        model.perform("この回のみ\(model.hm(p.start))〜\(model.hm(p.end))にしました", undo: { try model.repo.saveEvent(snapshot, isNew: false) }) {
            try model.repo.editOccurrence(masterId: o.masterId, originalStart: o.originalStart, start: p.start, end: p.end)
        }
    }

    @ViewBuilder
    private func menuButtons(_ b: Block) -> some View {
        Button("開く") { open(b) }
        switch b.kind {
        case .event:
            let master = parseOccurrenceId(b.refId)?.masterId ?? b.refId
            Button("編集") { router.open(.editor(EditorSeed(kind: .event, eventId: master))) }
            Button("複製") { duplicateEvent(b) }
            Button("削除", role: .destructive) { confirmDelete = b }
        case .task:
            Button("編集") { router.open(.editor(EditorSeed(kind: .task, taskId: b.refId))) }
            Button("削除", role: .destructive) { confirmDelete = b }
        case .check:
            Button("編集") { router.open(.editor(EditorSeed(kind: .task, taskId: b.refId))) }
        case .session:
            EmptyView()
        }
        Button("キャンセル", role: .cancel) {}
    }

    @ViewBuilder
    private func deleteButtons(_ b: Block) -> some View {
        if b.kind == .event, let o = parseOccurrenceId(b.refId) {
            Button("この回のみ削除", role: .destructive) {
                model.perform("この回を削除しました") { try model.repo.cancelOccurrence(masterId: o.masterId, originalStart: o.originalStart) }
            }
            Button("すべての回を削除", role: .destructive) { deleteEvent(o.masterId) }
        } else if b.kind == .event {
            Button("削除", role: .destructive) { deleteEvent(b.refId) }
        } else if b.kind == .task {
            Button("削除", role: .destructive) {
                guard let snap = model.tasks.first(where: { $0.id == b.refId }) else { return }
                model.perform("削除しました", undo: { try model.repo.saveTask(snap, isNew: true) }) { try model.repo.deleteTask(b.refId) }
            }
        }
        Button("キャンセル", role: .cancel) {}
    }

    private func deleteEvent(_ id: String) {
        guard let snap = model.events.first(where: { $0.id == id }) else { return }
        model.perform("削除しました", undo: { try model.repo.saveEvent(snap, isNew: true) }) { try model.repo.deleteEvent(id) }
    }

    /// 予定の複製：同じ内容の単発の予定を、すぐ後ろの時間に作る（繰り返しは引き継がない）
    private func duplicateEvent(_ b: Block) {
        let master = parseOccurrenceId(b.refId)?.masterId ?? b.refId
        guard let src = model.events.first(where: { $0.id == master }) else { return }
        let len = b.end - b.start
        var copy = MTEvent.make(title: src.title, calendarId: src.calendarId, start: b.end, end: b.end + len, now: model.now, id: model.repo.newId())
        copy.notes = src.notes
        copy.extra = src.extra
        copy.employerId = src.employerId
        let newId = copy.id
        model.perform("複製しました（\(model.hm(copy.start))〜）", undo: { try model.repo.deleteEvent(newId) }) { try model.repo.saveEvent(copy, isNew: true) }
    }
}

/// 時刻軸の1つの予定・タスク。
/// 本体を長押し→上下で移動、上端・下端を長押し→上下で伸縮、動かさずに離す→メニュー
struct TimelineBlock: View {
    var block: DayTimeline.Block
    var hourHeight: CGFloat
    /// 仮の位置が他と重なるか（重なっても保存はできる。赤い枠で知らせるだけ）
    var conflicts: (EpochMs, EpochMs) -> Bool
    var onMove: (EpochMs) -> Void
    var onResize: (EpochMs, EpochMs) -> Void
    var onTap: () -> Void
    var onMenu: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Edge { case top, bottom }
    struct DragInfo: Equatable { var active = false; var edge: Edge?; var dy: CGFloat = 0 }
    @GestureState private var drag = DragInfo()
    @State private var pickedUp = 0
    @State private var snapped = 0
    /// 長押しが始まった時刻（長押しのあとに離したときは、タップとして詳細を開かない）
    @State private var lastPress = Date.distantPast

    private var stepMinutes: Int { Int((drag.dy / hourHeight * 60 / CGFloat(DayTimeline.snap)).rounded()) * Int(DayTimeline.snap) }

    /// 指の位置から決まる仮の開始・終了（移動は長さを保つ。伸縮は15分の目盛りにそろえ、最短15分）
    private var ghost: (start: EpochMs, end: EpochMs) {
        let d = EpochMs(stepMinutes) * MINUTE
        let snap = DayTimeline.snap * MINUTE
        switch drag.edge {
        case nil: return (block.start + d, block.plannedEnd + d)
        case .bottom:
            let e = ((block.plannedEnd + d) / snap) * snap
            return (block.start, max(block.start + snap, e))
        case .top:
            let s = ((block.start + d + snap / 2) / snap) * snap
            return (min(block.plannedEnd - snap, s), block.plannedEnd)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: block.kind == .check ? 9 : 6, style: .continuous)
        let g = ghost
        let changed = drag.active && (g.start != block.start || g.end != block.plannedEnd)
        let clash = changed && conflicts(g.start, g.end)
        let px: (EpochMs) -> CGFloat = { CGFloat($0) / CGFloat(MINUTE) / 60 * hourHeight }
        let topShift = drag.active ? px(g.start - block.start) : 0
        let bottomShift = drag.active ? px(g.end - block.plannedEnd) : 0
        HStack(alignment: .top, spacing: 0) {
            if block.kind != .check { Rectangle().fill(block.color).frame(width: 3) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: block.symbol).imageScale(.small)
                    Text(block.title).lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                if CGFloat(block.placed.height) / 60 * hourHeight > 34 || drag.active {
                    Text("\(model.hm(drag.active ? g.start : block.start))〜\(model.hm(drag.active ? g.end : block.end))")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
                if clash {
                    Label("重なり", systemImage: "exclamationmark.triangle.fill").font(.caption2.weight(.bold)).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(block.kind == .event ? block.color : Color.primary)
        .background(shape.fill(block.color.opacity(block.kind == .event ? 0.2 : 0.12)))
        .background(shape.fill(Color(.systemBackground)).opacity(drag.active ? 1 : 0))
        .overlay {
            if clash { shape.strokeBorder(Color.red, lineWidth: 2) }
            else if block.running { shape.strokeBorder(Color.green, lineWidth: 1.5) }
            else if block.kind == .task || block.kind == .session { shape.strokeBorder(block.color.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: block.kind == .session ? [3, 2] : [])) }
        }
        .clipShape(shape)
        // 伸縮中は、つかんだ端だけを伸ばして見せる（移動中は全体をずらす）
        .padding(.top, drag.edge == .top ? -topShift : 0)
        .padding(.bottom, drag.edge == .bottom ? -bottomShift : 0)
        .overlay(alignment: .top) { if block.movable { handle(.top) } }
        .overlay(alignment: .bottom) { if block.movable { handle(.bottom) } }
        .opacity(block.faded ? 0.5 : 1)
        .scaleEffect(drag.active && drag.edge == nil && !reduceMotion ? 1.03 : 1)
        .shadow(color: .black.opacity(drag.active ? 0.18 : 0), radius: 8, y: 4)
        .offset(y: drag.active && drag.edge == nil ? topShift : 0)
        .zIndex(drag.active ? 10 : 0)
        .animation(reduceMotion ? nil : Motion.pop, value: drag.active)
        .contentShape(shape)
        .gesture(pressGesture(edge: nil))
        // 長押しの操作と同時に受け取る。短く触れたときだけカードを開く
        .simultaneousGesture(TapGesture().onEnded {
            if Date().timeIntervalSince(lastPress) > 0.6 { onTap() }
        })
        .sensoryFeedback(.impact(weight: .medium), trigger: pickedUp)
        .sensoryFeedback(.selection, trigger: snapped)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "操作メニュー") { onMenu() }
        .accessibilityAction(named: "15分遅らせる") { if block.movable { onMove(block.start + 15 * MINUTE) } }
        .accessibilityAction(named: "15分早める") { if block.movable { onMove(block.start - 15 * MINUTE) } }
        .accessibilityAction(named: "終了を15分延ばす") { if block.movable { onResize(block.start, block.plannedEnd + 15 * MINUTE) } }
        .accessibilityAction(named: "終了を15分縮める") { if block.movable && block.plannedEnd - block.start > 15 * MINUTE { onResize(block.start, block.plannedEnd - 15 * MINUTE) } }
    }

    private var accessibilityText: String {
        let kind: String
        switch block.kind {
        case .event: kind = "予定"
        case .task: kind = "タスク"
        case .check: kind = "確認"
        case .session: kind = "作業枠"
        }
        return "\(kind) \(block.title)、\(model.hm(block.start))〜\(model.hm(block.end))"
    }

    /// 上端・下端のつかむ所（見た目は細い線、触れる範囲は高さ12）
    private func handle(_ edge: Edge) -> some View {
        let h: CGFloat = min(12, max(6, CGFloat(block.placed.height) / 60 * hourHeight / 4))
        return Color.clear
            .frame(height: h)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: edge == .top ? .top : .bottom) {
                if drag.active && drag.edge == edge {
                    Capsule().fill(block.color).frame(width: 28, height: 4).padding(edge == .top ? .top : .bottom, 1)
                }
            }
            .gesture(pressGesture(edge: edge))
            .accessibilityHidden(true)
    }

    /// 長押し（0.4秒、端は0.3秒）→ 上下のドラッグ。動かさずに離せばメニュー
    private func pressGesture(edge: Edge?) -> some Gesture {
        LongPressGesture(minimumDuration: edge == nil ? 0.4 : 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($drag) { value, state, _ in
                if case .second(true, let d) = value {
                    state = DragInfo(active: block.movable || edge == nil, edge: block.movable ? edge : nil, dy: block.movable ? (d?.translation.height ?? 0) : 0)
                }
            }
            .onChanged { value in
                if case .second(true, let d) = value {
                    lastPress = Date()
                    if d == nil || (d!.translation == .zero && snapped == 0) { pickedUp += 1 }
                    if let d, block.movable {
                        let m = Int((d.translation.height / hourHeight * 60 / CGFloat(DayTimeline.snap)).rounded())
                        if m != snapped { snapped = m }
                    }
                }
            }
            .onEnded { value in
                defer { snapped = 0 }
                guard case .second(true, let d) = value else { return }
                lastPress = Date()
                let dy = d?.translation.height ?? 0
                let m = Int((dy / hourHeight * 60 / CGFloat(DayTimeline.snap)).rounded()) * Int(DayTimeline.snap)
                // 動かさずに離した：メニュー
                if abs(dy) < 6 || m == 0 || !block.movable {
                    if abs(dy) < 6 { onMenu() }
                    return
                }
                let delta = EpochMs(m) * MINUTE
                let snap = DayTimeline.snap * MINUTE
                switch edge {
                case nil: onMove(block.start + delta)
                case .bottom: onResize(block.start, max(block.start + snap, ((block.plannedEnd + delta) / snap) * snap))
                case .top: onResize(min(block.plannedEnd - snap, ((block.start + delta + snap / 2) / snap) * snap), block.plannedEnd)
                }
            }
    }
}
