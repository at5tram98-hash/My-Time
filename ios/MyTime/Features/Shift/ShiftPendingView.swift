import SwiftUI
import MyTimeCore

// MARK: シフトの「調整中」

/// バイトのシフトか（アルバイトのカレンダー、または種類が「勤務シフト」）
@MainActor
func isShift(_ e: MTEvent, model: AppModel) -> Bool {
    e.specType == .shift || model.calendar(e.calendarId)?.kind == .job
}

/// 調整中か（extra.shiftPending。Web 版は知らない項目を残すだけ）
func isShiftPending(_ e: MTEvent) -> Bool { e.extra?["shiftPending"]?.boolValue == true }

extension AppModel {
    /// まとめて調整中にする／解除する。取り消しは iPhone を振る
    @discardableResult
    func setShiftPending(_ ids: [String], pending: Bool) -> Int {
        let targets = events.filter { ids.contains($0.id) && isShiftPending($0) != pending }
        guard !targets.isEmpty else { return 0 }
        let snapshots = targets
        perform(pending ? "\(targets.count)件を調整中にしました" : "\(targets.count)件の調整中を解除しました", undo: { [weak self] in
            for s in snapshots { try self?.repo.saveEvent(s, isNew: false) }
        }) {
            for var e in targets {
                var x = e.extra?.objectValue ?? [:]
                x["shiftPending"] = pending ? .bool(true) : nil
                e.extra = .object(x)
                try repo.saveEvent(e, isNew: false)
            }
        }
        return targets.count
    }
}

/// 調整中の小さな印（時刻軸・カード・一覧で共通）
struct PendingBadge: View {
    var compact = false
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "hourglass")
            if !compact { Text("調整中") }
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, compact ? 4 : 6).padding(.vertical, 2)
        .background(Capsule().fill(Color.orange))
        .accessibilityLabel("調整中")
    }
}

/// 専用の画面：月のカレンダーで日を複数選び、その日のシフトをまとめて「調整中」にする／解除する
struct ShiftPendingView: View {
    @Environment(AppModel.self) private var model
    @State private var month: Date = Date()
    @State private var selected: Set<EpochMs> = []
    @State private var feedback = 0

    private var cal: Calendar { model.time.calendar }

    var body: some View {
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let shifts = shiftsByDay(monthStart)
        let selectedShifts = selected.sorted().flatMap { shifts[$0] ?? [] }
        List {
            Section {
                VStack(spacing: 10) {
                    HStack {
                        Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").font(.headline) }.buttonStyle(.plain)
                        Spacer()
                        Text(monthStart, format: .dateTime.year().month(.wide)).font(.headline)
                        Spacer()
                        Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").font(.headline) }.buttonStyle(.plain)
                    }
                    .foregroundStyle(Color.accentColor)
                    monthGrid(monthStart, shifts: shifts)
                    HStack(spacing: 14) {
                        legend(Color.orange, "調整中あり")
                        legend(Color(hex: "#FF9F0A").opacity(0.35), "シフトあり")
                        legend(Color.accentColor, "選んだ日")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } footer: {
                Text("日付をタップして複数選べます。もう一度タップすると外れます。")
            }

            Section {
                HStack(spacing: 10) {
                    Button { selectAllShiftDays(shifts) } label: { Label("シフトの日を全部", systemImage: "checkmark.circle") }
                    Spacer()
                    if !selected.isEmpty { Button("選択を外す") { selected = [] }.foregroundStyle(.secondary) }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }

            Section {
                if selectedShifts.isEmpty {
                    Text(selected.isEmpty ? "日を選ぶと、その日のシフトがここに出ます" : "選んだ日にシフトはありません").foregroundStyle(.secondary)
                }
                ForEach(selectedShifts, id: \.id) { o in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(Color(hex: model.eventColor(o.event))).frame(width: 4, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.title).lineLimit(1)
                            Text("\(model.time.dayLabel(o.start)) \(model.hm(o.start))〜\(model.hm(o.end))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        if isShiftPending(o.event) { PendingBadge() }
                    }
                }
            } header: {
                Text("選んだ日のシフト（\(selectedShifts.count)件）")
            }
        }
        .safeAreaInset(edge: .bottom) {
            let ids = Array(Set(selectedShifts.map(\.masterId)))
            HStack(spacing: 10) {
                BigActionButton(title: "調整中にする", symbol: "hourglass", tint: .orange, prominent: true) {
                    if model.setShiftPending(ids, pending: true) > 0 { feedback += 1 }
                }
                .disabled(ids.isEmpty)
                .opacity(ids.isEmpty ? 0.4 : 1)
                BigActionButton(title: "解除", symbol: "checkmark.circle", tint: .green, prominent: false) {
                    if model.setShiftPending(ids, pending: false) > 0 { feedback += 1 }
                }
                .disabled(ids.isEmpty)
                .opacity(ids.isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle("シフトの調整中")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: feedback)
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 8, height: 8); Text(t) }
    }

    private func shiftMonth(_ n: Int) {
        withAnimation(.snappy) { month = cal.date(byAdding: .month, value: n, to: month) ?? month }
    }

    /// その月（前後の週を含む6週）のシフトを日ごとに
    private func shiftsByDay(_ monthStart: Date) -> [EpochMs: [EventOccurrence]] {
        let from = model.time.addDays(model.time.ms(monthStart), -7), to = model.time.addDays(model.time.ms(monthStart), 45)
        var out: [EpochMs: [EventOccurrence]] = [:]
        for o in model.visibleEvents(from: from, to: to) where isShift(o.event, model: model) {
            out[model.time.startOfDay(o.start), default: []].append(o)
        }
        for k in out.keys { out[k]?.sort { $0.start < $1.start } }
        return out
    }

    private func selectAllShiftDays(_ shifts: [EpochMs: [EventOccurrence]]) {
        let m = cal.component(.month, from: month)
        selected = Set(shifts.keys.filter { cal.component(.month, from: model.time.date($0)) == m })
    }

    /// 月のカレンダー（日曜はじまり）。タップで選ぶ／外す、なぞって続けて選ぶ
    private func monthGrid(_ monthStart: Date, shifts: [EpochMs: [EventOccurrence]]) -> some View {
        let first = model.time.ms(monthStart)
        let lead = model.time.weekday(first)
        let gridStart = model.time.addDays(first, -lead)
        let days = (0..<42).map { model.time.addDays(gridStart, $0) }
        let m = cal.component(.month, from: monthStart)
        return VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(DomainTime.weekdayJa[i]).font(.caption2.weight(.semibold))
                        .foregroundStyle(i == 0 ? .red : i == 6 ? .blue : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { d in
                    dayCell(d, inMonth: cal.component(.month, from: model.time.date(d)) == m, shifts: shifts[d] ?? [])
                }
            }
        }
    }

    private func dayCell(_ d: EpochMs, inMonth: Bool, shifts: [EventOccurrence]) -> some View {
        let on = selected.contains(d)
        let pending = shifts.contains { isShiftPending($0.event) }
        let isToday = model.time.isSameDay(d, model.now)
        return Button {
            if on { selected.remove(d) } else { selected.insert(d) }
        } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: model.time.date(d)))")
                    .font(.subheadline.weight(isToday ? .bold : .regular)).monospacedDigit()
                    .foregroundStyle(on ? Color.white : inMonth ? (isToday ? Color.accentColor : .primary) : .secondary.opacity(0.5))
                ZStack {
                    if pending {
                        Image(systemName: "hourglass").font(.system(size: 9, weight: .bold)).foregroundStyle(on ? .white : .orange)
                    } else if !shifts.isEmpty {
                        Circle().fill(on ? Color.white : Color(hex: "#FF9F0A")).frame(width: 6, height: 6)
                    }
                }
                .frame(height: 10)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Color.accentColor : pending ? Color.orange.opacity(0.14) : !shifts.isEmpty ? Color(hex: "#FF9F0A").opacity(0.10) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.time.dayLabel(d))" + (shifts.isEmpty ? "" : "、シフト\(shifts.count)件") + (pending ? "、調整中" : ""))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
