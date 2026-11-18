import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif
import AppIntents

/// Live Activity（ロック画面・ダイナミックアイランド）の共通の形。
/// アプリと Widget Extension の両方に入る（このフォルダは2つのターゲットで共有）。
/// 授業・バイト・朝・清掃・勉強・移動・タスク・チェックポイントを同じ形で表す。
#if canImport(ActivityKit)
struct MyTimeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 名前（授業名・「GU勤務」・今の工程）
        var title: String
        /// いちばん大きく出す文字（教室など。無ければ出さない）
        var headline: String?
        /// 時刻など（10:45〜12:15）
        var detail: String?
        /// この時刻までの残りを数える
        var countdownTo: Date?
        /// この時刻からの経過を数える（朝・勉強・清掃）
        var elapsedFrom: Date?
        /// 一時停止中は経過を止めて出す（秒）
        var pausedElapsed: Double?
        var progressDone: Int?
        var progressTotal: Int?
        /// 次の工程・次の箇所
        var next: String?
        /// 状態（出勤前・勤務中・一時停止など）
        var status: String?
        /// 終わる時刻（これを過ぎたら「終了」として出す）
        var endsAt: Date?
        var tint: String
        var symbol: String
        /// タップで開く画面（mytime://event/ID など）
        var url: String
        /// 「完了」ボタンを出すか（朝の工程）
        var canComplete: Bool
        /// ボタンの操作の対象（"朝のID:工程の番号"）。押したときにこの工程のままなら1回だけ進める（連打で飛ばさない）
        var token: String? = nil
        /// 種類ごとの短い表示（Compact の左・右。長い名前や住所を入れない）
        var compactLeading: String? = nil
        var compactTrailing: String? = nil
        /// 段階：before（開始前）/ active（進行中）/ run（自分で進めている）。時間がたつと表示側で次の段階に移る
        var phase: String? = nil
        /// 詳細スケジュールの「いま」と「次」（予定の中の予定）
        var subNow: String? = nil
        var subNext: String? = nil
        /// 経路を開くリンク（場所がある予定。mytime://route/ID → アプリから Apple マップの経路を開く）
        var routeURL: String? = nil
    }

    /// 種類（LiveKind の rawValue）
    var kind: String
    /// 元の予定・タスクの ID（同じものは同じ ID）
    var sourceId: String
}
#endif

/// Live Activity のボタン（アプリの中で実行される）。
/// アプリの起動時（App の init）に handler を入れるので、ロック画面から押されてアプリが裏で起動したときも動く。
/// handler は永続の保存先に書き込み、成功したときだけ true を返す。
@MainActor
enum LiveActionRouter {
    static var handler: ((String, String) async -> Bool)?
}

struct LiveActionError: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "操作を保存できませんでした。アプリを開いてもう一度お試しください。" }
}

/// 朝の工程を進める（完了・スキップ・戻る・一時停止）
struct MorningStepIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "朝の工程を進める"
    static var isDiscoverable = false

    @Parameter(title: "操作") var action: String

    init() {}
    init(action: String) { self.action = action }

    func perform() async throws -> some IntentResult {
        // 受け口が無い・保存に失敗したときは成功にしない
        guard let h = await LiveActionRouter.handler, await h("morning", action) else { throw LiveActionError() }
        return .result()
    }
}

/// 実行中のタスクを完了する
struct FinishTaskIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "タスクを完了する"
    static var isDiscoverable = false

    @Parameter(title: "タスク") var taskId: String

    init() {}
    init(taskId: String) { self.taskId = taskId }

    func perform() async throws -> some IntentResult {
        guard let h = await LiveActionRouter.handler, await h("finishTask", taskId) else { throw LiveActionError() }
        return .result()
    }
}

/// 色の文字（#RRGGBB）を数値に
enum HexColor {
    static func rgb(_ hex: String) -> (Double, Double, Double) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (0.04, 0.52, 1) }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }
}
