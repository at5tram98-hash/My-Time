import SwiftUI
import SwiftData
import UserNotifications

@main
struct MyTimeApp: App {
    private let container: ModelContainer
    @State private var model: AppModel

    init() {
        // UI テスト・スクリーンショット用：起動引数 -inMemory で端末のデータに触れずに起動する
        let inMemory = ProcessInfo.processInfo.arguments.contains("-inMemory")
        var failure: String?
        do {
            container = try MyTimeSchema.container(inMemory: inMemory)
        } catch {
            // 保存先を開けない場合も、データを消さずにメモリ上で起動し、理由を表示する
            failure = "保存先を開けなかったため、一時的なメモリ上で起動しました。この状態の変更は保存されません。（\(error.localizedDescription)）"
            container = try! MyTimeSchema.container(inMemory: true)
        }
        let model = AppModel.live(container: container)
        model.errorMessage = failure
        model.storeFailure = failure
        _model = State(initialValue: model)
        // 通知を押したときの受け口（起動の最初に設定しないと、閉じていたときの通知を受け取れない）
        UNUserNotificationCenter.current().delegate = NotificationTapHandler.shared
        // ロック画面のボタンから裏で起動されたときも動くように、画面より先に受け口を用意する
        LiveActionRouter.handler = { kind, value in await LiveActions.handle(kind: kind, value: value, model: model) }
        // 閉じている間の Live Activity の更新（移動の区間の切り替わりなど）
        LiveBackground.register(model: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(container)
        }
    }
}
