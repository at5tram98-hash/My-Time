import Foundation
import SwiftUI
import Observation
import SwiftData
import MyTimeCore

/// 画面全体で共有する状態。書き込みはすべて Repository を通し、終わったら読み直して画面に反映する。
@MainActor
@Observable
final class AppModel {
    let repo: Repository
    let time = DomainTime.current

    /// 画面に出す予定・タスク（自動削除で片づけたものは含まない）
    private(set) var tasks: [MTTask] = []
    private(set) var events: [MTEvent] = []
    /// 自動削除で片づけた予定・タスク（1か月は分析のために中に残す）
    private(set) var archivedTasks: [MTTask] = []
    private(set) var archivedEvents: [MTEvent] = []
    /// 分析（振り返り）用：片づけたものも含む
    var analysisTasks: [MTTask] { tasks + archivedTasks }
    var analysisEvents: [MTEvent] { events + archivedEvents }
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
    /// 保存先を開けず、メモリ上で動いているとき（変更は保存されない）。画面の上に出し続ける
    var storeFailure: String?

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
        // カレンダーは「自分」「みお」の2つ（取り込みで増えても、ここでまとめる。済んでいれば何もしない）
        _ = try? repo.consolidateCalendars()
        load()
        // 朝の自動配置（予定が変わったら付いて動く）。変えたら読み直す
        if !isPreview, placeMorningsIfNeeded() { load() }
        scheduleNotifications()
    }

    private func load() {
        let allTasks = repo.tasks(), allEvents = repo.events()
        tasks = allTasks.filter { !$0.isArchived }
        archivedTasks = allTasks.filter(\.isArchived)
        events = allEvents.filter { !$0.isArchived }
        archivedEvents = allEvents.filter(\.isArchived)
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
            // ロック画面・Dynamic Island もすぐ合わせる（予定の取り消し・削除・移動が1分待たずに反映される。まとめて照合）
            LiveActivityCoordinator.shared.refresh(model: self)
            // 取り消せる操作だけを覚えておく（知らせは表示しない）
            if let undo {
                toast = Toast(text: message ?? "直前の変更", undo: { [weak self] in self?.perform { try undo() } })
            }
            return true
        } catch {
            errorMessage = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
            if !(error is RepositoryError) { Diagnostics.failure("save", error, context: "保存") }
            reload()
            return false
        }
    }

    // MARK: 読み取りの補助

    func subtasks(of taskId: String) -> [MTSubtask] { subtasks.filter { $0.taskId == taskId } }
    func calendar(_ id: String?) -> MTCalendar? { calendars.first { $0.id == id } }
    /// 「自分」（最初のカレンダー）以外の人の予定か。時間軸の札では、ほかの人の予定にだけ人のしるしを付ける
    func isOtherPerson(_ calendarId: String?) -> Bool { calendarId != nil && calendarId != MTCalendar.selfId && calendars.count > 1 }
    /// 人ごとの表示・非表示（隠すだけで予定は消えない）
    func setCalendarVisible(_ id: String, _ visible: Bool) {
        _ = perform(visible ? "表示しました" : "隠しました", undo: { try self.repo.setCalendarVisible(id, !visible) }) { try repo.setCalendarVisible(id, visible) }
    }
    /// 表示する予定。取り消した予定は既定で含めない（通知・ロック画面・給与・計画・分析に使わない）。
    /// カレンダーと今日の時間軸だけ includeStruck: true で灰色に出す
    func visibleEvents(from: EpochMs, to: EpochMs, includeArchived: Bool = false, includeStruck: Bool = false) -> [EventOccurrence] {
        let hidden = Set(calendars.filter { !$0.visible }.map(\.id))
        // 種類の設定で「出さない」にした種類は出さない
        let hiddenTypes = Set(specDisplay.filter { $0.value == "hidden" }.map(\.key))
        let all = expandAll((includeArchived ? analysisEvents : events).filter { !hidden.contains($0.calendarId) && !($0.specType.map(hiddenTypes.contains) ?? false) }, from: from, to: to, time: time)
        return includeStruck ? all : all.filter { !$0.isStruck }
    }
    /// 予定の色：自分で決めた色 → 勤務先の色（勤務先の画面で決めたとき）→ カレンダーの色
    func eventColor(_ e: MTEvent) -> String {
        e.colorOverride ?? employer(e.employerId).flatMap { $0.raw["pay"] != nil ? $0.pay.color : nil }
            // 「自分」の中の授業・勤務は種類の色（カレンダーをまとめても見分けられるように）
            ?? (e.calendarId == MTCalendar.selfId ? e.specType.flatMap { $0 == .class || $0 == .shift ? SPEC_BY_ID[$0]?.color : nil } : nil)
            ?? calendar(e.calendarId)?.color ?? "#0A84FF"
    }
    /// 回の色（取り消した回は灰色）
    func occurrenceColor(_ o: EventOccurrence) -> Color { o.isStruck ? Color.gray : Color(hex: eventColor(o.event)) }
    func employer(_ id: String?) -> MTEmployer? { employers.first { $0.id == id } }
    func studioType(_ id: String?) -> StudioType? { studioTypes.first { $0.id == id } }

    /// 未割当（時間を決めていない実行タスク）
    var inbox: [MTTask] { tasks.filter { $0.kind == .do && !$0.isDone && $0.plannedStart == nil && $0.onDay == nil }.sorted { ($0.deadline ?? .max) < ($1.deadline ?? .max) } }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        repo.updateSettings(change)
        // 保存に失敗したら、変更は取り消されている（画面は読み直した保存済みの値になる）
        if let e = (repo.store as? SwiftDataStore)?.lastSaveError {
            errorMessage = "保存できませんでした。変更は元に戻しました。（\(Diagnostics.describe(e))）"
        }
        reload()
    }

    /// 直前の設定の保存が成功したか
    var lastSaveSucceeded: Bool { (repo.store as? SwiftDataStore)?.lastSaveError == nil }
}

/// 時刻と日付の表示
extension AppModel {
    func hm(_ t: EpochMs) -> String { time.hm(t) }
    func dayTitle(_ t: EpochMs) -> String {
        let c = time.calendar.dateComponents([.month, .day], from: time.date(t))
        return "\(c.month ?? 0)月\(c.day ?? 0)日 \(DomainTime.weekdayJa[time.weekday(t)])曜日"
    }
}
