import Foundation

/// 移動の段取り（家を出てから予定の場所に着くまでの区間）。
/// 保存は予定の extra.travelPlan = [{ id, mode, from, to, line?, departMin, arriveMin }]
/// departMin・arriveMin は予定の開始からの分（出発は負の数。例：-40 は開始の40分前）
public struct TravelLeg: Identifiable, Equatable, Hashable, Sendable {
    public enum Mode: String, Sendable, CaseIterable {
        case walk, bus, train, subway, bike, car
        public var label: String {
            switch self {
            case .walk: return "徒歩"
            case .bus: return "バス"
            case .train: return "電車"
            case .subway: return "地下鉄"
            case .bike: return "自転車"
            case .car: return "車"
            }
        }
        public var symbol: String {
            switch self {
            case .walk: return "figure.walk"
            case .bus: return "bus.fill"
            case .train: return "tram.fill"
            case .subway: return "tram.fill.tunnel"
            case .bike: return "bicycle"
            case .car: return "car.fill"
            }
        }
        /// 乗り物か（乗り場で待つもの）
        public var isRide: Bool { self == .bus || self == .train || self == .subway }
    }
    public var id: String
    public var mode: Mode
    public var from: String
    public var to: String
    public var line: String?
    public var departMin: Int
    public var arriveMin: Int

    public init(id: String, mode: Mode, from: String, to: String, line: String? = nil, departMin: Int, arriveMin: Int) {
        self.id = id; self.mode = mode; self.from = from; self.to = to; self.line = line; self.departMin = departMin; self.arriveMin = arriveMin
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let d = json["departMin"]?.intValue, let a = json["arriveMin"]?.intValue, a >= d else { return nil }
        self.id = id
        mode = Mode(rawValue: json["mode"]?.stringValue ?? "") ?? .walk
        from = json["from"]?.stringValue ?? ""
        to = json["to"]?.stringValue ?? ""
        line = json["line"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        departMin = Int(d); arriveMin = Int(a)
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "mode": .string(mode.rawValue), "from": .string(from), "to": .string(to),
                                      "departMin": .number(Double(departMin)), "arriveMin": .number(Double(arriveMin))]
        if let line, !line.isEmpty { o["line"] = .string(line) }
        return .object(o)
    }

    public var minutes: Int { arriveMin - departMin }
}

public enum TravelPlan {
    public static func legs(_ extra: JSONValue?) -> [TravelLeg] {
        (extra?["travelPlan"]?.arrayValue ?? []).compactMap(TravelLeg.init(json:)).sorted { ($0.departMin, $0.arriveMin) < ($1.departMin, $1.arriveMin) }
    }

    /// 段取りを保存し、移動時間（travelMinutes）も最初の出発に合わせる
    public static func write(_ legs: [TravelLeg], into extra: JSONValue?) -> JSONValue {
        var o = extra?.objectValue ?? [:]
        let xs = legs.sorted { $0.departMin < $1.departMin }
        o["travelPlan"] = xs.isEmpty ? nil : .array(xs.map(\.json))
        if let first = xs.first { o["travelMinutes"] = .number(Double(max(0, -first.departMin))) }
        return .object(o)
    }

    /// 今の区間（乗っている・歩いている）と次の区間。minute は予定の開始からの分
    public static func position(_ legs: [TravelLeg], minute: Int) -> (current: TravelLeg?, next: TravelLeg?) {
        let cur = legs.first { $0.departMin <= minute && minute < $0.arriveMin }
        let next = legs.first { $0.departMin > minute }
        return (cur, next)
    }

    /// 区間をつなげて並べ直す（前の区間の到着より前には出発しない。所要の分は保つ）
    public static func chain(_ legs: [TravelLeg], endAt: Int = 0) -> [TravelLeg] {
        // 最後の区間が予定の開始（endAt）に着くように、後ろから時刻を決める
        var out = legs
        var t = endAt
        for i in out.indices.reversed() {
            let len = max(1, out[i].minutes)
            out[i].arriveMin = t
            out[i].departMin = t - len
            t = out[i].departMin
        }
        return out
    }
}
