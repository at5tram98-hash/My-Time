import SwiftUI
import MyTimeCore

/// 予定・タスクの追加と編集（Web 版と同じく「基本」「オプション」「専用」の3つに分ける）。
/// 基本：名前・日付（タップで月のカレンダー）・時間（なぞる／タップで時刻のホイール）・繰り返し・場所と移動・通知。
/// オプション：カレンダー・色・カテゴリー・フラグ・会議の URL・リンク・メモ・終了後に隠す。
/// 専用：種類ごとの項目、授業の科目と教室。
/// 保存できない入力は理由を表示し、入力はそのまま残す。
struct EditorView: View {
    var seed: EditorSeed
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss

    enum Page: String, CaseIterable { case basic = "基本", option = "オプション", special = "専用" }
    /// その場で開いている行（1つだけ開く）
    enum Open: Equatable { case none, date, time, place, deadline }

    @State private var page: Page = .basic
    @State private var open: Open = .none
    @State private var kind: EditorSeed.Kind = .task
    @State private var loaded = false
    @State private var isNew = true
    @State private var task = MTTask.make(title: "", now: 0)
    @State private var event = MTEvent.make(title: "", calendarId: "cal-general", start: 0, end: 0, now: 0)
    @State private var title = ""
    @State private var notes = ""
    @State private var spec: SpecTypeId?
    /// 種類ごとの専用の項目（extra.spec.details。締切 dueAt は別に扱う）
    @State private var details: [String: JSONValue] = [:]
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var hasTime = true
    @State private var allDay = false
    @State private var isCheck = false
    @State private var hasDeadline = false
    @State private var deadline = Date().addingTimeInterval(86400)
    @State private var estimate = 30
    @State private var hasEstimate = false
    @State private var calendarId = "cal-general"
    @State private var rule: RecurrenceRule?
    @State private var place: PlaceValue?
    @State private var travel: Int?
    @State private var notifies: [Int] = []
    @State private var meetingUrl = ""
    @State private var links: [LinkItem] = []
    @State private var color: String?
    @State private var category = ""
    @State private var taskCalendarId: String?
    @State private var hideAfterEnd = false
    @State private var subjectName = ""
    @State private var room = ""
    @State private var flagged = false
    @State private var icon = "book"
    @State private var saved = 0
    @State private var error: String?
    @State private var keyboardUp = false
    @State private var alarm = false
    /// シフトの勤務先と調整中（新しいシフトは最初から調整中）
    @State private var employerId: String?
    @State private var shiftPending = true
    @State private var newEmployerPrompt = false
    /// Create Studio の種類と値（extra.studio = { typeId, version, values }）
    @State private var studioId: String?
    @State private var studioValues: [String: JSONValue] = [:]
    @State private var bring = ""
    @FocusState private var titleFocused: Bool
    /// 開いたときの入力の内容（変更があるか比べる）
    @State private var initialSignature = ""
    @State private var confirmDiscard = false

    struct LinkItem: Identifiable, Equatable { var id = UUID().uuidString; var title = ""; var url = "" }

    static let colors = ["#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#30B0C7", "#0A84FF", "#5E5CE6", "#BF5AF2", "#FF2D55", "#A2845E", "#8E8E93"]
    static let notifyChoices = [0, 5, 10, 15, 30, 60, 120, 1440]

    var body: some View {
        NavigationStack {
            Form {
                header
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                switch page {
                case .basic: basicPage
                case .option: optionPage
                case .special: specialPage
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.top, 4, for: .scrollContent)
            .navigationTitle(isNew ? (kind == .event ? "新しい予定" : "新しいタスク") : (kind == .event ? "予定を編集" : "タスクを編集"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // 変更があるときは、消してよいか確かめてから閉じる（変更がなければすぐ閉じる）
                    Button("キャンセル") { if hasChanges { confirmDiscard = true } else { dismiss() } }
                        .confirmationDialog("変更を破棄しますか？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                            Button("破棄して閉じる", role: .destructive) { dismiss() }
                            Button("編集を続ける", role: .cancel) {}
                        }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "追加" : "保存", action: save).fontWeight(.semibold).disabled(!canSave)
                }
            }
            // キーボードが出ている間はタブを隠す（候補や入力欄を覆わない）
            .safeAreaInset(edge: .bottom) { if !keyboardUp { pageTabs.transition(.move(edge: .bottom).combined(with: .opacity)) } }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in withAnimation(.snappy) { keyboardUp = true } }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in withAnimation(.snappy) { keyboardUp = false } }
            .onAppear(perform: load)
            // 変更があるときは、下になぞって閉じない（キャンセルから確かめる）
            .interactiveDismissDisabled(hasChanges)
            .sensoryFeedback(.success, trigger: saved)

            .sensoryFeedback(.selection, trigger: page)
            .animation(.snappy, value: open)
        }
        .interactiveDismissDisabled(!title.isEmpty && isNew)
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: 見出し（種類の切り替え・名前）

    @ViewBuilder
    private var header: some View {
        if isNew {
            // タスク・予定・チェックポイント（チェックポイントを選ぶと、その画面へ切り替える）
            Picker("作成する種類", selection: Binding(get: { kind == .task ? 0 : 1 }, set: { v in
                if v == 2 {
                    let at = model.time.ms(start)
                    router.replace(.checkpoint(Checkpoint(id: model.repo.newId(), title: title, at: at)))
                } else {
                    withAnimation(.snappy) { kind = v == 0 ? .task : .event }
                }
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
            HStack(spacing: 10) {
                if kind == .event {
                    Circle().fill(tint).frame(width: 12, height: 12).accessibilityHidden(true)
                } else {
                    Image(systemName: IconMap.symbol(icon)).foregroundStyle(tint).accessibilityHidden(true)
                }
                TextField(kind == .event ? "予定のタイトル" : "タスクのタイトル", text: $title)
                    .font(.title3.weight(.medium))
                    .focused($titleFocused)
                    .submitLabel(canSave ? .done : .return)
                    // 改行で、そのまま追加（純正リマインダーと同じ速さで入れられる）
                    .onSubmit { if canSave { save() } else { titleFocused = false } }
                if isNew && title.isEmpty {
                    Button { router.replace(.quickAdd) } label: {
                        Image(systemName: "text.bubble").font(.title3).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("文章で追加")
                }
            }
            if isNew && !title.isEmpty && !suggestions.isEmpty { suggestionRow }
        }
    }

    /// 下の「基本・オプション・専用」（左右になぞっても切り替えられる）
    private var pageTabs: some View {
        let pages = Page.allCases.filter { $0 != .special || hasSpecial }
        return HStack(spacing: 4) {
            ForEach(pages, id: \.self) { p in
                Button { withAnimation(.snappy) { page = p; open = .none } } label: {
                    Text(p == .special ? specialLabel : p.rawValue)
                        .font(.subheadline.weight(page == p ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Capsule().fill(page == p ? Color.accentColor.opacity(0.16) : .clear))
                        .foregroundStyle(page == p ? Color.accentColor : .primary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == p ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        .padding(.horizontal, 40)
        .padding(.bottom, 6)
        .gesture(DragGesture(minimumDistance: 20).onEnded { v in
            guard let i = pages.firstIndex(of: page) else { return }
            let j = v.translation.width < 0 ? i + 1 : i - 1
            if pages.indices.contains(j) { withAnimation(.snappy) { page = pages[j] } }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("編集の項目")
    }

    private var hasSpecial: Bool { spec != nil || studioType != nil || (kind == .event && calendarKind == .class) }
    private var specialLabel: String { studioType?.name ?? spec.flatMap { SPEC_BY_ID[$0]?.name } ?? (calendarKind == .class ? "授業" : "専用") }
    private var studioType: StudioType? { model.studioType(studioId) }

    /// 自分で作った種類を選ぶ（予定かタスクかを合わせ、見本の種類は外す）
    private func applyStudio(_ t: StudioType?) {
        studioId = t?.id
        guard let t else { return }
        spec = nil
        if isNew { kind = t.target == "calendar" ? .event : .task }
        if color == nil { color = t.color }
        if kind == .task { icon = t.icon }
    }
    private var calendarKind: CalendarKind? { model.calendar(calendarId)?.kind }
    private var tint: Color { Color(hex: color ?? (kind == .event ? model.calendar(calendarId)?.color : nil) ?? "#0A84FF") }

    // MARK: 基本

    @ViewBuilder
    private var basicPage: some View {
        Section {
            NavigationLink {
                SpecTypePicker(spec: $spec, onPick: apply, studioTypes: model.studioTypes.filter { $0.status == "active" }, studioId: studioId, onPickStudio: applyStudio)
            } label: {
                row("種類", "square.stack.3d.up.fill", .gray, value: studioType?.name ?? spec.flatMap { SPEC_BY_ID[$0]?.name } ?? "指定しない")
            }
        }
        if kind == .task {
            // タスクの種類：大きな押しボタン（実行する／確認する）
            Section {
                HStack(spacing: 10) {
                    kindButton("実行する", "play.circle.fill", "時間をかけて進める", selected: !isCheck, tint: .doTask) { isCheck = false }
                    kindButton("確認する", "checkmark.circle.fill", "その時刻に確かめる", selected: isCheck, tint: .checkTask) { isCheck = true }
                }
            } header: { Text("タスクの種類") }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }

        Section {
            if kind == .event {
                Toggle(isOn: $allDay.animation()) { rowLabel("終日", "sun.max.fill", .orange) }
            } else if !isCheck {
                Toggle(isOn: $hasTime.animation()) { rowLabel("日時を指定", "clock.fill", .orange) }
            }
            if showsTime { dateTimeRows }
            if kind == .task && isCheck {
                DatePicker(selection: $start) { rowLabel("確認日時", "checkmark.circle.fill", .green) }
            }
        } footer: {
            if let c = conflict {
                Label("「\(c.title)」（\(model.hm(c.start))〜\(model.hm(c.end))）と重なっています", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if kind == .task && !isCheck && !hasTime {
                Text("日時を決めないタスクは「未割当」に入ります。")
            } else if end <= start && showsTime {
                Text("終了は開始より後にしてください。").foregroundStyle(.red)
            }
        }

        Section {
            if kind == .event {
                NavigationLink { RepeatEditor(rule: $rule, start: start) } label: {
                    row("繰り返し", "repeat", .indigo, value: describeRule(rule))
                }
            }
            if kind == .task && !isCheck {
                Picker(selection: Binding(get: { hasEstimate ? estimate : 0 }, set: { v in hasEstimate = v > 0; if v > 0 { estimate = v } })) {
                    Text("なし").tag(0)
                    ForEach([10, 15, 20, 30, 45, 60, 90, 120, 180, 240], id: \.self) { Text(durationLabel($0)).tag($0) }
                } label: { rowLabel("見積時間", "hourglass", .teal) }
            }
            if isShiftKind {
                Picker(selection: $employerId) {
                    Text("未設定").tag(String?.none)
                    ForEach(model.employers, id: \.id) { e in Text(e.name).tag(Optional(e.id)) }
                } label: { rowLabel("勤務先", "briefcase.fill", .orange) }
                Button { newEmployerPrompt = true } label: { Label("勤務先を追加", systemImage: "plus.circle") }
                    .font(.subheadline)
                    .modifier(NewEmployerAlert(isPresented: $newEmployerPrompt) { employerId = $0 })
                Toggle(isOn: $shiftPending) {
                    HStack(spacing: 12) {
                        RowIcon(symbol: "hourglass", tint: .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("調整中")
                            Text(shiftPending ? "シフトがまだ決まっていない" : "決まったシフト").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(.orange)
            }
            PlaceTravelEditor(place: $place, travel: $travel, expanded: Binding(get: { open == .place }, set: { open = $0 ? .place : .none }), start: start, history: placeHistory)
            NavigationLink { NotifyPicker(selection: $notifies, base: kind == .event ? "予定の開始" : isCheck ? "確認の時刻" : "開始の時刻") } label: {
                row("通知", "bell.fill", .pink, value: notifySummary)
            }
            if kind == .task && (isCheck || hasTime) {
                Toggle(isOn: Binding(get: { alarm }, set: setAlarm)) {
                    HStack(spacing: 12) {
                        RowIcon(symbol: "alarm.fill", tint: .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("アラーム")
                            Text(alarm ? "\(hm(start))に鳴らす（止めるまで）" : "\(isCheck ? "確認" : "開始")の時刻に鳴らす").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        Section("色") { colorStrip }
        if kind == .task {
            Section { iconGrid } header: { Text("アイコン") }
        }
    }

    /// バイトのシフトか（種類が勤務シフト、またはアルバイトのカレンダー）
    private var isShiftKind: Bool { kind == .event && (spec == .shift || calendarKind == .job) }

    private var showsTime: Bool { kind == .event || (!isCheck && hasTime) }

    /// 日付（タップで月のカレンダー・左右になぞって前後の日）と時間（なぞる／タップで時刻のホイール）
    @ViewBuilder
    private var dateTimeRows: some View {
        // 1つの行にまとめる（行ごとの区切り線がずれて見えないように）
        VStack(spacing: 10) {
            DaySwipeRow(date: startKeepingLength, onShift: shiftDay, onTap: { toggle(.date) }, expanded: open == .date)
            if !(kind == .event && allDay) {
                TimeRangeBar(start: $start, end: $end, tint: tint)
                Button { toggle(.time) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(hm(start))〜\(hm(end))").font(.title2.weight(.semibold)).monospacedDigit()
                            .contentTransition(.numericText())
                        if !model.time.isSameDay(model.time.ms(start), model.time.ms(end) - 1) {
                            Text("翌日").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        }
                        Spacer()
                        Text(lengthText).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open == .time ? 180 : 0))
                    }
                    .foregroundStyle(end <= start ? Color.red : Color.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("タップすると時刻を細かく選べます")
            }
        }
        .padding(.vertical, 4)
        .animation(.snappy, value: start)
        .animation(.snappy, value: end)

        if open == .date {
            DatePicker("日付", selection: startKeepingLength, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .transition(.opacity.combined(with: .move(edge: .top)))
            if kind == .event && allDay {
                DatePicker("終わる日", selection: $end, in: start..., displayedComponents: .date)
            }
        }
        if open == .time {
            DatePicker(selection: startKeepingLength, displayedComponents: [.date, .hourAndMinute]) { Text("開始") }
            DatePicker(selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute]) { Text("終了") }
        }
    }

    private func kindButton(_ title: String, _ symbol: String, _ sub: String, selected: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.subheadline.weight(.semibold))
                Text(sub).font(.caption2).foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .foregroundStyle(selected ? Color.white : tint)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground))))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? .clear : Color(.separator).opacity(0.5), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func setAlarm(_ on: Bool) {
        alarm = on
        guard on else { return }
        // 時計アプリと同じアラーム（AlarmKit）の許可を求める。使えないときは通知で鳴らす
        Task {
            if await !TaskAlarms.requestAuthorization() { _ = await NotificationScheduler.requestAuthorization() }
        }
    }

    private func toggle(_ o: Open) { withAnimation(.snappy) { open = open == o ? .none : o }; titleFocused = false }

    // MARK: オプション

    @ViewBuilder
    private var optionPage: some View {
        if kind == .event {
            Section("カレンダー") { calendarChips }
        } else {
            Section {
                Picker(selection: $taskCalendarId) {
                    Text("なし").tag(String?.none)
                    ForEach(model.calendars, id: \.id) { c in Text(c.name).tag(Optional(c.id)) }
                } label: { rowLabel("カレンダー", "calendar", .blue) }
                categoryPicker
                Toggle(isOn: $flagged) { rowLabel("フラグ", "flag.fill", .orange) }
            }
        }
        if kind == .task {
            Section {
                Toggle(isOn: $hasDeadline.animation()) { rowLabel("締切", "flag.checkered", .red) }.disabled(spec == nil)
                if hasDeadline && spec != nil { DatePicker("締切", selection: $deadline) }
            } footer: {
                if spec == nil { Text("締切は「種類」を選ぶと設定できます（Web 版と同じ保存形式）。") }
            }
        }
        Section {
            HStack(spacing: 12) {
                RowIcon(symbol: "video.fill", tint: .green)
                TextField("会議の URL（https://…）", text: $meetingUrl)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        } footer: {
            if !meetingUrl.isEmpty && !validURL(meetingUrl) { Text("https:// から始まる URL を入力してください").foregroundStyle(.red) }
        }
        Section {
            ForEach($links) { $l in
                VStack(alignment: .leading, spacing: 6) {
                    TextField("名前（任意）", text: $l.title)
                    TextField("https://", text: $l.url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .foregroundStyle(l.url.isEmpty || validURL(l.url) ? Color.primary : Color.red)
                }
            }
            .onDelete { links.remove(atOffsets: $0) }
            Button { withAnimation { links.append(LinkItem()) } } label: { Label("リンクを追加", systemImage: "link.badge.plus") }
        } header: { Text("リンク") }
        Section {
            HStack(spacing: 12) {
                RowIcon(symbol: "bag.fill", tint: .mint)
                TextField("持ち物（読点・カンマで区切る）", text: $bring)
            }
        } header: { Text("持ち物") } footer: { Text("今日の時刻軸にも表示します。") }
        Section("メモ") {
            TextField("メモ", text: $notes, axis: .vertical).lineLimit(3...10)
        }
        if kind == .event && !allDay && rule == nil {
            Section {
                Toggle(isOn: $hideAfterEnd) { rowLabel("終わったらすぐ隠す", "eye.slash.fill", .gray) }
            } footer: { Text("終わった予定を、今日の時刻軸からすぐに消します。") }
        }
    }

    private var categoryPicker: some View {
        let names = Array(Set(model.tasks.compactMap(\.category).filter { !$0.isEmpty } + (category.isEmpty ? [] : [category]))).sorted()
        return Menu {
            Button("なし") { category = "" }
            ForEach(names, id: \.self) { n in Button(n) { category = n } }
            Divider()
            Button("新しいカテゴリー…", systemImage: "plus") { newCategoryPrompt = true }
        } label: {
            row("カテゴリー", "tray.fill", .brown, value: category.isEmpty ? "なし" : category)
        }
        .alert("新しいカテゴリー", isPresented: $newCategoryPrompt) {
            TextField("名前", text: $newCategory)
            Button("追加") { if !newCategory.trimmingCharacters(in: .whitespaces).isEmpty { category = newCategory.trimmingCharacters(in: .whitespaces) }; newCategory = "" }
            Button("キャンセル", role: .cancel) { newCategory = "" }
        }
    }
    @State private var newCategoryPrompt = false
    @State private var newCategory = ""

    private var colorStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button { color = nil } label: {
                    ZStack {
                        Circle().strokeBorder(Color(.separator), lineWidth: 1.5).frame(width: 30, height: 30)
                        Image(systemName: "slash.circle").foregroundStyle(.secondary)
                    }
                    .overlay(Circle().strokeBorder(color == nil ? Color.primary : .clear, lineWidth: 2).padding(-4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(kind == .event ? "カレンダーの色" : "色なし")
                ForEach(Self.colors, id: \.self) { c in
                    Button { color = c } label: {
                        Circle().fill(Color(hex: c)).frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(color == c ? Color.primary : .clear, lineWidth: 2).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("色 \(c)")
                    .accessibilityAddTraits(color == c ? .isSelected : [])
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
        }
    }

    private var iconGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 10) {
            ForEach(Array(IconMap.symbols.keys.sorted()), id: \.self) { key in
                Button { icon = key } label: {
                    Image(systemName: IconMap.symbols[key]!)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(icon == key ? Color.accentColor.opacity(0.2) : Color.clear))
                        .foregroundStyle(icon == key ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key)
                .accessibilityAddTraits(icon == key ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: 専用

    @ViewBuilder
    private var specialPage: some View {
        if kind == .event && calendarKind == .class {
            Section {
                HStack(spacing: 12) {
                    RowIcon(symbol: "graduationcap.fill", tint: .indigo)
                    TextField("科目（未入力ならタイトル）", text: $subjectName)
                }
                HStack(spacing: 12) {
                    RowIcon(symbol: "door.left.hand.open", tint: .gray)
                    TextField("教室（例：3-201）", text: $room)
                }
            } header: { Text("授業") } footer: { Text("教室は「今日」の上のカードにも表示します。") }
        }
        if let st = studioType { StudioFieldsForm(type: st, values: $studioValues) }
        if let spec { SpecFieldsSection(spec: spec, details: $details) }
        if !hasSpecial {
            Section { Text("「基本」の「種類」を選ぶと、その種類だけの項目をここで入力できます。").foregroundStyle(.secondary) }
        }
    }

    // MARK: 部品

    private func rowLabel(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 12) {
            RowIcon(symbol: symbol, tint: tint)
            Text(title)
        }
    }

    private func row(_ title: String, _ symbol: String, _ tint: Color, value: String) -> some View {
        HStack(spacing: 12) {
            RowIcon(symbol: symbol, tint: tint)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func durationLabel(_ m: Int) -> String { m < 60 ? "\(m)分" : m % 60 == 0 ? "\(m / 60)時間" : "\(m / 60)時間\(m % 60)分" }

    private var notifySummary: String {
        if notifies.isEmpty { return "なし" }
        return notifies.sorted().map { NotifyPicker.label($0) }.joined(separator: "・")
    }

    private func validURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return (t.hasPrefix("https://") || t.hasPrefix("http://")) && URL(string: t) != nil
    }

    private var placeHistory: [PlaceValue] {
        var seen = Set<String>(), out: [PlaceValue] = []
        for v in model.settings.placeHistory { if let p = PlaceValue(v), seen.insert(p.name).inserted { out.append(p) } }
        for e in model.events.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if let p = PlaceValue(e.extra?["place"]), seen.insert(p.name).inserted { out.append(p) }
            if out.count >= 20 { break }
        }
        return out
    }

    /// 開始を変えたら長さを保って終了も動かす（時間のバーは開始・終了を別々に動かすので、これを使わない）
    private var startKeepingLength: Binding<Date> {
        Binding(get: { start }, set: { new in
            let len = end.timeIntervalSince(start)
            start = new
            if len > 0 { end = new.addingTimeInterval(len) }
        })
    }

    private func shiftDay(_ n: Int) {
        let cal = Calendar.current
        start = cal.date(byAdding: .day, value: n, to: start) ?? start
        end = cal.date(byAdding: .day, value: n, to: end) ?? end
    }

    private func hm(_ d: Date) -> String { model.hm(model.time.ms(d)) }

    private var lengthText: String { durationLabel(max(0, Int(end.timeIntervalSince(start) / 60))) }

    // MARK: 種類（S01〜S25）

    /// 種類を選ぶと、予定かタスクか・確認かどうかの既定を合わせる（新規のときだけ）
    private func apply(_ d: SpecDef) {
        spec = d.id
        guard isNew else { return }
        kind = d.isEvent ? .event : .task
        isCheck = d.isCheck
        if d.id == .assignment || d.id == .exam || d.id == .payment { hasDeadline = true }
        if d.isEvent, d.id == .shift || d.id == .class {
            calendarId = model.calendars.first { $0.kind == (d.id == .shift ? .job : .class) }?.id ?? calendarId
        }
        // 種類ごとの設定の既定（所要時間・通知・繰り返し）
        let st = model.specSetting(d.id)
        if let m = st.defaultMinutes { end = start.addingTimeInterval(TimeInterval(m * 60)) }
        if let n = st.notifyBefore { notifies = [n] }
        switch st.repeatRule {
        case "daily": rule = RecurrenceRule(freq: .daily)
        case "weekly": rule = RecurrenceRule(freq: .weekly)
        case "monthly": rule = RecurrenceRule(freq: .monthly)
        default: break
        }
    }

    /// カレンダーを色の丸で選ぶ（純正カレンダーの色分けと同じ考え方）
    private var calendarChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.calendars, id: \.id) { c in
                    let on = c.id == calendarId
                    Button { calendarId = c.id } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: c.color)).frame(width: 12, height: 12)
                            Text(c.name).font(.subheadline.weight(on ? .semibold : .regular))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(on ? Color(hex: c.color).opacity(0.18) : Color(.tertiarySystemFill)))
                        .overlay(Capsule().strokeBorder(on ? Color(hex: c.color) : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
    }

    /// 前に使った名前（入力中の文字で絞り込む）。選ぶと長さ・カレンダー・場所も前回と同じにする
    private struct Suggestion: Identifiable { var id: String { title }; var title: String; var minutes: Int?; var calendarId: String?; var place: PlaceValue?; var travel: Int? }

    private var suggestions: [Suggestion] {
        let q = title.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>(), out: [Suggestion] = []
        if kind == .event {
            for e in model.events.sorted(by: { $0.updatedAt > $1.updatedAt }) where !e.title.isEmpty && !seen.contains(e.title) {
                if !q.isEmpty && (!e.title.localizedCaseInsensitiveContains(q) || e.title == q) { continue }
                seen.insert(e.title)
                out.append(Suggestion(title: e.title, minutes: e.allDay ? nil : Int((e.end - e.start) / MINUTE), calendarId: e.calendarId, place: PlaceValue(e.extra?["place"]), travel: e.travelMinutes))
                if out.count >= 6 { break }
            }
        } else {
            for t in model.tasks.sorted(by: { $0.updatedAt > $1.updatedAt }) where !t.title.isEmpty && !seen.contains(t.title) {
                if !q.isEmpty && (!t.title.localizedCaseInsensitiveContains(q) || t.title == q) { continue }
                seen.insert(t.title)
                out.append(Suggestion(title: t.title, minutes: t.plannedStart.flatMap { s in t.plannedEnd.map { Int(($0 - s) / MINUTE) } }, calendarId: nil, place: nil, travel: nil))
                if out.count >= 6 { break }
            }
        }
        return out
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions) { sg in
                    Button {
                        title = sg.title
                        if let m = sg.minutes, m > 0 { end = start.addingTimeInterval(TimeInterval(m * 60)) }
                        if let c = sg.calendarId { calendarId = c }
                        if let p = sg.place { place = p }
                        if let t = sg.travel { travel = t }
                    } label: {
                        Label(sg.title, systemImage: "clock.arrow.circlepath")
                            .font(.subheadline).lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("前回と同じ長さ・カレンダー・場所で入力します")
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 0))
    }

    /// 同じ時間にある別の予定（終日は除く）
    private var conflict: EventOccurrence? {
        guard kind == .event, !allDay else { return nil }
        let s = model.time.ms(start), e = model.time.ms(end)
        guard e > s else { return nil }
        return model.visibleEvents(from: s - HOUR, to: e + HOUR).first { o in
            !o.event.allDay && o.start < e && s < o.end && (isNew || o.masterId != event.id)
        }
    }

    // MARK: 読み込みと保存

    private func loadCommon(_ extra: JSONValue?) {
        place = PlaceValue(extra?["place"])
        travel = extra?["travelMinutes"]?.intValue.map(Int.init)
        meetingUrl = extra?["meetingUrl"]?.stringValue ?? ""
        notifies = extra?["notifies"]?.arrayValue?.compactMap { $0.intValue.map(Int.init) } ?? []
        links = extra?["urls"]?.arrayValue?.compactMap { v in
            guard let u = v["url"]?.stringValue else { return nil }
            return LinkItem(id: v["id"]?.stringValue ?? UUID().uuidString, title: v["title"]?.stringValue ?? "", url: u)
        } ?? []
        color = extra?["color"]?.stringValue
        alarm = extra?["alarm"]?.boolValue ?? false
        bring = (extra?["bring"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "、")
        details = extra?["spec"]?["details"]?.objectValue ?? [:]
        studioId = extra?["studio"]?["typeId"]?.stringValue
        studioValues = extra?["studio"]?["values"]?.objectValue ?? [:]
    }

    /// 入力の内容をまとめた文字（変更の有無を比べるだけ）
    private var signature: String {
        [title, notes, spec?.rawValue ?? "", "\(details.count)", "\(start.timeIntervalSince1970)", "\(end.timeIntervalSince1970)", "\(hasTime)", "\(allDay)", "\(isCheck)",
         "\(hasDeadline)", "\(deadline.timeIntervalSince1970)", "\(estimate)", "\(hasEstimate)", calendarId, "\(String(describing: rule))", place?.name ?? "", "\(travel ?? -1)",
         "\(notifies)", meetingUrl, "\(links.map { $0.title + $0.url })", color ?? "", category, hideAfterEnd ? "1" : "0", subjectName, room, flagged ? "1" : "0", icon,
         alarm ? "1" : "0", employerId ?? "", shiftPending ? "1" : "0", studioId ?? "", "\(studioValues.count)", bring, "\(kind)"].joined(separator: "|")
    }
    private var hasChanges: Bool { loaded && !initialSignature.isEmpty && signature != initialSignature }

    private func load() {
        guard !loaded else { return }
        defer { DispatchQueue.main.async { initialSignature = signature } }
        loaded = true
        kind = seed.kind
        let now = model.now
        let base = seed.start ?? (((now / (15 * MINUTE)) + 1) * 15 * MINUTE)
        start = model.time.date(base)
        end = model.time.date(seed.end ?? base + HOUR)
        spec = seed.spec
        if let id = seed.taskId, let t = model.tasks.first(where: { $0.id == id }) {
            isNew = false; kind = .task; task = t
            title = t.title; notes = t.notes; spec = t.specType; isCheck = t.kind == .check
            flagged = t.flagged; icon = IconMap.symbols[t.icon] != nil ? t.icon : "book"
            category = t.category ?? ""; taskCalendarId = t.calendarId
            if let c = t.checkAt { start = model.time.date(c) }
            if let s = t.plannedStart, let e = t.plannedEnd { start = model.time.date(s); end = model.time.date(e); hasTime = true } else { hasTime = false }
            if let d = t.deadline { hasDeadline = true; deadline = model.time.date(d) }
            if let m = t.estimateMinutes { hasEstimate = true; estimate = m }
            loadCommon(t.extra)
            if notifies.isEmpty, let n = t.notifyMinutesBefore { notifies = [n] }
        } else if let id = seed.eventId, let e = model.events.first(where: { $0.id == id }) {
            isNew = false; kind = .event; event = e
            title = e.title; notes = e.notes; spec = e.specType; calendarId = e.calendarId
            start = model.time.date(e.start); end = model.time.date(e.end); allDay = e.allDay
            rule = e.recurrence; hideAfterEnd = e.hideAfterEnd
            employerId = e.employerId
            shiftPending = isShiftPending(e)
            subjectName = e.classInfo?["subjectName"]?.stringValue ?? ""
            room = e.classInfo?["room"]?.stringValue ?? ""
            loadCommon(e.extra)
            // 取り込んだ授業（種類なし）は「大学授業」として小テストなどを入れられるように
            if spec == nil && e.classInfo != nil {
                spec = .class
                if details["room"] == nil, !room.isEmpty { details["room"] = .string(room) }
            }
        } else {
            titleFocused = true
            calendarId = model.calendars.first?.id ?? "cal-general"
            if model.notifyMinutesBefore > 0 && model.notificationsEnabled { notifies = [model.notifyMinutesBefore] }
        }
    }

    /// Web 版と同じ extra の項目（知らない項目は残す）
    private func mergeExtra(_ old: JSONValue?, dueAt: EpochMs?) -> JSONValue? {
        var extra = old?.objectValue ?? [:]
        if kind == .event { extra["allDay"] = allDay ? .bool(true) : nil }
        extra["color"] = color.map { .string($0) }
        extra["place"] = place?.json
        extra["travelMinutes"] = travel.map { .number(Double($0)) }
        let url = meetingUrl.trimmingCharacters(in: .whitespaces)
        extra["meetingUrl"] = url.isEmpty ? nil : .string(url)
        extra["notifies"] = notifies.isEmpty ? nil : .array(notifies.sorted().map { .number(Double($0)) })
        let ls = links.filter { !$0.url.trimmingCharacters(in: .whitespaces).isEmpty }
        extra["urls"] = ls.isEmpty ? nil : .array(ls.map { .object(["id": .string($0.id), "title": .string($0.title), "url": .string($0.url.trimmingCharacters(in: .whitespaces))]) })
        extra["spec"] = specJSON(extra["spec"], dueAt: dueAt)
        if let st = studioType {
            extra["studio"] = .object(["typeId": .string(st.id), "version": .number(Double(st.version)), "values": .object(studioValues)])
        } else if old?["studio"] != nil {
            extra["studio"] = nil
        }
        if kind == .event { extra["shiftPending"] = isShiftKind && shiftPending ? .bool(true) : nil }
        extra["alarm"] = kind == .task && alarm && (isCheck || hasTime) ? .bool(true) : nil
        let items = bring.split(whereSeparator: { "、,，・".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        extra["bring"] = items.isEmpty ? nil : .array(items.map { .string($0) })
        return extra.isEmpty ? (old == nil ? nil : .object([:])) : .object(extra)
    }

    private func save() {
        error = nil
        let now = model.now
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 入力が足りないときは、その欄へ移って知らせる（閉じない・入力は消さない）
        guard !name.isEmpty else { page = .basic; error = "タイトルを入力してください"; titleFocused = true; return }
        if showsTime && !(kind == .event && allDay) && end <= start { page = .basic; error = "終了は開始より後にしてください"; return }
        if !meetingUrl.isEmpty && !validURL(meetingUrl) { page = .option; error = "会議の URL は https:// から始めてください"; return }
        if let st = studioType, let miss = st.visibleFields.first(where: { $0.required && studioValues[$0.id] == nil }) {
            page = .special; error = "「\(miss.label)」を入力してください"; return
        }
        let ok: Bool
        if kind == .event {
            var e = isNew ? MTEvent.make(title: name, calendarId: calendarId, start: 0, end: 0, now: now, id: model.repo.newId()) : event
            e.title = name
            e.notes = notes
            e.calendarId = calendarId
            if allDay {
                e.start = model.time.startOfDay(model.time.ms(start))
                e.end = model.time.addDays(model.time.startOfDay(model.time.ms(end)), 1)
            } else {
                e.start = model.time.ms(start)
                e.end = model.time.ms(end)
            }
            e.recurrence = rule
            e.hideAfterEnd = !allDay && rule == nil ? hideAfterEnd : false
            if isShiftKind { e.employerId = employerId }
            if calendarKind == .class {
                var ci = e.classInfo?.objectValue ?? [:]
                ci["subjectName"] = .string(subjectName.trimmingCharacters(in: .whitespaces).isEmpty ? name : subjectName.trimmingCharacters(in: .whitespaces))
                ci["room"] = .string(room.trimmingCharacters(in: .whitespaces))
                e.classInfo = .object(ci)
            }
            e.extra = mergeExtra(e.extra, dueAt: nil)
            ok = model.perform { try model.repo.saveEvent(e, isNew: isNew) }
        } else {
            var t = isNew ? MTTask.make(title: name, kind: isCheck ? .check : .do, now: now, id: model.repo.newId()) : task
            t.title = name
            t.notes = notes
            t.kind = isCheck ? .check : .do
            t.flagged = flagged
            t.icon = icon
            t.category = category.isEmpty ? nil : category
            t.calendarId = taskCalendarId
            t.notifyMinutesBefore = notifies.sorted().first
            if isCheck {
                t.checkAt = model.time.ms(start); t.plannedStart = nil; t.plannedEnd = nil
            } else if hasTime {
                t.plannedStart = model.time.ms(start); t.plannedEnd = model.time.ms(end); t.checkAt = nil
            } else {
                t.plannedStart = nil; t.plannedEnd = nil; t.checkAt = nil
            }
            t.estimateMinutes = hasEstimate && !isCheck ? estimate : nil
            t.extra = mergeExtra(t.extra, dueAt: hasDeadline && spec != nil ? model.time.ms(deadline) : nil)
            if !hasDeadline, t.assignment != nil, var a = t.assignment?.objectValue { a["deadline"] = .null; t.assignment = .object(a) }
            ok = model.perform { try model.repo.saveTask(t, isNew: isNew) }
        }
        if ok {
            rememberPlace()
            saved += 1
            dismiss()
        }
    }

    /// 使った場所を履歴の先頭に（Web 版の placeHistory と同じ）
    private func rememberPlace() {
        guard let p = place, p.name != "自宅" else { return }
        model.updateSettings { s in
            s.placeHistory = [p.json] + s.placeHistory.filter { PlaceValue($0)?.name != p.name }
        }
    }

    /// `extra.spec`（Web 版と同じ形：`{ type, details: { dueAt, … } }`）。知らない項目は残す
    private func specJSON(_ old: JSONValue?, dueAt: EpochMs?) -> JSONValue? {
        // Web 版の検証では type と details が両方必要。種類なしなら spec 自体を持たない
        guard let spec else { return nil }
        var o = old?.objectValue ?? [:]
        var details = o["type"]?.stringValue == spec.rawValue ? (o["details"]?.objectValue ?? [:]) : [:]
        // 画面で編集した項目を重ねる（空にした項目は消す。知らない項目は残す）
        let known = Set(SPEC_BY_ID[spec]!.fields.map(\.key))
        for k in known where k != "dueAt" { details[k] = self.details[k] }
        details["dueAt"] = dueAt.map { .number(Double($0)) }
        o["type"] = .string(spec.rawValue)
        o["details"] = .object(details)
        return .object(o)
    }
}

/// 種類を選ぶ画面（グループごと）。下にガラスの検索欄
struct SpecTypePicker: View {
    @Binding var spec: SpecTypeId?
    @Environment(AppModel.self) private var model: AppModel?
    var onPick: (SpecDef) -> Void
    var studioTypes: [StudioType] = []
    var studioId: String? = nil
    var onPickStudio: (StudioType?) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searching: Bool

    private func hit(_ name: String, _ blurb: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || name.localizedCaseInsensitiveContains(q) || blurb.localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        let mine = studioTypes.filter { hit($0.name, "") }
        List {
            if query.isEmpty {
                Section {
                    row(title: "指定しない", sub: nil, badge: AnyView(Image(systemName: "circle.dashed").font(.title3).foregroundStyle(.secondary).frame(width: 28)), selected: spec == nil && studioId == nil) {
                        spec = nil; onPickStudio(nil); dismiss()
                    }
                }
            }
            if !mine.isEmpty {
                Section("自分の種類") {
                    ForEach(mine) { t in
                        row(title: t.name, sub: t.target == "calendar" ? "予定" : "タスク", badge: AnyView(RowIcon(symbol: IconMap.symbol(t.icon), tint: Color(hex: t.color))), selected: studioId == t.id) {
                            onPickStudio(t); dismiss()
                        }
                    }
                }
            }
            ForEach(SpecGroup.allCases, id: \.self) { g in
                // 種類の設定でオフにした種類は出さない（選んでいる種類は残す）
                let defs = SPEC_PICKABLE.filter { $0.group == g && hit($0.name, $0.blurb) && ($0.id == spec || model?.specSetting($0.id).enabled != false) }
                if !defs.isEmpty {
                    Section(g.label) {
                        ForEach(defs) { d in
                            row(title: d.name, sub: d.blurb, badge: AnyView(SpecBadge(type: d.id, isEvent: d.isEvent, size: 28)), selected: spec == d.id) {
                                onPick(d); onPickStudio(nil); dismiss()
                            }
                        }
                    }
                }
            }
            if !query.isEmpty && mine.isEmpty && !SPEC_PICKABLE.contains(where: { hit($0.name, $0.blurb) }) {
                ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
            }
        }
        .navigationTitle("種類")
        .navigationBarTitleDisplayMode(.inline)
        // 下に浮かぶガラスの検索欄（親指で届く位置）
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("種類を探す（例：試験・バイト）", text: $query).focused($searching).submitLabel(.search)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .glass(Capsule(), interactive: true)
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            .padding(.horizontal).padding(.bottom, 6)
        }
        .animation(.snappy, value: query)
    }

    private func row(title: String, sub: String?, badge: AnyView, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    if let sub { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 通知の時刻を選ぶ（いくつでも。Web 版の extra.notifies と同じ「何分前」）
struct NotifyPicker: View {
    @Binding var selection: [Int]
    var base: String
    @Environment(AppModel.self) private var model

    static func label(_ m: Int) -> String {
        m == 0 ? "ちょうど" : m == 1440 ? "1日前" : m >= 60 && m % 60 == 0 ? "\(m / 60)時間前" : "\(m)分前"
    }

    var body: some View {
        List {
            Section {
                ForEach(EditorView.notifyChoices, id: \.self) { m in
                    Button {
                        if selection.contains(m) { selection.removeAll { $0 == m } } else { selection.append(m) }
                    } label: {
                        HStack {
                            Text(Self.label(m)).foregroundStyle(.primary)
                            Spacer()
                            if selection.contains(m) { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("\(base)を基準に知らせます。いくつでも選べます。" + (model.notificationsEnabled ? "" : "\n通知は「その他 › 通知」でオンにすると届きます。"))
            }
            if !selection.isEmpty {
                Section { Button("通知なし", role: .destructive) { selection = [] } }
            }
        }
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 新しい勤務先を入れるアラート（追加したら、その勤務先を選ぶ）
struct NewEmployerAlert: ViewModifier {
    @Binding var isPresented: Bool
    var onAdded: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var name = ""
    func body(content: Content) -> some View {
        content.alert("新しい勤務先", isPresented: $isPresented) {
            TextField("例：無印良品", text: $name)
            Button("追加") {
                var made: MTEmployer?
                let ok = model.perform { made = try model.repo.saveEmployer(name: name) }
                if ok, let id = made?.id { onAdded(id) }
                name = ""
            }
            Button("キャンセル", role: .cancel) { name = "" }
        }
    }
}
