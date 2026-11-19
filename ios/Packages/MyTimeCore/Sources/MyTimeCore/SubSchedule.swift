import Foundation

/// 詳細スケジュール：予定の中の予定（5分ごと）。予定とタスクの2つのレーンに分ける。
/// 保存は予定の extra.subSchedule = [{ id, lane: "event"|"task", title, startMin, endMin, done?, place?, color? }]
/// startMin・endMin は予定の開始からの分（繰り返しの予定でも、どの回でも同じ並びを使える）
public struct SubItem: Identifiable, Equatable, Hashable, Sendable {
    public enum Lane: String, Sendable, CaseIterable { case event, task
        public var label: String { self == .event ? "予定" : "タスク" }
    }
    public var id: String
    public var lane: Lane
    public var title: String
    public var startMin: Int
    public var endMin: Int
    public var done: Bool
    public var place: String?
    public var color: String?

    public init(id: String, lane: Lane, title: String, startMin: Int, endMin: Int, done: Bool = false, place: String? = nil, color: String? = nil) {
        self.id = id; self.lane = lane; self.title = title; self.startMin = startMin; self.endMin = endMin; self.done = done; self.place = place; self.color = color
    }

    public init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let s = json["startMin"]?.intValue, let e = json["endMin"]?.intValue, e > s else { return nil }
        self.id = id
        lane = Lane(rawValue: json["lane"]?.stringValue ?? "") ?? .event
        title = json["title"]?.stringValue ?? ""
        startMin = Int(s); endMin = Int(e)
        done = json["done"]?.boolValue ?? false
        place = json["place"]?.stringValue
        color = json["color"]?.stringValue
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "lane": .string(lane.rawValue), "title": .string(title), "startMin": .number(Double(startMin)), "endMin": .number(Double(endMin))]
        if done { o["done"] = .bool(true) }
        if let place, !place.isEmpty { o["place"] = .string(place) }
        if let color { o["color"] = .string(color) }
        return .object(o)
    }

    public var minutes: Int { endMin - startMin }
}

public enum SubSchedule {
    /// 5分ごと
    public static let step = 5

    public static func items(_ extra: JSONValue?) -> [SubItem] {
        (extra?["subSchedule"]?.arrayValue ?? []).compactMap(SubItem.init(json:)).sorted { ($0.startMin, $0.lane.rawValue, $0.id) < ($1.startMin, $1.lane.rawValue, $1.id) }
    }

    public static func write(_ items: [SubItem], into extra: JSONValue?) -> JSONValue {
        var o = extra?.objectValue ?? [:]
        o["subSchedule"] = items.isEmpty ? nil : .array(items.map(\.json))
        return .object(o)
    }

    /// 5分にそろえ、予定の長さの中に収める（短くても5分）
    public static func clamp(_ s: Int, _ e: Int, total: Int) -> (Int, Int) {
        let snap = { (m: Int) in Int((Double(m) / Double(step)).rounded()) * step }
        var a = max(0, min(snap(s), max(0, total - step)))
        var b = max(a + step, min(snap(e), total))
        if b > total { b = total; a = max(0, b - step) }
        return (a, b)
    }

    /// 同じレーンで重なっているもの（横に並べる列の番号と列の数）
    public static func columns(_ items: [SubItem]) -> [String: (col: Int, of: Int)] {
        var out: [String: (Int, Int)] = [:]
        for lane in SubItem.Lane.allCases {
            let xs = items.filter { $0.lane == lane }.sorted { ($0.startMin, $0.endMin) < ($1.startMin, $1.endMin) }
            var group: [SubItem] = [], ends: [Int] = [], groupEnd = -1
            func flush() {
                let n = max(1, ends.count)
                for it in group { out[it.id] = (out[it.id]?.0 ?? 0, n) }
                group = []; ends = []
            }
            for it in xs {
                if it.startMin >= groupEnd { flush() }
                if let i = ends.firstIndex(where: { $0 <= it.startMin }) { ends[i] = it.endMin; out[it.id] = (i, 1) }
                else { ends.append(it.endMin); out[it.id] = (ends.count - 1, 1) }
                group.append(it)
                groupEnd = max(groupEnd, it.endMin)
            }
            flush()
        }
        return out
    }

    /// 今の時刻（予定の開始からの分）に進行中のもの
    public static func current(_ items: [SubItem], minute: Int) -> SubItem? {
        items.first { $0.startMin <= minute && minute < $0.endMin && !$0.done }
    }

    /// あるレーンの空いた時間（`minimum` 分以上のものだけ。予定の初めから終わりまで）
    public static func gaps(_ items: [SubItem], lane: SubItem.Lane, total: Int, minimum: Int = 15) -> [(startMin: Int, endMin: Int)] {
        let xs = items.filter { $0.lane == lane }.sorted { $0.startMin < $1.startMin }
        var out: [(startMin: Int, endMin: Int)] = []
        var cursor = 0
        for it in xs {
            if it.startMin - cursor >= minimum { out.append((cursor, it.startMin)) }
            cursor = max(cursor, it.endMin)
        }
        if total - cursor >= minimum { out.append((cursor, total)) }
        return out
    }

    /// 前回の詳細スケジュールを、この回の長さに合わせて写す（新しい ID、未完了に戻す。はみ出す分は切る）
    public static func copy(_ source: [SubItem], total: Int, newId: () -> String) -> [SubItem] {
        source.compactMap { it in
            guard it.startMin < total else { return nil }
            var x = it
            x.id = newId()
            x.done = false
            x.endMin = min(it.endMin, total)
            return x.endMin > x.startMin ? x : nil
        }
    }
}

/// 持ち物の候補（種類ごとのよく使う物）
public enum BelongingSuggest {
    public static let everyday = ["財布", "鍵", "スマホ", "イヤホン", "モバイルバッテリー", "ハンカチ", "ティッシュ"]
    public static func forSpec(_ s: SpecTypeId?) -> [String] {
        switch s {
        case .class: return ["教科書", "ノート", "ノートPC", "充電器", "筆記用具", "学生証", "レジュメ"]
        case .exam, .language, .certification: return ["受験票", "身分証", "鉛筆", "消しゴム", "時計", "参考書"]
        case .shift: return ["名札", "制服", "社員証", "エプロン", "飲み物"]
        case .presentation: return ["ノートPC", "変換アダプタ", "USB メモリ", "原稿", "レーザーポインター"]
        case .appointment: return ["保険証", "診察券", "お薬手帳", "マイナンバーカード"]
        case .trip: return ["着替え", "充電器", "歯ブラシ", "常備薬", "身分証", "チケット"]
        case .outing: return ["日傘", "モバイルバッテリー", "ハンカチ", "プレゼント"]
        case .workout: return ["タオル", "着替え", "飲み物", "シューズ"]
        case .paperwork: return ["印鑑", "身分証", "必要な書類", "通帳"]
        case .shopping: return ["エコバッグ", "ポイントカード"]
        default: return []
        }
    }

    /// 文字を「、」「,」で分けて整える（同じ物は1つ）
    public static func split(_ s: String) -> [String] {
        var seen = Set<String>()
        return s.split(whereSeparator: { "、,，・\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
