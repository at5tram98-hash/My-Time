import SwiftUI
import MyTimeCore

/// チェックポイント：時刻に打つピン（「バスに乗る」など）。
/// 時刻軸の「予定」のレーンにオレンジの線で出し、タップで小さな詳細。アラームと通知も付けられる。
/// 保存は設定の iosCheckpoints（Web 版は知らない項目を無視する）
struct Checkpoint: Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var at: EpochMs
    var notes: String = ""
    /// 時計アプリと同じアラームで鳴らす
    var alarm: Bool = false
    /// 何分前に知らせるか（nil：知らせない）
    var notifyBefore: Int? = nil
    /// 毎日・平日・毎週（nil：その日だけ）
    var repeatRule: String? = nil

    init(id: String, title: String, at: EpochMs, notes: String = "", alarm: Bool = false, notifyBefore: Int? = nil, repeatRule: String? = nil) {
        self.id = id; self.title = title; self.at = at; self.notes = notes; self.alarm = alarm; self.notifyBefore = notifyBefore; self.repeatRule = repeatRule
    }

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue, let at = v["at"]?.intValue else { return nil }
        self.id = id; self.at = at
        title = v["title"]?.stringValue ?? ""
        notes = v["notes"]?.stringValue ?? ""
        alarm = v["alarm"]?.boolValue ?? false
        notifyBefore = v["notifyBefore"]?.intValue.map(Int.init)
        repeatRule = v["repeat"]?.stringValue
    }

    var json: JSONValue {
        .object(["id": .string(id), "title": .string(title), "at": .number(Double(at)), "notes": .string(notes), "alarm": .bool(alarm),
                 "notifyBefore": notifyBefore.map { .number(Double($0)) } ?? .null, "repeat": repeatRule.map { .string($0) } ?? .null])
    }
}

extension AppModel {
    static let checkpointsKey = ChatGPTTransfer.checkpointsKey

    var checkpoints: [Checkpoint] {
        (settings.raw[Self.checkpointsKey]?.arrayValue ?? []).compactMap(Checkpoint.init).sorted { $0.at < $1.at }
    }

    /// その日に出るチェックポイント（繰り返しは、その日の同じ時刻に）
    func checkpoints(on day: EpochMs) -> [Checkpoint] {
        let records = settings.raw[Self.checkpointsKey]?.arrayValue ?? []
        return ChatGPTTransfer.checkpoints(records, on: day, time: time).compactMap(Checkpoint.init)
    }

    func saveCheckpoint(_ c: Checkpoint?, removing id: String? = nil) {
        guard let id = id ?? c?.id else { return }
        updateSettings { ChatGPTTransfer.updateCheckpoint(c?.json, id: id, settings: &$0) }
    }
}

// MARK: 時刻軸の線

/// オレンジの固定の線。現在時刻の札と同じく、時刻の目盛り（灰色の列）に時刻を出し、そのままタイトルへつなげる。
/// gutter：時刻の列の幅（週表示の列の中では 0）
struct CheckpointLine: View {
    var checkpoint: Checkpoint
    var width: CGFloat
    var gutter: CGFloat = 0
    /// 現在時刻の札と重なるとき（時刻の列ではなく、その右に出す）
    var nearNow = false
    /// 線の色（チェックポイントはオレンジ、起床アラームは黄色）
    var tint: Color = .orange
    /// 名前の前のアイコン（起床アラームなど）
    var symbol: String? = nil
    var onTap: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(tint).frame(height: 1.5).padding(.leading, gutter)
            HStack(spacing: 0) {
                Text(model.hm(checkpoint.at))
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .padding(.leading, 5).padding(.trailing, 4)
                if !checkpoint.title.isEmpty {
                    Rectangle().fill(.white.opacity(0.5)).frame(width: 1, height: 10)
                    if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)).padding(.leading, 4) }
                    Text(checkpoint.title)
                        .font(.caption2.weight(.semibold)).lineLimit(1)
                        .padding(.leading, 4).padding(.trailing, 6)
                }
            }
            .foregroundStyle(tint == .yellow ? Color.black : .white)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint))
            .fixedSize()
            // 時刻の部分が目盛りの列の右端にそろうように置く
            .offset(x: gutter > 0 ? (nearNow ? gutter + 2 : max(0, gutter - 40)) : 1)
        }
        .frame(width: width + gutter, height: 18, alignment: .leading)
        .contentShape(Rectangle())
        // 下の予定の札（UIKit のジェスチャー）より先に受け取る
        .overlay { PressDragRecognizer(onTap: onTap) }
        .accessibilityElement(children: .ignore)
        .accessibilityAction { onTap() }
        .accessibilityLabel("チェックポイント \(checkpoint.title)、\(model.hm(checkpoint.at))")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: 詳細（コンパクト）と編集

struct CheckpointSheet: View {
    @State var checkpoint: Checkpoint
    var isNew: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(Router.self) private var router: Router?
    @State private var editing = false
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if isNew || editing { editor } else { summary }
            }
            .navigationTitle(isNew ? "新しいチェックポイント" : editing ? "チェックポイントを編集" : "チェックポイント")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("閉じる")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isNew || editing {
                        Button(isNew ? "追加" : "保存") { save() }.fontWeight(.semibold)
                    } else {
                        Button("編集") {
                            if checkpoint.repeatRule != nil, let series = model.checkpoints.first(where: { $0.id == checkpoint.id }) {
                                checkpoint = series
                            }
                            withAnimation(.snappy) { editing = true }
                        }
                    }
                }
            }
            .alert("このチェックポイントを削除しますか？", isPresented: $confirmDelete) {
                Button("削除", role: .destructive) { model.saveCheckpoint(nil, removing: checkpoint.id); dismiss() }
                Button("キャンセル", role: .cancel) {}
            }
        }
        .presentationDetents(isNew || editing ? [.large] : [.height(260)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    /// 見るだけ：名前・時刻・あと何分・アラーム（コンパクト）
    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3).fill(Color.orange).frame(width: 6, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(checkpoint.title.isEmpty ? "チェックポイント" : checkpoint.title).font(.title3.weight(.bold)).lineLimit(2)
                    Text("\(model.time.dayLabel(checkpoint.at)) \(model.hm(checkpoint.at))").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    let m = Int((checkpoint.at - model.time.ms(ctx.date)) / MINUTE)
                    if m > 0 {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("あと").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            Text(m < 60 ? "\(m)分" : "\(m / 60)時間\(m % 60)分").font(.headline).monospacedDigit().foregroundStyle(.orange)
                        }
                        .fixedSize()
                    }
                }
            }
            HStack(spacing: 8) {
                if checkpoint.alarm { StatusPill(text: "アラーム", color: .orange, symbol: "alarm.fill") }
                if let n = checkpoint.notifyBefore { StatusPill(text: n == 0 ? "ちょうどに通知" : "\(n)分前に通知", color: .pink, symbol: "bell.fill") }
                if let r = checkpoint.repeatRule { StatusPill(text: Self.repeatLabel(r), color: .indigo, symbol: "repeat") }
            }
            if !checkpoint.notes.isEmpty { Text(checkpoint.notes).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
            Spacer(minLength: 0)
            Button(role: .destructive) { confirmDelete = true } label: {
                Text("削除").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    private var editor: some View {
        Form {
            if isNew {
                // タスク・予定にも戻れる（新しく作る画面と同じ切り替え）
                Picker("作成する種類", selection: Binding(get: { 2 }, set: { v in
                    guard v != 2, let router else { return }
                    let s = checkpoint.at
                    router.replace(.editor(EditorSeed(kind: v == 0 ? .task : .event, start: s, end: s + HOUR, title: checkpoint.title.isEmpty ? nil : checkpoint.title)))
                })) {
                    Text("タスク").tag(0)
                    Text("予定").tag(1)
                    Text("チェックポイント").tag(2)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0))
            }
            Section {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.orange).frame(width: 4, height: 28)
                    TextField("例：バスに乗る", text: $checkpoint.title).font(.title3.weight(.medium)).focused($focused)
                }
                DatePicker("時刻", selection: Binding(get: { model.time.date(checkpoint.at) }, set: { checkpoint.at = model.time.ms($0) }))
            }
            Section {
                Toggle(isOn: Binding(get: { checkpoint.alarm }, set: { v in
                    checkpoint.alarm = v
                    if v { Task { if await !TaskAlarms.requestAuthorization() { _ = await NotificationScheduler.requestAuthorization() } } }
                })) {
                    Label("アラーム", systemImage: "alarm.fill")
                }
                .tint(.orange)
                Picker(selection: $checkpoint.notifyBefore) {
                    Text("なし").tag(Int?.none)
                    ForEach([0, 5, 10, 15, 30, 60], id: \.self) { m in Text(m == 0 ? "ちょうど" : "\(m)分前").tag(Optional(m)) }
                } label: { Label("通知", systemImage: "bell.fill") }
                Picker(selection: $checkpoint.repeatRule) {
                    Text("しない").tag(String?.none)
                    ForEach(["daily", "weekdays", "weekly"], id: \.self) { r in Text(Self.repeatLabel(r)).tag(Optional(r)) }
                } label: { Label("繰り返し", systemImage: "repeat") }
            } footer: { Text("アラームは時計アプリと同じように、マナーモードでも鳴ります。") }
            Section("メモ") {
                TextField("メモ", text: $checkpoint.notes, axis: .vertical).lineLimit(2...6)
            }
        }
        .onAppear { if isNew { focused = true } }
    }

    static func repeatLabel(_ r: String) -> String { r == "daily" ? "毎日" : r == "weekdays" ? "平日" : "毎週" }

    private func save() {
        checkpoint.title = checkpoint.title.trimmingCharacters(in: .whitespacesAndNewlines)
        model.saveCheckpoint(checkpoint)
        if isNew { dismiss() } else { withAnimation(.snappy) { editing = false } }
    }
}
