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
    static let checkpointsKey = "iosCheckpoints"

    var checkpoints: [Checkpoint] {
        (settings.raw[Self.checkpointsKey]?.arrayValue ?? []).compactMap(Checkpoint.init).sorted { $0.at < $1.at }
    }

    /// その日に出るチェックポイント（繰り返しは、その日の同じ時刻に）
    func checkpoints(on day: EpochMs) -> [Checkpoint] {
        let d0 = time.startOfDay(day), d1 = time.addDays(d0, 1)
        return checkpoints.compactMap { c in
            if c.at >= d0 && c.at < d1 { return c }
            guard let r = c.repeatRule, c.at < d1 else { return nil }
            let wd = time.weekday(d0)
            let ok: Bool
            switch r {
            case "daily": ok = true
            case "weekdays": ok = (1...5).contains(wd)
            case "weekly": ok = time.weekday(c.at) == wd
            default: ok = false
            }
            guard ok else { return nil }
            var x = c
            x.at = d0 + (c.at - time.startOfDay(c.at))
            return x
        }
        .sorted { $0.at < $1.at }
    }

    func saveCheckpoint(_ c: Checkpoint?, removing id: String? = nil) {
        updateSettings { s in
            var list = s.raw[Self.checkpointsKey]?.arrayValue ?? []
            let rid = id ?? c?.id
            list.removeAll { $0["id"]?.stringValue == rid }
            if let c { list.append(c.json) }
            s.raw = s.raw.merging(.object([Self.checkpointsKey: .array(list)]))
        }
    }
}

// MARK: 時刻軸の線

/// オレンジの固定の線（現在線と同じ形で、名前だけ）。タップで詳細
struct CheckpointLine: View {
    var checkpoint: Checkpoint
    var width: CGFloat
    var onTap: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.orange).frame(width: width, height: 1.5)
            HStack(spacing: 3) {
                Image(systemName: checkpoint.alarm ? "alarm.fill" : "mappin").font(.system(size: 8, weight: .bold))
                Text(checkpoint.title.isEmpty ? model.hm(checkpoint.at) : checkpoint.title).font(.system(size: 10, weight: .bold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.orange))
            .fixedSize()
            .offset(x: 2)
        }
        .frame(width: width, height: 18, alignment: .leading)
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
                        Button("編集") { withAnimation(.snappy) { editing = true } }
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
                Image(systemName: "mappin.circle.fill").font(.system(size: 34)).foregroundStyle(.orange)
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
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(.orange)
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
