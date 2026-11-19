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
    case .active: return k == "shift" ? "勤務中" : k == "classNext" ? "授業中" : k == "transit" ? "移動中" : "進行中"
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

// MARK: - 時間の進み具合（OS が自動で動かす。アプリが止まっていても進む）

/// 進行中：開始から終了までの帯が時間とともに伸びる。開始前：出発・開始までの残りが縮む（直前の1時間）
struct TimeProgressBar: View {
    var state: MyTimeActivityAttributes.ContentState
    var stale: Bool
    var body: some View {
        let p = phase(state, stale: stale)
        Group {
            if p == .active, let s = state.countdownTo, let e = state.endsAt, e > s {
                ProgressView(timerInterval: s...e, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else if p == .before, let to = state.countdownTo, to > .now {
                ProgressView(timerInterval: to.addingTimeInterval(-3600)...to, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
            }
        }
        .progressViewStyle(.linear)
        .tint(accent(state))
        .labelsHidden()
    }
}

/// 小さな丸の進み具合（ダイナミックアイランドの右）
struct TimeRing: View {
    var state: MyTimeActivityAttributes.ContentState
    var stale: Bool
    var body: some View {
        let p = phase(state, stale: stale)
        if p == .active, let s = state.countdownTo, let e = state.endsAt, e > s {
            ProgressView(timerInterval: s...e, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                .progressViewStyle(.circular).tint(accent(state)).frame(width: 18, height: 18)
        }
    }
}

/// 詳細スケジュールの「いま」「次」
struct SubScheduleLine: View {
    var state: MyTimeActivityAttributes.ContentState
    var body: some View {
        if state.subNow != nil || state.subNext != nil {
            HStack(spacing: 6) {
                if let n = state.subNow {
                    Label(n, systemImage: "smallcircle.filled.circle").font(.caption.weight(.semibold)).foregroundStyle(accent(state))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .id("now-\(n)")
                        .transition(.push(from: .bottom))
                }
                if let x = state.subNext {
                    Text("次：\(x)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .id("next-\(x)")
                        .transition(.push(from: .bottom))
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - 移動の段取り（区間を時刻の順に。まだ来ていない区間には残りの分を出す）

struct LegsList: View {
    var state: MyTimeActivityAttributes.ContentState
    var limit = 4
    var body: some View {
        if let legs = state.legs, !legs.isEmpty {
            // 終わった区間は出さない（アプリが更新したとき）。乗り物の区間を目立たせる
            let rest = legs.filter { $0.arrive > .now }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array((rest.isEmpty ? legs : rest).prefix(limit).enumerated()), id: \.offset) { _, l in
                    HStack(spacing: 6) {
                        Image(systemName: l.symbol).font(.caption.weight(.bold))
                            .foregroundStyle(l.ride ? accent(state) : .secondary)
                            .frame(width: 18)
                        Text(l.depart, style: .time).font(.caption.weight(.semibold)).monospacedDigit().fixedSize()
                        // 乗る所→降りる所を優先して見せる。路線名は余りがあるときだけ
                        Text(l.ride ? "\(l.from) → \(l.to)" : "\(l.to)へ").font(.caption.weight(l.ride ? .bold : .regular)).lineLimit(1)
                            .minimumScaleFactor(0.8).layoutPriority(1)
                        if let line = l.line { Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1) }
                        Spacer(minLength: 2)
                        if l.depart > .now {
                            MinuteCountdown(from: .now, to: l.depart, compact: true)
                                .font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(accent(state))
                                .lineLimit(1).fixedSize()
                        }
                    }
                    .transition(.push(from: .bottom))
                }
            }
        }
    }
}

// MARK: - 拡張表示の下段

struct ExpandedBottom: View {
    var kind: String
    var state: MyTimeActivityAttributes.ContentState
    var stale: Bool
    var body: some View {
        let p = phase(state, stale: stale)
        // ダイナミックアイランドは高さに限りがある（はみ出すと切れる）。
        // 補足の行・進み具合・追加の1つ（区間か「いま／次」）・ボタンの1列、までにする
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if state.headline != nil { Text(state.title).font(.subheadline.weight(.semibold)).lineLimit(1).layoutPriority(1) }
                if let d = state.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit() }
                Spacer(minLength: 0)
                if let st = state.status { Text(st).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1).fixedSize() }
            }
            if let done = state.progressDone, let total = state.progressTotal, total > 0 {
                HStack(spacing: 8) {
                    ProgressView(value: Double(done), total: Double(total)).tint(accent(state))
                    Text(kind == "morning" ? "\(min(total, done + 1))/\(total)" : "\(done)/\(total)").font(.caption.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText()).fixedSize()
                }
                if let n = state.next { Text("次：\(n)").font(.caption).foregroundStyle(.secondary).lineLimit(1).id(n).transition(.push(from: .bottom)) }
            } else {
                TimeProgressBar(state: state, stale: stale)
            }
            if let legs = state.legs, !legs.isEmpty {
                LegsList(state: state, limit: 2)
            } else if state.progressTotal == nil {
                SubScheduleLine(state: state)
            }
            buttons(p)
        }
        .padding(.horizontal, 4)
    }

    /// ボタンは1列だけ（朝・清掃の工程 → タスクの完了 → 経路 の順に1つを選ぶ）
    @ViewBuilder
    private func buttons(_ p: Phase) -> some View {
        if state.canComplete, let token = state.token, p == .run {
            HStack(spacing: 8) {
                Button(intent: MorningStepIntent(action: "back:\(token)")) { Image(systemName: "chevron.backward").accessibilityLabel("前の工程へ") }
                    .tint(.gray)
                Button(intent: MorningStepIntent(action: "skip:\(token)")) { Label("スキップ", systemImage: "forward.end").frame(maxWidth: .infinity) }
                    .tint(.gray)
                Button(intent: MorningStepIntent(action: "complete:\(token)")) { Label("完了", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    .tint(accent(state))
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .buttonStyle(.borderedProminent)
        } else if (kind == "task" || kind == "study"), let tid = state.token, p == .run {
            Button(intent: FinishTaskIntent(taskId: tid)) { Label("完了", systemImage: "checkmark").frame(maxWidth: .infinity) }
                .tint(accent(state)).buttonStyle(.borderedProminent).font(.caption.weight(.semibold))
        } else if let r = state.routeURL, let u = URL(string: r), p == .before {
            Link(destination: u) {
                Label("経路", systemImage: "arrow.triangle.turn.up.right.diamond.fill").font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(accent(state).opacity(0.25)))
            }
        }
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
        let hasButtons = p == .run && state.token != nil && (state.canComplete || kind == "task" || kind == "study")
        let hasLegs = !(state.legs ?? []).isEmpty
        // ロック画面の表示は高さ160ptまで（超えると下が切れる）。ボタンがあるときは区間を1つに減らし、経路は小さく
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: p == .ended ? "checkmark" : state.symbol)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .background(accent(state).gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kindLabel(kind)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Text(state.title).font(.headline).lineLimit(1).minimumScaleFactor(0.85)
                        .id(state.title)
                        .transition(.push(from: .bottom))
                    if let d = state.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).monospacedDigit() }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(phaseLabel(kind, p)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    TimeValue(state: state, stale: stale)
                        .font(.title3.weight(.bold)).monospacedDigit()
                        .foregroundStyle(p == .ended ? Color.secondary : accent(state))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: 110, alignment: .trailing)
                }
            }
            // いちばん大事な情報を大きく（授業の教室・バイトの出勤時刻・朝の工程・清掃の場所）
            if let h = state.headline, p != .ended, h != state.title {
                Text(h).font(.system(size: hasLegs || hasButtons ? 24 : 28, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                    .id(h)
                    .transition(.asymmetric(insertion: .push(from: .bottom), removal: .push(from: .bottom)))
            }
            if let done = state.progressDone, let total = state.progressTotal, total > 0 {
                ProgressView(value: Double(done), total: Double(total)).tint(accent(state))
                HStack {
                    Text(kind == "morning" ? "全\(total)工程中 \(min(total, done + 1))工程目" : "\(done)/\(total)").font(.caption.weight(.semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                    if let n = state.next { Text("次：\(n)").font(.caption).foregroundStyle(.secondary).lineLimit(1).id(n).transition(.push(from: .bottom)) }
                    Spacer()
                }
            } else if p != .ended {
                // 時間の帯（開始前は縮み、進行中は伸びる。OS が動かすので、アプリが止まっていても進む）
                TimeProgressBar(state: state, stale: stale)
            }
            if hasLegs {
                LegsList(state: state, limit: hasButtons ? 1 : 2)
            } else {
                SubScheduleLine(state: state)
            }
            if !hasButtons, let r = state.routeURL, let u = URL(string: r), p == .before {
                Link(destination: u) {
                    Label("経路を開く", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.footnote.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(Capsule().fill(accent(state).opacity(0.2)))
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
        .padding(14)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: state)
        // 壁紙に左右されないよう、背景は OS の素材にまかせ、文字は標準の色（高いコントラスト）
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
    }
}
