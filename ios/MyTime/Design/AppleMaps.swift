import SwiftUI
import MapKit
import MyTimeCore

/// Apple マップとのつなぎ（場所の地点・経路・所要時間）。
/// 位置情報の許可は求めない：出発地は「自宅」（アカウントに入れた住所）。経路を開くときの現在地は Apple マップが扱う。
enum AppleMaps {
    enum Mode: String, CaseIterable, Identifiable {
        case transit, walking, driving
        var id: String { rawValue }
        var label: String { self == .transit ? "電車" : self == .walking ? "徒歩" : "車" }
        var symbol: String { self == .transit ? "tram.fill" : self == .walking ? "figure.walk" : "car.fill" }
        var transport: MKDirectionsTransportType { self == .transit ? .transit : self == .walking ? .walking : .automobile }
        var launch: String { self == .transit ? MKLaunchOptionsDirectionsModeTransit : self == .walking ? MKLaunchOptionsDirectionsModeWalking : MKLaunchOptionsDirectionsModeDriving }
    }

    /// 選んだ移動手段（最後に使ったものを覚える）
    static var preferredMode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "maps.mode") ?? "") ?? .transit }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "maps.mode") }
    }

    /// 場所の地点（緯度経度があればそのまま。なければ名前と住所でマップを検索）
    static func mapItem(_ p: PlaceValue) async -> MKMapItem? {
        if let lat = p.lat, let lng = p.lng {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng)))
            item.name = p.name
            return item
        }
        let q = [p.name, p.address].filter { !$0.isEmpty && $0 != "このまま使う" }.joined(separator: " ")
        guard !q.isEmpty else { return nil }
        let r = MKLocalSearch.Request()
        r.naturalLanguageQuery = q
        let item = try? await MKLocalSearch(request: r).start().mapItems.first
        if let item, item.name == nil { item.name = p.name }
        return item
    }

    /// 自宅（アカウントの住所）
    static var home: PlaceValue? {
        let a = UserDefaults.standard.string(forKey: AccountKeys.home) ?? ""
        return a.isEmpty ? nil : PlaceValue(name: "自宅", address: a)
    }

    /// 自宅からの所要時間（分）。arrival に着くように（電車は時刻表で）。求められないときは nil
    static func minutes(to dest: PlaceValue, mode: Mode, arrival: Date?) async -> Int? {
        guard let h = home, let from = await mapItem(h), let to = await mapItem(dest) else { return nil }
        let r = MKDirections.Request()
        r.source = from
        r.destination = to
        r.transportType = mode.transport
        if let arrival { r.arrivalDate = arrival }
        guard let eta = try? await MKDirections(request: r).calculateETA() else { return nil }
        return Int((eta.expectedTravelTime / 60).rounded(.up))
    }

    /// Apple マップで経路を開く（出発は現在地）
    @MainActor
    static func openDirections(to p: PlaceValue, mode: Mode = preferredMode) async {
        if let item = await mapItem(p) {
            item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode.launch])
        } else if let q = p.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let u = URL(string: "maps://?daddr=\(q)") {
            await UIApplication.shared.open(u)
        }
    }

    /// Apple マップで場所を見る
    @MainActor
    static func open(_ p: PlaceValue) async {
        if let item = await mapItem(p) { item.openInMaps() }
        else if let q = p.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let u = URL(string: "maps://?q=\(q)") { await UIApplication.shared.open(u) }
    }
}

/// 予定の詳細の地図：場所のピン・自宅からの所要時間・出発の目安・経路。地図を押すと Apple マップで開く
struct EventMapCard: View {
    var event: MTEvent
    var start: EpochMs

    @Environment(AppModel.self) private var model
    @State private var item: MKMapItem?
    @State private var mode: AppleMaps.Mode = AppleMaps.preferredMode
    @State private var eta: Int?
    @State private var loading = false

    private var place: PlaceValue? { PlaceValue(event.extra?["place"]) ?? event.placeName.map { PlaceValue(name: $0) } }

    var body: some View {
        if let place {
            Section {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let c = item?.placemark.coordinate {
                            Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 700, longitudinalMeters: 700)), interactionModes: []) {
                                Marker(place.name, systemImage: "mappin", coordinate: c).tint(.red)
                            }
                        } else {
                            ZStack {
                                Color(.tertiarySystemFill)
                                if loading { ProgressView() } else { Label(place.name, systemImage: "map").foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onTapGesture { Task { await AppleMaps.open(place) } }
                    .accessibilityLabel("\(place.name)の地図")
                    .accessibilityHint("Apple マップで開きます")
                    .accessibilityAddTraits(.isButton)
                    Button { Task { await AppleMaps.openDirections(to: place, mode: mode) } } label: {
                        Label("経路", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .glass(Capsule(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.name).font(.body.weight(.semibold))
                            if !place.address.isEmpty && place.address != "このまま使う" { Text(place.address).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                    }
                    GlassSegmented(items: AppleMaps.Mode.allCases.map { .init(value: $0, title: $0.label, symbol: $0.symbol) }, selection: $mode)
                    etaRow
                }
            } header: { Text("場所") }
            .task(id: place.name) { loading = true; item = await AppleMaps.mapItem(place); loading = false }
            .task(id: "\(place.name)-\(mode.rawValue)") {
                AppleMaps.preferredMode = mode
                eta = await AppleMaps.minutes(to: place, mode: mode, arrival: model.time.date(start))
            }
        }
    }

    @ViewBuilder
    private var etaRow: some View {
        if AppleMaps.home == nil {
            Label("「その他」の「アカウント」で自宅を入れると、所要時間と出発の目安を出します。", systemImage: "house").font(.caption).foregroundStyle(.secondary)
        } else if let m = eta {
            let leave = start - EpochMs(m) * MINUTE
            HStack(spacing: 8) {
                Image(systemName: mode.symbol).foregroundStyle(.orange)
                Text("自宅から\(mode.label)で約\(durationLabel(m))・\(model.hm(leave))に出発").font(.subheadline).monospacedDigit()
                Spacer(minLength: 4)
                if event.travelMinutes != m {
                    Button("移動に入れる") { setTravel(m) }.font(.caption.weight(.semibold)).buttonStyle(.bordered)
                }
            }
        } else {
            Label("所要時間を調べています…", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setTravel(_ m: Int) {
        var e = event
        let before = event
        var o = e.extra?.objectValue ?? [:]
        o["travelMinutes"] = .number(Double((m + 4) / 5 * 5))
        e.extra = .object(o)
        model.perform("移動時間を\((m + 4) / 5 * 5)分にしました", undo: { try model.repo.saveEvent(before, isNew: false) }) { try model.repo.saveEvent(e, isNew: false) }
    }
}
