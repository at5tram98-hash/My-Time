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
    /// 画面の一番上に見えている月（見出しに出す）。外から変えるとその月へスクロール
    @Binding var visibleMonth: Date
    /// 日を開く（タップした位置。画面に対する割合。そこから日の表示が広がる）
    var onOpenDay: (EpochMs, UnitPoint) -> Void

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 1週の行の高さ（ピンチで連続して変わる）
    @AppStorage("calendar.monthRowHeight2") private var rowHeight: Double = 128
    @State private var pinchBase: Double?
    @State private var level = 0
    @State private var openTick = 0
    static let minRow: Double = 48, maxRow: Double = 280
    @State private var copyDay: EpochMs?
    @State private var shownOffset = 0
    /// 自分でスクロールして見出しを変えたとき（外から変えたときと区別する）
    @State private var settingFromScroll = false

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
                                .background {
                                    GeometryReader { g in
                                        Color.clear.preference(key: MonthTopKey.self, value: [m: g.frame(in: .named("monthScroll")).minY])
                                    }
                                }
                        }
                    }
                    .padding(.bottom, 120)
                }
                .coordinateSpace(name: "monthScroll")
                .scrollIndicators(.hidden)
                .guardsTaps()
                // 一番上に見えている月を見出しへ
                .onPreferenceChange(MonthTopKey.self) { tops in
                    guard let m = tops.filter({ $0.value <= 60 }).max(by: { $0.value < $1.value })?.key ?? tops.min(by: { $0.value < $1.value })?.key,
                          m != shownOffset else { return }
                    shownOffset = m
                    settingFromScroll = true
                    visibleMonth = monthStart(m)
                }
                .onAppear {
                    scrollToWeek(model.time.ms(selected), proxy: proxy, animated: false)
                    visibleMonth = monthStart(monthOffset(model.time.ms(selected)))
                }
                .onChange(of: todayTick) { _, _ in scrollToWeek(model.now, proxy: proxy, animated: true) }
                // 年の表示で月を選んだとき：その月へ
                .onChange(of: visibleMonth) { _, m in
                    if settingFromScroll { settingFromScroll = false; return }
                    let off = monthOffset(model.time.ms(m))
                    guard off != shownOffset else { return }
                    shownOffset = off
                    proxy.scrollTo(off, anchor: .top)
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
                        let stops: [Double] = [56, 96, 128, 200, 280]
                        let target = stops.min { abs($0 - rowHeight) < abs($1 - rowHeight) } ?? 128
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

    private func monthOffset(_ day: EpochMs) -> Int {
        max(range.lowerBound, min(range.upperBound, cal.dateComponents([.month], from: monthStart(0), to: model.time.date(day)).month ?? 0))
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                Text(DomainTime.weekdayJa[i]).font(.caption2.weight(.medium))
                    .foregroundStyle(i == 0 || i == 6 ? Color.secondary.opacity(0.6) : .secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
    }

    /// その日のある週へ（行が高いときも、選んだ日が画面に入るように）
    private func scrollToWeek(_ day: EpochMs, proxy: ScrollViewProxy, animated: Bool) {
        let m = max(range.lowerBound, min(range.upperBound, cal.dateComponents([.month], from: monthStart(0), to: model.time.date(day)).month ?? 0))
        let first = model.time.ms(monthStart(m))
        let w = (model.time.weekday(first) + cal.component(.day, from: model.time.date(day)) - 1) / 7
        // 遅延表示なので、まず月へ。描かれてから週へ寄せる
        if animated { withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(m, anchor: .top) } } else { proxy.scrollTo(m, anchor: .top) }
        guard rowHeight >= 120, w > 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(animated ? 350 : 60))
            withAnimation(reduceMotion || !animated ? nil : .snappy) { proxy.scrollTo("w\(m)-\(w)", anchor: .top) }
        }
    }

    // MARK: 1か月

    private func monthBlock(_ offset: Int) -> some View {
        let start = monthStart(offset)
        let first = model.time.ms(start)
        let lead = model.time.weekday(first)
        let days = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        let weeks = Int(ceil(Double(lead + days) / 7))
        let isCurrent = offset == 0
        let last = model.time.addDays(first, days)
        let events = model.visibleEvents(from: first, to: last, includeStruck: true)
        var byDay: [EpochMs: [CellItem]] = [:]
        for o in events {
            var d = model.time.startOfDay(max(o.start, first))
            let end = min(o.end, last)
            while d < end { byDay[d, default: []].append(.event(o)); d = model.time.addDays(d, 1) }
        }
        // タスク（純正のリマインダーと同じく、丸の札で）：時刻のあるもの・日付だけのもの・確認
        for t in model.tasks {
            let at = t.kind == .check ? t.checkAt : (t.plannedStart ?? t.onDay)
            guard let a = at, a >= first, a < last else { continue }
            byDay[model.time.startOfDay(a), default: []].append(.task(t, a))
        }
        return VStack(alignment: .leading, spacing: 0) {
            // 月の名前（今の月は赤）。いちばん上の月は上の大きな見出しと重なるので出さない
            if offset != shownOffset || offset == range.lowerBound {
                Text(cal.component(.month, from: start) == 1 ? start.formatted(.dateTime.year().month(.wide)) : start.formatted(.dateTime.month(.wide)))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(isCurrent ? Color.red : Color.primary)
                    .padding(.leading, 16)
                    .padding(.top, 18).padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Color.clear.frame(height: 6)
            }
            ForEach(0..<weeks, id: \.self) { w in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        let idx = w * 7 + i - lead
                        if idx >= 0 && idx < days {
                            let d = model.time.addDays(first, idx)
                            dayCell(d, items: (byDay[d] ?? []).sorted(by: CellItem.order))
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(height: rowHeight)
                // 純正と同じく、週の上に細い線だけ（升目の線は引かない）
                .overlay(alignment: .top) { Rectangle().fill(Color(.separator).opacity(0.5)).frame(height: 0.5) }
                .id("w\(offset)-\(w)")
            }
        }
    }

    /// 日の中に並べるもの（予定とタスク）
    enum CellItem: Identifiable {
        case event(EventOccurrence), task(MTTask, EpochMs)
        var id: String {
            switch self {
            case .event(let o): return "e:" + o.id
            case .task(let t, _): return "t:" + t.id
            }
        }
        /// 終日 → 時刻順（タスクは同じ時刻なら後ろ）。取り消し・ほかの人の予定は後ろ
        static func order(_ a: CellItem, _ b: CellItem) -> Bool { a.key < b.key }
        private var key: (Int, Int, EpochMs, Int) {
            switch self {
            case .event(let o): return (o.isStruck ? 1 : 0, o.event.allDay ? 0 : 1, o.start, 0)
            case .task(let t, let a): return (t.isDone ? 1 : 0, 1, a, 1)
            }
        }
    }

    /// 0：点だけ／1：名前／2：名前と時刻／3：名前・時刻・場所や教室
    private func detailLevel(_ h: Double) -> Int { h < 70 ? 0 : h < 110 ? 1 : h < 200 ? 2 : 3 }

    private func dayCell(_ d: EpochMs, items: [CellItem]) -> some View {
        let today = model.time.isSameDay(d, model.now)
        let wd = model.time.weekday(d)
        let n = cal.component(.day, from: model.time.date(d))
        let lv = detailLevel(rowHeight)
        let past = d < model.time.startOfDay(model.now)
        // 札の高さ：時刻つきの予定は2〜3行、終日・タスク・ほかの人の予定は1行
        let room = CGFloat(rowHeight) - 40
        var used: CGFloat = 0
        var shown: [CellItem] = []
        for it in items {
            let h = chipHeight(it, level: lv) + 2
            if used + h > room - (it.id == items.last?.id ? 0 : 14) { break }
            used += h; shown.append(it)
        }
        let hidden = items.count - shown.count
        return VStack(spacing: 2) {
            Text("\(n)")
                .font(.system(size: 20, weight: today ? .bold : (wd == 0 || wd == 6) ? .regular : .semibold)).monospacedDigit()
                .foregroundStyle(today ? Color.white : (wd == 0 || wd == 6 || past) ? Color.secondary : Color.primary)
                .frame(width: 34, height: 34)
                .background { if today { Circle().fill(Color.red) } }
                .padding(.top, 4)
            if lv >= 1 {
                VStack(spacing: 2) {
                    ForEach(shown) { it in chip(it, level: lv) }
                    if hidden > 0 {
                        Text("+\(hidden)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 1.5)
            } else if !items.isEmpty {
                HStack(spacing: 2) {
                    ForEach(items.prefix(3)) { it in Circle().fill(dotColor(it)).frame(width: 5, height: 5) }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .contentShape(Rectangle())
        // タップ：その日へ（押した所から日の表示が広がる。純正と同じ）
        .onTapGesture(coordinateSpace: .global) { p in
            openTick += 1
            selected = model.time.date(d)
            let size = UIScreen.main.bounds.size
            onOpenDay(d, UnitPoint(x: p.x / max(1, size.width), y: p.y / max(1, size.height)))
        }
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
            Button("チェックポイント", systemImage: "flag.checkered") {
                router.open(.checkpoint(Checkpoint(id: model.repo.newId(), title: "", at: d + 8 * HOUR)))
            }
            if items.contains(where: { if case .event = $0 { return true } else { return false } }) {
                Divider()
                Button("この日の予定を複数の日にコピー…", systemImage: "doc.on.doc") { copyDay = d }
            }
        } preview: {
            DayPreview(day: d, events: items.compactMap { if case .event(let o) = $0 { return o } else { return nil } }).environment(model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.time.dayLabel(d) + (today ? "、今日" : "") + (items.isEmpty ? "" : "、\(items.count)件"))
        .accessibilityHint("タップでその日を開きます。長押しでメニュー")
        .accessibilityAction(named: "この日を開く") { onOpenDay(d, .center) }
    }

    private func dotColor(_ it: CellItem) -> Color {
        switch it {
        case .event(let o): return model.isOtherPerson(o.event.calendarId) ? Color.secondary.opacity(0.5) : model.occurrenceColor(o)
        case .task: return .secondary
        }
    }

    private func chipHeight(_ it: CellItem, level: Int) -> CGFloat {
        switch it {
        case .event(let o):
            if o.event.allDay || model.isOtherPerson(o.event.calendarId) || o.isStruck { return 18 }
            return level >= 3 ? 52 : level >= 2 ? 40 : 18
        case .task: return 18
        }
    }

    @ViewBuilder
    private func chip(_ it: CellItem, level: Int) -> some View {
        switch it {
        case .event(let o): eventChip(o, level: level)
        case .task(let t, let at): taskChip(t, at: at)
        }
    }

    /// 予定の札（純正と同じ）：時刻のある予定は淡い色の角丸に名前（2行まで）と時刻、終日は丸い札。
    /// ほかの人（みお）の予定は目立たせない：色を付けず、灰色の細い札に小さな人の点だけ
    private func eventChip(_ o: EventOccurrence, level: Int) -> some View {
        let c = model.occurrenceColor(o)
        let other = model.isOtherPerson(o.event.calendarId)
        let compact = o.event.allDay || other || o.isStruck || level < 2
        let room = o.event.classInfo?["room"]?.stringValue.flatMap { $0.isEmpty ? nil : "\($0)" }
        let sub = room ?? o.event.placeName
        return Group {
            if compact {
                HStack(spacing: 3) {
                    if other {
                        Circle().fill(c.opacity(0.45)).frame(width: 5, height: 5)
                    } else if o.event.allDay {
                        Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(c)
                    }
                    Text(o.title).font(.system(size: 11, weight: other ? .regular : .semibold)).lineLimit(1)
                        .strikethrough(o.isStruck)
                }
                .foregroundStyle(other || o.isStruck ? Color.secondary : o.event.allDay ? Color.primary : c)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
                .background {
                    if other || o.isStruck { Color.clear }
                    else if o.event.allDay { Capsule().fill(Color(.tertiarySystemFill)) }
                    else { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.opacity(0.18)) }
                }
                .opacity(other ? 0.75 : 1)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 2) {
                        if isShiftPending(o.event) { Image(systemName: "hourglass").font(.system(size: 8, weight: .bold)) }
                        Text(o.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(model.hm(o.start)).font(.system(size: 10.5)).monospacedDigit().opacity(0.85)
                    if level >= 3, let sub, !sub.isEmpty {
                        Text(sub).font(.system(size: 9.5)).lineLimit(1).opacity(0.75)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(c.deepened)
                .padding(.horizontal, 4).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: level >= 3 ? 52 : 40)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.opacity(0.2)))
            }
        }
        .contentShape(Rectangle())
        .deliberateTap { router.open(.event(o.id)) }
        .accessibilityElement(children: .combine)
        .accessibilityAction { router.open(.event(o.id)) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel((o.isStruck ? "取り消し、" : "") + (other ? "\(model.calendar(o.event.calendarId)?.name ?? "")の予定、" : "") + "\(o.title)、\(o.event.allDay ? "終日" : model.hm(o.start))")
    }

    /// タスクの札（純正のリマインダーと同じ、丸と名前）
    private func taskChip(_ t: MTTask, at: EpochMs) -> some View {
        let tint = t.kind == .check ? Color.checkTask : Color.doTask
        return HStack(spacing: 3) {
            Image(systemName: t.isDone ? "checkmark.circle.fill" : "circle").font(.system(size: 9, weight: .semibold)).foregroundStyle(tint)
            Text(t.title).font(.system(size: 11, weight: .medium)).lineLimit(1).strikethrough(t.isDone)
        }
        .foregroundStyle(t.isDone ? Color.secondary : Color.primary)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
        .background(Capsule().fill(Color(.quaternarySystemFill)))
        .contentShape(Rectangle())
        .deliberateTap { router.open(.task(t.id)) }
        .accessibilityElement(children: .combine)
        .accessibilityAction { router.open(.task(t.id)) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("タスク、\(t.title)\(t.isDone ? "、済み" : "")")
    }
}

/// 月ごとの見出しの位置（一番上に見えている月を求める）
private struct MonthTopKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue(), uniquingKeysWith: { $1 }) }
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
                    RoundedRectangle(cornerRadius: 2).fill(model.occurrenceColor(o)).frame(width: 4, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(o.title).strikethrough(o.isStruck).font(.subheadline.weight(.medium)).lineLimit(1)
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
        return model.visibleEvents(from: d, to: model.time.addDays(d, 1), includeStruck: true).filter { model.time.isSameDay($0.start, d) || $0.event.allDay }
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
                                RoundedRectangle(cornerRadius: 2).fill(model.occurrenceColor(o)).frame(width: 4, height: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(o.title).strikethrough(o.isStruck).foregroundStyle(.primary)
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
