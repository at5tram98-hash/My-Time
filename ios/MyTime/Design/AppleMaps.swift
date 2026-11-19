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

    /// 場所の近くの乗り場（バス停・駅）。近い順
    static func nearbyStops(_ p: PlaceValue, radius: Double = 700) async -> [(name: String, meters: Double)] {
        guard let item = await mapItem(p) else { return [] }
        let c = item.placemark.coordinate
        let r = MKLocalPointsOfInterestRequest(center: c, radius: radius)
        r.pointOfInterestFilter = MKPointOfInterestFilter(including: [.publicTransport])
        guard let items = try? await MKLocalSearch(request: r).start().mapItems else { return [] }
        let here = CLLocation(latitude: c.latitude, longitude: c.longitude)
        var seen = Set<String>()
        return items.compactMap { i -> (String, Double)? in
            guard let n = i.name, seen.insert(n).inserted else { return nil }
            let l = i.placemark.coordinate
            return (n, here.distance(from: CLLocation(latitude: l.latitude, longitude: l.longitude)))
        }
        .sorted { $0.1 < $1.1 }
    }

    /// 2つの場所の間の所要時間（分）
    static func minutes(from a: PlaceValue, to b: PlaceValue, mode: Mode, arrival: Date? = nil) async -> Int? {
        guard let from = await mapItem(a), let to = await mapItem(b) else { return nil }
        let r = MKDirections.Request()
        r.source = from; r.destination = to; r.transportType = mode.transport
        if let arrival { r.arrivalDate = arrival }
        guard let eta = try? await MKDirections(request: r).calculateETA() else { return nil }
        return max(1, Int((eta.expectedTravelTime / 60).rounded(.up)))
    }

    /// 移動の段取りの下書き：自宅 →（歩き）→ 最寄りの乗り場 →（バス・電車）→ 着く場所の最寄りの乗り場 →（歩き）→ 着く場所。
    /// Apple マップは乗り換えの経路そのものを渡さないため、電車の所要時間（時刻表から）と、周りの乗り場の名前と歩く時間から組み立てる。
    /// 乗り物の名前（系統・路線）は入らないので、必要なら自分で直す
    static func draftLegs(to dest: PlaceValue, arrival: Date, newId: () -> String) async -> [TravelLeg]? {
        guard let h = home else { return nil }
        let walkAll = await minutes(from: h, to: dest, mode: .walking, arrival: arrival)
        guard let total = await minutes(from: h, to: dest, mode: .transit, arrival: arrival) else {
            // 電車・バスで行けない（近い）ときは歩きだけ
            guard let w = walkAll else { return nil }
            return TravelPlan.chain([TravelLeg(id: newId(), mode: .walk, from: "自宅", to: dest.name, departMin: 0, arriveMin: w)])
        }
        if let w = walkAll, w <= total + 5 {
            return TravelPlan.chain([TravelLeg(id: newId(), mode: .walk, from: "自宅", to: dest.name, departMin: 0, arriveMin: w)])
        }
        let a = await nearbyStops(h).first
        let b = await nearbyStops(dest).first
        guard let a, let b, a.name != b.name else {
            return TravelPlan.chain([TravelLeg(id: newId(), mode: .bus, from: "自宅", to: dest.name, departMin: 0, arriveMin: total)])
        }
        let w1 = await minutes(from: h, to: PlaceValue(name: a.name), mode: .walking) ?? max(1, Int(a.meters / 70))
        let w2 = await minutes(from: PlaceValue(name: b.name), to: dest, mode: .walking) ?? max(1, Int(b.meters / 70))
        let ride = max(3, total - w1 - w2)
        let station = { (n: String) in n.hasSuffix("駅") || n.contains("駅") }
        let mode: TravelLeg.Mode = station(a.name) && station(b.name) ? .train : .bus
        return TravelPlan.chain([
            TravelLeg(id: newId(), mode: .walk, from: "自宅", to: a.name, departMin: 0, arriveMin: w1),
            TravelLeg(id: newId(), mode: mode, from: a.name, to: b.name, departMin: 0, arriveMin: ride),
            TravelLeg(id: newId(), mode: .walk, from: b.name, to: dest.name, departMin: 0, arriveMin: w2),
        ])
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
                // 家を出てから着くまでの区間（乗り場・路線・時刻）。移動中はロック画面に今の区間を出す
                TravelPlanSummary(event: event, start: start)
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
            let line = Label {
                Text("自宅から\(mode.label)で約\(durationLabel(m))・\(model.hm(leave))に出発").monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: mode.symbol).foregroundStyle(.orange) }
                .font(.subheadline)
            let button = Button("移動に入れる") { setTravel(m) }.font(.caption.weight(.semibold)).buttonStyle(.bordered).fixedSize()
            // 1行に入るときは横に、入らないときはボタンを下に（文字とボタンが押しつぶされない）
            if event.travelMinutes != m {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { line.lineLimit(1); Spacer(minLength: 4); button }
                    VStack(alignment: .leading, spacing: 6) { line; button }
                }
            } else {
                line
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
