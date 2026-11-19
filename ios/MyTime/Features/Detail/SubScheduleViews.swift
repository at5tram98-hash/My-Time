import SwiftUI
import MyTimeCore

// MARK: - 予定の詳細の上のプレビュー（純正「カレンダー」の予定の詳細と同じ、時刻の目盛りに予定の札を置いた小さな日の表示）

/// 予定の前後の時間に予定の札を置き、その中に詳細スケジュール（予定・タスク）を小さく並べる。押すと詳細スケジュールを開く
struct EventDayPreview: View {
    var event: MTEvent
    var start: EpochMs
    var end: EpochMs
    var tint: Color
    var struck = false

    @Environment(AppModel.self) private var model
    /// プレビューの高さは決まった大きさ（長い予定は目盛りを細かくして全体を入れる。切れないように）
    private let height: CGFloat = 210
    private let gutter: CGFloat = 52
    private let pad: CGFloat = 12

    var body: some View {
        let t = model.time
        // 予定の前後30分を含む、正時から正時まで（3〜10時間）
        let winStart = t.startOfDay(start) + EpochMs(max(0, t.minutesOfDay(start - 30 * MINUTE) / 60)) * HOUR
        let rawEnd = end + 30 * MINUTE
        let endHours = Int((rawEnd - winStart + HOUR - 1) / HOUR)
        let hours = min(10, max(3, endHours))
        let hourH = (height - pad * 2) / CGFloat(hours)
        let labelEvery = hourH < 26 ? 2 : 1
        let items = SubSchedule.items(event.extra)
        let total = Int((end - start) / MINUTE)
        GeometryReader { g in
            let w = g.size.width - gutter - 14
            let y0 = pad + CGFloat(start - winStart) / CGFloat(HOUR) * hourH
            let h = max(18, min(height - pad - y0, CGFloat(end - start) / CGFloat(HOUR) * hourH))
            ZStack(alignment: .topLeading) {
                // 時刻の目盛り（細かいときは2時間ごとに時刻）
                ForEach(0...hours, id: \.self) { i in
                    let y = pad + CGFloat(i) * hourH
                    HStack(spacing: 8) {
                        Text(i % labelEvery == 0 ? "\((t.minutesOfDay(winStart) / 60 + i) % 24):00" : "")
                            .font(hourH < 30 ? .caption : .subheadline).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: gutter - 8, alignment: .trailing)
                        Rectangle().fill(Color(.separator)).frame(height: 0.5)
                    }
                    .frame(height: 16)
                    .offset(y: y - 8)
                }
                // 予定の札（純正と同じく色で塗る。高さに入る分だけ文字を出す）
                let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        if h < 34 {
                            HStack(spacing: 6) {
                                Text(event.title).font(.caption.weight(.bold)).lineLimit(1).strikethrough(struck)
                                Text("\(model.hm(start))–\(model.hm(end))").font(.caption2).monospacedDigit().lineLimit(1)
                            }
                        } else {
                            Text(event.title).font(.subheadline.weight(.bold)).lineLimit(1).strikethrough(struck)
                            if h >= 70, let p = event.placeName, !p.isEmpty {
                                Label(p, systemImage: "location").labelStyle(CompactLabel()).font(.caption).lineLimit(1)
                            }
                            Label("\(model.hm(start))–\(model.hm(end))", systemImage: "clock").labelStyle(CompactLabel()).font(.caption).monospacedDigit().lineLimit(1)
                            if h >= 90 && !items.isEmpty {
                                Label("詳細 \(items.count)件", systemImage: "list.bullet.indent").labelStyle(CompactLabel()).font(.caption2.weight(.semibold)).lineLimit(1)
                            }
                        }
                    }
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(struck ? Color.secondary : Color.white)
                    .padding(.horizontal, 8).padding(.vertical, h < 34 ? 2 : 5)
                    Spacer(minLength: 4)
                    // 中の予定・タスク（右に細い2列。札が小さいときは出さない）
                    if total > 0 && !items.isEmpty && h >= 40 {
                        HStack(alignment: .top, spacing: 3) {
                            ForEach(SubItem.Lane.allCases, id: \.self) { lane in
                                ZStack(alignment: .top) {
                                    Capsule().fill(.white.opacity(0.15)).frame(width: 6)
                                    ForEach(items.filter { $0.lane == lane }) { it in
                                        MiniBar(height: h - 8, startMin: it.startMin, minutes: it.minutes, total: total, strong: lane == .event)
                                    }
                                }
                                .frame(width: 6, height: h - 8, alignment: .top)
                            }
                        }
                        .padding(.vertical, 4).padding(.trailing, 6)
                        .accessibilityHidden(true)
                    }
                }
                .frame(width: w, height: h, alignment: .topLeading)
                .background(struck ? AnyShapeStyle(Color(.tertiarySystemFill)) : AnyShapeStyle(tint.gradient), in: shape)
                .clipShape(shape)
                .offset(x: gutter + 4, y: y0)
                // 今の時刻の赤い線
                if model.now >= winStart && model.now < winStart + EpochMs(hours) * HOUR {
                    let y = pad + CGFloat(model.now - winStart) / CGFloat(HOUR) * hourH
                    HStack(spacing: 0) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Rectangle().fill(.red).frame(height: 1.2)
                    }
                    .offset(x: gutter - 3, y: y - 3.5)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .clipped()
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.title)、\(model.hm(start))から\(model.hm(end))" + (items.isEmpty ? "" : "、詳細スケジュール\(items.count)件"))
        .accessibilityHint("詳細スケジュールを開きます")
    }
}

/// プレビューの中の小さな帯（詳細スケジュールの1件）
private struct MiniBar: View {
    var height: CGFloat
    var startMin: Int
    var minutes: Int
    var total: Int
    var strong: Bool
    var body: some View {
        let k = height / CGFloat(max(1, total))
        Capsule()
            .fill(Color.white.opacity(strong ? 0.9 : 0.6))
            .frame(width: 6, height: max(3, k * CGFloat(minutes) - 1))
            .offset(y: k * CGFloat(startMin))
    }
}

// MARK: - 詳細スケジュール（予定の中の予定。5分ごと、予定とタスクのレーン）

/// 予定の時間を5分ごとの目盛りで表示し、その中に予定・タスクを置く。
/// 空いた所を押す（15分）・長押しして上下になぞる（好きな長さ）で追加。札は長押しで動かす（左右でレーンも変わる）、下の端で長さ、押すと編集。
/// 2本指でつまむと目盛りの幅が変わる。
struct SubScheduleView: View {
    var eventId: String
    var start: EpochMs
    var end: EpochMs

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 5分あたりの高さ
    @State private var unit: CGFloat = 16
    @State private var pinchBase: CGFloat?
    @State private var creating: (lane: SubItem.Lane, a: Int, b: Int)?
    @State private var naming: SubItem?
    @State private var draftTitle = ""
    @State private var editing: SubItem?
    @State private var dragging = false
    @State private var createTick = 0
    @State private var snapTick = 0
    @State private var confirmClear = false
    /// 下のよく使う名前から足すレーン
    @State private var quickLane: SubItem.Lane = .event
    @State private var addTick = 0

    static let gutter: CGFloat = 52

    private var event: MTEvent? { model.events.first { $0.id == eventId } }
    private var total: Int { max(SubSchedule.step, Int((end - start) / MINUTE)) }
    private var items: [SubItem] { SubSchedule.items(event?.extra) }
    private var tint: Color { event.map { Color(hex: model.eventColor($0)) } ?? .accentColor }

    var body: some View {
        VStack(spacing: 0) {
            laneHeader
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { g in
                        let laneW = (g.size.width - Self.gutter - 8) / 2
                        ZStack(alignment: .topLeading) {
                            grid
                            // 予定の時間（うすい色）
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.07))
                                .frame(width: laneW * 2 + 4, height: CGFloat(total / SubSchedule.step) * unit)
                                .offset(x: Self.gutter, y: 0)
                            emptyArea(laneW: laneW)
                            let cols = SubSchedule.columns(items)
                            ForEach(items) { it in
                                let c = cols[it.id] ?? (0, 1)
                                SubBlock(item: it, unit: unit, laneW: laneW, total: total, base: start, tint: tint,
                                         onTap: { editing = it },
                                         onToggle: { toggleDone(it) },
                                         onCommit: { save(replacing: $0) },
                                         onDragging: { dragging = $0 })
                                    .frame(width: max(10, laneW / CGFloat(c.of) - 3), height: max(14, CGFloat(it.minutes) / CGFloat(SubSchedule.step) * unit - 2))
                                    .offset(x: Self.gutter + laneX(it.lane, laneW) + laneW * CGFloat(c.col) / CGFloat(c.of) + 1,
                                            y: CGFloat(it.startMin) / CGFloat(SubSchedule.step) * unit + 1)
                            }
                            if let c = creating { ghost(c, laneW: laneW) }
                            if items.isEmpty && creating == nil {
                                // 何もないときの案内（最初の1回だけ目に入る位置に、うすく）
                                VStack(spacing: 6) {
                                    Image(systemName: "hand.tap").font(.title2)
                                    Text("空いた所を押すと15分で追加\n長押しして上下になぞると好きな長さ\n下のよく使う名前からも追加できます")
                                        .font(.caption).multilineTextAlignment(.center)
                                }
                                .foregroundStyle(.tertiary)
                                .frame(width: laneW * 2)
                                .offset(x: Self.gutter, y: min(120, CGFloat(total / SubSchedule.step) * unit / 2 - 40))
                                .allowsHitTesting(false)
                            }
                            nowLine(width: g.size.width)
                        }
                    }
                    .frame(height: CGFloat(total / SubSchedule.step) * unit + 24)
                    .padding(.top, 10)
                }
                .scrollDisabled(creating != nil || dragging)
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            let b = pinchBase ?? unit
                            pinchBase = b
                            unit = min(40, max(8, b * v.magnification))
                        }
                        .onEnded { _ in pinchBase = nil }
                )
                .onAppear {
                    let m = Int((model.now - start) / MINUTE)
                    if m > 0 && m < total { proxy.scrollTo("m\(max(0, m / 15 * 15 - 15))", anchor: .top) }
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("詳細スケジュール")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { quickBar }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("次の空いた時間に追加", systemImage: "plus") { addNext() }
                    Button("隙間なく詰める", systemImage: "rectangle.compress.vertical") { pack() }.disabled(items.isEmpty)
                    Button("済んだタスクを外す", systemImage: "checkmark.circle") {
                        write(items.filter { !($0.lane == .task && $0.done) }, message: "済んだタスクを外しました")
                    }
                    .disabled(!items.contains { $0.lane == .task && $0.done })
                    Divider()
                    Button("すべて外す", systemImage: "trash", role: .destructive) { confirmClear = true }.disabled(items.isEmpty)
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("詳細スケジュールの操作")
            }
        }
        .confirmationDialog("詳細スケジュールをすべて外しますか？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("すべて外す", role: .destructive) { write([], message: "詳細スケジュールを外しました") }
        } message: { Text("iPhone を振ると元に戻せます。") }
        .sensoryFeedback(.impact(weight: .medium), trigger: createTick)
        .sensoryFeedback(.selection, trigger: snapTick)
        .alert("名前を入れてください", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("例：受付・移動・休憩", text: $draftTitle)
            Button("追加") {
                if var it = naming {
                    it.title = draftTitle.trimmingCharacters(in: .whitespaces).isEmpty ? (it.lane == .event ? "予定" : "やること") : draftTitle
                    save(adding: it)
                }
                naming = nil
            }
            Button("キャンセル", role: .cancel) { naming = nil }
        } message: {
            if let it = naming { Text("\(it.lane.label)・\(model.hm(start + EpochMs(it.startMin) * MINUTE))〜\(model.hm(start + EpochMs(it.endMin) * MINUTE))") }
        }
        .sheet(item: $editing) { it in
            SubItemEditor(item: it, base: start, total: total, tint: tint,
                          onSave: { save(replacing: $0) }, onDelete: { delete(it) },
                          onDuplicate: { x in DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { save(adding: x) } })
                .environment(model)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: 見出し（レーンの名前と、予定の時間）

    private var laneHeader: some View {
        VStack(spacing: 6) {
            if let e = event {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 4, height: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(e.title).font(.headline).lineLimit(1)
                        Text("\(model.time.dayLabel(start)) \(model.hm(start))〜\(model.hm(end))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    // 予定の時間のうち、まだ何も入れていない時間
                    let used = Set(items.filter { $0.lane == .event }.flatMap { Array(stride(from: $0.startMin, to: $0.endMin, by: SubSchedule.step)) }).count * SubSchedule.step
                    Text("空き \(durationLabel(max(0, total - used)))").font(.caption.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            nowBar
            HStack(spacing: 4) {
                Color.clear.frame(width: Self.gutter - 4)
                ForEach(SubItem.Lane.allCases, id: \.self) { l in
                    let xs = items.filter { $0.lane == l }
                    Label(l == .event ? "予定 \(xs.count)" : "タスク \(xs.filter(\.done).count)/\(xs.count)", systemImage: l == .event ? "calendar" : "checklist")
                        .monospacedDigit()
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .background(.bar)
    }

    /// 予定の最中：いまの項目・残り・次（予定の前は、最初の項目まで）
    @ViewBuilder
    private var nowBar: some View {
        let m = Int((model.now - start) / MINUTE)
        let xs = items.filter { $0.lane == .event || !$0.done }
        if m >= -60 && m < total && !xs.isEmpty {
            let cur = SubSchedule.current(xs, minute: m)
            let next = xs.first { $0.startMin > m }
            HStack(spacing: 10) {
                if let c = cur {
                    ZStack {
                        Circle().stroke(tint.opacity(0.25), lineWidth: 3)
                        Circle().trim(from: 0, to: CGFloat(m - c.startMin) / CGFloat(max(1, c.minutes)))
                            .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("いま：\(c.title)").font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("あと\(c.endMin - m)分" + (next.map { "・次：\($0.title) \(model.hm(start + EpochMs($0.startMin) * MINUTE))" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit()
                    }
                } else if let n = next {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(tint)
                    Text("次：\(n.title) \(model.hm(start + EpochMs(n.startMin) * MINUTE))・あと\(n.startMin - m)分")
                        .font(.subheadline.weight(.semibold)).lineLimit(1).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.1)))
        }
    }

    /// よく使う名前（押すと、選んだレーンの最後の後ろに15分で足す）
    private var quickBar: some View {
        let names = quickNames
        return VStack(spacing: 6) {
            Picker("足すレーン", selection: $quickLane) {
                ForEach(SubItem.Lane.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(names, id: \.self) { n in
                        Button { quickAdd(n) } label: {
                            Label(n, systemImage: "plus").font(.subheadline)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .glass(Capsule(), interactive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
        .sensoryFeedback(.success, trigger: addTick)
    }

    /// 前に使った名前（ほかの予定の詳細スケジュールから）と、よくある名前
    private var quickNames: [String] {
        var count: [String: Int] = [:]
        for e in model.events { for it in SubSchedule.items(e.extra) where it.lane == quickLane && !it.title.isEmpty { count[it.title, default: 0] += 1 } }
        let used = count.sorted { $0.value > $1.value }.map(\.key)
        let base = quickLane == .event ? ["移動", "受付", "準備", "休憩", "昼ごはん", "片付け", "振り返り"] : ["資料を開く", "メモを取る", "質問する", "写真を撮る", "提出する", "連絡する"]
        var seen = Set<String>()
        return (used + base).filter { seen.insert($0).inserted }.prefix(12).map { $0 }
    }

    private func quickAdd(_ name: String) {
        let last = items.filter { $0.lane == quickLane }.map(\.endMin).max() ?? 0
        let len = name == "休憩" ? 10 : 15
        guard last < total else { return }
        let r = SubSchedule.clamp(last, last + len, total: total)
        save(adding: SubItem(id: model.repo.newId(), lane: quickLane, title: name, startMin: r.0, endMin: r.1))
        addTick += 1
    }

    /// レーンごとに、最初から隙間なく並べ直す（長さは保つ。入りきらない分は最後に詰める）
    private func pack() {
        var out: [SubItem] = []
        for lane in SubItem.Lane.allCases {
            var t = 0
            for var it in items.filter({ $0.lane == lane }).sorted(by: { $0.startMin < $1.startMin }) {
                let r = SubSchedule.clamp(t, t + it.minutes, total: total)
                it.startMin = r.0; it.endMin = r.1
                t = r.1
                out.append(it)
            }
        }
        write(out, message: "隙間なく詰めました")
    }

    // MARK: 目盛り（5分ごとの線。15分ごとに時刻、正時は太く）

    private var grid: some View {
        VStack(spacing: 0) {
            ForEach(0...(total / SubSchedule.step), id: \.self) { i in
                let m = i * SubSchedule.step
                let t = start + EpochMs(m) * MINUTE
                let hour = model.time.minutesOfDay(t) % 60 == 0
                HStack(alignment: .top, spacing: 6) {
                    Text(m % 15 == 0 || unit >= 22 ? model.hm(t) : "")
                        .font(hour ? .caption.weight(.semibold) : .caption2)
                        .foregroundStyle(hour ? .primary : .secondary).monospacedDigit()
                        .frame(width: Self.gutter - 8, alignment: .trailing)
                        .offset(y: -7)
                    Rectangle().fill(Color(.separator).opacity(hour ? 0.9 : m % 15 == 0 ? 0.5 : 0.18)).frame(height: hour ? 0.8 : 0.5)
                }
                .frame(height: unit, alignment: .top)
                .id("m\(m)")
            }
        }
        .accessibilityHidden(true)
    }

    private func laneX(_ l: SubItem.Lane, _ laneW: CGFloat) -> CGFloat { l == .event ? 0 : laneW + 4 }

    private func minute(atY y: CGFloat) -> Int { Int(y / unit * CGFloat(SubSchedule.step)) }

    // MARK: 追加（押す・長押しして上下になぞる）

    private func emptyArea(laneW: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: Self.gutter + laneW * 2 + 8, height: CGFloat(total / SubSchedule.step) * unit)
            .overlay {
                PressDragRecognizer(
                    minimumDuration: 0.35,
                    onTapAt: { p in
                        let lane: SubItem.Lane = p.x - Self.gutter > laneW ? .task : .event
                        let a = minute(atY: p.y) / 15 * 15
                        let r = SubSchedule.clamp(a, a + 15, total: total)
                        naming = SubItem(id: model.repo.newId(), lane: lane, title: "", startMin: r.0, endMin: r.1)
                        draftTitle = ""
                    },
                    onBegan: { p in
                        let lane: SubItem.Lane = p.x - Self.gutter > laneW ? .task : .event
                        let a = minute(atY: p.y) / SubSchedule.step * SubSchedule.step
                        createTick += 1
                        withAnimation(reduceMotion ? nil : .interactiveSpring()) { creating = (lane, a, a + 15) }
                    },
                    onChanged: { p, _ in
                        guard let c = creating else { return }
                        let m = Int((Double(minute(atY: p.y)) / Double(SubSchedule.step)).rounded()) * SubSchedule.step
                        let b = max(c.a + SubSchedule.step, min(total, m))
                        if b != c.b { snapTick += 1; creating = (c.lane, c.a, b) }
                    },
                    onEnded: { _, _ in
                        guard let c = creating else { return }
                        creating = nil
                        let r = SubSchedule.clamp(c.a, c.b, total: total)
                        naming = SubItem(id: model.repo.newId(), lane: c.lane, title: "", startMin: r.0, endMin: r.1)
                        draftTitle = ""
                    },
                    onCancelled: { creating = nil }
                )
            }
            .accessibilityElement()
            .accessibilityLabel("詳細スケジュールの空き")
            .accessibilityAction(named: "次の空いた時間に追加") { addNext() }
    }

    private func ghost(_ c: (lane: SubItem.Lane, a: Int, b: Int), laneW: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return VStack(alignment: .leading, spacing: 1) {
            Text(c.lane == .event ? "新しい予定" : "新しいタスク").font(.caption.weight(.semibold))
            Text("\(model.hm(start + EpochMs(c.a) * MINUTE))〜\(model.hm(start + EpochMs(c.b) * MINUTE))・\(c.b - c.a)分").font(.caption2).monospacedDigit()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(width: laneW - 3, height: max(16, CGFloat(c.b - c.a) / CGFloat(SubSchedule.step) * unit - 2), alignment: .topLeading)
        .background(shape.fill(tint.opacity(0.16)))
        .overlay(shape.strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
        .offset(x: Self.gutter + laneX(c.lane, laneW) + 1, y: CGFloat(c.a) / CGFloat(SubSchedule.step) * unit + 1)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func nowLine(width: CGFloat) -> some View {
        let m = Double(model.now - start) / Double(MINUTE)
        if m >= 0 && m < Double(total) {
            HStack(spacing: 0) {
                Text(model.hm(model.now)).font(.caption2.weight(.bold)).foregroundStyle(.white).monospacedDigit()
                    .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(.red))
                    .frame(width: Self.gutter - 2, alignment: .trailing)
                Rectangle().fill(.red).frame(height: 1.5)
            }
            .frame(width: width)
            .offset(y: CGFloat(m / Double(SubSchedule.step)) * unit - 7)
            .allowsHitTesting(false)
        }
    }

    // MARK: 保存

    private func write(_ xs: [SubItem], message: String?) {
        guard let e = event else { return }
        var n = e
        n.extra = SubSchedule.write(xs, into: e.extra)
        model.perform(message, undo: { try model.repo.saveEvent(e, isNew: false) }) { try model.repo.saveEvent(n, isNew: false) }
    }

    private func save(adding it: SubItem) { write(items + [it], message: nil) }

    private func save(replacing it: SubItem) {
        var xs = items
        if let i = xs.firstIndex(where: { $0.id == it.id }) { xs[i] = it } else { xs.append(it) }
        write(xs, message: nil)
    }

    private func delete(_ it: SubItem) { write(items.filter { $0.id != it.id }, message: "「\(it.title)」を外しました") }

    private func toggleDone(_ it: SubItem) {
        var x = it
        x.done.toggle()
        save(replacing: x)
    }

    /// 予定のレーンで最後の札のすぐ後（なければ最初）に15分
    private func addNext() {
        let last = items.filter { $0.lane == .event }.map(\.endMin).max() ?? 0
        let r = SubSchedule.clamp(last, last + 15, total: total)
        naming = SubItem(id: model.repo.newId(), lane: .event, title: "", startMin: r.0, endMin: r.1)
        draftTitle = ""
    }
}

/// 詳細スケジュールの札。押すと編集、長押しして動かす（上下で時刻、左右でレーン）、下の端をなぞって長さ
private struct SubBlock: View {
    var item: SubItem
    var unit: CGFloat
    var laneW: CGFloat
    var total: Int
    var base: EpochMs
    var tint: Color
    var onTap: () -> Void
    var onToggle: () -> Void
    var onCommit: (SubItem) -> Void
    var onDragging: (Bool) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dy: CGFloat = 0
    @State private var dx: CGFloat = 0
    @State private var resizing = false
    @State private var active = false
    @State private var picked = 0
    @State private var snap = 0

    private var stepMinutes: Int { Int((dy / unit).rounded()) * SubSchedule.step }
    private var ghost: SubItem {
        var x = item
        if resizing {
            x.endMin = max(x.startMin + SubSchedule.step, min(total, item.endMin + stepMinutes))
        } else if active {
            let len = item.minutes
            let s = max(0, min(total - len, item.startMin + stepMinutes))
            x.startMin = s; x.endMin = s + len
            if abs(dx) > laneW / 2 { x.lane = item.lane == .event ? .task : .event }
        }
        return x
    }

    var body: some View {
        let g = ghost
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let isEvent = g.lane == .event
        let color = item.color.map { Color(hex: $0) } ?? tint
        let h = CGFloat(item.minutes) / CGFloat(SubSchedule.step) * unit
        HStack(alignment: .top, spacing: 0) {
            if !isEvent { Rectangle().fill(color).frame(width: 4) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if !isEvent {
                        Button(action: onToggle) {
                            Image(systemName: item.done ? "checkmark.circle.fill" : "circle").foregroundStyle(item.done ? .green : color)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.done ? "済み" : "まだ")
                    }
                    Text(item.title).lineLimit(h > 40 ? 2 : 1).strikethrough(item.done)
                }
                .font(.caption.weight(.semibold))
                if h > 26 || active || resizing {
                    Text("\(model.hm(base + EpochMs(g.startMin) * MINUTE))〜\(model.hm(base + EpochMs(g.endMin) * MINUTE))・\(g.minutes)分")
                        .font(.caption2).monospacedDigit().opacity(0.85)
                }
                if h > 44, let p = item.place, !p.isEmpty {
                    Label(p, systemImage: "mappin").labelStyle(CompactLabel()).font(.caption2).lineLimit(1).opacity(0.85)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(isEvent ? Color.white : Color.primary)
        .background {
            if isEvent { shape.fill(color.gradient.opacity(item.done ? 0.45 : 0.92)) }
            else { shape.fill(Color(.secondarySystemGroupedBackground)).shadow(color: .black.opacity(0.08), radius: 2, y: 1) }
        }
        .overlay { if !isEvent { shape.strokeBorder(Color(.separator).opacity(0.6), lineWidth: 0.5) } }
        .clipShape(shape)
        .padding(.bottom, resizing ? -(CGFloat(g.endMin - item.endMin) / CGFloat(SubSchedule.step) * unit) : 0)
        .overlay {
            PressDragRecognizer(
                minimumDuration: 0.3,
                onTap: onTap,
                onBegan: { _ in picked += 1; withAnimation(.snappy) { active = true }; onDragging(true) },
                onChanged: { _, t in
                    let before = ghost
                    dy = t.height; dx = t.width
                    if ghost != before { snap += 1 }
                },
                onEnded: { _, _ in finish() },
                onCancelled: { reset() }
            )
        }
        .overlay(alignment: .bottom) {
            // 下の端：なぞって長さを変える
            Color.clear.frame(height: 12).frame(maxWidth: .infinity).contentShape(Rectangle())
                .overlay(alignment: .bottom) { Capsule().fill(isEvent ? .white.opacity(0.7) : color.opacity(0.6)).frame(width: 22, height: 3).padding(.bottom, 2) }
                .overlay {
                    PressDragRecognizer(
                        minimumDuration: 0.15,
                        onBegan: { _ in picked += 1; resizing = true; onDragging(true) },
                        onChanged: { _, t in
                            let before = ghost
                            dy = t.height
                            if ghost != before { snap += 1 }
                        },
                        onEnded: { _, _ in finish() },
                        onCancelled: { reset() }
                    )
                }
                .accessibilityHidden(true)
        }
        .offset(x: active && !resizing ? (abs(dx) > laneW / 2 ? (item.lane == .event ? laneW + 4 : -(laneW + 4)) : dx * 0.2) : 0,
                y: active && !resizing ? CGFloat(g.startMin - item.startMin) / CGFloat(SubSchedule.step) * unit : 0)
        .scaleEffect(active && !resizing && !reduceMotion ? 1.04 : 1)
        .shadow(color: .black.opacity(active ? 0.2 : 0), radius: 8, y: 4)
        .zIndex(active || resizing ? 10 : 0)
        .animation(reduceMotion ? nil : .interactiveSpring(), value: g)
        .sensoryFeedback(.impact(weight: .medium), trigger: picked)
        .sensoryFeedback(.selection, trigger: snap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.lane.label) \(item.title)、\(model.hm(base + EpochMs(item.startMin) * MINUTE))から\(item.minutes)分" + (item.done ? "、済み" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
        .accessibilityAction(named: "5分遅らせる") { var x = item; let r = SubSchedule.clamp(x.startMin + 5, x.endMin + 5, total: total); x.startMin = r.0; x.endMin = r.1; onCommit(x) }
        .accessibilityAction(named: "5分早める") { var x = item; let r = SubSchedule.clamp(x.startMin - 5, x.endMin - 5, total: total); x.startMin = r.0; x.endMin = r.1; onCommit(x) }
        .accessibilityAction(named: "5分延ばす") { var x = item; x.endMin = min(total, x.endMin + 5); onCommit(x) }
    }

    private func finish() {
        let g = ghost
        reset()
        if g != item { onCommit(g) }
    }

    private func reset() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) { active = false; resizing = false; dy = 0; dx = 0 }
        onDragging(false)
    }
}

/// 詳細スケジュールの1件を編集する（名前・レーン・開始と長さのスライダー・済み・場所）
struct SubItemEditor: View {
    @State var item: SubItem
    var base: EpochMs
    var total: Int
    var tint: Color
    var onSave: (SubItem) -> Void
    var onDelete: () -> Void
    var onDuplicate: ((SubItem) -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名前", text: $item.title).font(.title3.weight(.medium))
                    Picker("レーン", selection: $item.lane) {
                        ForEach(SubItem.Lane.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    GlassSlider(value: Binding(get: { item.startMin }, set: { s in
                        let len = item.minutes
                        let r = SubSchedule.clamp(s, s + len, total: total)
                        item.startMin = r.0; item.endMin = r.1
                    }), steps: Array(stride(from: 0, through: max(0, total - SubSchedule.step), by: SubSchedule.step)),
                                label: { model.hm(base + EpochMs($0) * MINUTE) }, tint: tint, symbol: "clock", title: "開始")
                    GlassSlider(value: Binding(get: { item.minutes }, set: { m in item.endMin = min(total, item.startMin + m) }),
                                steps: Array(stride(from: SubSchedule.step, through: max(SubSchedule.step, total - item.startMin), by: SubSchedule.step)),
                                label: { durationLabel($0) }, tint: tint, symbol: "hourglass", title: "長さ")
                } footer: { Text("\(model.hm(base + EpochMs(item.startMin) * MINUTE))〜\(model.hm(base + EpochMs(item.endMin) * MINUTE))。5分ごとに止まります。") }
                Section {
                    if item.lane == .task { Toggle("済み", isOn: $item.done) }
                    HStack(spacing: 12) {
                        RowIcon(symbol: "mappin.and.ellipse", tint: .red)
                        TextField("場所（任意）", text: Binding(get: { item.place ?? "" }, set: { item.place = $0.isEmpty ? nil : $0 }))
                    }
                }
                Section("色") {
                    HStack(spacing: 10) {
                        ForEach([nil] + ["#FF3B30", "#FF9500", "#34C759", "#30B0C7", "#0A84FF", "#5E5CE6", "#8E8E93"].map(Optional.some), id: \.self) { c in
                            Button { item.color = c } label: {
                                Circle().fill(c.map { Color(hex: $0) } ?? tint).frame(width: 28, height: 28)
                                    .overlay { if item.color == c { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) } }
                                    .overlay { if c == nil { Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1) } }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c == nil ? "予定と同じ色" : "色")
                        }
                    }
                }
                Section {
                    Button("すぐ後に複製", systemImage: "plus.square.on.square") {
                        var x = item
                        x.id = UUID().uuidString.lowercased()
                        let r = SubSchedule.clamp(item.endMin, item.endMin + item.minutes, total: total)
                        x.startMin = r.0; x.endMin = r.1
                        onSave(item); onDuplicate?(x); dismiss()
                    }
                    Button("外す", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .navigationTitle(item.lane == .event ? "予定" : "タスク")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { onSave(item); dismiss() }.fontWeight(.semibold) }
            }
        }
    }
}
