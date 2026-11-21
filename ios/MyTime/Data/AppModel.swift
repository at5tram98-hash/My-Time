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
    let chatGPT = ChatGPTLiveConnection()

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
        Prefs.apply()
        load()
        // 朝の自動配置（予定を変えたらすぐ付いて動く）。変えたら読み直す
        if !isPreview, placeMornings() { load() }
        scheduleNotifications()
        chatGPT.changed(self)
        // 起床アラームは読み直しの後で（保存がまた読み直しを呼ぶため、入れ子にしない）
        DispatchQueue.main.async { [weak self] in self?.syncWakeAlarms() }
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

    // MARK: 朝の自動配置（今日と明日。最初の「自分」の予定の2時間前）

    /// 予定が変わったら朝も置き直す。手で動かした・始めた朝はそのまま（MorningAuto）
    func autoPlaceMornings() {
        // 前の日から続いたままの朝は終わりにする（ロック画面に「経過25時間」と出続けないように）
        var m = morning
        if m.closeStale(now: now) { saveMorning(m) }
        if placeMornings() { reload() }
        syncWakeAlarms()
    }

    /// 自動の起床アラーム（これから7日分）。最初の予定・移動時間・準備の見込みから、ゆとりを持った時刻を毎回計算する。
    /// 予定が変わるたびに通知・アラームの予約し直しで入れ替わるので、アプリを開かなくても毎朝その日に合った時刻で鳴る
    var autoWakeAlarms: [WakeAlarm] {
        guard UserDefaults.standard.object(forKey: Self.autoWakeKey) as? Bool ?? true else { return [] }
        let prep = max(30, morning.estimate().minutes)
        return MorningAuto.wakeAlarms(now: now, prepMinutes: prep, time: time) { d in
            self.myEvents(from: d, to: self.time.addDays(d, 1))
                .filter { !$0.event.allDay && $0.start >= d }
                .min { $0.start < $1.start }
                .map { (start: $0.start, travel: $0.event.travelMinutes) }
        }
    }

    /// 前の形（曜日くり返しの「自動」アラームを朝の設定に入れていた）を外す
    func syncWakeAlarms() {
        guard !isPreview else { return }
        let r = morning
        let cleaned = MorningAuto.removeLegacyAutoAlarms(r)
        if cleaned.alarms != r.alarms { saveMorning(cleaned) }
    }
    static let autoWakeKey = "morning.autoWake"

    /// 置いた・動かした・外したら true
    private func placeMornings() -> Bool {
        let est = morning.estimate().minutes
        let minutes = est > 0 ? est : 60
        var changed = false
        // 試作の版が置いた形の古い朝（autoMorning が文字の日付）は外す（新しい形で置き直す）
        for t in tasks where t.extra?["autoMorning"]?.stringValue != nil && t.status == .notStarted {
            try? repo.deleteTask(t.id, byUser: false); changed = true
        }
        for i in 0..<2 {
            let d = time.addDays(time.startOfDay(now), i)
            let occ = expandAll(events, from: d, to: time.addDays(d, 1), time: time).filter { $0.event.calendarId == MTCalendar.selfId }
            if (try? repo.autoPlaceMorning(day: d, events: occ, minutes: minutes, time: time)) != nil { changed = true }
        }
        return changed
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
            autoPlaceMornings()
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
        let all = expandAll(includeArchived ? analysisEvents : events, from: from, to: to, time: time)
            .filter { !hidden.contains($0.event.calendarId) && !($0.event.specType.map(hiddenTypes.contains) ?? false) }
        // 「表示と動き」で「ほかの人の予定を出さない」にしたとき
        let shown = Prefs.hideOthers ? all.filter { $0.event.calendarId == MTCalendar.selfId } : all
        return includeStruck ? shown : shown.filter { !$0.isStruck }
    }
    /// 下に引っぱって最新にする：読み直し・朝の置き直し・ChatGPT の同期・ロック画面と通知の照合
    @MainActor
    func refreshAll() async {
        let started = Date()
        reload()
        autoPlaceMornings()
        await chatGPT.sync(self)
        LiveActivityCoordinator.shared.refresh(model: self)
        scheduleNotifications()
        // すぐ終わっても、引っぱった手応えが分かるよう少しだけ待つ
        let wait = 0.45 - Date().timeIntervalSince(started)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// ほかの人の予定をうすく出すか（「表示と動き」で選ぶ）
    func dimOther(_ calendarId: String?) -> Bool { isOtherPerson(calendarId) && Prefs.dimOthers }
    /// 「自分」の予定だけ（今日の画面・朝の目安。カレンダーの表示の切り替えに関係なく出す）
    func myEvents(from: EpochMs, to: EpochMs, includeStruck: Bool = false) -> [EventOccurrence] {
        let hiddenTypes = Set(specDisplay.filter { $0.value == "hidden" }.map(\.key))
        let all = expandAll(events, from: from, to: to, time: time)
            .filter { $0.event.calendarId == MTCalendar.selfId && !($0.event.specType.map(hiddenTypes.contains) ?? false) }
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
