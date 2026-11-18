import SwiftUI
import MyTimeCore

// MARK: - 種類ごとの設定（一覧）

struct SpecSettingsListView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        List {
            ForEach(SpecGroup.allCases, id: \.self) { g in
                let defs = SPEC_PICKABLE.filter { $0.group == g && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.blurb.localizedCaseInsensitiveContains(query)) }
                if !defs.isEmpty {
                    Section(g.label) {
                        ForEach(defs) { d in
                            NavigationLink { SpecSettingsView(type: d.id) } label: { row(d) }
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "種類を探す")
        .navigationTitle("専門の種類")
    }

    private func row(_ d: SpecDef) -> some View {
        let s = model.specSetting(d.id)
        return HStack(spacing: 12) {
            Image(systemName: model.specSymbol(d.id)).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(model.specTint(d.id).gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .opacity(s.enabled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.name).foregroundStyle(s.enabled ? .primary : .secondary)
                Text(s.enabled ? d.blurb : "オフ（種類の選択に出しません）").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - 種類ごとの設定（1つ）

struct SpecSettingsView: View {
    var type: SpecTypeId
    @Environment(AppModel.self) private var model
    @State private var s = SpecSettings()
    @State private var loaded = false

    private static let symbols = ["briefcase.fill", "graduationcap.fill", "book.fill", "pencil", "doc.text.fill", "target", "star.fill", "cart.fill", "heart.fill", "airplane", "tram.fill", "sun.max.fill", "sunrise.fill", "sparkles", "bubbles.and.sparkles.fill", "frying.pan.fill", "figure.run", "laptopcomputer", "creditcard.fill", "music.note", "yensign.circle.fill", "person.3.fill", "lightbulb.fill", "calendar"]
    private static let colors = ["#FF453A", "#FF9F0A", "#FFD60A", "#34C759", "#30B0C7", "#64D2FF", "#0A84FF", "#5E5CE6", "#BF5AF2", "#FF375F", "#A2845E", "#8E8E93"]

    var body: some View {
        let def = SPEC_BY_ID[type]!
        Form {
            Section {
                Toggle(isOn: $s.enabled) { Label("この種類を使う", systemImage: "checkmark.circle") }
            } footer: { Text("オフにすると種類の選択に出しません。すでにある予定・タスクはそのまま残ります。") }

            if type == .cleaning || type == .morning || type == .shift || type == .payday {
                Section("専用の画面") {
                    switch type {
                    case .cleaning: NavigationLink { CleaningHomeView() } label: { Label("清掃の場所・頻度・履歴", systemImage: "bubbles.and.sparkles.fill") }
                    case .morning: NavigationLink { MorningHomeView() } label: { Label("起床アラーム・顔と髪の工程", systemImage: "sunrise.fill") }
                    default: NavigationLink { EmployersView() } label: { Label("勤務先と給与", systemImage: "yensign.circle.fill") }
                    }
                }
            }

            Section("見た目") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach([def.symbol] + Self.symbols.filter { $0 != def.symbol }, id: \.self) { sym in
                            Button { s.symbol = sym == def.symbol ? nil : sym } label: {
                                Image(systemName: sym).frame(width: 36, height: 36)
                                    .background(Circle().fill((s.symbol ?? def.symbol) == sym ? model.specTint(type).opacity(0.25) : Color(.tertiarySystemFill)))
                            }
                            .buttonStyle(.plain).accessibilityLabel(sym)
                        }
                    }
                }
                HStack(spacing: 8) {
                    ForEach([def.color] + Self.colors.filter { $0 != def.color }, id: \.self) { c in
                        Button { s.color = c == def.color ? nil : c } label: {
                            Circle().fill(Color(hex: c)).frame(width: 24, height: 24)
                                .overlay { if (s.color ?? def.color) == c { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) } }
                        }
                        .buttonStyle(.plain).accessibilityLabel("色 \(c)")
                    }
                }
            }

            Section {
                Picker("既定の所要時間", selection: $s.defaultMinutes) {
                    Text("指定しない").tag(Int?.none)
                    ForEach([15, 30, 45, 60, 90, 120, 180, 240], id: \.self) { m in Text(m < 60 ? "\(m)分" : "\(m / 60)時間\(m % 60 == 0 ? "" : "\(m % 60)分")").tag(Optional(m)) }
                }
                Picker("通知", selection: $s.notifyBefore) {
                    Text("指定しない").tag(Int?.none)
                    ForEach([0, 5, 10, 15, 30, 60, 1440], id: \.self) { m in Text(NotifyPicker.label(m)).tag(Optional(m)) }
                }
                Picker("繰り返し", selection: $s.repeatRule) {
                    Text("指定しない").tag(String?.none)
                    Text("毎日").tag(Optional("daily")); Text("毎週").tag(Optional("weekly")); Text("毎月").tag(Optional("monthly"))
                }
                Picker("カレンダーへの表示", selection: $s.calendarDisplay) {
                    Text("ふつう").tag("normal"); Text("薄く").tag("quiet"); Text("出さない").tag("hidden")
                }
            } header: { Text("新しく作るときの既定") } footer: { Text("この種類を選んだときに、所要時間・通知・繰り返しを自動で入れます。") }

            if !def.fields.isEmpty {
                Section {
                    ForEach(def.fields, id: \.key) { f in
                        Toggle(f.label, isOn: Binding(get: { !s.hiddenFields.contains(f.key) }, set: { on in if on { s.hiddenFields.remove(f.key) } else { s.hiddenFields.insert(f.key) } }))
                    }
                } header: { Text("専門項目") } footer: { Text("オフにした項目は入力画面に出しません（保存済みの値は消えません）。") }
            }

            Section {
                if s.templates.isEmpty { Text("入力画面の「テンプレートとして保存」で追加できます").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(s.templates) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name)
                        Text(t.title + (t.minutes.map { "・\($0)分" } ?? "")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { s.templates.remove(atOffsets: $0) }
            } header: { Text("テンプレート") }

            historySection(def)

            Section {
                Button("既定に戻す", role: .destructive) { s = SpecSettings() }
            }
        }
        .navigationTitle(def.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !loaded { s = model.specSetting(type); loaded = true } }
        .onChange(of: s) { _, v in model.saveSpecSetting(type, v) }
    }

    @ViewBuilder
    private func historySection(_ def: SpecDef) -> some View {
        let now = model.now
        let monthAgo = model.time.addDays(now, -30)
        let tasks = model.tasks.filter { $0.specType == type }
        let events = model.events.filter { $0.specType == type }
        let done = tasks.filter(\.isDone)
        let worked = done.reduce(EpochMs(0)) { $0 + workedMs($1, at: now) }
        let recent = tasks.filter { ($0.plannedStart ?? $0.createdAt) >= monthAgo }.count + events.filter { $0.start >= monthAgo }.count
        Section {
            LabeledContent("登録した数", value: "予定 \(events.count)・タスク \(tasks.count)")
            LabeledContent("完了したタスク", value: "\(done.count)件")
            if worked > 0 { LabeledContent("完了までの作業時間", value: formatDuration(worked)) }
            LabeledContent("最近30日", value: "\(recent)件")
            if type == .cleaning { LabeledContent("清掃の記録", value: "\(model.cleaning.history.count)回") }
            if type == .morning { LabeledContent("朝の記録", value: "\(model.morning.history.count)回") }
        } header: { Text("履歴・実績") }
    }
}

// MARK: - Live Activity の設定

struct LiveActivitySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var p = LivePrefs()
    @State private var loaded = false
    @State private var active: [String] = []

    var body: some View {
        Form {
            Section {
                LabeledContent("この iPhone", value: LiveActivityCoordinator.shared.activitiesEnabled ? "使えます" : "オフ（設定アプリ › My Time で許可）")
                if !active.isEmpty {
                    ForEach(active, id: \.self) { Text($0).font(.subheadline) }
                }
            } header: { Text("状態") } footer: {
                Text("ロック画面とダイナミックアイランドに出します。どれをダイナミックアイランドに出すかは iPhone（OS）が決めるため、ここで決めるのは「どれを先に始めるか」です。")
            }
            Section {
                ForEach(LiveKind.allCases, id: \.self) { k in
                    Toggle(k.label, isOn: Binding(get: { !p.disabled.contains(k) }, set: { on in if on { p.disabled.remove(k) } else { p.disabled.insert(k) } }))
                }
            } header: { Text("出す種類（上から重要な順）") }
            Section {
                Picker("同時に出す数", selection: $p.maxConcurrent) { Text("1つ").tag(1); Text("2つ").tag(2) }
                Picker("授業：開始の何分前から", selection: $p.classLeadMinutes) { ForEach([10, 15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0)分前").tag($0) } }
                Picker("授業：開始の何分後に終える", selection: $p.classEndAfterStart) { ForEach([0, 5, 10, 15, 30], id: \.self) { Text($0 == 0 ? "開始時刻" : "\($0)分後").tag($0) } }
                Picker("移動：出発の何分前から", selection: $p.transitLeadMinutes) { ForEach([10, 15, 30, 45, 60], id: \.self) { Text("\($0)分前").tag($0) } }
                Picker("チェックポイント：何分前から", selection: $p.checkpointLeadMinutes) { ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0)分前").tag($0) } }
                NavigationLink { EmployersView() } label: { Text("バイト：勤務先ごとに設定") }
            } header: { Text("タイミング") } footer: {
                Text("iOS 26 以降は、これからの授業・バイトを予約しておき、アプリを開いていなくても時刻になると出ます。それより前の iOS では、アプリを開いたときに出し、通知で代わりに知らせます。終わる時刻を過ぎると「終了」と表示し、次にアプリを開いたときに消えます。")
            }
            Section {
                Button("いま出ているものをすべて終える", role: .destructive) { Task { await LiveActivityCoordinator.shared.endAll(); active = [] } }
                Button("いま照合する") { Task { await LiveActivityCoordinator.shared.reconcile(model: model); active = LiveActivityCoordinator.shared.activeSummaries } }
            }
        }
        .navigationTitle("Live Activity")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !loaded { p = model.livePrefs; loaded = true }
            active = LiveActivityCoordinator.shared.activeSummaries
        }
        .onChange(of: p) { _, v in model.saveLivePrefs(v) }
    }
}
