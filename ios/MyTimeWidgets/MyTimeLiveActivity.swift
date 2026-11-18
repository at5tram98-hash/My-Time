import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct MyTimeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MyTimeLiveActivity()
    }
}

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
    var body: some View {
        let p = phase(state, stale: stale)
        switch p {
        case .before:
            if let to = state.countdownTo { MinuteCountdown(from: .now, to: to) } else { Text("—") }
        case .active:
            if let s = state.countdownTo, let e = state.endsAt, e > s { MinuteCountdown(from: s, to: e) }
            else if let e = state.endsAt { MinuteCountdown(from: .now, to: e) }
            else { Text(phaseLabel("", p)) }
        case .run:
            if let paused = state.pausedElapsed {
                Text(Duration.seconds(paused).formatted(.time(pattern: paused >= 3600 ? .hourMinute : .minuteSecond)))
            } else if let from = state.elapsedFrom {
                MinuteStopwatch(from: from)
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
    var body: some View {
        if #available(iOS 18.0, *) {
            Text(.currentDate, format: .timer(countingDownIn: min(from, to)..<to, showsHours: true, maxPrecision: .seconds(60)))
        } else {
            Text(timerInterval: min(from, to)...to, countsDown: true, showsHours: true)
        }
    }
}

struct MinuteStopwatch: View {
    var from: Date
    var body: some View {
        if #available(iOS 18.0, *) {
            Text(.currentDate, format: .stopwatch(startingAt: from, showsHours: true, maxPrecision: .seconds(60)))
        } else {
            Text(timerInterval: from...Date.distantFuture, countsDown: false, showsHours: true)
        }
    }
}

// MARK: - ウィジェット

struct MyTimeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MyTimeActivityAttributes.self) { context in
            LockScreenView(kind: context.attributes.kind, state: context.state, stale: context.isStale)
                .activityBackgroundTint(nil)
                .activitySystemActionForegroundColor(.primary)
                .widgetURL(URL(string: context.state.url))
        } dynamicIsland: { context in
            let s = context.state
            let k = context.attributes.kind
            let stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(kindLabel(k)).font(.caption2.weight(.semibold)).lineLimit(1)
                    } icon: {
                        Image(systemName: s.symbol).foregroundStyle(accent(s))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(phaseLabel(k, phase(s, stale: stale))).font(.caption2).foregroundStyle(.secondary)
                        TimeValue(state: s, stale: stale)
                            .font(.callout.weight(.semibold)).monospacedDigit()
                            .multilineTextAlignment(.trailing)
                    }
                    .frame(maxWidth: 96, alignment: .trailing)
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    // いちばん大事な1つ（授業＝教室、バイト＝出勤時刻、朝・清掃＝いまの工程・場所）
                    Text(s.headline ?? s.title)
                        .font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.75)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(kind: k, state: s, stale: stale)
                }
            } compactLeading: {
                // 左：短い識別子だけ（教室・勤務先の略称・工程の略名）。無ければアイコン
                HStack(spacing: 3) {
                    Image(systemName: s.symbol).foregroundStyle(accent(s))
                    if let l = s.compactLeading, !l.isEmpty {
                        Text(l).font(.caption.weight(.semibold)).lineLimit(1).monospacedDigit()
                    }
                }
                .frame(maxWidth: 70, alignment: .leading)
            } compactTrailing: {
                // 右：短い時間か進み具合
                Group {
                    if let t = s.compactTrailing, phase(s, stale: stale) == .run { Text(t) }
                    else { TimeValue(state: s, stale: stale) }
                }
                .font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(accent(s))
                .lineLimit(1)
                .frame(maxWidth: 52, alignment: .trailing)
            } minimal: {
                if let d = s.progressDone, let t = s.progressTotal, t > 0 {
                    ZStack {
                        Circle().stroke(accent(s).opacity(0.3), lineWidth: 2)
                        Circle().trim(from: 0, to: CGFloat(d) / CGFloat(t)).stroke(accent(s), style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                        Image(systemName: s.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(accent(s))
                    }
                } else {
                    Image(systemName: s.symbol).foregroundStyle(accent(s))
                }
            }
            .widgetURL(URL(string: s.url))
            .keylineTint(accent(s))
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
