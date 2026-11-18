import SwiftUI
import MyTimeCore

// MARK: - 清掃のホーム

struct CleaningHomeView: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false
    @State private var running = false

    var body: some View {
        let book = model.cleaning
        let now = model.now
        let neglected = book.neglected(now: now, time: model.time)
        List {
            Section {
                if let s = book.active {
                    let c = CleaningSession.completion(s.statuses(in: book.areas).map(\.status))
                    Button { running = true } label: {
                        HStack(spacing: 12) {
                            ProgressRing(value: c.ratio ?? 0, ideal: nil, symbol: "bubbles.and.sparkles.fill", tint: .teal, size: 44, done: c.ratio == 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("清掃の途中です").font(.headline).foregroundStyle(.primary)
                                Text("\(c.done)/\(c.total)箇所・\(model.hm(s.startedAt))から").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("続ける").font(.subheadline.weight(.semibold))
                        }
                    }
                } else {
                    Button { choosing = true } label: {
                        Label("清掃を始める", systemImage: "play.fill").font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundStyle(.white)
                            .background(Color.teal.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            if !neglected.isEmpty {
                Section {
                    ForEach(Array(neglected.prefix(5).enumerated()), id: \.offset) { _, x in
                        HStack {
                            Image(systemName: x.area.symbol).foregroundStyle(.teal).frame(width: 24)
                            Text("\(x.area.name)・\(x.item.name)")
                            Spacer()
                            Text(x.overdue.map { "\($0)日過ぎ" } ?? "記録なし").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        }
                    }
                } header: { Text("長く清掃していない場所") }
            }

            ForEach(book.areas) { a in
                Section {
                    ForEach(a.items) { i in itemRow(i) }
                } header: {
                    HStack {
                        Label(a.name, systemImage: a.symbol).foregroundStyle(.teal)
                        Spacer()
                        if let r = book.areaAchievement(a, now: now, time: model.time) {
                            Text("達成 \(Int((r * 100).rounded()))%").font(.caption.weight(.semibold)).monospacedDigit()
                        }
                    }
                    .textCase(nil)
                }
            }

            Section {
                NavigationLink { CleaningHistoryView() } label: { Label("清掃の履歴", systemImage: "clock.arrow.circlepath") }
                NavigationLink { CleaningAreasEditor() } label: { Label("場所と箇所を編集", systemImage: "square.and.pencil") }
            }
        }
        .navigationTitle("清掃")
        .sheet(isPresented: $choosing) { CleaningStartSheet { running = true }.environment(model) }
        .navigationDestination(isPresented: $running) { CleaningSessionView() }
    }

    private func itemRow(_ i: CleaningItem) -> some View {
        let due = i.nextDue(time: model.time)
        let overdue = i.overdueDays(now: model.now, time: model.time) ?? 0
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(i.name)
                Text(i.frequency?.label ?? "頻度なし").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(i.lastDone.map { "前回 \(model.time.dayLabel($0))" } ?? "未記録").font(.caption).foregroundStyle(.secondary)
                if let due {
                    Text(overdue > 0 ? "\(overdue)日過ぎ" : "次 \(model.time.dayLabel(due))").font(.caption.weight(.semibold))
                        .foregroundStyle(overdue > 0 ? Color.white : Color.teal)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(overdue > 0 ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color.teal.opacity(0.12))))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 始める前：場所を選ぶ

struct CleaningStartSheet: View {
    var onStart: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    var body: some View {
        let book = model.cleaning
        NavigationStack {
            ScrollView {
                HStack {
                    Text("今回清掃する場所を選んでください").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button(selected.count == book.areas.count ? "すべて外す" : "すべて選ぶ") {
                        selected = selected.count == book.areas.count ? [] : Set(book.areas.map(\.id))
                    }
                    .font(.subheadline.weight(.semibold))
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(book.areas) { a in
                        let on = selected.contains(a.id)
                        let due = a.items.filter { ($0.overdueDays(now: model.now, time: model.time) ?? 0) > 0 || ($0.frequency != nil && $0.lastDone == nil) }.count
                        Button {
                            if on { selected.remove(a.id) } else { selected.insert(a.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: a.symbol).font(.title2).foregroundStyle(on ? .white : .teal)
                                    Spacer()
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(on ? .white : .secondary)
                                        .contentTransition(.symbolEffect(.replace))
                                }
                                Text(a.name).font(.headline).foregroundStyle(on ? .white : .primary)
                                Text("\(a.items.count)箇所" + (due > 0 ? "・\(due)箇所が目標日を過ぎています" : ""))
                                    .font(.caption).foregroundStyle(on ? .white.opacity(0.85) : .secondary).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                            .background(on ? AnyShapeStyle(Color.teal.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .padding()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("清掃する場所")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("開始") {
                        var b = model.cleaning
                        b.active = CleaningSession(startedAt: model.now, areaIds: book.areas.map(\.id).filter { selected.contains($0) })
                        model.saveCleaning(b)
                        dismiss()
                        onStart()
                    }
                    .fontWeight(.semibold)
                    .disabled(selected.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - 清掃中：箇所ごとのカード（Yes／No／対象外）

struct CleaningSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var summary: CleaningSession?
    @State private var tap = 0

    var body: some View {
        let book = model.cleaning
        Group {
            if let s = book.active {
                let st = s.statuses(in: book.areas)
                let c = CleaningSession.completion(st.map(\.status))
                ScrollView {
                    VStack(spacing: 16) {
                        HStack(spacing: 14) {
                            ProgressRing(value: c.ratio ?? 0, ideal: nil, symbol: "bubbles.and.sparkles.fill", tint: .teal, size: 60, done: c.ratio == 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(c.done) / \(c.total) 箇所").font(.title2.weight(.bold)).monospacedDigit()
                                    .contentTransition(.numericText())
                                    .animation(Motion.value, value: c.done)
                                Text("Yes＝清掃した・No＝まだ・対象外＝今回はしない（数えない）").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Text(Date(timeIntervalSince1970: Double(s.startedAt) / 1000), style: .timer).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.teal)
                            }
                            Spacer()
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        ForEach(book.areas.filter { s.areaIds.contains($0.id) }) { a in
                            VStack(alignment: .leading, spacing: 10) {
                                let ac = CleaningSession.completion(a.items.map { s.results[$0.id] ?? .no })
                                HStack {
                                    Label(a.name, systemImage: a.symbol).font(.headline).foregroundStyle(.teal)
                                    Spacer()
                                    Text("\(ac.done)/\(ac.total)").font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                                        .contentTransition(.numericText())
                                }
                                ProgressView(value: ac.ratio ?? 0).tint(.teal).animation(Motion.value, value: ac.done)
                                ForEach(a.items) { i in card(i, status: s.results[i.id] ?? .no) }
                            }
                        }
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 10) {
                        Button { dismiss() } label: {
                            Text("途中で保存").frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.bordered)
                        Button { finish() } label: {
                            Text("清掃を完了").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent).tint(.teal)
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(.bar)
                }
            } else if let summary {
                summaryView(summary)
            } else {
                ContentUnavailableView("清掃は終わりました", systemImage: "checkmark.circle", description: Text("「清掃を始める」から新しく始められます。"))
            }
        }
        .navigationTitle(model.cleaning.active != nil ? "清掃中" : "清掃の記録")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: tap)
    }

    private func card(_ i: CleaningItem, status: CleaningStatus) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(i.name).font(.body.weight(.semibold)).strikethrough(status == .skip).foregroundStyle(status == .skip ? .secondary : .primary)
                Text(i.lastDone.map { "前回 \(model.time.dayLabel($0))" } ?? "未記録").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                ForEach(CleaningStatus.allCases, id: \.self) { x in
                    let on = x == status
                    Button { set(i.id, x) } label: {
                        Text(x.label).font(.caption.weight(.bold))
                            .frame(minWidth: x == .skip ? 50 : 40, minHeight: 34)
                            .scaleEffect(on ? 1.06 : 1)
                            .foregroundStyle(on ? .white : color(x))
                            .background(Capsule().fill(on ? AnyShapeStyle(color(x).gradient) : AnyShapeStyle(color(x).opacity(0.12))))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(i.name)を\(x.label)にする")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(status == .yes ? Color.green.opacity(0.6) : .clear, lineWidth: 1.5))
        .animation(.snappy, value: status)
    }

    private func color(_ x: CleaningStatus) -> Color { x == .yes ? .green : x == .no ? .orange : .gray }

    private func set(_ id: String, _ x: CleaningStatus) {
        var b = model.cleaning
        b.active?.results[id] = x
        model.saveCleaning(b)
        tap += 1
    }

    private func finish() {
        var b = model.cleaning
        let s = b.finish(at: model.now)
        model.saveCleaning(b, message: "清掃を記録しました")
        withAnimation(.snappy) { summary = s }
    }

    private func summaryView(_ s: CleaningSession) -> some View {
        let done = s.results.filter { $0.value == .yes }.map { s.names[$0.key] ?? "" }.sorted()
        let undone = s.results.filter { $0.value == .no }.map { s.names[$0.key] ?? "" }.sorted()
        let mins = Int(((s.endedAt ?? s.startedAt) - s.startedAt) / MINUTE)
        return List {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 48)).foregroundStyle(.teal)
                        .symbolEffect(.bounce, options: .nonRepeating, value: s.id)
                    Text("清掃を記録しました").font(.title3.weight(.bold))
                    Text(mins < 1 ? "所要時間 1分未満" : "所要時間 \(mins)分").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            Section("清掃した（\(done.count)）") { ForEach(done, id: \.self) { Label($0, systemImage: "checkmark.circle.fill").foregroundStyle(.green) } }
            if !undone.isEmpty { Section("まだの箇所（\(undone.count)）") { ForEach(undone, id: \.self) { Label($0, systemImage: "circle").foregroundStyle(.orange) } } }
            Section { Button("閉じる") { dismiss() } }
        }
    }
}

// MARK: - 履歴

struct CleaningHistoryView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let h = model.cleaning.history
        List {
            if h.isEmpty { ContentUnavailableView("まだ記録がありません", systemImage: "clock") }
            ForEach(h) { s in
                let c = CleaningSession.completion(Array(s.results.values))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(model.time.dayLabel(s.startedAt)) \(model.hm(s.startedAt))").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(c.ratio.map { "\(Int(($0 * 100).rounded()))%" } ?? "-").font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(.teal)
                    }
                    Text("清掃 \(c.done)・まだ \(c.total - c.done)・対象外 \(s.results.values.filter { $0 == .skip }.count)・\(Int(((s.endedAt ?? s.startedAt) - s.startedAt) / MINUTE))分")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("清掃の履歴")
    }
}

// MARK: - 場所と箇所の編集（追加・削除・並べ替え・改名・頻度）

struct CleaningAreasEditor: View {
    @Environment(AppModel.self) private var model
    @State private var book = CleaningBook(areas: [])
    @State private var loaded = false
    @State private var addingArea = false
    @State private var newName = ""

    var body: some View {
        List {
            ForEach($book.areas) { $a in
                Section {
                    TextField("場所の名前", text: $a.name).font(.headline)
                    ForEach($a.items) { $i in
                        NavigationLink {
                            CleaningItemEditor(item: $i)
                        } label: {
                            HStack {
                                Text(i.name.isEmpty ? "（名前なし）" : i.name)
                                Spacer()
                                Text(i.frequency?.label ?? "頻度なし").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { a.items.remove(atOffsets: $0) }
                    .onMove { a.items.move(fromOffsets: $0, toOffset: $1) }
                    Button("箇所を追加", systemImage: "plus") { a.items.append(CleaningItem(name: "新しい箇所", frequency: .weekly)) }
                } header: {
                    HStack {
                        Label(a.name, systemImage: a.symbol)
                        Spacer()
                        Button(role: .destructive) { book.areas.removeAll { $0.id == a.id } } label: { Image(systemName: "trash") }
                            .accessibilityLabel("\(a.name)を削除")
                    }
                }
            }
            .onMove { book.areas.move(fromOffsets: $0, toOffset: $1) }
            Section {
                Button("場所を追加", systemImage: "plus.circle.fill") { newName = ""; addingArea = true }
            } footer: { Text("「編集」で並べ替え、左へなぞって削除できます。間違えたときは iPhone を振ると戻せます。") }
        }
        .navigationTitle("場所と箇所")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .alert("場所を追加", isPresented: $addingArea) {
            TextField("例：洗面所", text: $newName)
            Button("追加") { book.areas.append(CleaningArea(name: newName.isEmpty ? "新しい場所" : newName, symbol: "house.fill", items: [])) }
            Button("キャンセル", role: .cancel) {}
        }
        .onAppear { if !loaded { book = model.cleaning; loaded = true } }
        .onChange(of: book) { _, b in model.saveCleaning(b, message: "清掃の場所を変更しました") }
    }
}

struct CleaningItemEditor: View {
    @Binding var item: CleaningItem
    var body: some View {
        Form {
            Section { TextField("箇所の名前", text: $item.name) }
            Section {
                Toggle("頻度の目標", isOn: Binding(get: { item.frequency != nil }, set: { item.frequency = $0 ? .weekly : nil }))
                if let f = item.frequency {
                    Picker("単位", selection: Binding(get: { f.unit }, set: { item.frequency?.unit = $0 })) {
                        ForEach(CleanFrequency.Unit.allCases, id: \.self) { Text($0 == .day ? "日" : $0 == .week ? "週" : "月").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper("\(f.every)\(f.unit.label)ごとに", value: Binding(get: { f.every }, set: { item.frequency?.every = max(1, $0) }), in: 1...12)
                    Stepper("\(f.times)回", value: Binding(get: { f.times }, set: { item.frequency?.times = max(1, $0) }), in: 1...14)
                    LabeledContent("目標", value: item.frequency?.label ?? "")
                }
            } footer: { Text("例：浴槽は毎日、排水口は週2回、窓は月1回。清掃を記録すると次の目標日を計算し直します。") }
            Section {
                if let l = item.lastDone {
                    LabeledContent("前回", value: DomainTime.current.dayLabel(l))
                    if let d = item.nextDue() { LabeledContent("次の目標日", value: DomainTime.current.dayLabel(d)) }
                    Button("前回の記録を消す", role: .destructive) { item.lastDone = nil }
                } else {
                    Text("まだ記録がありません").foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
