import Foundation

/// Create Studio（自分専用の種類）。Web 版 packages/domain/src/studio.ts と types.ts の StudioType と同じ形。
/// 保存は studioTypes 表。予定・タスクの値は extra.studio = { typeId, version, values } に入れる。

public enum StudioFieldType: String, CaseIterable, Sendable, Codable {
    case text, multiline, number, datetime, duration, toggle, check, select, multiselect, url, place, file, progress, worktime, note
}

public struct StudioField: Equatable, Sendable, Identifiable {
    public var id: String
    public var type: StudioFieldType
    public var label: String
    public var unit: String?
    public var precision: Int
    public var min: Double?
    public var max: Double?
    public var options: [String]
    public var required: Bool
    public var showInInfo: Bool
    public var sectionId: String
    public var body: String
    public var hidden: Bool

    public init(id: String, type: StudioFieldType, label: String, sectionId: String, unit: String? = nil, precision: Int = 0, min: Double? = nil, max: Double? = nil, options: [String] = [], required: Bool = false, showInInfo: Bool = true, body: String = "", hidden: Bool = false) {
        self.id = id; self.type = type; self.label = label; self.sectionId = sectionId; self.unit = unit; self.precision = precision
        self.min = min; self.max = max; self.options = options; self.required = required; self.showInInfo = showInInfo; self.body = body; self.hidden = hidden
    }

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue, let t = v["type"]?.stringValue.flatMap(StudioFieldType.init(rawValue:)) else { return nil }
        self.id = id; type = t
        label = v["label"]?.stringValue ?? ""
        unit = v["unit"]?.stringValue
        precision = Int(v["precision"]?.intValue ?? 0)
        min = v["min"]?.doubleValue; max = v["max"]?.doubleValue
        options = v["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
        required = v["required"]?.boolValue ?? false
        showInInfo = v["showInInfo"]?.boolValue ?? true
        sectionId = v["sectionId"]?.stringValue ?? "main"
        body = v["body"]?.stringValue ?? ""
        hidden = v["hidden"]?.boolValue ?? false
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "type": .string(type.rawValue), "label": .string(label), "showInInfo": .bool(showInInfo), "sectionId": .string(sectionId)]
        if let unit { o["unit"] = .string(unit) }
        if type == .number { o["precision"] = .number(Double(precision)) }
        if let min { o["min"] = .number(min) }
        if let max { o["max"] = .number(max) }
        if !options.isEmpty { o["options"] = .array(options.map { .string($0) }) }
        if required { o["required"] = .bool(true) }
        if !body.isEmpty { o["body"] = .string(body) }
        if hidden { o["hidden"] = .bool(true) }
        return .object(o)
    }
}

public struct StudioSection: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public enum StudioProgressMode: String, CaseIterable, Sendable { case none, time, number, checklist, manual }

public struct StudioProgress: Equatable, Sendable {
    public var mode: StudioProgressMode
    public var fieldId: String?
    public var target: Double?
    public init(mode: StudioProgressMode = .none, fieldId: String? = nil, target: Double? = nil) { self.mode = mode; self.fieldId = fieldId; self.target = target }
}

public struct StudioType: Record {
    public static let entity = EntityName.studioType
    public var id: String
    /// calendar（予定）または task（タスク）
    public var target: String
    public var name: String
    public var icon: String
    public var color: String
    /// draft / active / hidden
    public var status: String
    public var version: Int
    public var sections: [StudioSection]
    public var fields: [StudioField]
    public var progress: StudioProgress
    public var createdAt: EpochMs
    public var updatedAt: EpochMs
    public var raw: JSONValue

    public init(json: JSONValue) {
        raw = json
        id = json["id"]?.stringValue ?? ""
        target = json["target"]?.stringValue ?? "task"
        name = json["name"]?.stringValue ?? ""
        icon = json["icon"]?.stringValue ?? "star"
        color = json["color"]?.stringValue ?? "#5E5CE6"
        status = json["status"]?.stringValue ?? "active"
        version = Int(json["version"]?.intValue ?? 1)
        sections = json["sections"]?.arrayValue?.compactMap { v in v["id"]?.stringValue.map { StudioSection(id: $0, title: v["title"]?.stringValue ?? "") } } ?? []
        fields = json["fields"]?.arrayValue?.compactMap(StudioField.init) ?? []
        let p = json["progress"]
        progress = StudioProgress(mode: p?["mode"]?.stringValue.flatMap(StudioProgressMode.init(rawValue:)) ?? .none, fieldId: p?["fieldId"]?.stringValue, target: p?["target"]?.doubleValue)
        createdAt = json["createdAt"]?.intValue ?? 0
        updatedAt = json["updatedAt"]?.intValue ?? 0
    }

    public static func make(name: String, target: String, now: EpochMs, id: String) -> StudioType {
        StudioType(json: .object([
            "id": .string(id), "target": .string(target), "name": .string(name), "icon": "star".json, "color": "#5E5CE6".json,
            "status": "active".json, "version": .number(1),
            "sections": .array([.object(["id": "main".json, "title": "".json])]),
            "fields": .array([]), "progress": .object(["mode": "none".json, "fieldId": .null, "target": .null]),
            "revisions": .array([]), "createdAt": now.json, "updatedAt": now.json,
        ]))
    }

    /// 定義（版の履歴に残す部分）
    var definition: JSONValue {
        .object([
            "sections": .array(sections.map { .object(["id": .string($0.id), "title": .string($0.title)]) }),
            "fields": .array(fields.map(\.json)),
            "progress": .object(["mode": .string(progress.mode.rawValue), "fieldId": progress.fieldId.map { .string($0) } ?? .null, "target": progress.target.map { .number($0) } ?? .null]),
        ])
    }

    /// 知らない項目は元のまま残す
    public var json: JSONValue {
        raw.merging(definition).merging(.object([
            "id": .string(id), "target": .string(target), "name": .string(name), "icon": .string(icon), "color": .string(color),
            "status": .string(status), "version": .number(Double(version)), "createdAt": createdAt.json, "updatedAt": updatedAt.json,
        ]))
    }

    public var knownJSON: JSONValue { json }

    public var visibleFields: [StudioField] { fields.filter { !$0.hidden } }
}

// MARK: 単位と進捗（Web 版と同じ計算）

public struct StudioUnit: Equatable, Sendable { public var id: String; public var label: String; public var dim: String; public var toBase: Double }

public let STUDIO_UNITS: [StudioUnit] = [
    StudioUnit(id: "min", label: "分", dim: "time", toBase: 1),
    StudioUnit(id: "hour", label: "時間", dim: "time", toBase: 60),
    StudioUnit(id: "times", label: "回", dim: "count", toBase: 1),
    StudioUnit(id: "piece", label: "個", dim: "count", toBase: 1),
    StudioUnit(id: "page", label: "ページ", dim: "page", toBase: 1),
    StudioUnit(id: "yen", label: "円", dim: "money", toBase: 1),
]

public func studioUnitLabel(_ id: String?) -> String {
    guard let id else { return "" }
    if id.hasPrefix("custom:") { return String(id.dropFirst(7).prefix(20)) }
    return STUDIO_UNITS.first { $0.id == id }?.label ?? ""
}

public func studioFormat(_ f: StudioField, _ v: Double) -> String {
    let s = v.isFinite ? String(format: "%.\(f.precision)f", v) : "—"
    let u = studioUnitLabel(f.unit)
    if u == "円", let n = Double(s) {
        let nf = NumberFormatter(); nf.numberStyle = .decimal; nf.locale = Locale(identifier: "ja_JP")
        return (nf.string(from: NSNumber(value: n)) ?? s) + "円"
    }
    return s + u
}

/// 進捗（0〜1。超過は over）。number：現在値/目標、checklist：チェック済み/項目数、time：実行時間（分）/目標、manual：0〜100
public func studioProgress(_ type: StudioType, values: [String: JSONValue], workedMinutes: Double = 0) -> (value: Double?, over: Bool, label: String) {
    let p = type.progress
    func clamp(_ x: Double) -> Double { Swift.max(0, Swift.min(1, x)) }
    switch p.mode {
    case .none: return (nil, false, "")
    case .checklist:
        let checks = type.fields.filter { $0.type == .check && !$0.hidden }
        if checks.isEmpty { return (nil, false, "項目なし") }
        let done = checks.filter { values[$0.id]?.boolValue == true }.count
        return (Double(done) / Double(checks.count), false, "\(done)/\(checks.count)項目")
    case .manual:
        let v = values[p.fieldId ?? ""]?.doubleValue ?? 0
        return (clamp(v / 100), v > 100, "\(Int(Swift.max(0, v).rounded()))%")
    case .number, .time:
        let f = type.fields.first { $0.id == p.fieldId }
        let cur = p.mode == .time ? workedMinutes : (values[p.fieldId ?? ""]?.doubleValue ?? 0)
        let c = cur.isFinite ? Swift.max(0, cur) : 0
        let t = p.target ?? 0
        if !(t > 0) { return (nil, false, f.map { studioFormat($0, c) } ?? "\(c)") }
        let unit = p.mode == .time ? "分" : studioUnitLabel(f?.unit)
        let cs = String(format: "%.\(f?.precision ?? 0)f", c)
        let ts = t == t.rounded() ? "\(Int(t))" : "\(t)"
        return (clamp(c / t), c > t, "\(cs)/\(ts)\(unit)")
    }
}

/// 項目の部品（Web 版 STUDIO_PARTS と同じ）
public struct StudioPart: Sendable { public var type: StudioFieldType; public var label: String; public var desc: String; public var words: [String] }

public let STUDIO_PARTS: [StudioPart] = [
    StudioPart(type: .text, label: "1行テキスト", desc: "教室名・科目名など短い文字", words: ["テキスト", "文字", "名前", "教室"]),
    StudioPart(type: .multiline, label: "複数行テキスト", desc: "内容・感想など長い文章", words: ["メモ", "文章", "内容"]),
    StudioPart(type: .number, label: "数値", desc: "ページ数・金額・回数（単位つき）", words: ["数", "数値", "ページ", "金額", "円", "回", "時給"]),
    StudioPart(type: .datetime, label: "日時", desc: "締切・試験日など", words: ["日付", "期限", "締切", "日時"]),
    StudioPart(type: .duration, label: "時間量", desc: "休憩時間・目標時間など（分・時間）", words: ["時間", "休憩", "長さ", "分"]),
    StudioPart(type: .toggle, label: "オン／オフ", desc: "持ち物あり・提出済みなど", words: ["スイッチ", "オン", "オフ", "はい"]),
    StudioPart(type: .check, label: "チェック項目", desc: "手順・持ち物のチェック（進捗に使える）", words: ["チェック", "やること", "手順"]),
    StudioPart(type: .select, label: "選択（1つ）", desc: "難易度・場所の区分など", words: ["選択", "区分", "カテゴリ"]),
    StudioPart(type: .multiselect, label: "選択（複数）", desc: "使う教材・メンバーなど", words: ["複数", "選択", "タグ"]),
    StudioPart(type: .url, label: "URL", desc: "資料や提出先のリンク", words: ["リンク", "URL", "ウェブ"]),
    StudioPart(type: .place, label: "場所", desc: "教室・勤務先の住所など", words: ["場所", "住所", "地図"]),
    StudioPart(type: .progress, label: "進捗（手動％）", desc: "0〜100% を自分で入力", words: ["進捗", "パーセント", "達成"]),
    StudioPart(type: .worktime, label: "実行時間", desc: "開始〜完了で記録した時間を表示", words: ["実行時間", "作業時間", "経過"]),
    StudioPart(type: .note, label: "説明・区切り", desc: "入力欄の説明文や見出し", words: ["説明", "見出し", "区切り"]),
]

public func searchStudioParts(_ q: String) -> [StudioPart] {
    let k = q.trimmingCharacters(in: .whitespaces).lowercased()
    if k.isEmpty { return STUDIO_PARTS }
    return STUDIO_PARTS.filter { p in
        p.label.lowercased().contains(k) || p.desc.lowercased().contains(k) || p.words.contains { $0.lowercased().contains(k) || k.contains($0.lowercased()) }
    }
}

// MARK: 保存

extension Repository {
    public func studioTypes() -> [StudioType] { store.all(.studioType).map(StudioType.init).sorted { $0.createdAt < $1.createdAt } }

    /// 保存のたびに版を1つ上げ、前の定義を履歴に残す（Web 版と同じ。最大20版）
    public func saveStudioType(_ type: StudioType, isNew: Bool) throws {
        var t = type
        let name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RepositoryError("名前を入力してください") }
        guard name.count <= 40 else { throw RepositoryError("名前は40文字までです") }
        let labels = t.visibleFields.filter { $0.type != .note }.map { $0.label.trimmingCharacters(in: .whitespaces) }
        if labels.contains(where: \.isEmpty) { throw RepositoryError("名前のない項目があります") }
        if Set(labels).count != labels.count { throw RepositoryError("同じ名前の項目があります") }
        t.name = name
        try store.transaction {
            let prev = isNew ? nil : store.get(.studioType, id: t.id).map(StudioType.init)
            if let prev {
                t.version = prev.version + 1
                var revs = prev.raw["revisions"]?.arrayValue ?? []
                revs.append(.object(["version": .number(Double(prev.version)), "at": clock().json, "definition": prev.definition]))
                t.raw = t.raw.merging(.object(["revisions": .array(Array(revs.suffix(20)))]))
            }
            t.updatedAt = clock()
            if isNew { t.createdAt = t.updatedAt }
            store.put(.studioType, id: t.id, json: t.json)
            record(.studioType, t.id, op: "put", action: isNew ? "create" : "update", detail: prev.map { ["snapshot": $0.raw] })
        }
    }

    /// 削除は「隠す」（使っている予定・タスクの値はそのまま残る）
    public func hideStudioType(_ id: String, hidden: Bool = true) throws {
        guard var t = store.get(.studioType, id: id).map(StudioType.init) else { throw RepositoryError("種類が見つかりません") }
        t.status = hidden ? "hidden" : "active"
        try saveStudioType(t, isNew: false)
    }
}
