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
                        Text(kindLabel(k)).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    } icon: {
                        Image(systemName: phase(s, stale: stale) == .ended ? "checkmark.circle.fill" : s.symbol).foregroundStyle(accent(s))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(phaseLabel(k, phase(s, stale: stale))).font(.caption2).foregroundStyle(.secondary)
                        TimeValue(state: s, stale: stale)
                            .font(.callout.weight(.semibold)).monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: 96, alignment: .trailing)
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    // いちばん大事な1つ（授業＝教室、バイト＝出勤時刻、朝・清掃＝いまの工程・場所）
                    Text(s.headline ?? s.title)
                        .font(.title3.weight(.bold)).lineLimit(1).minimumScaleFactor(0.75)
                        .id(s.headline ?? s.title)
                        .transition(.push(from: .bottom))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(kind: k, state: s, stale: stale)
                }
            } compactLeading: {
                // 左：短い識別子だけ（教室・勤務先の略称・工程の略名）。無ければアイコン
                HStack(spacing: 3) {
                    Image(systemName: s.symbol).foregroundStyle(accent(s))
                    if let l = s.compactLeading, !l.isEmpty {
                        Text(l).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75).monospacedDigit()
                    }
                }
                .frame(maxWidth: 70, alignment: .leading)
            } compactTrailing: {
                // 右：短い時間か進み具合
                HStack(spacing: 4) {
                    Group {
                        if let t = s.compactTrailing, phase(s, stale: stale) == .run { Text(t).contentTransition(.numericText()) }
                        else { TimeValue(state: s, stale: stale, compact: true) }
                    }
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(accent(s))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    // 進行中は、残りが減っていく小さな丸（OS が動かす）
                    TimeRing(state: s, stale: stale)
                }
                .frame(maxWidth: 74, alignment: .trailing)
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

