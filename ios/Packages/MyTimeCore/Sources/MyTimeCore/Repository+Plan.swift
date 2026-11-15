import Foundation

// 文章からの追加・計画の支援の保存（Web 版 repo.applyPlan / quickadd の保存と同じ考え方）。
// ユーザーが確認画面で承認したものだけを保存する。1回の承認＝1トランザクション。

public extension Repository {
    /// 確認画面で選んだ候補を保存する。予定の準備はタスク（sourceEventId でつながる）、作業枠は日時付きサブタスクとして作る。
    /// 戻り値は作った件数
    @discardableResult
    func createFromCandidates(_ cands: [Candidate]) throws -> Int {
        let now = clock()
        var made = 0
        try store.transaction {
            for c in cands {
                let specJSON: JSONValue? = c.spec.map { s in
                    var details = c.details
                    if let due = c.due { details["dueAt"] = due.json }
                    return .object(["type": s.rawValue.json, "details": .object(details)])
                }
                switch c.entity {
                case .event:
                    guard let s = c.start, let e = c.end else { throw RepositoryError("「\(c.title)」の日時がありません") }
                    let cal = c.spec == .shift ? "cal-job" : c.spec == .class ? "cal-class" : "cal-general"
                    var ev = MTEvent.make(title: c.title, calendarId: cal, start: s, end: e, now: now, id: newId())
                    var extra: [String: JSONValue] = [:]
                    if let specJSON { extra["spec"] = specJSON }
                    if c.allDay { extra["allDay"] = .bool(true) }
                    if !extra.isEmpty { ev.extra = .object(extra) }
                    ev.employerId = c.employerId
                    store.put(.event, id: ev.id, json: ev.json)
                    record(.event, ev.id, op: "put", action: "create", detail: ["via": "text".json])
                    made += 1
                    for p in c.prep {
                        var t = MTTask.make(title: p.title, now: now, id: newId())
                        t.plannedStart = p.start; t.plannedEnd = p.end; t.sourceEventId = ev.id
                        store.put(.task, id: t.id, json: t.json)
                        record(.task, t.id, op: "put", action: "create", detail: ["via": "text".json, "prepFor": ev.id.json])
                        made += 1
                    }
                case .task:
                    let kind: TaskKind = c.spec.map { SPEC_BY_ID[$0]!.taskKind } ?? .do
                    var t = MTTask.make(title: c.title, kind: kind, now: now, id: newId())
                    if kind == .check { t.checkAt = c.start ?? c.due } else { t.plannedStart = c.start; t.plannedEnd = c.end }
                    t.estimateMinutes = c.estimateMinutes
                    if let specJSON { t.extra = .object(["spec": specJSON]) }
                    if let sym = c.spec.flatMap({ SPEC_BY_ID[$0]?.symbol }) { t.icon = sym }
                    store.put(.task, id: t.id, json: t.json)
                    record(.task, t.id, op: "put", action: "create", detail: ["via": "text".json])
                    made += 1
                    for (i, s) in c.sessions.enumerated() {
                        var sub = MTSubtask.make(taskId: t.id, title: s.title, order: Int64(i), now: now, id: newId())
                        sub.plannedStart = s.start; sub.plannedEnd = s.end; sub.estimateMinutes = Int((s.end - s.start) / MINUTE)
                        store.put(.subtask, id: sub.id, json: sub.json)
                        record(.subtask, sub.id, op: "put", action: "create", detail: ["taskId": t.id.json, "via": "text".json])
                    }
                }
            }
        }
        return made
    }

    /// 承認した提案を保存する（タスク・サブタスクの日時の変更と、作業枠の追加）。予定の変更は「ずらす」のときだけ
    func applyProposal(_ p: Proposal) throws {
        let now = clock()
        try store.transaction {
            for c in p.changes {
                switch c.entity {
                case .task:
                    guard var t = task(c.id) else { throw RepositoryError("「\(c.title)」が見つかりません") }
                    let prev = t.json
                    t.plannedStart = c.after.start; t.plannedEnd = c.after.end; t.updatedAt = now
                    store.put(.task, id: t.id, json: t.json)
                    record(.task, t.id, op: "put", action: "plan", detail: ["proposal": p.id.json, "snapshot": prev])
                case .event:
                    guard var e = event(c.id), let s = c.after.start, let en = c.after.end else { throw RepositoryError("「\(c.title)」が見つかりません") }
                    let prev = e.json
                    e.start = s; e.end = en; e.updatedAt = now
                    store.put(.event, id: e.id, json: e.json)
                    record(.event, e.id, op: "put", action: "plan", detail: ["proposal": p.id.json, "snapshot": prev])
                case .subtask:
                    guard var s = store.get(.subtask, id: c.id).map(MTSubtask.init) else { throw RepositoryError("「\(c.title)」が見つかりません") }
                    s.plannedStart = c.after.start; s.plannedEnd = c.after.end; s.updatedAt = now
                    store.put(.subtask, id: s.id, json: s.json)
                    record(.subtask, s.id, op: "put", action: "plan", detail: ["proposal": p.id.json])
                }
            }
            for (i, s) in p.sessions.enumerated() {
                let base = Int64(store.all(.subtask).filter { $0["taskId"]?.stringValue == s.taskId }.count)
                var sub = MTSubtask.make(taskId: s.taskId, title: s.title, order: base + Int64(i), now: now, id: newId())
                sub.plannedStart = s.start; sub.plannedEnd = s.end; sub.estimateMinutes = Int((s.end - s.start) / MINUTE)
                store.put(.subtask, id: sub.id, json: sub.json)
                record(.subtask, sub.id, op: "put", action: "create", detail: ["taskId": s.taskId.json, "proposal": p.id.json])
            }
        }
    }

    /// 操作履歴（新しい順）
    func history(limit: Int = 200) -> [JSONValue] {
        Array(store.logs().suffix(limit).reversed())
    }
}
