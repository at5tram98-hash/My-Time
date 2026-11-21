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
    /// 一番左に見えている日（はじめは今日。週の区切りに関係なく、日をまたいで続けて流れる）
    @State private var leftDay: EpochMs?
    /// 前後にあらかじめ並べておく日数（指を離すまでに見える分）
    private let pad = 7
    @State private var dragX: CGFloat = 0
    @State private var hourHeight: CGFloat = 52
    @State private var tick = 0
    /// 最後に横へなぞった時刻（なぞった直後のタップで予定を開かない）
    @State private var lastSwipe = Date.distantPast
    static let gutter: CGFloat = 44

    /// 並べる最初の日（一番左の日の pad 日前）
    private var base: EpochMs {
        let l = leftDay ?? model.time.startOfDay(now)
        return model.time.addDays(l, -pad)
    }
    private var columns: Int { visible + pad * 2 }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width - Self.gutter)
            let colW = w / CGFloat(visible)
            let x = -CGFloat(pad) * colW + dragX
            VStack(spacing: 0) {
                header(colW: colW, width: w, x: x)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            gutterColumn
                            ZStack(alignment: .topLeading) {
                                HStack(spacing: 0) {
                                    ForEach(0..<columns, id: \.self) { i in
                                        dayColumn(model.time.addDays(base, i), width: colW)
                                    }
                                }
                                .offset(x: x)
                            }
                            .frame(width: w, height: hourHeight * 24, alignment: .topLeading)
                            .clipped()
                        }
                        .background(alignment: .topLeading) { gridLines }
                    }
                    .guardsTaps()
                    .refreshable { await model.refreshAll() }
                    .onAppear {
                        // はじめは今日を一番左に（別の日を選んでいたら、その日を一番左に）
                        // 「表示と動き」で「日曜から」にしたときは、その週の日曜を一番左に
                        if leftDay == nil {
                            let d = model.time.startOfDay(model.time.ms(selected))
                            leftDay = Prefs.bool(Prefs.weekFromToday, true) ? d : model.time.addDays(d, -model.time.weekday(d))
                        }
                        // 「いま」を画面の上から3割ほどに
                        let h = model.time.minutesOfDay(now) / 60
                        proxy.scrollTo("w\(max(0, min(23, h)))", anchor: UnitPoint(x: 0.5, y: 0.3))
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                MagnifyGesture().onEnded { v in
                    let next = v.magnification < 1 ? 7 : 3
                    guard next != visible else { return }
                    withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) { visible = next }
                }
            )
        }
        .sensoryFeedback(.selection, trigger: tick)
        // 「今日」や日付の選び直しで、見えていない日になったら、その日を一番左へ
        .onChange(of: selected) { _, d in
            let sd = model.time.startOfDay(model.time.ms(d))
            let l = leftDay ?? sd
            if sd < l || sd >= model.time.addDays(l, visible) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9)) { leftDay = sd }
            }
        }
    }

    /// 指を離したら、勢いに合わせて列の境目にそろえる（最大7日）。動き終わったら並べ直して、続けて流れるように
    private func settle(dx: CGFloat, predicted: CGFloat, colW: CGFloat) {
        let n = max(-pad, min(pad, Int((-(dx + predicted * 0.6) / colW).rounded())))
        let anim: Animation? = reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.9)
        withAnimation(anim, completionCriteria: .logicallyComplete) {
            dragX = -CGFloat(n) * colW
        } completion: {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                leftDay = model.time.addDays(leftDay ?? model.time.startOfDay(now), n)
                dragX = 0
            }
            if let l = leftDay { selected = model.time.date(l) }
        }
        if n != 0 { tick += 1 }
    }

    /// 今日を一番左へ（「今日」ボタン）
    func goToday() { leftDay = model.time.startOfDay(now) }

    // MARK: 見出し（日付・終日の予定）

    private func header(colW: CGFloat, width: CGFloat, x: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button { withAnimation(.snappy) { visible = visible == 3 ? 7 : 3 } } label: {
                Text(visible == 3 ? "3日" : "7日").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
                    .frame(width: Self.gutter - 6, height: 26)
                    .glass(Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .frame(width: Self.gutter)
            .accessibilityLabel(visible == 3 ? "7日表示にする" : "3日表示にする")
            HStack(spacing: 0) {
                ForEach(0..<columns, id: \.self) { k in
                    let d = model.time.addDays(base, k)
                    let i = model.time.weekday(d)
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
                    // 長押しで、その日に新しい予定・タスク
                    .contextMenu {
                        Button("この日に予定を追加", systemImage: "calendar.badge.plus") { router.open(.editor(EditorSeed(kind: .event, start: d + 9 * HOUR, end: d + 10 * HOUR))) }
                        Button("この日にタスクを追加", systemImage: "checklist") { router.open(.editor(EditorSeed(kind: .task, start: d + 9 * HOUR, end: d + 10 * HOUR))) }
                        Button("日の表示で開く", systemImage: "calendar.day.timeline.left") { onOpenDay(d) }
                    }
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
        /// 予定の前の移動時間（分）。出発の ◆ を出す
        var travel: Int? = nil
        /// ほかの人（みお）の予定：塗らずに目立たせない
        var other = false
    }

    private func items(_ d: EpochMs) -> [Item] {
        let d1 = model.time.addDays(d, 1)
        var out: [Item] = model.visibleEvents(from: d, to: d1, includeStruck: true).filter { !$0.event.allDay && $0.start < d1 && $0.end > d }.map { o in
            Item(id: "e:\(o.id)", title: o.title, start: max(o.start, d), end: min(o.end, d1), color: o.isStruck ? .gray : Color(hex: model.eventColor(o.event)), isEvent: true, done: o.isStruck, pending: isShiftPending(o.event), open: .event(o.id),
                 symbol: o.event.specType.flatMap { SPEC_BY_ID[$0]?.symbol } ?? (model.calendar(o.event.calendarId)?.kind == .class ? "graduationcap.fill" : model.calendar(o.event.calendarId)?.kind == .job ? "briefcase.fill" : "calendar"),
                 sub: o.isStruck ? nil : (o.event.classInfo?["room"]?.stringValue.flatMap { $0.isEmpty ? nil : compactRoom($0) } ?? o.event.placeName),
                 travel: o.isStruck || o.start < d ? nil : o.event.travelMinutes.flatMap { $0 > 0 ? $0 : nil },
                 other: model.dimOther(o.event.calendarId))
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
                            settle(dx: dx, predicted: predicted - dx, colW: width)
                        }
                    )
                }
            // 日の境目の線はごく薄く（目立つ縦線にしない）
            Rectangle().fill(Color(.separator).opacity(0.18)).frame(width: 0.5).frame(maxHeight: .infinity).allowsHitTesting(false)
            ForEach(list) { it in
                if let p = placed[it.id] {
                    let cw = (width - 4) / CGFloat(p.columns)
                    block(it, height: max(20, CGFloat(p.height) / 60 * hourHeight - 2), width: cw - 2)
                        .offset(x: 2 + cw * CGFloat(p.column), y: CGFloat(p.top) / 60 * hourHeight + 1)
                }
            }
            // 出発の時刻（◆だけ。列の左に）
            ForEach(list.filter { $0.travel != nil && !$0.done }) { it in
                let leave = it.start - EpochMs(it.travel ?? 0) * MINUTE
                if leave >= d {
                    Text("◆").font(.system(size: 9, weight: .bold)).foregroundStyle(it.color)
                        .offset(x: 1, y: CGFloat(model.time.minutesOfDay(leave)) / 60 * hourHeight - 6)
                        .accessibilityLabel("出発 \(model.hm(leave))")
                        .allowsHitTesting(false)
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
                    Image(systemName: !it.isEvent && it.done ? "checkmark.circle.fill" : it.symbol).font(.system(size: visible == 7 ? 6.5 : 8, weight: .bold))
                    Text(it.title).tracking(-0.2).lineLimit(height > 44 ? 2 : 1).truncationMode(.tail).strikethrough(it.done)
                }
                .font(.system(size: visible == 7 ? 8.5 : 10.5, weight: .semibold))
                if height > 30 {
                    Text(visible == 3 ? "\(model.hm(it.start))〜\(model.hm(it.end))" : model.hm(it.start)).font(.system(size: visible == 7 ? 7.5 : 9)).monospacedDigit().opacity(0.75).lineLimit(1)
                }
                if height > 48, let sub = it.sub, !sub.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "mappin").font(.system(size: 6.5))
                        Text(sub).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: visible == 7 ? 7.5 : 8.5)).opacity(0.7)
                }
            }
            .padding(.leading, 4).padding(.trailing, 2).padding(.vertical, 3)
            .frame(width: max(8, width), height: height, alignment: .topLeading)
                        // 純正カレンダーと同じ：淡い色の札に、左の色の帯と同じ色の文字。ほかの人の予定は枠だけでうすく
            .foregroundStyle(it.other || it.done ? Color.secondary : it.isEvent ? it.color.deepened : it.color)
            .background(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(it.other ? AnyShapeStyle(Color.clear) : AnyShapeStyle(it.color.opacity(it.isEvent ? 0.22 : 0.12)))
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(it.other ? Color(.separator) : it.isEvent ? .clear : it.color.opacity(0.45), style: StrokeStyle(lineWidth: 0.8, dash: it.other ? [3, 2] : [])))
            .opacity(it.done ? 0.55 : it.other ? 0.7 : 1)
        .contentShape(Rectangle())
        .deliberateTap { if Date().timeIntervalSince(lastSwipe) > 0.4 { router.open(it.open) } }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { router.open(it.open) }
        .accessibilityLabel("\(it.isEvent ? "予定" : "タスク") \(it.title)、\(model.hm(it.start))〜\(model.hm(it.end))")
    }
}
