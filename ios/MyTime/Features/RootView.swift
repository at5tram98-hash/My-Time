import SwiftUI
import MyTimeCore

enum AppTab: Hashable { case today, calendar, tasks, more }

/// その他タブの中で開く画面
enum MoreRoute: Hashable { case review, settings }

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
    /// その他タブの表示中の画面（余白のチップから振り返りを直接開くため）
    var morePath: [MoreRoute] = []
    func open(_ s: SheetRoute) { sheet = s }
    func openMore(_ r: MoreRoute) { morePath = [r]; tab = .more }
}

/// 4つのタブ（今日・カレンダー・タスク・その他）。追加は各画面の右上（iOS 標準の位置）。振り返りと設定は「その他」の中。
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
            MoreScreen()
                .tabItem { Label("その他", systemImage: "ellipsis") }
                .tag(AppTab.more)
        }
        .environment(router)
        #if DEBUG
        // 開発用：起動引数 `-route quickAdd|planAssist|settings` `-tab calendar|tasks|review` で画面を直接開く（UI テスト・スクリーンショット用）
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-tab"), i + 1 < args.count {
                switch args[i + 1] {
                case "calendar": router.tab = .calendar
                case "tasks": router.tab = .tasks
                case "more": router.tab = .more
                case "review": router.openMore(.review)
                default: router.tab = .today
                }
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

/// その他タブ：振り返り・設定
struct MoreScreen: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.morePath) {
            List {
                Section {
                    NavigationLink(value: MoreRoute.review) { Label("振り返り", systemImage: "chart.bar.xaxis") }
                }
                Section {
                    NavigationLink(value: MoreRoute.settings) { Label("設定", systemImage: "gearshape") }
                }
            }
            .navigationTitle("その他")
            .navigationDestination(for: MoreRoute.self) { r in
                switch r {
                case .review: ReviewScreen(embedded: true)
                case .settings: SettingsView(embedded: true)
                }
            }
        }
    }
}

/// embedded のときは外側のナビゲーションを使い、そうでなければ自分で NavigationStack を持つ
struct OptionalNavigationStack<Content: View>: View {
    var embedded: Bool
    @ViewBuilder var content: Content
    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }
}

/// 各画面の右上：追加（設定は「その他」タブ）
struct MainToolbar: ToolbarContent {
    @Environment(Router.self) private var router
    var addKind: EditorSeed.Kind = .task
    var body: some ToolbarContent {
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
