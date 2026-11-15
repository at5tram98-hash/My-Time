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
    private(set) var settings = AppSettings(json: nil)
    private(set) var outboxPending = 0

    /// 画面下に短く出す知らせ（取り消し付きのこともある）
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
        settings = repo.settings()
        outboxPending = repo.store.outbox().filter { $0["synced"]?.intValue == 0 }.count
    }

    var now: EpochMs { EpochMs(Date().timeIntervalSince1970 * 1000) }

    /// 書き込みを行い、失敗したら理由を表示する（入力・データはそのまま）
    @discardableResult
    func perform(_ message: String? = nil, undo: (() throws -> Void)? = nil, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            reload()
            if let message {
                toast = Toast(text: message, undo: undo.map { u in { [weak self] in self?.perform { try u() } } })
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
        return expandAll(events.filter { !hidden.contains($0.calendarId) }, from: from, to: to, time: time)
    }
    func eventColor(_ e: MTEvent) -> String { e.colorOverride ?? calendar(e.calendarId)?.color ?? "#0A84FF" }
    func employer(_ id: String?) -> MTEmployer? { employers.first { $0.id == id } }

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
