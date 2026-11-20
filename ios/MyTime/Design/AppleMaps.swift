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

    /// 移動時間の余裕（分）。Apple マップの所要時間に足す
    static let bufferMinutes = 20
    /// 所要時間＋余裕を5分単位に
    static func withBuffer(_ m: Int) -> Int { (m + bufferMinutes + 4) / 5 * 5 }

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

/// 予定の詳細の「場所」：Apple マップのプレビュー（押すとマップで開く。経路のボタンは出さない）と、
/// 移動の段取り（あるときだけ。区間の時刻と乗り場）
struct EventMapCard: View {
    var event: MTEvent
    var start: EpochMs
    @Environment(AppModel.self) private var model

    var body: some View {
        if let place = AppleMaps.place(of: event) {
            Section {
                PlaceMapPreview(place: place, height: 140, subline: subline)
                    .listRowInsets(EdgeInsets())
            } header: { Text("場所") }
            Section {
                TravelPlanSummary(event: event, start: start)
            } header: { Text("移動の段取り") }
        }
    }

    private var subline: String? {
        let legs = TravelPlan.legs(event.extra)
        if let f = legs.first {
            let r = legs.first(where: { $0.mode.isRide })
            return "\(model.hm(start + EpochMs(f.departMin) * MINUTE))に出発" + (r.map { "・\($0.from)から\($0.mode.label)" } ?? "")
        }
        if let m = event.travelMinutes, m > 0 { return "\(model.hm(start - EpochMs(m) * MINUTE))に出発・移動\(durationLabel(m))" }
        return nil
    }
}

extension AppleMaps {
    /// 予定の場所。授業で場所が空なら、アカウントの学校（住所が分かっているので）
    static func place(of e: MTEvent) -> PlaceValue? {
        if let p = PlaceValue(e.extra?["place"]) { return p }
        if let n = e.placeName, !n.isEmpty { return PlaceValue(name: n) }
        if e.specType == .class || e.classInfo != nil { return school }
        return nil
    }

    /// 学校（アカウントの学校名と住所。住所が無ければ nil）
    static var school: PlaceValue? {
        let a = UserDefaults.standard.string(forKey: AccountKeys.schoolAddress) ?? ""
        guard !a.isEmpty else { return nil }
        let n = UserDefaults.standard.string(forKey: AccountKeys.school) ?? ""
        return PlaceValue(name: n.isEmpty ? "学校" : n, address: a)
    }
}


extension AppModel {
    /// 予定に場所があって移動時間が空のとき、自宅から公共交通機関で調べて（＋余裕）入れる。自宅が無ければ何もしない
    @MainActor
    func fillTravel(eventId: String) {
        guard AppleMaps.home != nil else { return }
        Task { @MainActor in
            guard let e = events.first(where: { $0.id == eventId }), e.travelMinutes == nil,
                  let p = PlaceValue(e.extra?["place"]) ?? e.placeName.map({ PlaceValue(name: $0) }), p.name != "自宅",
                  let m = await AppleMaps.minutes(to: p, mode: .transit, arrival: time.date(e.start)),
                  var cur = events.first(where: { $0.id == eventId }), cur.travelMinutes == nil else { return }
            var o = cur.extra?.objectValue ?? [:]
            o["travelMinutes"] = .number(Double(AppleMaps.withBuffer(m)))
            cur.extra = .object(o)
            _ = perform(nil) { try repo.saveEvent(cur, isNew: false) }
        }
    }
}
