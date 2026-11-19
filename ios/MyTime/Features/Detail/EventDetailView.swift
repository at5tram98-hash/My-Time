import SwiftUI
import MyTimeCore

/// 予定のカード（純正「カレンダー」の予定の詳細にならう）。
/// 上：色の帯・名前・日時と長さ・今の状態。続いて：よく使う操作（編集・複製・ずらす・共有）、詳細、メモ。
/// 一番下に赤い「予定を削除」。繰り返し予定は「この回のみ」「すべて」を選べ、削除は取り消せる。
struct EventDetailView: View {
    /// 単発は予定 ID、繰り返しの回は `masterId@start`
    var occurrenceId: String
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmDelete = false
    @State private var deleted = 0
    @State private var copyOccurrence: EventOccurrence?
    /// 繰り返しの予定の取り消しで「この回のみ／すべての回」を選ぶ
    @State private var askStrike = false
    @State private var struckTick = 0

    var body: some View {
        let parsed = parseOccurrenceId(occurrenceId)
        let masterId = parsed?.masterId ?? occurrenceId
        NavigationStack {
            if let ev = model.events.first(where: { $0.id == masterId }) {
                let ex = parsed.flatMap { p in ev.exceptions.first { $0.originalStart == p.originalStart } }
                let start = ex?.start ?? parsed?.originalStart ?? ev.start
                let end = ex?.end ?? start + (ev.end - ev.start)
                let tint = Color(hex: model.eventColor(ev))
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    let now = model.time.ms(ctx.date)
                    List {
                        Section { header(ev, start: start, end: end, now: now, tint: isStruck(ev, parsed) ? .gray : tint, struck: isStruck(ev, parsed)) }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                        // 純正カレンダーと同じ、時刻の目盛りに予定を置いたプレビュー。押すと5分ごとの詳細スケジュール
                        if !ev.allDay && end > start {
                            Section {
                                NavigationLink {
                                    SubScheduleView(eventId: ev.id, start: start, end: end)
                                } label: {
                                    EventDayPreview(event: ev, start: start, end: end, tint: tint, struck: isStruck(ev, parsed))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Section {
                            actions(ev, parsed: parsed, start: start, end: end)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        // 勤務：勤務先の条件で給与を計算し、出勤・退勤を記録する
                        if isShift(ev, model: model) {
                            ShiftWorkSection(event: ev, start: start, end: end)
                        }
                        if let spec = ev.specType ?? (ev.classInfo != nil ? .class : nil), SPEC_BY_ID[spec] != nil,
                           !(spec == .shift && model.employer(ev.employerId) != nil) {
                            SpecPanel(spec: spec, details: specDetails(ev), start: start, end: end,
                                      employerName: model.employer(ev.employerId)?.name, task: nil) { d in
                                var e = ev
                                e.extra = withSpecDetails(e.extra, d, type: spec)
                                _ = model.perform(nil, undo: { try model.repo.saveEvent(ev, isNew: false) }) { try model.repo.saveEvent(e, isNew: false) }
                            }
                        }
                        // 場所：地図・自宅からの所要時間・Apple マップの経路
                        EventMapCard(event: ev, start: start)
                        details(ev, start: start, end: end)
                        // 持ち物：その場で押して確認（回ごとに印が残る）
                        if let occ = model.visibleEvents(from: start - 1, to: end + 1, includeStruck: true).first(where: { $0.masterId == ev.id && $0.start == start }) {
                            let names = BelongingsList.eventItems(ev)
                            if !names.isEmpty {
                                let k = BelongingsList.key(occ)
                                let checked = BelongingsList.checked(ev, key: k)
                                let g = BelongingGroup(id: "e:\(occ.id)", title: ev.title, when: start, source: .event(occurrenceId: occ.id, masterId: ev.id, key: k), items: names.map { ($0, checked.contains($0)) })
                                Section {
                                    ForEach(names, id: \.self) { n in
                                        let on = checked.contains(n)
                                        Button { BelongingsList.set(model: model, group: g, names: [n], on: !on) } label: {
                                            HStack(spacing: 12) {
                                                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(on ? Color.green : Color.secondary)
                                                    .contentTransition(.symbolEffect(.replace))
                                                Text(n).strikethrough(on).foregroundStyle(on ? .secondary : .primary)
                                                Spacer()
                                            }
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                } header: {
                                    HStack { Text("持ち物"); Spacer(); Text("\(checked.intersection(names).count)/\(names.count)").monospacedDigit() }
                                }
                            }
                        }
                        if let st = model.studioType(ev.extra?["studio"]?["typeId"]?.stringValue) {
                            let rows = studioInfoRows(st, values: ev.extra?["studio"]?["values"]?.objectValue ?? [:], time: model.time, hm: model.hm)
                            if !rows.isEmpty {
                                Section {
                                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in LabeledContent(r.0, value: r.1) }
                                } header: { Label(st.name, systemImage: IconMap.symbol(st.icon)).foregroundStyle(Color(hex: st.color)) }
                            }
                        }
                        if !ev.notes.isEmpty {
                            Section("メモ") { Text(ev.notes).textSelection(.enabled) }
                        }
                        // 純正カレンダーと同じく、一番下に赤い「予定を削除」（中央ぞろえ）
                        Section {
                            Button(role: .destructive) { confirmDelete = true } label: {
                                Text(ev.recurrence == nil ? "予定を削除" : "予定を削除…")
                                    .font(.body.weight(.medium))
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .contentMargins(.top, 0, for: .scrollContent)
                }
                .navigationTitle("予定の詳細")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("閉じる")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("編集") { router.open(.editor(EditorSeed(kind: .event, eventId: ev.id))) }
                    }
                }
                // 削除の確認は画面の中央に（吹き出しがずれたり重なったりしない）
                .alert(ev.recurrence == nil ? "この予定を削除しますか？" : "繰り返しの予定を削除します", isPresented: $confirmDelete) {
                    if let p = parsed, ev.recurrence != nil {
                        Button("この回のみ削除", role: .destructive) {
                            let snapshot = ev
                            if model.perform("この回を削除しました", undo: { try model.repo.saveEvent(snapshot, isNew: false) }, { try model.repo.cancelOccurrence(masterId: p.masterId, originalStart: p.originalStart) }) { close() }
                        }
                    }
                    Button(ev.recurrence == nil ? "削除" : "すべての回を削除", role: .destructive) {
                        let snapshot = ev
                        if model.perform("削除しました", undo: { try model.repo.saveEvent(snapshot, isNew: true) }, { try model.repo.deleteEvent(ev.id) }) { close() }
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: {
                    Text("「\(ev.title)」")
                }
                .sensoryFeedback(.warning, trigger: deleted)
            } else {
                ContentUnavailableView("予定が見つかりません", systemImage: "calendar.badge.exclamationmark", description: Text("削除されたか、別の端末で変更された可能性があります。"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            }
        }
        .sheet(item: $copyOccurrence) { o in CopyToDaysSheet(occurrence: o).environment(model) }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    /// 種類の項目（授業の取り込みで種類がないときは、教室を授業の情報から補う）
    private func specDetails(_ ev: MTEvent) -> [String: JSONValue] {
        var d = ev.extra?["spec"]?["details"]?.objectValue ?? [:]
        if d["room"] == nil, let r = ev.classInfo?["room"] { d["room"] = r }
        return d
    }

    private func close() { deleted += 1; dismiss() }

    // MARK: 見出し

    /// この回が取り消されているか（繰り返しはその回の印、またはすべての回）
    private func isStruck(_ ev: MTEvent, _ parsed: (masterId: String, originalStart: EpochMs)?) -> Bool {
        if ev.isStruckAll { return true }
        guard let p = parsed else { return false }
        return ev.exceptions.first { $0.originalStart == p.originalStart }?.raw["struck"]?.boolValue == true
    }

    /// 取り消す・取り消しを戻す（削除はしない。振ると元に戻せる）
    private func setStruck(_ ev: MTEvent, originalStart: EpochMs?, _ on: Bool) {
        let snapshot = ev
        if model.perform(on ? "予定を取り消しました" : "取り消しを戻しました", undo: { try model.repo.saveEvent(snapshot, isNew: false) }, {
            try model.repo.setStruck(eventId: ev.id, originalStart: originalStart, struck: on)
        }) { struckTick += 1 }
    }

    private func header(_ ev: MTEvent, start: EpochMs, end: EpochMs, now: EpochMs, tint: Color, struck: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint).frame(width: 6)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if ev.specType != nil { SpecBadge(type: ev.specType, isEvent: true, size: 28) }
                    Text(ev.title).font(.title2.weight(.bold)).lineLimit(3)
                        .strikethrough(struck)
                        .foregroundStyle(struck ? .secondary : .primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(dateText(start, end, allDay: ev.allDay)).font(.subheadline.weight(.medium))
                    if !ev.allDay {
                        Text("\(model.hm(start))〜\(model.hm(end))（\(durationText(end - start))）")
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if isShiftPending(ev) {
                    Label("調整中のシフト", systemImage: "hourglass").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.orange.opacity(0.14)))
                }
                // 人と今の状態を1行に（枠や塗りは付けず、文字だけ）
                HStack(spacing: 10) {
                    if model.calendars.count > 1 {
                        PersonLabel(calendar: model.calendar(ev.calendarId), size: 20)
                            .font(.subheadline.weight(.medium))
                            .saturation(struck ? 0 : 1)
                    }
                    if !struck, let s = status(start: start, end: end, now: now, allDay: ev.allDay) {
                        Label(s.text, systemImage: s.symbol).labelStyle(CompactLabel())
                            .font(.subheadline.weight(.semibold)).foregroundStyle(s.color)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }

    private func dateText(_ start: EpochMs, _ end: EpochMs, allDay: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日（EEE）"
        let s = f.string(from: model.time.date(start))
        if allDay {
            let last = end - 1
            return model.time.isSameDay(start, last) ? "\(s) 終日" : "\(s)〜\(f.string(from: model.time.date(last))) 終日"
        }
        return model.time.isSameDay(start, end - 1) ? s : "\(s) 〜 \(f.string(from: model.time.date(end)))"
    }

    private func durationText(_ ms: EpochMs) -> String {
        let m = Int(ms / MINUTE)
        if m < 60 { return "\(m)分" }
        return m % 60 == 0 ? "\(m / 60)時間" : "\(m / 60)時間\(m % 60)分"
    }

    private struct Status { var text: String; var symbol: String; var color: Color }

    private func status(start: EpochMs, end: EpochMs, now: EpochMs, allDay: Bool) -> Status? {
        if allDay { return nil }
        if now >= end { return Status(text: "終了しました", symbol: "checkmark.circle", color: .secondary) }
        if now >= start { return Status(text: "あと\(durationText(end - now))", symbol: "dot.radiowaves.left.and.right", color: .green) }
        let diff = start - now
        if diff < 24 * HOUR { return Status(text: "あと\(durationText(diff))", symbol: "clock", color: .blue) }
        return nil
    }

    // MARK: よく使う操作

    /// よく使う操作（編集は右上）。ひとつ目は大きく（参加・マップ）、ほかは同じ形の丸いボタンを横に並べる
    /// 大きな主ボタン（参加・経路）は1行まるごと、ほかの操作はその下に同じ幅のタイル（形の上に名前）。
    /// 横1列に詰めると、主ボタンに幅を取られて右のボタンの文字が切れていた
    private func actions(_ ev: MTEvent, parsed: (masterId: String, originalStart: EpochMs)?, start: EpochMs, end: EpochMs) -> some View {
        VStack(spacing: 10) {
            if let url = ev.extra?["meetingUrl"]?.stringValue, let u = URL(string: url) {
                primaryButton("参加する", "video.fill") { openURL(u) }
            } else if let place = ev.placeName, !place.isEmpty {
                primaryButton(ev.travelMinutes.map { "\(model.hm(start - EpochMs($0) * MINUTE))に出発・経路を見る" } ?? "経路を見る", AppleMaps.preferredMode.symbol) {
                    let p = PlaceValue(ev.extra?["place"]) ?? PlaceValue(name: place)
                    Task { await AppleMaps.openDirections(to: p) }
                }
            }
            secondaryActions(ev, parsed: parsed, start: start, end: end)
        }
        .padding(.vertical, 2)
        .animation(Motion.pop, value: isStruck(ev, parsed))
        .sensoryFeedback(.impact(weight: .light), trigger: struckTick)
    }

    private func secondaryActions(_ ev: MTEvent, parsed: (masterId: String, originalStart: EpochMs)?, start: EpochMs, end: EpochMs) -> some View {
        HStack(spacing: 10) {
            Menu {
                Button("すぐ後に複製", systemImage: "plus.square.on.square") { duplicate(ev, start: start, end: end) }
                Button("ほかの日にもコピー…", systemImage: "calendar.badge.plus") {
                    copyOccurrence = model.visibleEvents(from: start - 1, to: end + 1, includeStruck: true).first { $0.id == occurrenceId || $0.masterId == ev.id && $0.start == start }
                }
            } label: { roundLabel("複製", "plus.square.on.square") }
            .buttonStyle(PressableStyle())
            ShareLink(item: shareText(ev, start: start, end: end)) { roundLabel("共有", "square.and.arrow.up") }
                .buttonStyle(PressableStyle())
            let struck = isStruck(ev, parsed)
            Button {
                if struck {
                    // 取り消しを戻す：すべての回の取り消しならすべて、その回だけならその回
                    setStruck(ev, originalStart: ev.isStruckAll ? nil : parsed?.originalStart, false)
                } else if ev.recurrence != nil && parsed != nil {
                    askStrike = true
                } else {
                    setStruck(ev, originalStart: nil, true)
                }
            } label: { roundLabel(struck ? "戻す" : "取り消す", struck ? "arrow.uturn.backward" : "strikethrough") }
            .buttonStyle(PressableStyle())
            .accessibilityHint(struck ? "取り消しをやめて元の予定に戻します" : "削除せずに、灰色にして線を引きます")
            .confirmationDialog("繰り返しの予定を取り消します", isPresented: $askStrike, titleVisibility: .visible) {
                Button("この回のみ取り消す") { setStruck(ev, originalStart: parsed?.originalStart, true) }
                Button("すべての回を取り消す") { setStruck(ev, originalStart: nil, true) }
                Button("キャンセル", role: .cancel) {}
            } message: { Text("削除はせず、灰色にして線を引きます。") }
        }
    }

    private func primaryButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.accentColor.gradient, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .layoutPriority(1)
    }

    /// 同じ幅のタイル（形の上に名前。文字が大きくても切れずに縮む）
    private func roundLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.body.weight(.semibold))
            Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func duplicate(_ ev: MTEvent, start: EpochMs, end: EpochMs) {
        var copy = MTEvent.make(title: ev.title, calendarId: ev.calendarId, start: end, end: end + (end - start), now: model.now, id: model.repo.newId())
        copy.notes = ev.notes
        copy.extra = ev.extra
        copy.employerId = ev.employerId
        let id = copy.id
        if model.perform("複製しました（\(model.hm(copy.start))〜）", undo: { try model.repo.deleteEvent(id) }, { try model.repo.saveEvent(copy, isNew: true) }) { dismiss() }
    }

    private func shareText(_ ev: MTEvent, start: EpochMs, end: EpochMs) -> String {
        var s = "\(ev.title)\n\(dateText(start, end, allDay: ev.allDay))"
        if !ev.allDay { s += " \(model.hm(start))〜\(model.hm(end))" }
        if let p = ev.placeName, !p.isEmpty { s += "\n場所：\(p)" }
        if !ev.notes.isEmpty { s += "\n\(ev.notes)" }
        return s
    }

    // MARK: 詳細

    @ViewBuilder
    private func details(_ ev: MTEvent, start: EpochMs, end: EpochMs) -> some View {
        Section {
            if let cal = model.calendar(ev.calendarId), model.calendars.count <= 1 {
                LabeledContent("カレンダー") { PersonLabel(calendar: cal, size: 18) }
            }
            if let r = ev.recurrence { LabeledContent("繰り返し", value: recurrenceText(r)) }
            if let m = ev.travelMinutes, m > 0 {
                LabeledContent("移動", value: "\(m)分・\(model.hm(start - EpochMs(m) * MINUTE))発")
            }
            if let url = ev.extra?["meetingUrl"]?.stringValue, let u = URL(string: url) {
                Link(destination: u) { LabeledContent("会議") { Label("参加する", systemImage: "video.fill").foregroundStyle(Color.accentColor) } }
            }
            ForEach(Array((ev.extra?["urls"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, l in
                if let s = l["url"]?.stringValue, let u = URL(string: s) {
                    Link(destination: u) {
                        LabeledContent(l["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "リンク") {
                            Text(u.host() ?? s).foregroundStyle(Color.accentColor).lineLimit(1)
                        }
                    }
                }
            }
            if let n = ev.extra?["notifies"]?.arrayValue, !n.isEmpty {
                LabeledContent("通知", value: n.compactMap { $0.intValue.map { NotifyPicker.label(Int($0)) } }.joined(separator: "・"))
            }
            if ev.specType != .shift, let emp = model.employer(ev.employerId) { LabeledContent("勤務先", value: emp.name) }
            if isShift(ev, model: model) {
                Toggle(isOn: Binding(get: { isShiftPending(ev) }, set: { model.setShiftPending([ev.id], pending: $0) })) {
                    Label("調整中", systemImage: "hourglass")
                }
                .tint(.orange)
            }
        }
    }

    private func recurrenceText(_ r: RecurrenceRule) -> String {
        let unit = r.freq == .daily ? "日" : r.freq == .weekly ? "週" : "か月"
        var s = r.interval == 1 ? "毎\(unit == "か月" ? "月" : unit)" : "\(r.interval)\(unit)ごと"
        if let w = r.byWeekday, !w.isEmpty { s += "（" + w.sorted().map { DomainTime.weekdayJa[$0] }.joined(separator: "・") + "）" }
        if let u = r.until { s += "・\(model.time.dayLabel(u))まで" }
        return s
    }
}
