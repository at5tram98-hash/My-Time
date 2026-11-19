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

/// 場所と移動を、その場で開いて選ぶ行（タップすると下に検索と候補が広がる）
struct PlaceTravelEditor: View {
    @Binding var place: PlaceValue?
    @Binding var travel: Int?
    @Binding var expanded: Bool
    var start: Date
    var history: [PlaceValue]
    /// 専用の画面の中で使う（見出しの行を出さず、いつも開いた状態。選んだ場所は地図のカードで出す）
    var embedded = false

    @Environment(AppModel.self) private var model
    @AppStorage(AccountKeys.home) private var homeAddress = ""
    @AppStorage(AccountKeys.schoolAddress) private var schoolAddress = ""
    @AppStorage(AccountKeys.school) private var schoolName = ""
    @State private var query = ""
    @State private var completer = PlaceCompleter()
    @FocusState private var focused: Bool
    @State private var calculating = false

    static let travelChoices = [0, 5, 10, 15, 20, 30, 45, 60, 90, 120]

    var body: some View {
        if !embedded { headerRow }
        if expanded || embedded { expandedContent }
    }

    private var headerRow: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
            if expanded { focused = place == nil }
        } label: {
            HStack(spacing: 12) {
                RowIcon(symbol: "mappin.and.ellipse", tint: .red)
                Text("場所と移動").foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(summary).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var expandedContent: some View {
            if let p = place, embedded {
                PlaceMapHeader(place: p) { withAnimation(.snappy) { place = nil } }
            } else if let p = place {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.body.weight(.semibold))
                        if !p.address.isEmpty { Text(p.address).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    Button { withAnimation(.snappy) { place = nil } } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("場所を外す")
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(place == nil ? "場所や住所を入力" : "別の場所を探す", text: $query)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { if !query.isEmpty { choose(PlaceValue(name: query)) } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .onChange(of: query) { _, q in completer.update(q) }

            // 候補：自宅・学校 → 入力に合う履歴 → マップの検索結果
            ForEach(quickPlaces, id: \.self) { p in suggestionRow(p, symbol: p.name == "自宅" ? "house.fill" : p.name == schoolLabel ? "graduationcap.fill" : "clock.arrow.circlepath") { choose(p) } }
            ForEach(completer.results, id: \.self) { c in
                suggestionRow(PlaceValue(name: c.title, address: c.subtitle), symbol: "mappin") {
                    Task { choose(await completer.resolve(c)) }
                }
            }
            if !query.isEmpty {
                suggestionRow(PlaceValue(name: query, address: "このまま使う"), symbol: "text.cursor") { choose(PlaceValue(name: query)) }
            }

            // 移動時間：指でなぞって決める（5分ごと。0 は「なし」）
            GlassSlider(value: Binding(get: { travel ?? 0 }, set: { travel = $0 == 0 ? nil : $0 }),
                        steps: Array(stride(from: 0, through: 120, by: 5)),
                        label: { m in m == 0 ? "なし" : durationLabel(m) + "・" + model.hm(model.time.ms(start) - EpochMs(m) * MINUTE) + "発" },
                        tint: .orange, symbol: "tram.fill", title: "移動時間")
            // Apple マップで自宅からの所要時間を調べて、移動時間に入れる
            if let p = place, AppleMaps.home != nil {
                Button {
                    Task {
                        calculating = true
                        if let m = await AppleMaps.minutes(to: p, mode: AppleMaps.preferredMode, arrival: start) { travel = (m + 4) / 5 * 5 }
                        calculating = false
                    }
                } label: {
                    HStack {
                        Label("自宅から\(AppleMaps.preferredMode.label)の時間を調べて入れる", systemImage: "arrow.triangle.turn.up.right.diamond")
                        if calculating { Spacer(); ProgressView() }
                    }
                }
                .disabled(calculating)
            }
    }

    private var schoolLabel: String { schoolName.isEmpty ? "学校" : schoolName }

    private var summary: String {
        let t = travel.map { $0 >= 60 && $0 % 60 == 0 ? "移動\($0 / 60)時間" : "移動\($0)分" }
        let parts = [place?.name, t].compactMap { $0 }
        return parts.isEmpty ? "なし" : parts.joined(separator: "・")
    }

    private var quickPlaces: [PlaceValue] {
        let k = query.trimmingCharacters(in: .whitespaces)
        var out: [PlaceValue] = []
        if k.isEmpty || "自宅".contains(k) || homeAddress.contains(k) { out.append(PlaceValue(name: "自宅", address: homeAddress)) }
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
        withAnimation(.snappy) { place = p; query = ""; completer.update("") }
        focused = false
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


/// 選んだ場所の地図のカード（場所と移動の画面の上）
struct PlaceMapHeader: View {
    var place: PlaceValue
    var onRemove: () -> Void
    @State private var coord: CLLocationCoordinate2D?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let c = coord {
                    Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 600, longitudinalMeters: 600)), interactionModes: []) {
                        Marker(place.name, coordinate: c).tint(.red)
                    }
                } else {
                    Color(.tertiarySystemFill)
                    ProgressView()
                }
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.name).font(.headline)
                    if !place.address.isEmpty && place.address != "このまま使う" { Text(place.address).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                Button("外す", role: .destructive, action: onRemove).font(.subheadline).buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .task(id: place.name) { coord = await AppleMaps.mapItem(place)?.placemark.coordinate }
    }
}

/// 予定の編集の「場所と移動」の画面（検索・地図・移動時間を1つの画面で）
struct PlaceTravelScreen: View {
    @Binding var place: PlaceValue?
    @Binding var travel: Int?
    var start: Date
    var history: [PlaceValue]
    var body: some View {
        Form {
            PlaceTravelEditor(place: $place, travel: $travel, expanded: .constant(true), start: start, history: history, embedded: true)
        }
        .navigationTitle("場所と移動")
        .navigationBarTitleDisplayMode(.inline)
    }
}
