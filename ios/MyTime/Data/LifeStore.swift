import Foundation
import SwiftUI
import MyTimeCore

/// iOS 版だけの生活支援データ（清掃・朝・Live Activity・種類ごとの設定・確定した給与）。
///
/// 保存先は設定のレコード（`settings.raw`）の iOS 専用キー。Web 版は知らない項目を残したまま無視するので、
/// 移行ファイル・同期で Web 版を経由しても消えない。既存の予定・タスクには手を加えない（追加のキーだけ）。
/// 同じ値を2回保存しても1件のまま（キーごとに丸ごと置き換える）。
enum LifeKey: String {
    case cleaning = "iosCleaning"
    case morning = "iosMorning"
    case live = "iosLiveActivity"
    case specSettings = "iosSpecSettings"
    case confirmedPay = "iosConfirmedPay"
}

extension AppModel {
    func lifeValue<T: Decodable>(_ key: LifeKey, as type: T.Type) -> T? {
        guard let v = settings.raw[key.rawValue], v != .null else { return nil }
        return try? v.decode(type)
    }

    /// 保存する。message を付けると、iPhone を振って元に戻せる
    func setLifeValue<T: Encodable>(_ key: LifeKey, _ value: T, message: String? = nil) {
        guard let json = try? JSONValue.from(value) else { return }
        let before = settings.raw[key.rawValue] ?? .null
        guard before != json else { return }
        updateSettings { s in s.raw = s.raw.merging(.object([key.rawValue: json])) }
        if let message {
            toast = Toast(text: message, undo: { [weak self] in
                self?.updateSettings { s in s.raw = s.raw.merging(.object([key.rawValue: before])) }
                if let self { LiveActivityCoordinator.shared.refresh(model: self) }
            })
        }
        LiveActivityCoordinator.shared.refresh(model: self)
    }

    // MARK: 清掃

    var cleaning: CleaningBook { lifeValue(.cleaning, as: CleaningBook.self) ?? .template() }
    func saveCleaning(_ b: CleaningBook, message: String? = nil) { setLifeValue(.cleaning, b, message: message) }

    // MARK: 朝

    var morning: MorningRoutine { lifeValue(.morning, as: MorningRoutine.self) ?? .template() }
    func saveMorning(_ r: MorningRoutine, message: String? = nil) {
        setLifeValue(.morning, r, message: message)
        Task { await AlarmService.sync(model: self) }
    }

    // MARK: Live Activity の設定

    var livePrefs: LivePrefs { lifeValue(.live, as: LivePrefs.self) ?? LivePrefs() }
    func saveLivePrefs(_ p: LivePrefs) { setLifeValue(.live, p) }

    // MARK: 種類ごとの設定

    var specSettings: [String: SpecSettings] { lifeValue(.specSettings, as: [String: SpecSettings].self) ?? [:] }
    func specSetting(_ t: SpecTypeId) -> SpecSettings { specSettings[t.rawValue] ?? SpecSettings() }
    func saveSpecSetting(_ t: SpecTypeId, _ s: SpecSettings) {
        var all = specSettings
        all[t.rawValue] = s
        setLifeValue(.specSettings, all)
    }
    /// 種類の見た目（自分で変えていればそれ、なければ既定）
    func specSymbol(_ t: SpecTypeId) -> String { specSetting(t).symbol ?? SPEC_BY_ID[t]?.symbol ?? "circle" }
    func specTint(_ t: SpecTypeId) -> Color { specSetting(t).color.map { Color(hex: $0) } ?? SPEC_BY_ID[t]?.tint ?? .accentColor }
    /// 種類を選ぶ画面に出す種類（無効にしたものは出さない）
    var enabledSpecDefs: [SpecDef] { SPEC_PICKABLE.filter { specSetting($0.id).enabled } }

    // MARK: 確定した給与

    var confirmedPays: [ConfirmedPay] { lifeValue(.confirmedPay, as: [ConfirmedPay].self) ?? [] }
    func confirmPay(_ p: ConfirmedPay?, removing id: String? = nil) {
        var all = confirmedPays
        all.removeAll { $0.id == (id ?? p?.id) }
        if let p { all.append(p) }
        setLifeValue(.confirmedPay, all)
    }
}

/// Live Activity の種類ごとの設定
struct LivePrefs: Codable, Equatable {
    /// 無効にした種類
    var disabled: Set<LiveKind> = []
    /// 授業：開始の何分前から出すか・開始の何分後に終えるか
    var classLeadMinutes = 60
    var classEndAfterStart = 10
    /// 移動：出発の何分前から
    var transitLeadMinutes = 30
    /// チェックポイント：何分前から
    var checkpointLeadMinutes = 30
    /// 同時に出す数（1〜2）
    var maxConcurrent = 1

    init() {}
    enum CodingKeys: String, CodingKey { case disabled, classLeadMinutes, classEndAfterStart, transitLeadMinutes, checkpointLeadMinutes, maxConcurrent }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        disabled = (try? c.decode(Set<LiveKind>.self, forKey: .disabled)) ?? []
        classLeadMinutes = (try? c.decode(Int.self, forKey: .classLeadMinutes)) ?? 60
        classEndAfterStart = (try? c.decode(Int.self, forKey: .classEndAfterStart)) ?? 10
        transitLeadMinutes = (try? c.decode(Int.self, forKey: .transitLeadMinutes)) ?? 30
        checkpointLeadMinutes = (try? c.decode(Int.self, forKey: .checkpointLeadMinutes)) ?? 30
        maxConcurrent = (try? c.decode(Int.self, forKey: .maxConcurrent)) ?? 1
    }
}

/// 種類ごとの設定（どの種類にも共通の項目。種類固有の項目は専用の画面で編集する）
struct SpecSettings: Codable, Equatable {
    var enabled = true
    var symbol: String?
    var color: String?
    /// 既定の所要時間（分）
    var defaultMinutes: Int?
    /// 既定の通知（何分前。nil は通知なし）
    var notifyBefore: Int?
    /// 既定の繰り返し（none / daily / weekly / monthly）
    var repeatRule: String?
    /// 表示しない専門項目（キー）
    var hiddenFields: Set<String> = []
    /// テンプレート（名前と専門項目の値）
    var templates: [SpecTemplate] = []
    /// カレンダーへの出し方（normal：ふつう / quiet：薄く / hidden：出さない）
    var calendarDisplay = "normal"

    init() {}
    enum CodingKeys: String, CodingKey { case enabled, symbol, color, defaultMinutes, notifyBefore, repeatRule, hiddenFields, templates, calendarDisplay }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        symbol = try? c.decodeIfPresent(String.self, forKey: .symbol)
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        defaultMinutes = try? c.decodeIfPresent(Int.self, forKey: .defaultMinutes)
        notifyBefore = try? c.decodeIfPresent(Int.self, forKey: .notifyBefore)
        repeatRule = try? c.decodeIfPresent(String.self, forKey: .repeatRule)
        hiddenFields = (try? c.decode(Set<String>.self, forKey: .hiddenFields)) ?? []
        templates = (try? c.decode([SpecTemplate].self, forKey: .templates)) ?? []
        calendarDisplay = (try? c.decode(String.self, forKey: .calendarDisplay)) ?? "normal"
    }
}

struct SpecTemplate: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var title: String
    var details: JSONValue
    var minutes: Int?
}
