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
                        Section { header(ev, start: start, end: end, now: now, tint: tint) }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                        Section {
                            actions(ev, parsed: parsed, start: start, end: end)
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        details(ev, start: start, end: end)
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
                        Section {
                            LabeledContent("作成", value: "\(model.time.dayLabel(ev.createdAt)) \(model.hm(ev.createdAt))")
                            if ev.updatedAt != ev.createdAt {
                                LabeledContent("最終更新", value: "\(model.time.dayLabel(ev.updatedAt)) \(model.hm(ev.updatedAt))")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                    Text("「\(ev.title)」\n間違えたときは iPhone を振ると元に戻せます。")
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

    private func close() { deleted += 1; dismiss() }

    // MARK: 見出し

    private func header(_ ev: MTEvent, start: EpochMs, end: EpochMs, now: EpochMs, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint).frame(width: 6)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if ev.specType != nil { SpecBadge(type: ev.specType, isEvent: true, size: 28) }
                    Text(ev.title).font(.title2.weight(.bold)).lineLimit(3)
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
                if let s = status(start: start, end: end, now: now, allDay: ev.allDay) {
                    Label(s.text, systemImage: s.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(s.color)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(s.color.opacity(0.14)))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        if now >= start { return Status(text: "進行中・あと\(durationText(end - now))", symbol: "dot.radiowaves.left.and.right", color: .green) }
        let diff = start - now
        if diff < 24 * HOUR { return Status(text: "あと\(durationText(diff))で始まります", symbol: "clock", color: .blue) }
        return nil
    }

    // MARK: よく使う操作

    private func actions(_ ev: MTEvent, parsed: (masterId: String, originalStart: EpochMs)?, start: EpochMs, end: EpochMs) -> some View {
        // ボタンはそれぞれ独立した形（同じ行の別のボタンが反応しないように）
        HStack(spacing: 10) {
            roundButton("編集", "pencil") { router.open(.editor(EditorSeed(kind: .event, eventId: ev.id))) }
            roundButton("複製", "plus.square.on.square") { duplicate(ev, start: start, end: end) }
            roundButton("複数日", "doc.on.doc") {
                copyOccurrence = model.visibleEvents(from: start - 1, to: end + 1).first { $0.id == occurrenceId || $0.masterId == ev.id && $0.start == start }
            }
            if let url = ev.extra?["meetingUrl"]?.stringValue, let u = URL(string: url) {
                roundButton("参加", "video.fill") { openURL(u) }
            } else if let place = ev.placeName, !place.isEmpty {
                roundButton("マップ", "map.fill") {
                    let q = place.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let u = URL(string: "maps://?q=\(q)") { openURL(u) }
                }
            }
            ShareLink(item: shareText(ev, start: start, end: end)) { roundLabel("共有", "square.and.arrow.up") }
                .buttonStyle(PressableStyle())
        }
        .padding(.vertical, 2)
    }

    private func roundButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { roundLabel(title, symbol) }.buttonStyle(PressableStyle())
    }

    private func roundLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title3.weight(.medium))
            Text(title).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
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
            if let cal = model.calendar(ev.calendarId) {
                LabeledContent("カレンダー") {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: cal.color)).frame(width: 10, height: 10)
                        Text(cal.name)
                    }
                }
            }
            if let r = ev.recurrence { LabeledContent("繰り返し", value: recurrenceText(r)) }
            if let place = ev.placeName, !place.isEmpty {
                Button {
                    let q = place.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let url = URL(string: "maps://?q=\(q)") { openURL(url) }
                } label: {
                    LabeledContent("場所") {
                        Label(place, systemImage: "map").foregroundStyle(Color.accentColor)
                    }
                }
                .accessibilityHint("マップで開きます")
            }
            if let m = ev.travelMinutes, m > 0 {
                LabeledContent("移動", value: "\(m)分（\(model.hm(start - EpochMs(m) * MINUTE))に出発）")
            }
            if let room = ev.classInfo?["room"]?.stringValue, !room.isEmpty { LabeledContent("教室", value: room) }
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
            if let emp = model.employer(ev.employerId) { LabeledContent("勤務先", value: emp.name) }
            if isShift(ev, model: model) {
                Toggle(isOn: Binding(get: { isShiftPending(ev) }, set: { model.setShiftPending([ev.id], pending: $0) })) {
                    Label("調整中", systemImage: "hourglass")
                }
                .tint(.orange)
            }
            if ev.specType == .shift, let wage = ev.extra?["spec"]?["details"]?["hourlyWage"]?.doubleValue,
               let pay = shiftPay(start: start, end: end, hourlyWage: wage, breakMinutes: Int(ev.extra?["spec"]?["details"]?["breakMinutes"]?.intValue ?? 0)) {
                LabeledContent("見込みの給与", value: yen(pay.pay))
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
