import Foundation
import MyTimeCore

/// タスクを始める（どの画面の「開始」もここを通す）。
/// 「朝」のタスクは、朝の準備をそのまま始めて、朝の準備の画面を開く（タスクも実行中にする）。
/// 「清掃」のタスクは、清掃の場所を選ぶ画面を開く。
extension AppModel {
    @MainActor
    func startTask(_ t: MTTask, router: Router?) {
        switch t.specType {
        case .morning:
            var r = morning
            if r.active == nil || r.active?.finishedAt != nil {
                r.active = MorningRun(startedAt: now, steps: r.enabledSteps)
                saveMorning(r)
            }
            if t.status == .notStarted { perform(nil) { try repo.taskAction(t.id, .start) } }
            router?.closeAll()
            router?.openTasks(.morningRun)
        case .cleaning:
            if t.status == .notStarted { perform(nil) { try repo.taskAction(t.id, .start) } }
            router?.closeAll()
            router?.openTasks(cleaning.active != nil ? .cleaningRun : .cleaning)
        default:
            let a: TaskAction = t.status == .paused ? .resume : .start
            perform("開始しました", undo: { try self.repo.taskAction(t.id, .undoStart) }) { try self.repo.taskAction(t.id, a) }
        }
    }

    /// 朝の準備が終わったら、実行中の「朝」のタスクも完了にする
    @MainActor
    func finishMorningTasksIfDone() {
        guard morning.active?.finishedAt != nil else { return }
        for t in tasks where t.specType == .morning && (t.status == .running || t.status == .paused) {
            perform(nil) { try repo.taskAction(t.id, .finish) }
        }
    }
}
