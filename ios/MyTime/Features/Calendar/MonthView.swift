import SwiftUI
import MyTimeCore

/// 月の表示（純正カレンダーと同じ操作）。
/// 上下にスクロールして月をまたぐ／ピンチで行の高さを連続で変え、高さに合わせて詳しく（点→名前→時刻→場所）／
/// 予定をタップで予定の詳細、日をタップで選ぶ、日をダブルタップでその日の表示へ（その場所から広がる）／
/// 日を長押しでメニュー（新しい予定・この日の予定を複数の日にコピー）。今日は赤い丸、月の名前は1日の上に。
struct MonthView: View {
    @Binding var selected: Date
    /// 「今日」ボタンを押すたびに増える（今日の月へスクロール）
    var todayTick: Int
    /// 日を開く（タップした位置。画面に対する割合。そこから日の表示が広がる）
    var onOpenDay: (EpochMs, UnitPoint) -> Void

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 1週の行の高さ（ピンチで連続して変わる）
    @AppStorage("calendar.monthRowHeight") private var rowHeight: Double = 92
    @State private var pinchBase: Double?
    @State private var level = 0
    @State private var openTick = 0
    static let minRow: Double = 48, maxRow: Double = 280
    @State private var copyDay: EpochMs?
    @State private var visibleMonth = 0

    private var cal: Calendar { model.time.calendar }
    private let range = -24...24

    private func monthStart(_ offset: Int) -> Date {
        let base = cal.date(from: cal.dateComponents([.year, .month], from: model.time.date(model.now)))!
        return cal.date(byAdding: .month, value: offset, to: base)!
    }

    var body: some View {
        VStack(spacing: 0) {
            weekdayHeader
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(range, id: \.self) { m in
                            monthBlock(m).id(m)
                                .onAppear { visibleMonth = m }
                        }
                    }
                    .padding(.bottom, 80)
                }
                .onAppear {
                    let sel = cal.dateComponents([.month], from: monthStart(0), to: model.time.date(model.time.ms(selected))).month ?? 0
                    proxy.scrollTo(max(range.lowerBound, min(range.upperBound, sel)), anchor: .top)
                }
                .onChange(of: todayTick) { _, _ in
                    withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(0, anchor: .top) }
                }
            }
            // ピンチ：指の動きに合わせて行が縦に伸び縮みする（離すと段階にそろえる）
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        let base = pinchBase ?? rowHeight
                        pinchBase = base
                        rowHeight = min(Self.maxRow, max(Self.minRow, base * v.magnification))
                        let l = detailLevel(rowHeight)
                        if l != level { level = l }
                    }
                    .onEnded { _ in
                        pinchBase = nil
                        let stops: [Double] = [50, 92, 150, 220, 280]
                        let target = stops.min { abs($0 - rowHeight) < abs($1 - rowHeight) } ?? 92
                        withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) { rowHeight = target }
                        level = detailLevel(target)
                    }
            )
        }
        .sensoryFeedback(.selection, trigger: level)
        .sensoryFeedback(.impact(weight: .medium), trigger: openTick)
        .onAppear { level = detailLevel(rowHeight) }
        .sheet(item: Binding(get: { copyDay.map(CopySource.init) }, set: { copyDay = $0?.day })) { src in
            CopyToDaysSheet(sourceDay: src.day).environment(model)
        }
    }

    struct CopySource: Identifiable { var day: EpochMs; var id: EpochMs { day } }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                Text(DomainTime.weekdayJa[i]).font(.caption2.weight(.semibold))
                    .foregroundStyle(i == 0 || i == 6 ? Color.secondary.opacity(0.7) : .secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: 1か月

    private func monthBlock(_ offset: Int) -> some View {
        let start = monthStart(offset)
        let first = model.time.ms(start)
        let lead = model.time.weekday(first)
        let days = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        let weeks = Int(ceil(Double(lead + days) / 7))
        let isCurrent = offset == 0
        let events = model.visibleEvents(from: first, to: model.time.addDays(first, days))
        var byDay: [EpochMs: [EventOccurrence]] = [:]
        for o in events {
            var d = model.time.startOfDay(max(o.start, first))
            let end = min(o.end, model.time.addDays(first, days))
            while d < end { byDay[d, default: []].append(o); d = model.time.addDays(d, 1) }
        }
        return VStack(alignment: .leading, spacing: 0) {
            // 月の名前は、その月の1日の列の上に（純正カレンダーと同じ）
            GeometryReader { g in
                let colW = g.size.width / 7
                Text(cal.component(.month, from: start) == 1 || offset == range.lowerBound ? start.formatted(.dateTime.year().month(.wide)) : start.formatted(.dateTime.month(.wide)))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isCurrent ? Color.red : Color.primary)
                    .fixedSize()
                    .offset(x: max(8, colW * CGFloat(lead) + colW / 2 - 14))
            }
            .frame(height: 34)
            .padding(.top, 10)
            ForEach(0..<weeks, id: \.self) { w in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        let idx = w * 7 + i - lead
                        if idx >= 0 && idx < days {
                            let d = model.time.addDays(first, idx)
                            dayCell(d, events: (byDay[d] ?? []).sorted { ($0.event.allDay ? 0 : 1, $0.start) < ($1.event.allDay ? 0 : 1, $1.start) })
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: rowHeight)
                .overlay(alignment: .top) { Rectangle().fill(Color(.separator).opacity(0.6)).frame(height: 0.5) }
            }
        }
    }

    /// 0：点だけ／1：名前／2：名前と時刻／3：名前・時刻・場所や教室
    private func detailLevel(_ h: Double) -> Int { h < 70 ? 0 : h < 135 ? 1 : h < 200 ? 2 : 3 }

    private func dayCell(_ d: EpochMs, events: [EventOccurrence]) -> some View {
        let today = model.time.isSameDay(d, model.now)
        let sel = model.time.isSameDay(d, model.time.ms(selected))
        let wd = model.time.weekday(d)
        let n = cal.component(.day, from: model.time.date(d))
        let lv = detailLevel(rowHeight)
        let rowH: CGFloat = lv >= 3 ? 40 : lv == 2 ? 27 : 14
        let maxRows = max(1, Int((CGFloat(rowHeight) - 36) / (rowH + 1)))
        return VStack(spacing: 2) {
            Text("\(n)")
                .font(.callout.weight(today || sel ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(today ? Color.white : sel ? Color(.systemBackground) : (wd == 0 || wd == 6) ? Color.secondary : Color.primary)
                .frame(width: 28, height: 28)
                .background {
                    if today { Circle().fill(Color.red) } else if sel { Circle().fill(Color.primary) }
                }
                .padding(.top, 3)
            if lv >= 1 {
                VStack(spacing: 1) {
                    ForEach(events.prefix(events.count > maxRows ? maxRows - 1 : maxRows), id: \.id) { o in
                        eventRow(o, level: lv, height: rowH)
                    }
                    if events.count > maxRows {
                        Text("他\(events.count - (maxRows - 1))件").font(.system(size: 9)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 2)
                    }
                }
                .padding(.horizontal, 1)
            } else if !events.isEmpty {
                HStack(spacing: 2) {
                    ForEach(events.prefix(3), id: \.id) { o in Circle().fill(Color(hex: model.eventColor(o.event))).frame(width: 5, height: 5) }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { if sel && !today { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.06)).padding(1) } }
        .clipped()
        .contentShape(Rectangle())
        // ダブルタップ：その場所から日の表示へ広がる
        .onTapGesture(count: 2, coordinateSpace: .global) { p in
            openTick += 1
            selected = model.time.date(d)
            let size = UIScreen.main.bounds.size
            onOpenDay(d, UnitPoint(x: p.x / max(1, size.width), y: p.y / max(1, size.height)))
        }
        // タップ：その日を選ぶ
        .onTapGesture { withAnimation(.snappy) { selected = model.time.date(d) } }
        .contextMenu {
            Button("この日を開く", systemImage: "calendar.day.timeline.left") { onOpenDay(d, .center) }
            Button("新しい予定", systemImage: "plus") {
                let s = d + 9 * HOUR
                router.open(.editor(EditorSeed(kind: .event, start: s, end: s + HOUR)))
            }
            Button("新しいタスク", systemImage: "checklist") {
                let s = d + 9 * HOUR
                router.open(.editor(EditorSeed(kind: .task, start: s, end: s + HOUR)))
            }
            if !events.isEmpty {
                Divider()
                Button("この日の予定を複数の日にコピー…", systemImage: "doc.on.doc") { copyDay = d }
            }
        } preview: {
            DayPreview(day: d, events: events).environment(model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.time.dayLabel(d) + (today ? "、今日" : "") + (events.isEmpty ? "" : "、予定\(events.count)件"))
        .accessibilityHint("ダブルタップでその日を開きます。長押しでメニュー")
        .accessibilityAction(named: "この日を開く") { onOpenDay(d, .center) }
    }

    /// 予定の1行。タップで予定の詳細。高さに合わせて、名前→時刻→場所・教室まで出す
    private func eventRow(_ o: EventOccurrence, level: Int, height: CGFloat) -> some View {
        let c = Color(hex: model.eventColor(o.event))
        let filled = o.event.allDay
        let room = o.event.classInfo?["room"]?.stringValue.flatMap { $0.isEmpty ? nil : "\($0)教室" }
        let sub = room ?? o.event.placeName
        return HStack(alignment: .top, spacing: 3) {
            if !filled { RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 2) }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 2) {
                    if isShiftPending(o.event) { Image(systemName: "hourglass").font(.system(size: 7, weight: .bold)) }
                    Text(o.title).font(.system(size: level >= 2 ? 10 : 9, weight: .semibold)).lineLimit(1)
                }
                if level >= 2 && !filled {
                    Text(model.hm(o.start)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                if level >= 3, let sub, !sub.isEmpty {
                    Text(sub).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(filled ? Color.white : Color.primary)
        .padding(.horizontal, 2).padding(.vertical, level >= 2 ? 2 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 3).fill(filled ? AnyShapeStyle(c) : AnyShapeStyle(c.opacity(0.15))))
        .contentShape(Rectangle())
        .onTapGesture { router.open(.event(o.id)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(o.title)、\(o.event.allDay ? "終日" : model.hm(o.start))")
    }
}

/// 日を長押ししたときのプレビュー（その日の予定）
struct DayPreview: View {
    var day: EpochMs
    var events: [EventOccurrence]
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.time.dayLabel(day)).font(.headline)
            if events.isEmpty { Text("予定はありません").foregroundStyle(.secondary) }
            ForEach(events.prefix(8), id: \.id) { o in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: model.eventColor(o.event))).frame(width: 4, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(o.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(o.event.allDay ? "終日" : "\(model.hm(o.start))〜\(model.hm(o.end))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }
}

// MARK: 複数の日にコピー

/// 予定を、選んだいくつもの日に同じ時刻でコピーする（繰り返しにせず、1つずつの予定として作る）
struct CopyToDaysSheet: View {
    /// その日の予定をまとめてコピーするとき
    var sourceDay: EpochMs?
    /// 1つの予定（回）をコピーするとき
    var occurrence: EventOccurrence?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var dates: Set<DateComponents> = []
    @State private var chosen: Set<String> = []
    @State private var done = 0

    private var sources: [EventOccurrence] {
        if let occurrence { return [occurrence] }
        guard let d = sourceDay else { return [] }
        return model.visibleEvents(from: d, to: model.time.addDays(d, 1)).filter { model.time.isSameDay($0.start, d) || $0.event.allDay }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(sources, id: \.id) { o in
                        Button {
                            if chosen.contains(o.id) { chosen.remove(o.id) } else { chosen.insert(o.id) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: chosen.contains(o.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).foregroundStyle(chosen.contains(o.id) ? Color.accentColor : .secondary)
                                RoundedRectangle(cornerRadius: 2).fill(Color(hex: model.eventColor(o.event))).frame(width: 4, height: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(o.title).foregroundStyle(.primary)
                                    Text(o.event.allDay ? "終日" : "\(model.hm(o.start))〜\(model.hm(o.end))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("コピーする予定") }

                Section {
                    MultiDatePicker("コピー先の日", selection: $dates)
                        .tint(.accentColor)
                } header: {
                    Text("コピー先の日（いくつでも）")
                } footer: {
                    Text("同じ時刻で、選んだ日それぞれに新しい予定を作ります。間違えたときは iPhone を振ると元に戻せます。")
                }
            }
            .navigationTitle("複数の日にコピー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("コピー") { copy() }.fontWeight(.semibold).disabled(dates.isEmpty || chosen.isEmpty)
                }
            }
            .safeAreaInset(edge: .top) {
                if !dates.isEmpty && !chosen.isEmpty {
                    GlassPill(text: "\(dates.count)日 × \(chosen.count)件 = \(dates.count * chosen.count)件を作ります", symbol: "doc.on.doc", tint: .accentColor)
                        .padding(.vertical, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: dates.count * chosen.count)
            .onAppear { chosen = Set(sources.map(\.id)) }
            .sensoryFeedback(.success, trigger: done)
        }
        .presentationDetents([.large])
    }

    private func copy() {
        let targets = dates.compactMap { model.time.calendar.date(from: $0) }.map { model.time.startOfDay(model.time.ms($0)) }
        let picks = sources.filter { chosen.contains($0.id) }
        var made: [String] = []
        let ok = model.perform("\(targets.count * picks.count)件をコピーしました", undo: {
            for id in made { try model.repo.deleteEvent(id) }
        }) {
            for t in targets {
                for o in picks {
                    let shift = t - model.time.startOfDay(o.start)
                    var e = MTEvent.make(title: o.title, calendarId: o.event.calendarId, start: o.start + shift, end: o.end + shift, now: model.now, id: model.repo.newId())
                    e.notes = o.event.notes
                    e.extra = o.event.extra
                    e.employerId = o.event.employerId
                    e.classInfo = o.event.classInfo
                    try model.repo.saveEvent(e, isNew: true)
                    made.append(e.id)
                }
            }
        }
        if ok { done += 1; dismiss() }
    }
}
