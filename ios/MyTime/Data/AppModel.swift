import Foundation
import Observation
import SwiftData
import MyTimeCore

/// 画面全体で共有する状態。書き込みはすべて Repository を通し、終わったら読み直して画面に反映する。
@MainActor
@Observable
final class AppModel {
    let repo: Repository
    let time = DomainTime.current

    private(set) var tasks: [MTTask] = []
    private(set) var events: [MTEvent] = []
    private(set) var calendars: [MTCalendar] = []
    private(set) var subtasks: [MTSubtask] = []
    private(set) var employers: [MTEmployer] = []
    /// Create Studio の種類（自分専用の種類）
    private(set) var studioTypes: [StudioType] = []
    private(set) var settings = AppSettings(json: nil)
    private(set) var outboxPending = 0
    /// 種類ごとのカレンダーへの出し方（normal / quiet / hidden）。設定を読み直すたびに作る
    private(set) var specDisplay: [SpecTypeId: String] = [:]

    /// 直前の操作（画面には出さない。iPhone を振ると取り消せる）
    var toast: Toast?
    var errorMessage: String?

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var undo: (() -> Void)?
        static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
    }

    init(store: RecordStore) {
        repo = Repository(store: store)
        try? repo.ensureDefaults()
        reload()
    }

    static func live(container: ModelContainer) -> AppModel {
        AppModel(store: SwiftDataStore(context: container.mainContext))
    }

    func reload() {
        tasks = repo.tasks()
        events = repo.events()
        calendars = repo.calendars()
        subtasks = repo.subtasks()
        employers = repo.employers()
        studioTypes = repo.studioTypes()
        settings = repo.settings()
        var disp: [SpecTypeId: String] = [:]
        for (k, v) in settings.raw["iosSpecSettings"]?.objectValue ?? [:] {
            if let t = SpecTypeId(rawValue: k), let d = v["calendarDisplay"]?.stringValue, d != "normal" { disp[t] = d }
        }
        specDisplay = disp
        outboxPending = repo.store.outbox().filter { $0["synced"]?.intValue == 0 }.count
        scheduleNotifications()
    }

    // MARK: 通知（端末内の予約。変更のたびに少し待ってから予約し直す）

    @ObservationIgnored private var notifyTask: Task<Void, Never>?
    private var isPreview: Bool { ProcessInfo.processInfo.arguments.contains("-inMemory") }

    func scheduleNotifications() {
        guard !isPreview else { return }
        notifyTask?.cancel()
        notifyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            await NotificationScheduler.reschedule(model: self)
        }
    }

    /// iOS 版だけの設定（Web 版の設定に項目を足すだけ。Web 版は知らない項目を無視する）
    var notificationsEnabled: Bool { settings.raw["iosNotifications"]?.boolValue ?? false }
    var notifyMinutesBefore: Int { settings.raw["iosNotifyMinutes"]?.intValue.map(Int.init) ?? 10 }
    func setNotifications(enabled: Bool? = nil, minutes: Int? = nil) {
        updateSettings { s in
            var o: [String: JSONValue] = [:]
            if let enabled { o["iosNotifications"] = .bool(enabled) }
            if let minutes { o["iosNotifyMinutes"] = .number(Double(minutes)) }
            s.raw = s.raw.merging(.object(o))
        }
    }

    var planOptions: PlanOptions { PlanOptions(fromHour: settings.suggestFromHour, toHour: settings.suggestToHour) }

    var now: EpochMs { EpochMs(Date().timeIntervalSince1970 * 1000) }

    /// 書き込みを行い、失敗したら理由を表示する（入力・データはそのまま）
    @discardableResult
    func perform(_ message: String? = nil, undo: (() throws -> Void)? = nil, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            reload()
            // 取り消せる操作だけを覚えておく（知らせは表示しない）
            if let undo {
                toast = Toast(text: message ?? "直前の変更", undo: { [weak self] in self?.perform { try undo() } })
            }
            return true
        } catch {
            errorMessage = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
            return false
        }
    }

    // MARK: 読み取りの補助

    func subtasks(of taskId: String) -> [MTSubtask] { subtasks.filter { $0.taskId == taskId } }
    func calendar(_ id: String?) -> MTCalendar? { calendars.first { $0.id == id } }
    func visibleEvents(from: EpochMs, to: EpochMs) -> [EventOccurrence] {
        let hidden = Set(calendars.filter { !$0.visible }.map(\.id))
        // 種類の設定で「出さない」にした種類は出さない
        let hiddenTypes = Set(specDisplay.filter { $0.value == "hidden" }.map(\.key))
        return expandAll(events.filter { !hidden.contains($0.calendarId) && !($0.specType.map(hiddenTypes.contains) ?? false) }, from: from, to: to, time: time)
    }
    func eventColor(_ e: MTEvent) -> String { e.colorOverride ?? calendar(e.calendarId)?.color ?? "#0A84FF" }
    func employer(_ id: String?) -> MTEmployer? { employers.first { $0.id == id } }
    func studioType(_ id: String?) -> StudioType? { studioTypes.first { $0.id == id } }

    /// 未割当（時間を決めていない実行タスク）
    var inbox: [MTTask] { tasks.filter { $0.kind == .do && !$0.isDone && $0.plannedStart == nil }.sorted { ($0.deadline ?? .max) < ($1.deadline ?? .max) } }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        repo.updateSettings(change)
        reload()
    }
}

/// 時刻と日付の表示
extension AppModel {
    func hm(_ t: EpochMs) -> String { time.hm(t) }
    func dayTitle(_ t: EpochMs) -> String {
        let c = time.calendar.dateComponents([.month, .day], from: time.date(t))
        return "\(c.month ?? 0)月\(c.day ?? 0)日 \(DomainTime.weekdayJa[time.weekday(t)])曜日"
    }
}
