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
    }

    /// 種類（LiveKind の rawValue）
    var kind: String
    /// 元の予定・タスクの ID（同じものは同じ ID）
    var sourceId: String
}
#endif

/// Live Activity のボタン（アプリの中で実行される）。アプリ側が handler を入れる
@MainActor
enum LiveActionRouter {
    static var handler: ((String, String) async -> Void)?
}

/// 朝の工程を進める（完了・スキップ・戻る・一時停止）
struct MorningStepIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "朝の工程を進める"
    static var isDiscoverable = false

    @Parameter(title: "操作") var action: String

    init() {}
    init(action: String) { self.action = action }

    func perform() async throws -> some IntentResult {
        await LiveActionRouter.handler?("morning", action)
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
        await LiveActionRouter.handler?("finishTask", taskId)
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
