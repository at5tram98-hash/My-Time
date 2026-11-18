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

/// ロック画面とダイナミックアイランド（Compact・Minimal・Expanded）
struct MyTimeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MyTimeActivityAttributes.self) { context in
            LockScreenView(kind: context.attributes.kind, state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.6))
                .activitySystemActionForegroundColor(accent(context.state))
                .widgetURL(URL(string: context.state.url))
        } dynamicIsland: { context in
            let s = context.state
            let k = context.attributes.kind
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
                    TimeBadge(state: s, stale: context.isStale)
                        .font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(accent(s))
                        .frame(maxWidth: 90, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(s.title).font(.headline).lineLimit(1)
                        if let d = s.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(kind: k, state: s)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: s.symbol).foregroundStyle(accent(s))
                    // Compact：朝は今の工程、授業は教室、そのほかは名前
                    Text(s.headline ?? s.title).font(.caption2.weight(.semibold)).lineLimit(1).frame(maxWidth: 64)
                }
            } compactTrailing: {
                TimeBadge(state: s, stale: context.isStale, compact: true)
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(accent(s))
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: s.symbol).foregroundStyle(accent(s))
            }
            .widgetURL(URL(string: s.url))
            .keylineTint(accent(s))
        }
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

/// 残り（あと○分）か経過。終わった・止めたときはその旨
struct TimeBadge: View {
    var state: MyTimeActivityAttributes.ContentState
    var stale: Bool
    var compact = false
    var body: some View {
        if stale || (state.endsAt.map { $0 < .now } ?? false) {
            Text("終了")
        } else if let p = state.pausedElapsed {
            Text(Duration.seconds(p).formatted(.time(pattern: p >= 3600 ? .hourMinuteSecond : .minuteSecond)))
        } else if let to = state.countdownTo, to > .now {
            Text(timerInterval: Date.now...to, countsDown: true, showsHours: true)
                .multilineTextAlignment(.trailing)
        } else if let from = state.elapsedFrom {
            Text(timerInterval: from...Date.distantFuture, countsDown: false, showsHours: true)
                .multilineTextAlignment(.trailing)
        } else if let st = state.status {
            Text(st).lineLimit(1)
        } else {
            Text(compact ? "" : "")
        }
    }
}

struct ExpandedBottom: View {
    var kind: String
    var state: MyTimeActivityAttributes.ContentState
    var body: some View {
        VStack(spacing: 6) {
            if let h = state.headline, kind == "classNext" || kind == "transit" || kind == "shift" {
                Text(h).font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let done = state.progressDone, let total = state.progressTotal, total > 0 {
                ProgressView(value: Double(done), total: Double(total)).tint(accent(state))
                HStack {
                    Text("\(done)/\(total)").font(.caption.weight(.semibold)).monospacedDigit()
                    if let n = state.next { Text("次：\(n)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    if let st = state.status { Text(st).font(.caption2).foregroundStyle(.secondary) }
                }
            } else if let st = state.status {
                Text(st).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.canComplete {
                HStack(spacing: 8) {
                    Button(intent: MorningStepIntent(action: "back")) { Image(systemName: "chevron.backward") }
                        .tint(.gray)
                    Button(intent: MorningStepIntent(action: "skip")) { Label("スキップ", systemImage: "forward.end") }
                        .tint(.gray)
                    Button(intent: MorningStepIntent(action: "complete")) { Label("完了", systemImage: "checkmark") }
                        .tint(accent(state))
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// ロック画面
struct LockScreenView: View {
    var kind: String
    var state: MyTimeActivityAttributes.ContentState
    var stale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: state.symbol)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(accent(state).gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(kindLabel(kind)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(state.title).font(.headline).lineLimit(1)
                    if let d = state.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit() }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    if state.countdownTo != nil && !stale { Text("あと").font(.caption2).foregroundStyle(.secondary) }
                    TimeBadge(state: state, stale: stale)
                        .font(.title3.weight(.bold)).monospacedDigit()
                        .foregroundStyle(accent(state))
                        .frame(maxWidth: 110, alignment: .trailing)
                }
            }
            // 授業の教室など、いちばん大事な情報を大きく
            if let h = state.headline, kind != "morning" {
                Text(h).font(.system(size: 30, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
            }
            if let done = state.progressDone, let total = state.progressTotal, total > 0 {
                ProgressView(value: Double(done), total: Double(total)).tint(accent(state))
                HStack {
                    if kind == "morning" { Text("全\(total)工程中 \(min(total, done + 1))工程目").font(.caption.weight(.semibold)) }
                    else { Text("\(done)/\(total)").font(.caption.weight(.semibold)).monospacedDigit() }
                    if let n = state.next { Text("次：\(n)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                }
            }
            if state.canComplete {
                HStack(spacing: 8) {
                    Button(intent: MorningStepIntent(action: "skip")) { Label("スキップ", systemImage: "forward.end").frame(maxWidth: .infinity) }
                        .tint(.gray)
                    Button(intent: MorningStepIntent(action: "complete")) { Label("完了", systemImage: "checkmark").frame(maxWidth: .infinity) }
                        .tint(accent(state))
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}
