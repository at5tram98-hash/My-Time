import Foundation
import BackgroundTasks

/// アプリが閉じている間も、移動の区間の切り替わりなどで Live Activity を更新するための、裏での照合。
/// iOS が実行の時刻を決めるため、頼んだ時刻より遅れることがある（遅れても、各区間の残りの分は OS が数える）
enum LiveBackground {
    static let id = "com.fujiiyuuki.mytime.live"

    @MainActor
    static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
            Task { @MainActor in
                model.reload()
                // ChatGPT からの変更も、アプリを開いていない間に取り込む（確認なしで反映）
                await model.chatGPT.sync(model)
                await LiveActivityCoordinator.shared.reconcile(model: model)
                task.setTaskCompleted(success: true)
                // ChatGPT とつないでいる間は、30分ごとにまた見に来る（iOS が時刻を決める）
                if model.chatGPT.connected { schedule(at: Date().addingTimeInterval(30 * 60)) }
            }
        }
    }

    static func schedule(at date: Date?) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
        guard let date else { return }
        let r = BGAppRefreshTaskRequest(identifier: id)
        r.earliestBeginDate = date
        try? BGTaskScheduler.shared.submit(r)
    }
}
