import SwiftUI
import AppIntents
#if canImport(ActivityKit)
import ActivityKit
#endif

// ロック画面・ダイナミックアイランドの表示の部品（アプリと Widget Extension の両方で使う。アプリでは設定のプレビューに使う）

// MARK: - 表示の段階
//
// アプリが止まっていても表示が嘘にならないように、段階は「時間で必ず決まるもの」だけで決める。
//  before：開始前（staleDate＝開始時刻）。開始時刻を過ぎて stale になったら active として表示する
//  active：進行中（staleDate＝終了時刻）。終了時刻を過ぎて stale になったら「終了」
//  run   ：朝・清掃・タスクなど、自分で進めているもの（経過時間）
// 残り時間は秒ではなく分の単位（iOS 18 以降）。それより前は OS の秒タイマー。

enum Phase { case before, active, ended, run }

func phase(_ s: MyTimeActivityAttributes.ContentState, stale: Bool) -> Phase {
    switch s.phase ?? (s.elapsedFrom != nil ? "run" : "before") {
    case "run": return stale ? .ended : .run
    case "active": return stale ? .ended : .active
    default:
        if !stale { return .before }
        // 開始を過ぎた：終わりが分かれば進行中、分からなければ終了
        if let e = s.endsAt, e > .now { return .active }
        return s.endsAt == nil ? .active : .ended
    }
}

func accent(_ s: MyTimeActivityAttributes.ContentState) -> Color {
    let (r, g, b) = HexColor.rgb(s.tint)
    return Color(red: r, green: g, blue: b)
}

func kindLabel(_ k: String) -> String {
    switch k {
    case "classNext": return "次の授業"
    case "shift": return "バイト"
    case "morning": return "朝の準備"
    case "cleaning": return "清掃"
    case "study": return "勉強"
    case "transit": return "出発"
    case "checkpoint": return "チェックポイント"
    default: return "タスク"
    }
}

/// 段階の言葉（色だけに頼らない）
func phaseLabel(_ k: String, _ p: Phase) -> String {
    switch p {
    case .before: return k == "shift" ? "出勤まで" : k == "transit" ? "出発まで" : k == "classNext" ? "開始まで" : "あと"
    case .active: return k == "shift" ? "勤務中" : k == "classNext" ? "授業中" : k == "transit" ? "出発の時刻" : "進行中"
    case .ended: return "終了"
    case .run: return k == "study" ? "集中" : "経過"
    }
}

// MARK: - 残り・経過の時間（分の単位）

struct TimeValue: View {
    var state: MyTimeActivityAttributes.ContentState
    var stale: Bool
    /// Compact（狭い所）では一番大きい単位だけ（「2時間」「45分」）
    var compact = false
    var body: some View {
        let p = phase(state, stale: stale)
        switch p {
        case .before:
            if let to = state.countdownTo { MinuteCountdown(from: .now, to: to, compact: compact) } else { Text("—") }
        case .active:
            if let s = state.countdownTo, let e = state.endsAt, e > s { MinuteCountdown(from: s, to: e, compact: compact) }
            else if let e = state.endsAt { MinuteCountdown(from: .now, to: e, compact: compact) }
            else { Text(phaseLabel("", p)) }
        case .run:
            if let paused = state.pausedElapsed {
                Text(Duration.seconds(paused).formatted(.time(pattern: paused >= 3600 ? .hourMinute : .minuteSecond)))
            } else if let from = state.elapsedFrom {
                MinuteStopwatch(from: from, compact: compact)
            } else { Text("—") }
        case .ended:
            Text("終了")
        }
    }
}

/// 分の単位のカウントダウン（0 で止まる）
struct MinuteCountdown: View {
    var from: Date
    var to: Date
    var compact = false
    var body: some View {
        if #available(iOS 18.0, *) {
            Text(.currentDate, format: .timer(countingDownIn: min(from, to)..<to, showsHours: true, maxFieldCount: compact ? 1 : 2, maxPrecision: .seconds(60)))
        } else {
            Text(timerInterval: min(from, to)...to, countsDown: true, showsHours: true)
        }
    }
}

struct MinuteStopwatch: View {
    var from: Date
    var compact = false
    var body: some View {
        if #available(iOS 18.0, *) {
            Text(.currentDate, format: .stopwatch(startingAt: from, showsHours: true, maxFieldCount: compact ? 1 : 2, maxPrecision: .seconds(60)))
        } else {
            Text(timerInterval: from...Date.distantFuture, countsDown: false, showsHours: true)
        }
    }
}

// MARK: - 拡張表示の下段

struct ExpandedBottom: View {
    var kind: String
    var state: MyTimeActivityAttributes.ContentState
    var stale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 補足：名前・時刻（いちばん大事なものは上で大きく出している）
            HStack(spacing: 6) {
                if state.headline != nil { Text(state.title).font(.subheadline.weight(.semibold)).lineLimit(1) }
                if let d = state.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit() }
                Spacer(minLength: 0)
                if let st = state.status { Text(st).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1) }
            }
            if let done = state.progressDone, let total = state.progressTotal, total > 0 {
                ProgressView(value: Double(done), total: Double(total)).tint(accent(state))
                HStack {
                    Text(kind == "morning" ? "全\(total)工程中 \(min(total, done + 1))工程目" : "\(done)/\(total)").font(.caption.weight(.semibold)).monospacedDigit()
                    if let n = state.next { Text("次：\(n)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            if (kind == "task" || kind == "study"), let tid = state.token, phase(state, stale: stale) == .run {
                Button(intent: FinishTaskIntent(taskId: tid)) { Label("完了", systemImage: "checkmark") }
                    .tint(accent(state)).buttonStyle(.borderedProminent).font(.caption.weight(.semibold))
            }
            if state.canComplete, let token = state.token, phase(state, stale: stale) == .run {
                HStack(spacing: 8) {
                    Button(intent: MorningStepIntent(action: "back:\(token)")) { Image(systemName: "chevron.backward").accessibilityLabel("前の工程へ") }
                        .tint(.gray)
                    Button(intent: MorningStepIntent(action: "skip:\(token)")) { Label("スキップ", systemImage: "forward.end") }
                        .tint(.gray)
                    Button(intent: MorningStepIntent(action: "complete:\(token)")) { Label("完了", systemImage: "checkmark") }
                        .tint(accent(state))
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - ロック画面

struct LockScreenView: View {
    var kind: String
    var state: MyTimeActivityAttributes.ContentState
    var stale: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = phase(state, stale: stale)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: state.symbol)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(accent(state).gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kindLabel(kind)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(state.title).font(.headline).lineLimit(1)
                    if let d = state.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit() }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(phaseLabel(kind, p)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    TimeValue(state: state, stale: stale)
                        .font(.title3.weight(.bold)).monospacedDigit()
                        .foregroundStyle(p == .ended ? Color.secondary : accent(state))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110, alignment: .trailing)
                }
            }
            // いちばん大事な情報を大きく（授業の教室・バイトの出勤時刻・朝の工程・清掃の場所）
            if let h = state.headline, p != .ended, h != state.title {
                Text(h).font(.system(size: 30, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            }
            if let done = state.progressDone, let total = state.progressTotal, total > 0 {
                ProgressView(value: Double(done), total: Double(total)).tint(accent(state))
                HStack {
                    Text(kind == "morning" ? "全\(total)工程中 \(min(total, done + 1))工程目" : "\(done)/\(total)").font(.caption.weight(.semibold)).monospacedDigit()
                    if let n = state.next { Text("次：\(n)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                }
            }
            if (kind == "task" || kind == "study"), let tid = state.token, p == .run {
                Button(intent: FinishTaskIntent(taskId: tid)) { Label("完了", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .tint(accent(state)).buttonStyle(.borderedProminent).font(.subheadline.weight(.semibold))
            }
            if state.canComplete, let token = state.token, p == .run {
                HStack(spacing: 8) {
                    Button(intent: MorningStepIntent(action: "skip:\(token)")) { Label("スキップ", systemImage: "forward.end").frame(maxWidth: .infinity) }
                        .tint(.gray)
                    Button(intent: MorningStepIntent(action: "complete:\(token)")) { Label("完了", systemImage: "checkmark").frame(maxWidth: .infinity) }
                        .tint(accent(state))
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        // 壁紙に左右されないよう、背景は OS の素材にまかせ、文字は標準の色（高いコントラスト）
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
    }
}
