import SwiftUI
import MyTimeCore

/// 週の時刻軸。日の表示と同じ時刻軸を、日ごとの列にして並べる。
/// 左右になぞると1日ずつ動き、週の端を越えると前後の週へ。ピンチで3日表示⇄7日表示。
/// 予定・タスクをタップで開く、空いている所を長押しでその時刻に新しい予定。
struct WeekTimeline: View {
    @Binding var selected: Date
    var now: EpochMs
    var onOpenDay: (EpochMs) -> Void

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("calendar.weekVisible") private var visible = 3
    @State private var first = 0
    @State private var dragX: CGFloat = 0
    @State private var hourHeight: CGFloat = 52
    @State private var tick = 0
    /// 最後に横へなぞった時刻（なぞった直後のタップで予定を開かない）
    @State private var lastSwipe = Date.distantPast
    static let gutter: CGFloat = 44

    private var weekStart: EpochMs {
        let d = model.time.startOfDay(model.time.ms(selected))
        return model.time.addDays(d, -model.time.weekday(d))
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - Self.gutter)
            let colW = w / CGFloat(visible)
            let x = -CGFloat(first) * colW + dragX
            VStack(spacing: 0) {
                header(colW: colW, width: w, x: x)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            gutterColumn
                            ZStack(alignment: .topLeading) {
                                HStack(spacing: 0) {
                                    ForEach(0..<7, id: \.self) { i in
                                        dayColumn(model.time.addDays(weekStart, i), width: colW)
                                    }
                                }
                                .offset(x: x)
                            }
                            .frame(width: w, height: hourHeight * 24, alignment: .topLeading)
                            .clipped()
                        }
                        .background(alignment: .topLeading) { gridLines }
                    }
                    .onAppear {
                        first = clampFirst(model.time.weekday(model.time.ms(selected)) - visible / 2)
                        let h = model.time.minutesOfDay(now) / 60
                        proxy.scrollTo("w\(max(0, min(23, h - 1)))", anchor: .top)
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                MagnifyGesture().onEnded { v in
                    let next = v.magnification < 1 ? 7 : 3
                    guard next != visible else { return }
                    withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) {
                        visible = next
                        first = clampFirst(first)
                    }
                }
            )
        }
        .sensoryFeedback(.selection, trigger: tick)
    }

    private func clampFirst(_ f: Int) -> Int { max(0, min(7 - visible, f)) }

    /// 指を離したら列の境目にそろえる。週の端を越えたら前後の週へ
    private func settle(_ target: Int) {
        let anim: Animation? = reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)
        if target < 0 {
            selected = model.time.date(model.time.addDays(weekStart, -7 + max(0, 7 - visible)))
            first = 7 - visible
            dragX = 0
            tick += 1
        } else if target > 7 - visible {
            selected = model.time.date(model.time.addDays(weekStart, 7))
            first = 0
            dragX = 0
            tick += 1
        } else {
            let changed = target != first
            withAnimation(anim) { first = target; dragX = 0 }
            if changed { tick += 1 }
            selected = model.time.date(model.time.addDays(weekStart, target))
        }
    }

    // MARK: 見出し（日付・終日の予定）

    private func header(colW: CGFloat, width: CGFloat, x: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button { withAnimation(.snappy) { visible = visible == 3 ? 7 : 3; first = clampFirst(first) } } label: {
                Text(visible == 3 ? "3日" : "7日").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
                    .frame(width: Self.gutter - 6, height: 26)
                    .glass(Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .frame(width: Self.gutter)
            .accessibilityLabel(visible == 3 ? "7日表示にする" : "3日表示にする")
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    let d = model.time.addDays(weekStart, i)
                    let today = model.time.isSameDay(d, now)
                    let allDay = model.visibleEvents(from: d, to: model.time.addDays(d, 1), includeStruck: true).filter(\.event.allDay)
                    Button { onOpenDay(d) } label: {
                        VStack(spacing: 2) {
                            HStack(spacing: 3) {
                                Text(DomainTime.weekdayJa[i]).font(.caption2.weight(.semibold))
                                    .foregroundStyle(i == 0 ? .red : i == 6 ? .blue : .secondary)
                                Text("\(model.time.calendar.component(.day, from: model.time.date(d)))")
                                    .font(.subheadline.weight(today ? .bold : .semibold)).monospacedDigit()
                                    .foregroundStyle(today ? Color.white : Color.primary)
                                    .padding(.horizontal, today ? 6 : 0).padding(.vertical, 1)
                                    .background { if today { Capsule().fill(Color.red.gradient) } }
                            }
                            ForEach(allDay.prefix(visible == 3 ? 2 : 1), id: \.id) { o in
                                Text(o.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                    .foregroundStyle(Color(hex: model.eventColor(o.event)))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: model.eventColor(o.event)).opacity(0.16)))
                            }
                        }
                        .padding(.horizontal, 2).padding(.vertical, 4)
                        .frame(width: colW, alignment: .top)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(model.time.dayLabel(d))を日の表示で開く")
                }
            }
            .offset(x: x)
            .frame(width: width, alignment: .leading)
            .clipped()
        }
        .padding(.vertical, 2)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: 目盛り

    private var gutterColumn: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                Text("\(h):00").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: Self.gutter - 6, height: hourHeight, alignment: .topTrailing)
                    .offset(y: -6)
                    .opacity(h == 0 ? 0 : 1)
                    .id("w\(h)")
            }
        }
        .frame(width: Self.gutter)
    }

    private var gridLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { _ in
                Rectangle().fill(Color(.separator).opacity(0.5)).frame(height: 0.5)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .frame(height: hourHeight)
            }
        }
        .padding(.leading, Self.gutter)
        .allowsHitTesting(false)
    }

    // MARK: 1日の列

    private struct Item: Identifiable {
        var id: String
        var title: String
        var start: EpochMs
        var end: EpochMs
        var color: Color
        var isEvent: Bool
        var done: Bool
        var pending: Bool
        var open: SheetRoute
        var symbol: String = "calendar"
        /// 教室・場所など（余裕があれば表示）
        var sub: String? = nil
    }

    private func items(_ d: EpochMs) -> [Item] {
        let d1 = model.time.addDays(d, 1)
        var out: [Item] = model.visibleEvents(from: d, to: d1, includeStruck: true).filter { !$0.event.allDay && $0.start < d1 && $0.end > d }.map { o in
            Item(id: "e:\(o.id)", title: o.title, start: max(o.start, d), end: min(o.end, d1), color: o.isStruck ? .gray : Color(hex: model.eventColor(o.event)), isEvent: true, done: o.isStruck, pending: isShiftPending(o.event), open: .event(o.id),
                 symbol: o.event.specType.flatMap { SPEC_BY_ID[$0]?.symbol } ?? (model.calendar(o.event.calendarId)?.kind == .class ? "graduationcap.fill" : model.calendar(o.event.calendarId)?.kind == .job ? "briefcase.fill" : "calendar"),
                 sub: o.isStruck ? nil : (o.event.classInfo?["room"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? o.event.placeName))
        }
        for t in model.tasks {
            if t.kind == .do, let s = t.plannedStart, let e = t.plannedEnd, s < d1, e > d {
                out.append(Item(id: "t:\(t.id)", title: t.title, start: max(s, d), end: min(e, d1), color: t.extra?["color"]?.stringValue.map { Color(hex: $0) } ?? .accentColor, isEvent: false, done: t.isDone, pending: false, open: .task(t.id), symbol: IconMap.symbol(t.icon), sub: PlaceValue(t.extra?["place"])?.name))
            } else if t.kind == .check, let c = t.checkAt, c >= d, c < d1 {
                out.append(Item(id: "c:\(t.id)", title: t.title, start: c, end: c + 15 * MINUTE, color: .checkTask, isEvent: false, done: t.checked, pending: false, open: .task(t.id), symbol: "checkmark.circle"))
            }
        }
        return out
    }

    private func dayColumn(_ d: EpochMs, width: CGFloat) -> some View {
        let list = items(d)
        let placed = Dictionary(layoutDay(list.map { TimedItem(id: $0.id, start: $0.start, end: $0.end) }, day: d, time: model.time).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let today = model.time.isSameDay(d, now)
        return ZStack(alignment: .topLeading) {
            // 空いている所：長押しでその時刻に新しい予定
            Rectangle().fill(today ? Color.accentColor.opacity(0.04) : Color.clear)
                .contentShape(Rectangle())
                // 長押しで新しい予定・左右になぞって日を動かす（UIKit のジェスチャー：上下のスクロールを邪魔しない）
                .overlay {
                    PressDragRecognizer(
                        minimumDuration: 0.75,
                        onEnded: { p, t in
                            guard abs(t.width) < 10 && abs(t.height) < 10 else { return }
                            let m = Int(p.y / hourHeight * 60) / 15 * 15
                            let s = d + EpochMs(m) * MINUTE
                            router.open(.editor(EditorSeed(kind: .event, start: s, end: s + HOUR)))
                        },
                        onHorizontalPan: { dx in dragX = dx; lastSwipe = Date() },
                        onHorizontalPanEnded: { dx, predicted in
                            lastSwipe = Date()
                            let moved = Int((-(dx + predicted) / 2 / width).rounded())
                            settle(first + moved)
                        }
                    )
                }
            Rectangle().fill(Color(.separator).opacity(0.5)).frame(width: 0.5).frame(maxHeight: .infinity).allowsHitTesting(false)
            ForEach(list) { it in
                if let p = placed[it.id] {
                    let cw = (width - 4) / CGFloat(p.columns)
                    block(it, height: max(20, CGFloat(p.height) / 60 * hourHeight - 2), width: cw - 2)
                        .offset(x: 2 + cw * CGFloat(p.column), y: CGFloat(p.top) / 60 * hourHeight + 1)
                }
            }
            ForEach(model.checkpoints(on: d)) { c in
                CheckpointLine(checkpoint: c, width: width) { router.open(.checkpoint(c)) }
                    .offset(y: CGFloat(model.time.minutesOfDay(c.at)) / 60 * hourHeight - 9)
            }
            if today {
                let y = CGFloat(model.time.minutesOfDay(now)) / 60 * hourHeight
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.red).frame(height: 1.5)
                    Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: -4)
                }
                .offset(y: y - 0.75)
                .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: hourHeight * 24, alignment: .topLeading)
    }

    private func block(_ it: Item, height: CGFloat, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    if it.pending { Image(systemName: "hourglass").font(.system(size: 8, weight: .bold)) }
                    Image(systemName: !it.isEvent && it.done ? "checkmark.circle.fill" : it.symbol).font(.system(size: visible == 7 ? 7 : 9, weight: .bold))
                    Text(it.title).lineLimit(height > 40 ? 2 : 1).strikethrough(it.done)
                }
                .font(.system(size: visible == 7 ? 9 : 11, weight: .semibold))
                if height > 30 {
                    Text(visible == 3 ? "\(model.hm(it.start))〜\(model.hm(it.end))" : model.hm(it.start)).font(.system(size: visible == 7 ? 8 : 9)).monospacedDigit().opacity(0.85).lineLimit(1)
                }
                if height > 48, let sub = it.sub, !sub.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "mappin").font(.system(size: 7))
                        Text(sub).lineLimit(1)
                    }
                    .font(.system(size: visible == 7 ? 8 : 9)).opacity(0.85)
                }
            }
            .padding(.horizontal, 3).padding(.vertical, 2)
            .frame(width: max(8, width), height: height, alignment: .topLeading)
            .foregroundStyle(it.isEvent ? Color.white : it.color)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(it.isEvent ? AnyShapeStyle(it.color.gradient.opacity(it.done ? 0.4 : 0.9)) : AnyShapeStyle(it.color.opacity(0.14))))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(it.isEvent ? .clear : it.color.opacity(0.5), lineWidth: 0.8))
            .opacity(it.done ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if Date().timeIntervalSince(lastSwipe) > 0.4 { router.open(it.open) } }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { router.open(it.open) }
        .accessibilityLabel("\(it.isEvent ? "予定" : "タスク") \(it.title)、\(model.hm(it.start))〜\(model.hm(it.end))")
    }
}
