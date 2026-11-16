import SwiftUI
import MyTimeCore

/// 月の表示（純正カレンダーと同じ操作）。
/// 上下にスクロールして月をまたぐ／日をタップでその日の表示へ／ピンチで「予定の名前を出す⇄点だけ」／
/// 日を長押しでメニュー（新しい予定・この日の予定を複数の日にコピー）。今日は赤い丸、月の名前は1日の上に。
struct MonthView: View {
    @Binding var selected: Date
    /// 「今日」ボタンを押すたびに増える（今日の月へスクロール）
    var todayTick: Int
    var onOpenDay: (EpochMs) -> Void

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("calendar.monthDetailed") private var detailed = true
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
            .simultaneousGesture(
                MagnifyGesture().onEnded { v in
                    let next = v.magnification > 1
                    guard next != detailed else { return }
                    withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) { detailed = next }
                }
            )
        }
        .sensoryFeedback(.selection, trigger: detailed)
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
                .frame(height: detailed ? 92 : 50)
                .overlay(alignment: .top) { Rectangle().fill(Color(.separator).opacity(0.6)).frame(height: 0.5) }
            }
        }
    }

    private func dayCell(_ d: EpochMs, events: [EventOccurrence]) -> some View {
        let today = model.time.isSameDay(d, model.now)
        let sel = model.time.isSameDay(d, model.time.ms(selected))
        let wd = model.time.weekday(d)
        let n = cal.component(.day, from: model.time.date(d))
        let maxRows = 3
        return VStack(spacing: 2) {
            Text("\(n)")
                .font(.callout.weight(today || sel ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(today ? Color.white : sel ? Color(.systemBackground) : (wd == 0 || wd == 6) ? Color.secondary : Color.primary)
                .frame(width: 28, height: 28)
                .background {
                    if today { Circle().fill(Color.red) } else if sel { Circle().fill(Color.primary) }
                }
                .padding(.top, 3)
            if detailed {
                VStack(spacing: 1) {
                    ForEach(events.prefix(events.count > maxRows ? maxRows - 1 : maxRows), id: \.id) { o in
                        let c = Color(hex: model.eventColor(o.event))
                        HStack(spacing: 2) {
                            if !o.event.allDay { RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 2) }
                            if isShiftPending(o.event) { Image(systemName: "hourglass").font(.system(size: 7, weight: .bold)) }
                            Text(o.title).font(.system(size: 9, weight: .medium)).lineLimit(1)
                        }
                        .foregroundStyle(o.event.allDay ? Color.white : Color.primary)
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 13)
                        .background(RoundedRectangle(cornerRadius: 3).fill(o.event.allDay ? AnyShapeStyle(c) : AnyShapeStyle(c.opacity(0.15))))
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
        .contentShape(Rectangle())
        .onTapGesture {
            selected = model.time.date(d)
            onOpenDay(d)
        }
        .contextMenu {
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.time.dayLabel(d) + (today ? "、今日" : "") + (events.isEmpty ? "" : "、予定\(events.count)件"))
        .accessibilityHint("タップでその日を開きます。長押しでメニュー")
        .accessibilityAddTraits(.isButton)
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
