import SwiftUI
import MyTimeCore

/// 操作履歴（Web 版と同じ operationLog を新しい順に。何をいつ変えたかを確かめる）
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let logs = model.repo.history(limit: 300)
        let byDay = Dictionary(grouping: logs) { model.time.startOfDay($0["at"]?.intValue ?? 0) }
        List {
            // 直前の操作を元に戻す（振る操作のほかに、ここからも。VoiceOver からも使える）
            if let t = model.toast, t.undo != nil {
                Section {
                    Button {
                        t.undo?(); model.toast = nil
                    } label: {
                        Label { VStack(alignment: .leading, spacing: 2) { Text("直前の操作を元に戻す"); Text(t.text).font(.caption).foregroundStyle(.secondary) } }
                        icon: { Image(systemName: "arrow.uturn.backward.circle.fill") }
                    }
                } footer: { Text("iPhone を振っても元に戻せます。") }
            }
            if logs.isEmpty {
                ContentUnavailableView("まだ操作はありません", systemImage: "clock.arrow.circlepath")
            }
            ForEach(byDay.keys.sorted(by: >), id: \.self) { d in
                Section(model.time.dayLabel(d)) {
                    ForEach(Array(byDay[d]!.enumerated()), id: \.offset) { _, log in row(log) }
                }
            }
        }
        .navigationTitle("操作履歴")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ log: JSONValue) -> some View {
        let entity = log["entity"]?.stringValue ?? ""
        let id = log["entityId"]?.stringValue ?? ""
        let name: String = {
            if entity == "task" { return model.tasks.first { $0.id == id }?.title ?? log["detail"]?["snapshot"]?["title"]?.stringValue ?? "削除したタスク" }
            if entity == "event" { return model.events.first { $0.id == id }?.title ?? log["detail"]?["snapshot"]?["title"]?.stringValue ?? "削除した予定" }
            if entity == "subtask" { return model.subtasks.first { $0.id == id }?.title ?? "サブタスク" }
            return entity
        }()
        return HStack(spacing: 12) {
            Image(systemName: entity == "event" ? "calendar" : entity == "subtask" ? "list.bullet.indent" : "checklist").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(Self.actionLabel(log["action"]?.stringValue ?? "") + (log["detail"]?["via"]?.stringValue == "text" ? "（文章から）" : log["detail"]?["proposal"] != nil ? "（計画の支援）" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.hm(log["at"]?.intValue ?? 0)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    static func actionLabel(_ a: String) -> String {
        switch a {
        case "create": return "追加"
        case "update": return "編集"
        case "delete": return "削除"
        case "move": return "時間を移動"
        case "plan": return "時間を変更"
        case "start": return "開始"
        case "pause": return "停止"
        case "resume": return "再開"
        case "finish": return "完了"
        case "undoFinish": return "完了を取り消し"
        case "undoStart": return "開始を取り消し"
        case "complete": return "チェック"
        case "uncomplete": return "チェックを外す"
        case "occurrence-cancel": return "この回だけ削除"
        case "import": return "読み込み"
        default: return a
        }
    }
}
