import SwiftUI
import MyTimeCore

/// 計画の支援（Web 版 plan と同じ規則）。
/// 重なり・二重登録・移動不足・期限の不足・詰め込みを理由つきで示し、直す案は「変更前→変更後」で見せてから承認で保存する。
/// 時間の決まった予定は自動で動かさない。
struct PlanAssistView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var showReplan = false

    var body: some View {
        let now = model.now
        let d0 = model.time.startOfDay(now)
        let to = model.time.addDays(d0, 7)
        let events = model.visibleEvents(from: model.time.addDays(d0, -1), to: model.time.addDays(to, 1))
        let issues = detectIssues(events: events, tasks: model.tasks, subtasks: model.subtasks, now: now, from: d0, to: to, opts: model.planOptions, time: model.time)
        let replan = replanDay(d0, events: events, tasks: model.tasks, subtasks: model.subtasks, now: now, opts: model.planOptions, time: model.time)
        NavigationStack {
            List {
                Section {
                    Button { withAnimation { showReplan.toggle() } } label: {
                        Label(replan.changes.isEmpty ? "今日の予定は組み直す必要がありません" : "今日を組み直す（\(replan.changes.count)件）", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(replan.changes.isEmpty && replan.alternatives.isEmpty)
                } footer: {
                    Text("過ぎた・予定と重なった未着手のタスクを、今より後の空き時間に置き直します。")
                }
                if showReplan { ProposalSection(proposal: replan, apply: apply) }

                if issues.isEmpty {
                    Section {
                        ContentUnavailableView("気になる点はありません", systemImage: "checkmark.seal", description: Text("今日から7日間の予定とタスクを確認しました。"))
                    }
                } else {
                    ForEach(issues) { i in IssueSection(issue: i, apply: apply, open: open) }
                }
            }
            .navigationTitle("計画の支援")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    private func apply(_ p: Proposal) {
        model.perform("変更しました") { try model.repo.applyProposal(p) }
    }

    private func open(_ route: SheetRoute) {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            router.open(route)
        }
    }
}

private struct IssueSection: View {
    @Environment(AppModel.self) private var model
    let issue: PlanIssue
    let apply: (Proposal) -> Void
    let open: (SheetRoute) -> Void
    @State private var expanded = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label(issue.title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Text(issue.reason).font(.caption).foregroundStyle(.secondary)
                if !issue.confident { Text("根拠が十分ではないため、目安です").font(.caption2).foregroundStyle(.tertiary) }
            }
            .padding(.vertical, 2)
            ForEach(issue.taskIds, id: \.self) { id in
                if let t = model.tasks.first(where: { $0.id == id }) {
                    Button { open(.task(id)) } label: { Label(t.title, systemImage: "checklist") }
                }
            }
            ForEach(issue.eventIds, id: \.self) { id in
                if let e = model.visibleEvents(from: model.time.addDays(model.now, -1), to: model.time.addDays(model.now, 8)).first(where: { $0.id == id }) {
                    Button { open(.event(id)) } label: { Label("\(e.title)  \(model.hm(e.start))", systemImage: "calendar") }
                }
            }
            if !issue.proposals.isEmpty {
                DisclosureGroup("直す案（\(issue.proposals.count)）", isExpanded: $expanded) {
                    ForEach(issue.proposals) { p in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.title).font(.subheadline)
                            Text(p.reason).font(.caption).foregroundStyle(.secondary)
                            ForEach(p.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                            Button("この案にする") { apply(p) }.buttonStyle(.borderedProminent).controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var symbol: String {
        switch issue.kind {
        case .overlap: return "rectangle.on.rectangle"
        case .duplicate: return "doc.on.doc"
        case .travel: return "tram.fill"
        case .lateRisk: return "clock.badge.exclamationmark"
        case .deadline: return "flag.fill"
        case .unplanned: return "calendar.badge.plus"
        case .overload: return "gauge.with.dots.needle.67percent"
        case .dependency: return "arrow.triangle.branch"
        }
    }
    private var tint: Color { issue.severity == .alert ? .red : issue.severity == .warn ? .orange : .secondary }
}
