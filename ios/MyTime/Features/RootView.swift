import SwiftUI
import MyTimeCore

enum AppTab: Hashable { case today, calendar, tasks, review }

/// 開くシート（下から出る画面）
enum SheetRoute: Identifiable, Hashable {
    case task(String)
    case event(String)
    case editor(EditorSeed)
    case settings
    case inbox
    case dayTasks(EpochMs)
    case quickAdd
    case planAssist

    var id: String {
        switch self {
        case .task(let id): return "task:\(id)"
        case .event(let id): return "event:\(id)"
        case .editor(let s): return "editor:\(s.hashValue)"
        case .settings: return "settings"
        case .inbox: return "inbox"
        case .dayTasks(let d): return "day:\(d)"
        case .quickAdd: return "quickAdd"
        case .planAssist: return "planAssist"
        }
    }
}

/// 新規作成・編集の初期値
struct EditorSeed: Hashable {
    enum Kind: Hashable { case task, event }
    var kind: Kind
    var taskId: String?
    var eventId: String?
    var start: EpochMs?
    var end: EpochMs?
    var spec: SpecTypeId?
}

@MainActor
@Observable
final class Router {
    var tab: AppTab = .today
    var sheet: SheetRoute?
    func open(_ s: SheetRoute) { sheet = s }
}

/// 4つのタブ（今日・カレンダー・タスク・振り返り）。追加と設定は各画面の右上（iOS 標準の位置）。
/// iOS 26 以降の SDK でビルドすると、タブバーとツールバーは自動で Liquid Glass になる。
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var router = Router()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TabView(selection: $router.tab) {
            TodayView()
                .tabItem { Label("今日", systemImage: "rectangle.split.2x1") }
                .tag(AppTab.today)
            CalendarScreen()
                .tabItem { Label("カレンダー", systemImage: "calendar") }
                .tag(AppTab.calendar)
            TasksScreen()
                .tabItem { Label("タスク", systemImage: "checklist") }
                .tag(AppTab.tasks)
            ReviewScreen()
                .tabItem { Label("振り返り", systemImage: "chart.bar.xaxis") }
                .tag(AppTab.review)
        }
        .environment(router)
        #if DEBUG
        // 開発用：起動引数 `-route quickAdd|planAssist|settings` `-tab calendar|tasks|review` で画面を直接開く（UI テスト・スクリーンショット用）
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-tab"), i + 1 < args.count {
                router.tab = ["calendar": .calendar, "tasks": .tasks, "review": .review][args[i + 1]] ?? .today
            }
            if let i = args.firstIndex(of: "-route"), i + 1 < args.count {
                try? await Task.sleep(for: .milliseconds(400))
                router.sheet = ["quickAdd": .quickAdd, "planAssist": .planAssist, "settings": .settings, "inbox": .inbox][args[i + 1]]
            }
        }
        #endif
        .sheet(item: $router.sheet) { route in
            sheet(for: route)
                .environment(model)
                .environment(router)
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                ToastView(toast: t) { t.undo?(); model.toast = nil }
                    .padding(.bottom, 64)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task(id: t.id) {
                        try? await Task.sleep(for: .seconds(5))
                        if model.toast?.id == t.id { model.toast = nil }
                    }
            }
        }
        .animation(reduceMotion ? nil : Motion.sheet, value: model.toast)
        .alert("できませんでした", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .preferredColorScheme(model.settings.theme == "dark" ? .dark : model.settings.theme == "light" ? .light : nil)
    }

    @ViewBuilder
    private func sheet(for route: SheetRoute) -> some View {
        switch route {
        case .task(let id): TaskDetailView(taskId: id)
        case .event(let id): EventDetailView(occurrenceId: id)
        case .editor(let seed): EditorView(seed: seed)
        case .settings: SettingsView()
        case .inbox: InboxView()
        case .dayTasks(let day): DayTasksView(day: day)
        case .quickAdd: QuickAddView()
        case .planAssist: PlanAssistView()
        }
    }
}

/// 各画面の右上：追加と設定
struct MainToolbar: ToolbarContent {
    @Environment(Router.self) private var router
    var addKind: EditorSeed.Kind = .task
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { router.open(.settings) } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("設定")
        }
        ToolbarItem(placement: .topBarTrailing) {
            // タップで追加、長押しで「文章で追加」などを選べる（iOS 標準の primaryAction 付きメニュー）
            Menu {
                Button("新しいタスク", systemImage: "checklist") { router.open(.editor(EditorSeed(kind: .task))) }
                Button("新しい予定", systemImage: "calendar") { router.open(.editor(EditorSeed(kind: .event))) }
                Button("文章で追加", systemImage: "text.bubble") { router.open(.quickAdd) }
                Divider()
                Button("計画の支援", systemImage: "wand.and.stars") { router.open(.planAssist) }
            } label: {
                Image(systemName: "plus")
            } primaryAction: {
                router.open(.editor(EditorSeed(kind: addKind)))
            }
            .accessibilityLabel("追加")
            .accessibilityHint("長押しで文章で追加・計画の支援")
        }
    }
}
