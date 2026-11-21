import SwiftUI
import MyTimeCore

/// 予定の詳細の「移動の段取り」の行（区間を縦に並べ、押すと編集）
struct TravelPlanSummary: View {
    var event: MTEvent
    var start: EpochMs
    @Environment(AppModel.self) private var model
    @State private var editing = false

    var body: some View {
        let legs = TravelPlan.legs(event.extra)
        Button { editing = true } label: {
            if legs.isEmpty {
                HStack {
                    Label("移動の段取りを作る", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(legs.enumerated()), id: \.element.id) { i, l in
                        LegRow(leg: l, start: start, isLast: i == legs.count - 1)
                    }
                }
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $editing) {
            TravelPlanEditor(eventId: event.id, start: start).environment(model)
        }
    }
}

/// 区間の1行（時刻・乗り物・乗る所 → 降りる所）
struct LegRow: View {
    var leg: TravelLeg
    var start: EpochMs
    var isLast: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        let d = start + EpochMs(leg.departMin) * MINUTE
        let a = start + EpochMs(leg.arriveMin) * MINUTE
        HStack(alignment: .top, spacing: 10) {
            // 時刻の列は文字の大きさに合わせて広がる（固定の幅だと大きな文字で切れる）
            Text(model.hm(d)).font(.subheadline.weight(.semibold)).monospacedDigit()
                .fixedSize()
                .frame(minWidth: 44, alignment: .trailing)
            // 乗り物の丸と、次の区間までつなぐ線（行の高さいっぱいに伸ばす）
            VStack(spacing: 0) {
                Image(systemName: leg.mode.symbol).font(.caption.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(leg.mode.isRide ? Color.green.gradient : Color.gray.gradient))
                if !isLast {
                    Rectangle().fill(Color(.separator)).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(leg.mode.isRide ? "\(leg.from)から" : leg.from)
                    .font(.subheadline.weight(leg.mode.isRide ? .bold : .regular))
                    .lineLimit(2)
                Text("\(leg.mode.label)\(leg.line.map { "・\($0)" } ?? "")・\(leg.minutes)分")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("→ \(leg.to.isEmpty ? "到着" : leg.to)  \(model.hm(a))着")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, isLast ? 0 : 10)
        }
        // 線を行の高さに合わせるため、縦は中身の高さで決める
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// 移動の段取りの編集。Apple マップから下書きし、区間ごとに乗り物・乗る所・降りる所・路線・所要の分を直す。
/// 最後の区間が「着いておく時刻」に着くように、後ろから時刻を決める
struct TravelPlanEditor: View {
    var eventId: String
    var start: EpochMs
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var legs: [TravelLeg] = []
    @State private var early = 5
    @State private var loaded = false
    @State private var drafting = false
    @State private var message: String?
    @State private var stops: [String] = []

    private var event: MTEvent? { model.events.first { $0.id == eventId } }
    private var chained: [TravelLeg] { TravelPlan.chain(legs, endAt: -early) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await draft() }
                    } label: {
                        HStack {
                            Label("Apple マップから下書き", systemImage: "map.fill")
                            if drafting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(drafting)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                } footer: {
                    Text("自宅から、電車・バスの時刻表での所要時間と、近くの乗り場（バス停・駅）の名前で組み立てます。路線や乗り換えは自分で直せます。")
                }
                Section {
                    GlassSlider(value: $early, steps: [0, 3, 5, 10, 15, 20, 30], label: { $0 == 0 ? "ちょうど" : "\($0)分前" },
                                tint: .green, symbol: "flag.checkered", title: "着いておく")
                }
                Section {
                    // Apple マップで下書きしている間は、区間の形の仮の表示
                    if drafting && legs.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
                    }
                    ForEach($legs) { $l in
                        let c = chained.first { $0.id == l.id } ?? l
                        NavigationLink {
                            LegEditor(leg: $l, stops: stops)
                        } label: {
                            LegRow(leg: c, start: start, isLast: true)
                        }
                    }
                    .onDelete { legs.remove(atOffsets: $0) }
                    .onMove { legs.move(fromOffsets: $0, toOffset: $1) }
                    Button("区間を追加", systemImage: "plus") {
                        let prev = legs.last?.to ?? "自宅"
                        legs.append(TravelLeg(id: model.repo.newId(), mode: legs.isEmpty ? .walk : .bus, from: prev, to: event?.placeName ?? "", departMin: 0, arriveMin: 10))
                    }
                } header: {
                    if let f = chained.first {
                        Text("\(model.hm(start + EpochMs(f.departMin) * MINUTE))に出発・\(-f.departMin)分").textCase(nil)
                    }
                } footer: {
                    Text("左になぞって削除、長押しで並べ替え。移動中は、ロック画面とダイナミックアイランドに今の区間と次の乗り場を出します。")
                }
            }
            .navigationTitle("移動の段取り")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).fontWeight(.semibold) }
            }
            .onAppear(perform: load)
            .task { await loadStops() }
        }
    }

    private func load() {
        guard !loaded, let e = event else { return }
        loaded = true
        legs = TravelPlan.legs(e.extra)
        if let last = legs.last { early = max(0, -last.arriveMin) }
    }

    private func loadStops() async {
        var names: [String] = []
        if let h = AppleMaps.home { names += await AppleMaps.nearbyStops(h).prefix(5).map(\.name) }
        if let e = event, let p = PlaceValue(e.extra?["place"]) ?? e.placeName.map({ PlaceValue(name: $0) }) {
            names += await AppleMaps.nearbyStops(p).prefix(5).map(\.name)
        }
        var seen = Set<String>()
        stops = names.filter { seen.insert($0).inserted }
    }

    private func draft() async {
        guard let e = event, let p = PlaceValue(e.extra?["place"]) ?? e.placeName.map({ PlaceValue(name: $0) }) else {
            message = "予定に場所を入れると下書きできます。"; return
        }
        guard AppleMaps.home != nil else { message = "「その他」の「アカウント」で自宅の住所を入れてください。"; return }
        drafting = true
        defer { drafting = false }
        let arrival = model.time.date(start - EpochMs(early) * MINUTE)
        if let xs = await AppleMaps.draftLegs(to: p, arrival: arrival, newId: { model.repo.newId() }) {
            withAnimation(Motion.pop) { legs = xs }
            message = "下書きしました。乗り物の路線や乗り換えは、区間を押して直せます。"
        } else {
            message = "Apple マップで経路を求められませんでした。区間を追加して入れてください。"
        }
    }

    private func save() {
        guard let e = event else { dismiss(); return }
        var n = e
        n.extra = TravelPlan.write(chained, into: e.extra)
        model.perform("移動の段取りを保存しました", undo: { try model.repo.saveEvent(e, isNew: false) }) { try model.repo.saveEvent(n, isNew: false) }
        dismiss()
    }
}

/// 区間の編集（乗り物・乗る所・降りる所・路線・所要の分）
private struct LegEditor: View {
    @Binding var leg: TravelLeg
    var stops: [String]

    var body: some View {
        Form {
            Section {
                Picker("乗り物", selection: $leg.mode) {
                    ForEach(TravelLeg.Mode.allCases, id: \.self) { m in Label(m.label, systemImage: m.symbol).tag(m) }
                }
                .pickerStyle(.navigationLink)
                GlassSlider(value: Binding(get: { leg.minutes }, set: { leg.arriveMin = leg.departMin + $0 }),
                            steps: Array(1...20) + Array(stride(from: 25, through: 120, by: 5)),
                            label: { durationLabel($0) }, tint: .green, symbol: "clock", title: "所要")
            }
            Section("乗る所・出る所") {
                TextField("例：丸太町智恵光院", text: $leg.from)
                chips { leg.from = $0 }
            }
            Section("降りる所・着く所") {
                TextField("例：丸太町", text: $leg.to)
                chips { leg.to = $0 }
            }
            if leg.mode.isRide {
                Section {
                    TextField("例：市バス10系統・烏丸線", text: Binding(get: { leg.line ?? "" }, set: { leg.line = $0.isEmpty ? nil : $0 }))
                } header: { Text("路線（任意）") } footer: { Text("ロック画面の「次の乗り場」に一緒に出します。") }
            }
        }
        .navigationTitle(leg.mode.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func chips(_ pick: @escaping (String) -> Void) -> some View {
        if !stops.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(stops, id: \.self) { s in
                        Button { pick(s) } label: {
                            Label(s, systemImage: "mappin").font(.subheadline)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Capsule().fill(Color(.tertiarySystemFill)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
