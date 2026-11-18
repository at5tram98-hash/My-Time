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
        /// この時刻で表示が古くなる（開始前は開始時刻、進行中は終了時刻）。表示側が次の段階へ移る
        var staleAt: EpochMs
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

    /// 照合の結果（設定の診断に出す）
    struct Report { var active = 0; var scheduled = 0; var ended = 0; var failed = 0; var at = Date() }
    private(set) var lastReport = Report()

    @discardableResult
    func reconcile(model: AppModel) async -> Report {
        var r = Report()
        #if canImport(ActivityKit)
        guard activitiesEnabled else {
            lastReport = r
            return r
        }
        let now = model.now
        let prefs = model.livePrefs
        let items = candidates(model: model, now: now)
        let byId = Dictionary(items.map { ($0.candidate.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = LivePlanner.select(items.map(\.candidate), now: now, disabled: prefs.disabled, limit: max(1, min(2, prefs.maxConcurrent)))
        var keep = Set(live.map(\.id))
        // 予約開始（iOS 26 以降）：これから24時間の授業・バイト・移動・チェックポイントを、近いものから4件まで。
        // 5件目以降は予約せず、近づいたときの照合（アプリを開いたとき）と通知で補う
        var schedule: [Item] = []
        if #available(iOS 26.0, *) {
            let up = LivePlanner.upcoming(items.map(\.candidate), now: now, disabled: prefs.disabled, within: 24 * HOUR)
                .filter { [.classNext, .shift, .transit, .checkpoint].contains($0.kind) }
            schedule = up.prefix(4).compactMap { byId[$0.id] }
            keep.formUnion(schedule.map(\.candidate.id))
            if up.count > 4 { Diagnostics.record("live", ok: true, "予約は近い4件まで（残り\(up.count - 4)件は近づいてから）") }
        }
        let existing = Activity<MyTimeActivityAttributes>.activities
        // 要らなくなったもの（予定の変更・削除・取り消し・終了・無効にした種類）を終える。予約中（pending）も同じ
        for a in existing where !keep.contains(a.attributes.sourceId) || a.activityState == .ended {
            await a.end(nil, dismissalPolicy: .immediate)
            r.ended += 1
        }
        // 同じ ID が2つあれば1つだけ残す（重複の防止）
        var seen = Set<String>()
        for a in existing where keep.contains(a.attributes.sourceId) && a.activityState != .ended && a.activityState != .dismissed {
            if !seen.insert(a.attributes.sourceId).inserted { await a.end(nil, dismissalPolicy: .immediate); r.ended += 1 }
        }
        let running = Set(existing.filter { keep.contains($0.attributes.sourceId) && $0.activityState != .ended && $0.activityState != .dismissed }.map(\.attributes.sourceId))
        // 今出すもの：あれば内容を更新、なければ始める
        for c in live {
            guard let item = byId[c.id] else { continue }
            let content = ActivityContent(state: item.content, staleDate: model.time.date(item.staleAt), relevanceScore: Double(c.priority))
            if let a = existing.first(where: { $0.attributes.sourceId == c.id }), running.contains(c.id) {
                if a.content.state != item.content || a.content.staleDate != content.staleDate { await a.update(content) }
                r.active += 1
            } else {
                do {
                    _ = try Activity.request(attributes: MyTimeActivityAttributes(kind: c.kind.rawValue, sourceId: c.id), content: content, pushType: nil)
                    r.active += 1
                } catch {
                    r.failed += 1
                    Diagnostics.failure("live", error, context: "\(c.kind.label)の表示を始められませんでした")
                }
            }
        }
        if #available(iOS 26.0, *) {
            for item in schedule where !running.contains(item.candidate.id) {
                let content = ActivityContent(state: item.content, staleDate: model.time.date(item.staleAt), relevanceScore: Double(item.candidate.priority))
                let alert = AlertConfiguration(title: LocalizedStringResource(stringLiteral: item.content.title), body: LocalizedStringResource(stringLiteral: item.content.detail ?? ""), sound: .default)
                do {
                    _ = try Activity.request(attributes: MyTimeActivityAttributes(kind: item.candidate.kind.rawValue, sourceId: item.candidate.id),
                                             content: content, pushType: nil, style: .standard, alertConfiguration: alert,
                                             start: model.time.date(item.candidate.showFrom))
                    r.scheduled += 1
                } catch {
                    r.failed += 1
                    Diagnostics.failure("live", error, context: "\(item.candidate.kind.label)の予約ができませんでした（通知で知らせます）")
                }
            }
            r.scheduled += schedule.filter { running.contains($0.candidate.id) }.count
        }
        if r.failed == 0 { Diagnostics.record("live", ok: true, "表示 \(r.active)件・予約 \(r.scheduled)件") }
        #endif
        lastReport = r
        return r
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

    /// 短くする（Compact に入れる。長い名前は先頭だけ）
    static func short(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count <= n ? t : String(t.prefix(n))
    }

    /// 教室の表示。数字だけなら「5302教室」、そうでなければ入力のまま（勝手に読み替えない）
    static func roomText(_ raw: String) -> (full: String, code: String) {
        let r = raw.trimmingCharacters(in: .whitespaces)
        if r.hasSuffix("教室") { return (r, String(r.dropLast(2))) }
        if r.allSatisfy({ $0.isNumber || $0 == "-" }) { return ("\(r)教室", r) }
        return ("教室：\(r)", short(r, 6))
    }

    func candidates(model: AppModel, now: EpochMs) -> [Item] {
        var out: [Item] = []
        let time = model.time
        let prefs = model.livePrefs
        let privacy = prefs.privacy
        let occ = model.visibleEvents(from: now - 12 * HOUR, to: time.addDays(time.startOfDay(now), 2))
        func range(_ s: EpochMs, _ e: EpochMs) -> String {
            // 日をまたぐときは終わりに「翌」
            "\(time.hm(s))〜" + (time.isSameDay(s, e - 1) ? "" : "翌") + time.hm(e)
        }
        func date(_ t: EpochMs) -> Date { time.date(t) }
        /// 時刻で決まる段階：開始前は開始時刻で stale、進行中は終了時刻で stale
        func timed(start: EpochMs, end: EpochMs) -> (phase: String, stale: EpochMs) { now < start ? ("before", start) : ("active", end) }
        /// 詳細スケジュールの「いま」「次」（人前モードでは出さない）
        func sub(_ o: EventOccurrence) -> (now: String?, next: String?) {
            guard !privacy else { return (nil, nil) }
            let xs = SubSchedule.items(o.event.extra).filter { $0.lane == .event || !$0.done }
            let m = Int((now - o.start) / MINUTE)
            let nx = xs.first { $0.startMin > m }
            return (SubSchedule.current(xs, minute: m)?.title, nx.map { "\($0.title) \(time.hm(o.start + EpochMs($0.startMin) * MINUTE))" })
        }
        /// 場所がある予定は、ロック画面から Apple マップの経路を開ける
        func route(_ o: EventOccurrence) -> String? {
            guard !privacy, let p = o.event.placeName, !p.isEmpty else { return nil }
            return "mytime://route/\(o.id)"
        }

        // 授業：次の授業を1つ（休講＝取り消し・削除した回は occ に入らない。教室の変更はそのまま反映される）
        let isClass: (MTEvent) -> Bool = { e in e.specType == .class || e.classInfo != nil || model.calendar(e.calendarId)?.kind == .class }
        if let c = LivePlanner.nextClass(occ, isClass: isClass, now: now, endAfterStartMinutes: prefs.classEndAfterStart) {
            let rawRoom = (c.event.extra?["spec"]?["details"]?["room"]?.stringValue ?? c.event.classInfo?["room"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 }
            let room = rawRoom.map(Self.roomText)
            let from = c.start - EpochMs(prefs.classLeadMinutes) * MINUTE
            let until = c.start + EpochMs(prefs.classEndAfterStart) * MINUTE
            let quiz = c.event.extra?["spec"]?["details"]?["quizAt"]?.intValue.map { time.isSameDay($0, c.start) } ?? false
            let t = timed(start: c.start, end: until)
            out.append(Item(
                candidate: LiveCandidate(id: "class:\(c.id)@\(from)", kind: .classNext, showFrom: from, showUntil: until, start: c.start),
                content: .init(title: privacy ? "授業" : c.title, headline: privacy ? nil : room?.full, detail: range(c.start, c.end),
                               countdownTo: date(c.start), status: quiz && !privacy ? "小テストあり" : nil, endsAt: date(c.end),
                               tint: model.eventColor(c.event), symbol: "graduationcap.fill", url: "mytime://event/\(c.id)", canComplete: false,
                               compactLeading: privacy ? nil : room?.code, phase: t.phase,
                               subNow: sub(c).now, subNext: sub(c).next, routeURL: route(c)),
                staleAt: t.stale))
        }

        // バイト：勤務先の開始前の分数から、終わるまで。Compact は勤務先の略称（住所は出さない）
        for o in occ where !o.event.allDay && o.end > now {
            let emp = model.employer(o.event.employerId)
            guard emp != nil || o.event.specType == .shift || model.calendar(o.event.calendarId)?.kind == .job else { continue }
            let p = emp?.pay ?? PayProfile()
            let from = o.start - EpochMs(p.noticeMinutes) * MINUTE
            let name = emp?.name ?? o.title
            let t = timed(start: o.start, end: o.end)
            out.append(Item(
                candidate: LiveCandidate(id: "shift:\(o.id)@\(from)", kind: .shift, showFrom: from, showUntil: o.end, start: o.start),
                content: .init(title: privacy ? "勤務" : (name.contains("勤務") ? name : "\(name)勤務"),
                               headline: "\(time.hm(o.start)) 出勤", detail: range(o.start, o.end),
                               countdownTo: date(o.start), endsAt: date(o.end),
                               tint: emp.map { $0.pay.color } ?? model.eventColor(o.event), symbol: p.symbol, url: "mytime://event/\(o.id)", canComplete: false,
                               compactLeading: privacy ? nil : Self.short(name, 4), phase: t.phase,
                               subNow: sub(o).now, subNext: sub(o).next, routeURL: route(o)),
                staleAt: t.stale))
        }

        // 移動：出発の何分前から出発まで（移動時間が入っている予定だけ。根拠のない出発時刻は出さない）
        for o in occ where !o.event.allDay {
            guard let tm = o.event.travelMinutes, tm > 0 else { continue }
            let leave = o.start - EpochMs(tm) * MINUTE
            guard leave + 5 * MINUTE > now else { continue }
            let from = leave - EpochMs(prefs.transitLeadMinutes) * MINUTE
            out.append(Item(
                candidate: LiveCandidate(id: "transit:\(o.id)@\(from)", kind: .transit, showFrom: from, showUntil: leave + 5 * MINUTE, start: leave),
                content: .init(title: privacy ? "出発" : "\(o.title)へ出発", headline: "\(time.hm(leave))発", detail: privacy ? nil : (o.event.placeName.map { "\($0)・" } ?? "") + "\(time.hm(o.start))開始",
                               countdownTo: date(leave), endsAt: date(leave + 5 * MINUTE),
                               tint: model.eventColor(o.event), symbol: "figure.walk", url: "mytime://event/\(o.id)", canComplete: false,
                               compactLeading: time.hm(leave), phase: "before", routeURL: route(o)),
                staleAt: leave))
        }

        // 朝：実行中の朝
        let m = model.morning
        if let r = m.active, r.finishedAt == nil, let cur = r.current {
            let elapsed = r.elapsed(now: now)
            out.append(Item(
                candidate: LiveCandidate(id: "morning:\(r.id)", kind: .morning, showFrom: r.startedAt, showUntil: now + 4 * HOUR, start: r.startedAt),
                content: .init(title: cur.name, headline: nil, detail: "\(cur.group)・全\(r.steps.count)工程中 \(r.index + 1)工程目",
                               elapsedFrom: date(now - elapsed), pausedElapsed: r.isPaused ? Double(elapsed) / 1000 : nil,
                               progressDone: r.doneCount, progressTotal: r.steps.count, next: r.next?.name, status: r.isPaused ? "一時停止中" : nil,
                               tint: "#FF9F0A", symbol: "sunrise.fill", url: "mytime://morning", canComplete: true,
                               token: "\(r.id):\(r.index)", compactLeading: Self.short(cur.name, 5), compactTrailing: "\(r.index + 1)/\(r.steps.count)", phase: "run"),
                staleAt: now + 4 * HOUR))
        }

        // 清掃：実行中の清掃（いま清掃する箇所を大きく）
        let book = model.cleaning
        if let s = book.active {
            let st = s.statuses(in: book.areas)
            let c = CleaningSession.completion(st.map(\.status))
            let nextItem = st.first { $0.status == .no }
            let nextArea = nextItem.flatMap { n in book.areas.first { $0.items.contains { $0.id == n.item.id } } }
            out.append(Item(
                candidate: LiveCandidate(id: "cleaning:\(s.id)", kind: .cleaning, showFrom: s.startedAt, showUntil: now + 4 * HOUR, start: s.startedAt),
                content: .init(title: "清掃", headline: nextItem.map { "\(nextArea?.name ?? "")・\($0.item.name)" } ?? "すべて記録しました",
                               detail: "残り \(c.total - c.done)箇所", elapsedFrom: date(s.startedAt),
                               progressDone: c.done, progressTotal: c.total, next: nil,
                               tint: "#30B0C7", symbol: "bubbles.and.sparkles.fill", url: "mytime://cleaning", canComplete: false,
                               compactLeading: nil, compactTrailing: "\(c.done)/\(c.total)", phase: "run"),
                staleAt: now + 4 * HOUR))
        }

        // 実行中のタスク（勉強は種類で分ける）
        for t in model.tasks where t.status == .running {
            let study = t.specType?.isExamLike == true || t.specType == .assignment || t.specType == .report || t.extra?["studyFor"] != nil
            let worked = workedMs(t, at: now)
            let kind: LiveKind = study ? .study : .task
            let until = max(now + HOUR, (t.plannedEnd ?? now) + HOUR)
            out.append(Item(
                candidate: LiveCandidate(id: "task:\(t.id)", kind: kind, showFrom: now - MINUTE, showUntil: until, start: t.plannedStart ?? now),
                content: .init(title: privacy ? (study ? "勉強" : "タスク") : t.title, headline: nil, detail: t.plannedEnd.map { "\(time.hm($0))までの予定" },
                               elapsedFrom: date(now - worked), status: study ? "集中" : "実行中",
                               tint: study ? "#5E5CE6" : "#34C759", symbol: study ? "book.fill" : "checklist", url: "mytime://task/\(t.id)", canComplete: false,
                               token: privacy ? nil : t.id, compactLeading: nil, phase: "run"),
                staleAt: until))
        }

        // チェックポイント：何分前から、その時刻まで。時刻を過ぎたら終える
        for c in (0..<2).flatMap({ model.checkpoints(on: time.addDays(time.startOfDay(now), $0)) }) where c.at > now {
            let from = c.at - EpochMs(prefs.checkpointLeadMinutes) * MINUTE
            // 迫っているほど優先（10分以内は授業・バイトと同じくらい）
            let urgent = c.at - now <= 10 * MINUTE
            out.append(Item(
                candidate: LiveCandidate(id: "cp:\(c.id)@\(c.at)", kind: .checkpoint, showFrom: from, showUntil: c.at + MINUTE, start: c.at, priority: urgent ? 74 : nil),
                content: .init(title: privacy ? "チェックポイント" : (c.title.isEmpty ? "チェックポイント" : c.title), headline: "\(time.hm(c.at))", detail: nil,
                               countdownTo: date(c.at), endsAt: date(c.at),
                               tint: "#FF9F0A", symbol: "flag.checkered", url: "mytime://checkpoint/\(c.id)", canComplete: false,
                               compactLeading: nil, phase: "before"),
                staleAt: c.at))
        }
        return out
    }
}

/// Live Activity のボタン（ロック画面・ダイナミックアイランド）から呼ばれる操作。アプリの中で実行する。
/// value は「操作:朝のID:工程の番号」。いまの工程が違えば（連打・古い表示）何もしない＝冪等。
@MainActor
enum LiveActions {
    static func handle(kind: String, value: String, model: AppModel) async -> Bool {
        defer { Task { await LiveActivityCoordinator.shared.reconcile(model: model) } }
        switch kind {
        case "morning":
            let parts = value.split(separator: ":").map(String.init)
            guard let op = parts.first else { return false }
            var x = model.morning
            guard var run = x.active else { return false }
            if parts.count >= 3, let idx = Int(parts[2]) {
                // 押した表示の工程と、保存されているいまの工程が違う → すでに処理済み
                guard parts[1] == run.id, idx == run.index else { return true }
            }
            let now = model.now
            switch op {
            case "complete": run.complete(now: now)
            case "skip": run.complete(now: now, skipped: true)
            case "back": run.back(now: now)
            case "pause": run.isPaused ? run.resume(now: now) : run.pause(now: now)
            default: return false
            }
            x.active = run
            if run.finishedAt != nil { x.finishActive() }
            model.saveMorning(x)
            let ok = model.lastSaveSucceeded
            Diagnostics.record("live", ok: ok, ok ? "ロック画面の操作（朝）を保存" : "ロック画面の操作（朝）を保存できませんでした")
            return ok
        case "finishTask":
            guard let t = model.tasks.first(where: { $0.id == value }), !t.isDone else { return true }
            return model.perform("完了しました", undo: { try model.repo.taskAction(value, .undoFinish) }) { try model.repo.taskAction(value, .finish) }
        default:
            return false
        }
    }
}
