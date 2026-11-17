import SwiftUI
import AudioToolbox
import MyTimeCore

enum AppTab: Hashable { case today, calendar, tasks, more }

/// その他タブの中で開く画面
enum MoreRoute: Hashable { case review, settings, dayPlan }

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
    /// チェックポイント（nil：新しく作る）
    case checkpoint(Checkpoint?)

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
        case .checkpoint(let c): return "checkpoint:\(c?.id ?? "new")"
        }
    }
}

struct SheetLevel: Identifiable { var id: Int }

/// i 段目のシートの中身。上にさらにシートを重ねられる
struct SheetHost: View {
    var level: Int
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    /// 閉じる途中も中身を出し続けるため、最後に出していた画面を覚えておく
    @State private var shown: SheetRoute?

    var body: some View {
        let route = level < router.stack.count ? router.stack[level] : shown
        Group {
            if let route {
                content(route)
                    .id(route.id)
            }
        }
        // 半分の高さのシートでも後ろの色がにじまないように（読みやすさ優先）
        .presentationBackground(Color(.systemGroupedBackground))
        .sheet(item: router.level(level + 1)) { _ in
            SheetHost(level: level + 1)
                .environment(model)
                .environment(router)
        }
        .onAppear { if level < router.stack.count { shown = router.stack[level] } }
        .onChange(of: level < router.stack.count ? router.stack[level] : nil) { _, r in if let r { shown = r } }
    }

    @ViewBuilder
    private func content(_ route: SheetRoute) -> some View {
        switch route {
        case .task(let id): TaskDetailView(taskId: id)
        case .event(let id): EventDetailView(occurrenceId: id)
        case .editor(let seed): EditorView(seed: seed)
        case .settings: SettingsView()
        case .inbox: InboxView()
        case .dayTasks(let day): DayTasksView(day: day)
        case .quickAdd: QuickAddView()
        case .planAssist: PlanAssistView()
        case .checkpoint(let c): CheckpointRouteView(initial: c)
        }
    }
}

/// チェックポイントのシート。新しいかどうかは開いたときに一度だけ決める
/// （保存した瞬間に「新しい」でなくなり、閉じる途中で小さな表示に変わってしまうのを防ぐ）
private struct CheckpointRouteView: View {
    var initial: Checkpoint?
    @Environment(AppModel.self) private var model
    @State private var start: (Checkpoint, Bool)?

    var body: some View {
        ZStack {
            if let start { CheckpointSheet(checkpoint: start.0, isNew: start.1) } else { Color.clear }
        }
        .onAppear {
            guard start == nil else { return }
            let next = ((model.now / (15 * MINUTE)) + 1) * 15 * MINUTE
            let c = initial ?? Checkpoint(id: model.repo.newId(), title: "", at: next)
            start = (c, !model.checkpoints.contains { $0.id == c.id })
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
    /// 開いているシート（下から順）。詳細の上に編集を重ね、閉じると詳細に戻る（純正のカレンダーと同じ）
    var stack: [SheetRoute] = []
    var sheet: SheetRoute? {
        get { stack.first }
        set { stack = newValue.map { [$0] } ?? [] }
    }
    /// その他タブの表示中の画面（余白のチップから振り返りを直接開くため）
    var morePath: [MoreRoute] = []
    /// 今の画面の上に重ねて開く（何も開いていなければ最初のシート）
    func open(_ s: SheetRoute) {
        guard stack.last != s else { return }
        // 同じものが下にあれば、そこまで戻る（詳細→編集→同じ詳細 のような重なりを作らない）
        if let i = stack.firstIndex(of: s) { stack = Array(stack.prefix(i + 1)); return }
        stack.append(s)
    }
    /// いちばん上のシートの中身を入れ替える（シートは閉じずにそのまま）
    func replace(_ s: SheetRoute) {
        withAnimation(.snappy) {
            if stack.isEmpty { stack = [s] } else { stack[stack.count - 1] = s }
        }
    }
    /// すべてのシートを閉じる
    func closeAll() { stack = [] }
    /// i 段目のシートの表示（SwiftUI の sheet(item:) 用。中身を入れ替えてもシートは閉じない）
    func level(_ i: Int) -> Binding<SheetLevel?> {
        Binding(get: { self.stack.count > i ? SheetLevel(id: i) : nil },
                set: { if $0 == nil, self.stack.count > i { self.stack = Array(self.stack.prefix(i)) } })
    }
    func openMore(_ r: MoreRoute) { morePath = [r]; tab = .more }
}

/// 4つのタブ（今日・カレンダー・タスク・その他）。追加は各画面の右上（iOS 標準の位置）。振り返りと設定は「その他」の中。
/// iOS 26 以降の SDK でビルドすると、タブバーとツールバーは自動で Liquid Glass になる。
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var router = Router()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showUndo = false
    /// 鳴っているアラーム（アプリを開いているとき）
    @State private var ringing: MTTask?
    @State private var fired = Set<String>()

    var body: some View {
        TabView(selection: $router.tab) {
            TodayView()
                .tabItem { Label("今日", systemImage: "house.fill") }
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
            // 開発用：起動引数 `-importFile <path>` で移行ファイルを読み込む（追加だけ）
            if let i = args.firstIndex(of: "-importFile"), i + 1 < args.count,
               let text = try? String(contentsOfFile: args[i + 1], encoding: .utf8),
               let file = try? DeviceTransfer.read(text) {
                model.perform { _ = try DeviceTransfer.importAddOnly(file, into: model.repo.store, now: model.now, newId: model.repo.newId) }
            }
            if let i = args.firstIndex(of: "-route"), i + 1 < args.count {
                try? await Task.sleep(for: .milliseconds(400))
                router.sheet = ["quickAdd": .quickAdd, "planAssist": .planAssist, "settings": .settings, "inbox": .inbox][args[i + 1]]
            }
        }
        #endif
        .sheet(item: router.level(0)) { _ in
            SheetHost(level: 0)
                .environment(model)
                .environment(router)
        }
        // アラーム：開いているときは画面いっぱいに出して鳴らし続ける
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                // 本物のアラーム（AlarmKit）が鳴るときは、アプリ内の画面は出さない
                guard ringing == nil, !TaskAlarms.systemAlarmsActive else { continue }
                let now = model.now
                if let t = model.tasks.first(where: { t in
                    guard let at = NotificationScheduler.alarmTime(t) else { return false }
                    return at <= now && now - at < 60 * 1000 && !fired.contains("\(t.id)@\(at)")
                }) {
                    if let at = NotificationScheduler.alarmTime(t) { fired.insert("\(t.id)@\(at)") }
                    ringing = t
                }
            }
        }
        .fullScreenCover(item: $ringing) { t in
            AlarmView(task: t) { ringing = nil }
                .environment(model)
        }
        // 操作のあとに画面下へ知らせは出さない。取り消しは iPhone を振る（純正アプリと同じ「シェイクで取り消す」）
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            if model.toast?.undo != nil { showUndo = true }
        }
        .alert("取り消しますか？", isPresented: $showUndo, presenting: model.toast) { t in
            Button("取り消す") { t.undo?(); model.toast = nil }
            Button("キャンセル", role: .cancel) {}
        } message: { t in
            Text("直前の操作：\(t.text)")
        }
        .alert("できませんでした", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .preferredColorScheme(model.settings.theme == "dark" ? .dark : model.settings.theme == "light" ? .light : nil)
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
                Section {
                    Button("新しい予定", systemImage: "calendar") { router.open(.editor(EditorSeed(kind: .event))) }
                    Button("新しいタスク", systemImage: "checklist") { router.open(.editor(EditorSeed(kind: .task))) }
                    Button("新しいチェックポイント", systemImage: "flag.checkered") { router.open(.checkpoint(nil)) }
                }
                Section {
                    Button("文章で追加", systemImage: "text.bubble") { router.open(.quickAdd) }
                    Button("計画の支援", systemImage: "wand.and.stars") { router.open(.planAssist) }
                }
            } label: {
                Image(systemName: "plus")
            } primaryAction: {
                router.open(.editor(EditorSeed(kind: addKind)))
            }
            .accessibilityLabel("追加")
            .accessibilityHint("長押しで予定・タスク・チェックポイントを選べます")
        }
    }
}

// MARK: シェイクで取り消す

extension Notification.Name {
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

extension UIWindow {
    /// iPhone を振ったことを SwiftUI に知らせる（直前の操作の取り消しに使う）
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { NotificationCenter.default.post(name: .deviceDidShake, object: nil) }
        super.motionEnded(motion, with: event)
    }
}

// MARK: アラーム


/// アラームの画面（時計アプリのアラームにならう）。止めるまで鳴らし、振動させる
struct AlarmView: View {
    var task: MTTask
    var onClose: () -> Void
    @Environment(AppModel.self) private var model
    @State private var pulse = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "alarm.fill")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(.white)
                    .scaleEffect(pulse ? 1.12 : 0.92)
                    .rotationEffect(.degrees(pulse ? 8 : -8))
                    .animation(.easeInOut(duration: 0.25).repeatForever(autoreverses: true), value: pulse)
                Text(Date(), format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                    .font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                Text(task.title).font(.title2.weight(.semibold)).foregroundStyle(.white).multilineTextAlignment(.center).padding(.horizontal)
                Spacer()
                if task.kind == .do && task.status == .notStarted {
                    Button {
                        model.perform("開始しました", undo: { try model.repo.taskAction(task.id, .undoStart) }) { try model.repo.taskAction(task.id, .start) }
                        onClose()
                    } label: {
                        Label("開始する", systemImage: "play.fill").font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .background(.white, in: Capsule()).foregroundStyle(.red)
                    }
                    .buttonStyle(PressableStyle())
                    .padding(.horizontal, 32)
                }
                Button(action: onClose) {
                    Text("止める").font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(.white.opacity(0.25), in: Capsule()).foregroundStyle(.white)
                }
                .buttonStyle(PressableStyle())
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
        .onAppear { pulse = true }
        // 止めるまで2秒ごとに音と振動
        .task {
            while !Task.isCancelled {
                AudioServicesPlayAlertSound(SystemSoundID(1005))
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("アラーム \(task.title)")
    }
}
