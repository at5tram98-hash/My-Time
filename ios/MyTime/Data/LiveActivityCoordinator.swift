import Foundation
import SwiftUI
import MyTimeCore
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Live Activity（ロック画面・ダイナミックアイランド）を1か所で開始・更新・終了する。
///
/// - 候補（次の授業・バイト・朝・清掃・勉強・移動・実行中のタスク・チェックポイント）を予定とタスクから毎回作り直し、
///   LivePlanner の重要度で今出すものを決める。端末がどれをダイナミックアイランドに出すかは OS が決める。
/// - ID は「元の予定・タスクの ID ＋ 表示を始める時刻」。予定を動かす・消すと ID が変わり、古いものは終える（T-03）。
/// - iOS 26 以降は、これから始まる授業・バイトを「予約開始」しておく（アプリを開いていなくても時刻になると出る）。
///   それより前の iOS では予約できないため、アプリを開いたとき・通知を受けたときに始める（通知が代わりの手段）。
/// - アプリが動いていない間に終える仕組み（サーバーからのプッシュ）は無いため、終わる時刻を staleDate に入れ、
///   時刻を過ぎると「終了」と表示する。次にアプリを開いたときに終える。
@MainActor
final class LiveActivityCoordinator {
    static let shared = LiveActivityCoordinator()
    private var pending: Task<Void, Never>?
    private var ticker: Task<Void, Never>?

    struct Item {
        var candidate: LiveCandidate
        var content: MyTimeActivityAttributes.ContentState
        var endsAt: EpochMs
    }

    var activitiesEnabled: Bool {
        #if canImport(ActivityKit)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return false
        #endif
    }

    /// データが変わったとき（少し待ってまとめて照合する）
    func refresh(model: AppModel) {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.reconcile(model: model)
        }
    }

    /// アプリが前面にある間は1分ごとに照合する（授業の切り替え・バイトの開始15分前など）
    func startTicking(model: AppModel) {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.reconcile(model: model)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stopTicking() { ticker?.cancel(); ticker = nil }

    // MARK: 照合

    func reconcile(model: AppModel) async {
        #if canImport(ActivityKit)
        let now = model.now
        let prefs = model.livePrefs
        let items = candidates(model: model, now: now)
        let byId = Dictionary(items.map { ($0.candidate.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = LivePlanner.select(items.map(\.candidate), now: now, disabled: prefs.disabled, limit: max(1, min(2, prefs.maxConcurrent)))
        var keep = Set(live.map(\.id))
        // 予約開始（iOS 26 以降）：これから12時間の授業・バイト・移動を2件まで
        var schedule: [Item] = []
        if #available(iOS 26.0, *) {
            schedule = LivePlanner.upcoming(items.map(\.candidate), now: now, disabled: prefs.disabled, within: 12 * HOUR)
                .filter { [.classNext, .shift, .transit].contains($0.kind) }
                .prefix(2).compactMap { byId[$0.id] }
            keep.formUnion(schedule.map(\.candidate.id))
        }
        let existing = Activity<MyTimeActivityAttributes>.activities
        // 要らなくなったもの（予定の変更・削除・終了・無効にした種類）を終える
        for a in existing where !keep.contains(a.attributes.sourceId) || a.activityState == .ended {
            await a.end(nil, dismissalPolicy: .immediate)
        }
        let running = Set(existing.filter { keep.contains($0.attributes.sourceId) && $0.activityState != .ended && $0.activityState != .dismissed }.map(\.attributes.sourceId))
        // 今出すもの：あれば内容を更新、なければ始める
        for c in live {
            guard let item = byId[c.id] else { continue }
            let content = ActivityContent(state: item.content, staleDate: model.time.date(item.endsAt), relevanceScore: Double(c.priority))
            if let a = existing.first(where: { $0.attributes.sourceId == c.id }), running.contains(c.id) {
                if a.content.state != item.content { await a.update(content) }
            } else {
                _ = try? Activity.request(attributes: MyTimeActivityAttributes(kind: c.kind.rawValue, sourceId: c.id), content: content, pushType: nil)
            }
        }
        if #available(iOS 26.0, *) {
            for item in schedule where !running.contains(item.candidate.id) {
                let content = ActivityContent(state: item.content, staleDate: model.time.date(item.endsAt), relevanceScore: Double(item.candidate.priority))
                let alert = AlertConfiguration(title: LocalizedStringResource(stringLiteral: item.content.title), body: LocalizedStringResource(stringLiteral: item.content.detail ?? ""), sound: .default)
                _ = try? Activity.request(attributes: MyTimeActivityAttributes(kind: item.candidate.kind.rawValue, sourceId: item.candidate.id),
                                          content: content, pushType: nil, style: .standard, alertConfiguration: alert,
                                          start: model.time.date(item.candidate.showFrom))
            }
        }
        #endif
    }

    /// すべて終える（設定でオフにしたとき）
    func endAll() async {
        #if canImport(ActivityKit)
        for a in Activity<MyTimeActivityAttributes>.activities { await a.end(nil, dismissalPolicy: .immediate) }
        #endif
    }

    /// いま出ているもの（設定画面の確認用）
    var activeSummaries: [String] {
        #if canImport(ActivityKit)
        return Activity<MyTimeActivityAttributes>.activities.filter { $0.activityState == .active || "\($0.activityState)" == "pending" }
            .map { "\(LiveKind(rawValue: $0.attributes.kind)?.label ?? "")：\($0.content.state.title)" + ("\($0.activityState)" == "pending" ? "（予約）" : "") }
        #else
        return []
        #endif
    }

    // MARK: 候補を作る

    func candidates(model: AppModel, now: EpochMs) -> [Item] {
        var out: [Item] = []
        let time = model.time
        let prefs = model.livePrefs
        let occ = model.visibleEvents(from: now - 12 * HOUR, to: time.addDays(time.startOfDay(now), 2))
        func range(_ s: EpochMs, _ e: EpochMs) -> String { "\(time.hm(s))〜\(time.hm(e))" }
        func date(_ t: EpochMs) -> Date { time.date(t) }

        // 授業：次の授業を1つ（休講＝取り消した回は occ に入らない。教室の変更はそのまま反映される）
        let isClass: (MTEvent) -> Bool = { e in e.specType == .class || e.classInfo != nil || model.calendar(e.calendarId)?.kind == .class }
        if let c = LivePlanner.nextClass(occ, isClass: isClass, now: now, endAfterStartMinutes: prefs.classEndAfterStart) {
            let room = (c.event.extra?["spec"]?["details"]?["room"]?.stringValue ?? c.event.classInfo?["room"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 }
            let from = c.start - EpochMs(prefs.classLeadMinutes) * MINUTE
            let until = c.start + EpochMs(prefs.classEndAfterStart) * MINUTE
            let quiz = c.event.extra?["spec"]?["details"]?["quizAt"]?.intValue.map { time.isSameDay($0, c.start) } ?? false
            out.append(Item(
                candidate: LiveCandidate(id: "class:\(c.id)@\(from)", kind: .classNext, showFrom: from, showUntil: until, start: c.start),
                content: .init(title: c.title, headline: room.map { $0.hasSuffix("教室") ? $0 : "\($0)教室" }, detail: range(c.start, c.end),
                               countdownTo: date(c.start), status: quiz ? "小テストあり" : nil, endsAt: date(until),
                               tint: model.eventColor(c.event), symbol: "graduationcap.fill", url: "mytime://event/\(c.id)", canComplete: false),
                endsAt: until))
        }

        // バイト：勤務先の開始前の分数から、終わるまで
        for o in occ where !o.event.allDay && o.end > now {
            let emp = model.employer(o.event.employerId)
            guard emp != nil || o.event.specType == .shift || model.calendar(o.event.calendarId)?.kind == .job else { continue }
            let p = emp?.pay ?? PayProfile()
            let from = o.start - EpochMs(p.noticeMinutes) * MINUTE
            let status = now < o.start ? "開始まで" : "勤務中"
            let name = emp?.name ?? o.title
            out.append(Item(
                candidate: LiveCandidate(id: "shift:\(o.id)@\(from)", kind: .shift, showFrom: from, showUntil: o.end, start: o.start),
                content: .init(title: name.contains("勤務") ? name : "\(name)勤務", headline: p.address.isEmpty ? nil : p.address, detail: range(o.start, o.end),
                               countdownTo: date(now < o.start ? o.start : o.end), status: now < o.start ? status : "勤務中・終了まで", endsAt: date(o.end),
                               tint: emp.map { $0.pay.color } ?? model.eventColor(o.event), symbol: p.symbol, url: "mytime://event/\(o.id)", canComplete: false),
                endsAt: o.end))
        }

        // 移動：出発の何分前から出発まで（移動時間が入っている予定だけ。根拠のない出発時刻は出さない）
        for o in occ where !o.event.allDay {
            guard let tm = o.event.travelMinutes, tm > 0 else { continue }
            let leave = o.start - EpochMs(tm) * MINUTE
            guard leave + 5 * MINUTE > now else { continue }
            let from = leave - EpochMs(prefs.transitLeadMinutes) * MINUTE
            out.append(Item(
                candidate: LiveCandidate(id: "transit:\(o.id)@\(from)", kind: .transit, showFrom: from, showUntil: leave + 5 * MINUTE, start: leave),
                content: .init(title: "\(o.title)へ出発", headline: o.event.placeName, detail: "\(time.hm(leave))発・\(time.hm(o.start))開始",
                               countdownTo: date(leave), endsAt: date(leave + 5 * MINUTE),
                               tint: model.eventColor(o.event), symbol: "figure.walk", url: "mytime://event/\(o.id)", canComplete: false),
                endsAt: leave + 5 * MINUTE))
        }

        // 朝：実行中の朝
        let m = model.morning
        if let r = m.active, r.finishedAt == nil, let cur = r.current {
            let elapsed = r.elapsed(now: now)
            out.append(Item(
                candidate: LiveCandidate(id: "morning:\(r.id)", kind: .morning, showFrom: r.startedAt, showUntil: now + 4 * HOUR, start: r.startedAt),
                content: .init(title: cur.name, headline: cur.name, detail: "\(cur.group)・全\(r.steps.count)工程中 \(r.index + 1)工程目",
                               elapsedFrom: date(now - elapsed), pausedElapsed: r.isPaused ? Double(elapsed) / 1000 : nil,
                               progressDone: r.doneCount, progressTotal: r.steps.count, next: r.next?.name, status: r.isPaused ? "一時停止中" : nil,
                               tint: "#FF9F0A", symbol: "sunrise.fill", url: "mytime://morning", canComplete: true),
                endsAt: now + 4 * HOUR))
        }

        // 清掃：実行中の清掃
        let book = model.cleaning
        if let s = book.active {
            let st = s.statuses(in: book.areas)
            let c = CleaningSession.completion(st.map(\.status))
            let nextItem = st.first { $0.status == .no }
            let areaName = book.areas.filter { s.areaIds.contains($0.id) }.map(\.name).joined(separator: "・")
            out.append(Item(
                candidate: LiveCandidate(id: "cleaning:\(s.id)", kind: .cleaning, showFrom: s.startedAt, showUntil: now + 4 * HOUR, start: s.startedAt),
                content: .init(title: "清掃", headline: areaName, detail: "完了 \(c.done)・残り \(c.total - c.done)", elapsedFrom: date(s.startedAt),
                               progressDone: c.done, progressTotal: c.total, next: nextItem?.item.name,
                               tint: "#30B0C7", symbol: "bubbles.and.sparkles.fill", url: "mytime://cleaning", canComplete: false),
                endsAt: now + 4 * HOUR))
        }

        // 実行中のタスク（勉強は種類で分ける）
        for t in model.tasks where t.status == .running {
            let study = t.specType?.isExamLike == true || t.specType == .assignment || t.specType == .report || t.extra?["studyFor"] != nil
            let worked = workedMs(t, at: now)
            let kind: LiveKind = study ? .study : .task
            let until = max(now + HOUR, (t.plannedEnd ?? now) + HOUR)
            out.append(Item(
                candidate: LiveCandidate(id: "task:\(t.id)", kind: kind, showFrom: now - MINUTE, showUntil: until, start: t.plannedStart ?? now),
                content: .init(title: t.title, headline: nil, detail: t.plannedEnd.map { "\(time.hm($0))までの予定" },
                               elapsedFrom: date(now - worked), status: study ? "集中" : "実行中",
                               tint: study ? "#5E5CE6" : "#34C759", symbol: study ? "book.fill" : "play.circle.fill", url: "mytime://task/\(t.id)", canComplete: false),
                endsAt: until))
        }

        // チェックポイント：何分前から、その時刻まで
        for c in (0..<2).flatMap({ model.checkpoints(on: time.addDays(time.startOfDay(now), $0)) }) where c.at > now {
            let from = c.at - EpochMs(prefs.checkpointLeadMinutes) * MINUTE
            out.append(Item(
                candidate: LiveCandidate(id: "cp:\(c.id)@\(c.at)", kind: .checkpoint, showFrom: from, showUntil: c.at + MINUTE, start: c.at),
                content: .init(title: c.title.isEmpty ? "チェックポイント" : c.title, detail: time.hm(c.at), countdownTo: date(c.at), endsAt: date(c.at + MINUTE),
                               tint: "#FF9F0A", symbol: "flag.checkered", url: "mytime://checkpoint/\(c.id)", canComplete: false),
                endsAt: c.at + MINUTE))
        }
        return out
    }
}

/// Live Activity のボタン（ロック画面・ダイナミックアイランド）から呼ばれる操作。アプリの中で実行する
@MainActor
enum LiveActions {
    static func handle(kind: String, value: String, model: AppModel) async {
        switch kind {
        case "morning":
            var x = model.morning
            guard var run = x.active else { return }
            let now = model.now
            switch value {
            case "complete": run.complete(now: now)
            case "skip": run.complete(now: now, skipped: true)
            case "back": run.back(now: now)
            case "pause": run.isPaused ? run.resume(now: now) : run.pause(now: now)
            default: return
            }
            x.active = run
            if run.finishedAt != nil { x.finishActive() }
            model.saveMorning(x)
        case "finishTask":
            model.perform("完了しました", undo: { try model.repo.taskAction(value, .undoFinish) }) { try model.repo.taskAction(value, .finish) }
        default: break
        }
        await LiveActivityCoordinator.shared.reconcile(model: model)
    }
}
