import SwiftUI
import MyTimeCore

/// 1日の時刻軸。`mainFraction` を渡すと左（予定）と右（タスク）のレーンに分ける。nil なら1列（カレンダーの日表示）。
/// - 縦スクロールとピンチ（時刻の間隔の拡大・縮小）はこの領域の中だけ。
/// - 予定・タスクは長押ししてから上下に動かすと15分刻みで移動（離したときだけ保存）。
/// - 赤い線と時刻は今日の列だけ。
struct DayTimeline: View {
    static let gutter: CGFloat = 44
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    var day: EpochMs
    var now: EpochMs
    var events: [EventOccurrence]
    var tasks: [MTTask]
    var mainFraction: CGFloat?

    @State private var hourHeight: CGFloat = 56
    @State private var pinchBase: CGFloat?

    struct Block: Identifiable {
        enum Kind { case event, task, check }
        var id: String
        var kind: Kind
        var refId: String
        var title: String
        var start: EpochMs
        var end: EpochMs
        var color: Color
        var symbol: String
        var lane: Int
        var placed: PlacedItem
        var faded: Bool
        var running: Bool
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
                            if let f = mainFraction {
                                Rectangle().fill(Color(.separator)).frame(width: 0.5, height: hourHeight * 24).offset(x: Self.gutter + width * f)
                            }
                            ForEach(blocks) { b in
                                TimelineBlock(block: b, hourHeight: hourHeight, day: day) { newStart in move(b, to: newStart) } onTap: { open(b) }
                                    .frame(width: max(8, laneWidth(b, width) / CGFloat(b.placed.columns) - 3), height: max(18, CGFloat(b.placed.height) / 60 * hourHeight - 2))
                                    .offset(x: Self.gutter + laneX(b, width) + laneWidth(b, width) * CGFloat(b.placed.column) / CGFloat(b.placed.columns) + 1, y: CGFloat(b.placed.top) / 60 * hourHeight + 1)
                            }
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
    }

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

    private func laneX(_ b: Block, _ width: CGFloat) -> CGFloat {
        guard let f = mainFraction else { return 0 }
        return b.lane == 0 ? 0 : width * f
    }
    private func laneWidth(_ b: Block, _ width: CGFloat) -> CGFloat {
        guard let f = mainFraction else { return width }
        return b.lane == 0 ? width * f : width * (1 - f)
    }

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
                Block(id: id, kind: .event, refId: e.id, title: e.title, start: e.start, end: e.end, color: color, symbol: symbol, lane: 0, placed: p, faded: false, running: false)
            })
        }
        for t in tasks {
            if t.kind == .do, let s = t.plannedStart, let e = t.plannedEnd, s < d1, e > d0 {
                let end = delayInfo(t, now: now).delayed ? max(e, now) : e
                let id = "task:\(t.id)"
                add(taskLane, Draft(item: TimedItem(id: id, start: s, end: end)) { p in
                    Block(id: id, kind: .task, refId: t.id, title: t.title, start: s, end: end, color: .accentColor, symbol: IconMap.symbol(t.icon), lane: taskLane, placed: p, faded: t.status == .done, running: t.status == .running)
                })
            } else if t.kind == .check, let c = t.checkAt, c >= d0, c < d1 {
                let id = "check:\(t.id)"
                add(taskLane, Draft(item: TimedItem(id: id, start: c, end: c + 15 * MINUTE)) { p in
                    Block(id: id, kind: .check, refId: t.id, title: t.title, start: c, end: c + 15 * MINUTE, color: .checkTask, symbol: "checkmark.circle", lane: taskLane, placed: p, faded: t.checked, running: false)
                })
            }
        }
        func place(_ list: [Draft]) -> [Block] {
            let placed = Dictionary(layoutDay(list.map(\.item), day: d0, time: model.time).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return list.compactMap { d in placed[d.item.id].map(d.make) }
        }
        return place(mains) + place(details)
    }

    private func open(_ b: Block) {
        switch b.kind {
        case .event: router.open(.event(b.refId))
        case .task, .check: router.open(.task(b.refId))
        }
    }

    private func move(_ b: Block, to newStart: EpochMs) {
        switch b.kind {
        case .event:
            if parseOccurrenceId(b.refId) != nil {
                model.errorMessage = "繰り返し予定の1回だけの移動は、まだ iOS 版ではできません。Web 版で行ってください。"
                return
            }
            let old = b.start
            model.perform("\(model.hm(newStart))に移動しました", undo: { try model.repo.moveEvent(b.refId, newStart: old) }) { try model.repo.moveEvent(b.refId, newStart: newStart) }
        case .task:
            guard let t = model.tasks.first(where: { $0.id == b.refId }), let old = t.plannedStart else { return }
            model.perform("\(model.hm(newStart))に移動しました", undo: { try model.repo.moveTask(b.refId, newStart: old) }) { try model.repo.moveTask(b.refId, newStart: newStart) }
        case .check:
            break
        }
    }
}

/// 時刻軸の1つの予定・タスク。長押ししてから上下に動かすと15分刻みで移動
struct TimelineBlock: View {
    var block: DayTimeline.Block
    var hourHeight: CGFloat
    var day: EpochMs
    var onMove: (EpochMs) -> Void
    var onTap: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag: (active: Bool, dy: CGFloat) = (false, 0)
    @State private var pickedUp = 0
    @State private var snapped = 0

    private var deltaMinutes: Int { Int((drag.dy / hourHeight * 60 / 15).rounded()) * 15 }

    var body: some View {
        let movable = block.kind != .check
        let shape = RoundedRectangle(cornerRadius: block.kind == .check ? 9 : 6, style: .continuous)
        HStack(alignment: .top, spacing: 0) {
            if block.kind != .check { Rectangle().fill(block.color).frame(width: 3) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: block.symbol).imageScale(.small)
                    Text(block.title).lineLimit(1)
                }
                .font(.caption.weight(.semibold))
                if CGFloat(block.placed.height) / 60 * hourHeight > 34 {
                    Text("\(model.hm(block.start + EpochMs(deltaMinutes) * MINUTE))〜\(model.hm(block.end + EpochMs(deltaMinutes) * MINUTE))")
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(block.kind == .event ? block.color : Color.primary)
        .background(shape.fill(block.color.opacity(block.kind == .event ? 0.2 : 0.12)))
        .overlay { if block.running { shape.strokeBorder(Color.green, lineWidth: 1.5) } else if block.kind == .task { shape.strokeBorder(block.color.opacity(0.35), lineWidth: 1) } }
        .clipShape(shape)
        .opacity(block.faded ? 0.5 : 1)
        .scaleEffect(drag.active && !reduceMotion ? 1.03 : 1)
        .shadow(color: .black.opacity(drag.active ? 0.18 : 0), radius: 8, y: 4)
        .offset(y: drag.active ? CGFloat(deltaMinutes) / 60 * hourHeight : 0)
        .zIndex(drag.active ? 10 : 0)
        .animation(reduceMotion ? nil : Motion.pop, value: drag.active)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .gesture(moveGesture, including: movable ? .all : .subviews)
        .sensoryFeedback(.impact(weight: .medium), trigger: pickedUp)
        .sensoryFeedback(.selection, trigger: snapped)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(block.kind == .event ? "予定" : block.kind == .check ? "確認" : "タスク") \(block.title)、\(model.hm(block.start))〜\(model.hm(block.end))")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "15分遅らせる") { if movable { onMove(block.start + 15 * MINUTE) } }
        .accessibilityAction(named: "15分早める") { if movable { onMove(block.start - 15 * MINUTE) } }
    }

    private var moveGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($drag) { value, state, _ in
                switch value {
                case .second(true, let d):
                    state = (true, d?.translation.height ?? 0)
                default: break
                }
            }
            .onChanged { value in
                if case .second(true, nil) = value { pickedUp += 1 }
                if case .second(true, let d?) = value {
                    let m = Int((d.translation.height / hourHeight * 60 / 15).rounded())
                    if m != snapped { snapped = m }
                }
            }
            .onEnded { value in
                guard case .second(true, let d?) = value else { return }
                let m = Int((d.translation.height / hourHeight * 60 / 15).rounded()) * 15
                snapped = 0
                if m != 0 { onMove(block.start + EpochMs(m) * MINUTE) }
            }
    }
}
