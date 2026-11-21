import SwiftUI
import MapKit
import MyTimeCore

/// 場所（Web 版と同じ形：{ name, address, lat, lng }）
struct PlaceValue: Equatable, Hashable {
    var name: String
    var address: String = ""
    var lat: Double?
    var lng: Double?

    init(name: String, address: String = "", lat: Double? = nil, lng: Double? = nil) {
        self.name = name; self.address = address; self.lat = lat; self.lng = lng
    }

    init?(_ v: JSONValue?) {
        guard let v, let n = v["name"]?.stringValue, !n.isEmpty else { return nil }
        name = n
        address = v["address"]?.stringValue ?? ""
        lat = v["lat"]?.doubleValue
        lng = v["lng"]?.doubleValue
    }

    var json: JSONValue {
        .object(["name": .string(name), "address": .string(address), "lat": lat.map { .number($0) } ?? .null, "lng": lng.map { .number($0) } ?? .null])
    }
}

/// アカウントの情報（この端末に保存。自宅・学校は場所の候補に出す）
enum AccountKeys {
    static let name = "account.name"
    static let school = "account.school"
    static let home = "account.homeAddress"
    static let schoolAddress = "account.schoolAddress"
    static let grade = "account.grade"
}

/// 入力中の文字から場所の候補を出す（純正マップと同じ検索。1文字ごとに更新）
@MainActor
@Observable
final class PlaceCompleter: NSObject, MKLocalSearchCompleterDelegate {
    var results: [MKLocalSearchCompletion] = []
    var failed = false
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    func update(_ q: String) {
        let k = q.trimmingCharacters(in: .whitespaces)
        if k.isEmpty { results = []; completer.cancel(); return }
        completer.queryFragment = k
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let r = Array(completer.results.prefix(6))
        Task { @MainActor in self.results = r; self.failed = false }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.failed = true }
    }

    /// 候補を選んだら、緯度経度つきの場所に変える（失敗しても名前と住所は使う）
    func resolve(_ c: MKLocalSearchCompletion) async -> PlaceValue {
        let base = PlaceValue(name: c.title, address: c.subtitle)
        guard let res = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: c)).start(),
              let item = res.mapItems.first else { return base }
        let coord = item.placemark.coordinate
        return PlaceValue(name: item.name ?? c.title, address: c.subtitle.isEmpty ? (item.placemark.title ?? "") : c.subtitle, lat: coord.latitude, lng: coord.longitude)
    }
}

/// 「設定」アプリと同じ、角丸の色つきアイコン
struct RowIcon: View {
    var symbol: String
    var tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}


/// 予定・タスクの編集の「場所と移動」の画面。
/// 「場所」と「移動」を別々のまとまりに分け、つながった枠にしない：
/// 1. 場所：選んだら地図のカード（変更・外す）。選ぶ前・変更中だけ検索と候補（よく使う場所／マップの候補）
/// 2. 移動：行き方（徒歩・電車・車）を選ぶと、自宅からの時間を自動で入れる。指でなぞって直せる
struct PlaceTravelScreen: View {
    @Binding var place: PlaceValue?
    @Binding var travel: Int?
    var start: Date
    var history: [PlaceValue]

    @Environment(AppModel.self) private var model
    @AppStorage(AccountKeys.home) private var homeAddress = ""
    @AppStorage(AccountKeys.schoolAddress) private var schoolAddress = ""
    @AppStorage(AccountKeys.school) private var schoolName = ""
    @State private var query = ""
    @State private var completer = PlaceCompleter()
    @State private var searching = false
    /// 行き方：公共交通機関が既定
    @State private var mode: AppleMaps.Mode = .transit
    @State private var calculating = false
    /// 自動で入れた値（自分で直したら、その後は自動で上書きしない）
    @State private var autoValue: Int?
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        List {
            placeSection
            if place != nil && !searching { travelSection }
        }
        .listSectionSpacing(.custom(24))
        .navigationTitle("場所と移動")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if place == nil { searching = true; focused = true }
            autoValue = travel
        }
        .task(id: "\(place?.name ?? "")-\(mode.rawValue)") { await autoFill() }
        .animation(.snappy, value: searching)
        .animation(.snappy, value: place)
    }

    // MARK: 場所

    @ViewBuilder
    private var placeSection: some View {
        if let p = place, !searching {
            Section {
                PlaceMapPreview(place: p, height: 170)
                    .listRowInsets(EdgeInsets())
                HStack(spacing: 12) {
                    Button { searching = true; focused = true } label: {
                        Label("変更", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                    }
                    Button(role: .destructive) { place = nil; travel = nil; autoValue = nil; searching = true } label: {
                        Label("外す", systemImage: "xmark").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
            } header: { Text("場所") }
        } else {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("場所や住所を検索", text: $query)
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { if !query.isEmpty { choose(PlaceValue(name: query)) } }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.plain)
                    }
                }
                .onChange(of: query) { _, q in completer.update(q) }
                if place != nil {
                    Button("やめる") { searching = false; query = "" }.font(.subheadline)
                }
            } header: { Text("場所") }
            if !quickPlaces.isEmpty {
                Section("よく使う場所") {
                    ForEach(quickPlaces, id: \.self) { p in
                        suggestionRow(p, symbol: p.name == "自宅" ? "house.fill" : p.name == schoolLabel ? "graduationcap.fill" : "clock.arrow.circlepath") { choose(p) }
                    }
                }
            }
            if !completer.results.isEmpty || !query.isEmpty {
                Section("マップの候補") {
                    // マップの候補が届くまでは、行の形の仮の表示
                    if completer.results.isEmpty && !completer.failed && !query.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in SkeletonRow() }
                    }
                    ForEach(completer.results, id: \.self) { c in
                        suggestionRow(PlaceValue(name: c.title, address: c.subtitle), symbol: "mappin") {
                            Task { choose(await completer.resolve(c)) }
                        }
                    }
                    if !query.isEmpty {
                        suggestionRow(PlaceValue(name: query, address: "この名前のまま使う"), symbol: "text.cursor") { choose(PlaceValue(name: query)) }
                    }
                }
            }
        }
    }

    // MARK: 移動

    private var travelSection: some View {
        Section {
            // 今の移動時間と出発の時刻（大きく1行）
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    if calculating && travel == nil {
                        SkeletonBlock(cornerRadius: 5).frame(width: 120, height: 22)
                    } else {
                        Text(travel.map { "移動 \(durationLabel($0))" } ?? "移動なし").font(.title3.weight(.semibold)).monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    if let t = travel, t > 0 {
                        Text("\(model.hm(model.time.ms(start) - EpochMs(t) * MINUTE))に出発").font(.subheadline).foregroundStyle(.orange).monospacedDigit()
                    }
                }
                Spacer()
                if calculating { ProgressView() }
                else if travel != nil && travel == autoValue && AppleMaps.home != nil && !failed {
                    Text("自動").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                }
            }
            GlassSlider(value: Binding(get: { travel ?? 0 }, set: { travel = $0 == 0 ? nil : $0 }),
                        steps: Array(stride(from: 0, through: 120, by: 5)),
                        label: { $0 == 0 ? "なし" : durationLabel($0) },
                        tint: .orange, symbol: mode.symbol, title: "直す")
        } header: {
            // 行き方（見出しの下に、枠の外で選ぶ）
            VStack(alignment: .leading, spacing: 8) {
                Text("移動")
                GlassSegmented(items: AppleMaps.Mode.allCases.map { .init(value: $0, title: $0.label, symbol: $0.symbol) }, selection: $mode)
                    .textCase(nil)
                    .padding(.horizontal, -16)
                    .padding(.bottom, 4)
            }
        } footer: {
            if AppleMaps.home == nil {
                Text("「その他」の「アカウント」で自宅の住所を入れると、場所を選んだときに移動時間を自動で入れます。")
            } else if failed {
                Text("Apple マップで時間を求められませんでした。指でなぞって入れてください。")
            } else {
                Text("自宅から\(mode.label)で着くまでの時間（Apple マップ）に、余裕の\(AppleMaps.bufferMinutes)分を足して入れます。なぞって直すと、その値を使います。")
            }
        }
    }

    /// 場所・行き方が変わったら、自宅からの時間を調べて入れる（自分で直した値は上書きしない）
    private func autoFill() async {
        guard let p = place, AppleMaps.home != nil, p.name != "自宅" else { return }
        guard travel == nil || travel == autoValue else { return }
        AppleMaps.preferredMode = mode
        calculating = true
        defer { calculating = false }
        if let m = await AppleMaps.minutes(to: p, mode: mode, arrival: start) {
            let v = AppleMaps.withBuffer(m)
            failed = false
            withAnimation(.snappy) { travel = v; autoValue = v }
        } else {
            failed = true
        }
    }

    private var schoolLabel: String { schoolName.isEmpty ? "学校" : schoolName }

    private var quickPlaces: [PlaceValue] {
        let k = query.trimmingCharacters(in: .whitespaces)
        var out: [PlaceValue] = []
        if !homeAddress.isEmpty, k.isEmpty || "自宅".contains(k) || homeAddress.contains(k) { out.append(PlaceValue(name: "自宅", address: homeAddress)) }
        if k.isEmpty || schoolLabel.contains(k) || schoolAddress.contains(k) { out.append(PlaceValue(name: schoolLabel, address: schoolAddress)) }
        for h in history where (k.isEmpty || h.name.localizedCaseInsensitiveContains(k) || h.address.localizedCaseInsensitiveContains(k)) && !out.contains(where: { $0.name == h.name }) {
            out.append(h)
            if out.count >= (k.isEmpty ? 5 : 4) { break }
        }
        return out
    }

    private func suggestionRow(_ p: PlaceValue, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).foregroundStyle(.primary)
                    if !p.address.isEmpty { Text(p.address).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ p: PlaceValue) {
        // 場所を変えたら、自動の移動時間は調べ直す
        if travel == autoValue { travel = nil; autoValue = nil }
        place = p; query = ""; completer.update(""); searching = false
        focused = false
    }
}

/// Apple マップのプレビュー（地図・ピン・名前・住所・出発の目安）。押すと Apple マップでその場所を開く（経路は出さない）
struct PlaceMapPreview: View {
    var place: PlaceValue
    var height: CGFloat = 150
    /// 「8:35に出発・移動25分」など（任意）
    var subline: String? = nil
    @State private var coord: CLLocationCoordinate2D?
    @State private var loading = true

    var body: some View {
        Button { Task { await AppleMaps.open(place) } } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if let c = coord {
                        Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 650, longitudinalMeters: 650)), interactionModes: []) {
                            Marker(place.name, coordinate: c).tint(.red)
                        }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    } else if loading {
                        // 地図を読み込むまでは、地図の形の仮の面（光が流れる）
                        SkeletonBlock(cornerRadius: 0)
                    } else {
                        Color(.tertiarySystemFill)
                        Image(systemName: "map").font(.title2).foregroundStyle(.secondary)
                    }
                }
                .frame(height: height)
                .clipped()
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        let addr = place.address == "このまま使う" || place.address == "この名前のまま使う" ? "" : place.address
                        if let subline { Text(subline).font(.subheadline).foregroundStyle(.orange).monospacedDigit().lineLimit(1) }
                        else if !addr.isEmpty { Text(addr).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.forward.app").font(.body).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Apple マップで開きます")
        .task(id: place.name) {
            loading = true
            let c = await AppleMaps.mapItem(place)?.placemark.coordinate
            withAnimation(.easeOut(duration: 0.35)) { coord = c; loading = false }
        }
    }
}
