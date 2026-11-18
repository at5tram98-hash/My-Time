import Foundation
import MyTimeCore

/// 自動削除の設定
struct AutoDeletePrefs: Codable, Equatable {
    var enabled = false
    /// 終わってから何日で消すか（2日以上）
    var days = 7
    /// 終わっていない（完了していない）タスクも消す
    var includeUnfinishedTasks = false
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        days = max(2, (try? c.decode(Int.self, forKey: .days)) ?? 7)
        includeUnfinishedTasks = (try? c.decode(Bool.self, forKey: .includeUnfinishedTasks)) ?? false
    }
}

extension MTTask { var isArchived: Bool { extra?["archivedAt"]?.intValue != nil } }
extension MTEvent { var isArchived: Bool { extra?["archivedAt"]?.intValue != nil } }

/// 終わってから決めた日数がたった予定・タスク・チェックポイントを片づける。
/// - 予定・タスク：画面からは消し（`extra.archivedAt`）、振り返りの分析のために30日は中に残す。30日を過ぎたら本当に削除する。
/// - チェックポイント：その場で削除する（分析に使わないため）。
/// - 繰り返しの予定は、これからの回があるので対象にしない。
@MainActor
enum AutoCleanup {
    static let retentionDays = 30

    struct Plan: Equatable { var events: [String] = []; var tasks: [String] = []; var checkpoints: [String] = []; var purgeEvents: [String] = []; var purgeTasks: [String] = []
        var isEmpty: Bool { events.isEmpty && tasks.isEmpty && checkpoints.isEmpty && purgeEvents.isEmpty && purgeTasks.isEmpty } }

    /// 片づける対象（純粋な計算。設定画面の「対象の件数」にも使う）
    static func plan(model: AppModel, prefs: AutoDeletePrefs, now: EpochMs) -> Plan {
        var p = Plan()
        let keep = DAY * EpochMs(retentionDays)
        _ = keep
        p.purgeEvents = AutoDeleteRules.purgeable(archivedAt: Dictionary(uniqueKeysWithValues: model.archivedEvents.map { ($0.id, $0.extra?["archivedAt"]?.intValue ?? now) }), now: now)
        p.purgeTasks = AutoDeleteRules.purgeable(archivedAt: Dictionary(uniqueKeysWithValues: model.archivedTasks.map { ($0.id, $0.extra?["archivedAt"]?.intValue ?? now) }), now: now)
        guard prefs.enabled else { return p }
        let cutoff = now - DAY * EpochMs(max(2, prefs.days))
        p.events = AutoDeleteRules.expiredEvents(model.events, now: now, days: prefs.days)
        p.tasks = AutoDeleteRules.expiredTasks(model.tasks, now: now, days: prefs.days, includeUnfinished: prefs.includeUnfinishedTasks)
        p.checkpoints = model.checkpoints.filter { $0.repeatRule == nil && $0.at < cutoff }.map(\.id)
        return p
    }

    /// 実行する（何度呼んでも同じ結果。片づけ済みのものは対象に入らない）
    @discardableResult
    static func run(model: AppModel) -> Plan {
        let prefs = model.autoDeletePrefs
        let now = model.now
        let p = plan(model: model, prefs: prefs, now: now)
        guard !p.isEmpty else { return p }
        func mark(_ x: JSONValue?) -> JSONValue { (x ?? .object([:])).merging(.object(["archivedAt": .number(Double(now))])) }
        model.perform {
            for id in p.events { if var e = model.events.first(where: { $0.id == id }) { e.extra = mark(e.extra); try? model.repo.saveEvent(e, isNew: false) } }
            for id in p.tasks { if var t = model.tasks.first(where: { $0.id == id }) { t.extra = mark(t.extra); try? model.repo.saveTask(t, isNew: false) } }
            for id in p.purgeEvents { try? model.repo.deleteEvent(id) }
            for id in p.purgeTasks { try? model.repo.deleteTask(id) }
        }
        if !p.checkpoints.isEmpty {
            model.updateSettings { s in
                let list = (s.raw[AppModel.checkpointsKey]?.arrayValue ?? []).filter { !p.checkpoints.contains($0["id"]?.stringValue ?? "") }
                s.raw = s.raw.merging(.object([AppModel.checkpointsKey: .array(list)]))
            }
        }
        return p
    }

    /// 片づけたものを元に戻す（設定画面から）
    static func restoreAll(model: AppModel) {
        func unmark(_ x: JSONValue?) -> JSONValue? {
            guard var o = x?.objectValue else { return x }
            o["archivedAt"] = nil
            return .object(o)
        }
        model.perform("片づけた予定・タスクを戻しました") {
            for var e in model.archivedEvents { e.extra = unmark(e.extra); try? model.repo.saveEvent(e, isNew: false) }
            for var t in model.archivedTasks { t.extra = unmark(t.extra); try? model.repo.saveTask(t, isNew: false) }
        }
    }
}
