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
        .fixedSize()
        .accessibilityLabel("調整中")
    }
}

/// 専用の画面：勤務先を選び、月のカレンダーで日を複数選んで、その日のシフトをまとめて「調整中」にする／解除する
struct ShiftPendingView: View {
    @Environment(AppModel.self) private var model
    @State private var month: Date = Date()
    @State private var selected: Set<EpochMs> = []
    /// nil = すべての勤務先、"" = 勤務先が未設定のシフト
    @State private var employerFilter: String?
    @State private var feedback = 0
    @State private var newEmployerPrompt = false
    @State private var newEmployerName = ""

    private var cal: Calendar { model.time.calendar }

    var body: some View {
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let shifts = shiftsByDay(monthStart)
        let selectedShifts = selected.sorted().flatMap { shifts[$0] ?? [] }
        let ids = Array(Set(selectedShifts.map(\.masterId)))
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                employerChips
                card { calendarCard(monthStart, shifts: shifts) }
                HStack {
                    Button { selectAll(shifts, monthStart: monthStart) } label: { Label("シフトの日をすべて選ぶ", systemImage: "checkmark.circle") }
                    Spacer()
                    if !selected.isEmpty { Button("選択を外す") { withAnimation(.snappy) { selected = [] } }.foregroundStyle(.secondary) }
                }
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("選んだ日のシフト（\(selectedShifts.count)件）").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
                    card {
                        if selectedShifts.isEmpty {
                            Text(selected.isEmpty ? "日をタップすると、その日のシフトがここに出ます" : "選んだ日にシフトはありません")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(selectedShifts.enumerated()), id: \.element.id) { i, o in
                                    if i > 0 { Divider().padding(.leading, 14) }
                                    shiftRow(o)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom) { actionBar(ids: ids) }
        .navigationTitle("シフトの調整中")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: feedback)
        .alert("新しい勤務先", isPresented: $newEmployerPrompt) {
            TextField("例：無印良品", text: $newEmployerName)
            Button("追加") {
                var made: MTEmployer?
                let ok = model.perform { made = try model.repo.saveEmployer(name: newEmployerName) }
                if ok { employerFilter = made?.id }
                newEmployerName = ""
            }
            Button("キャンセル", role: .cancel) { newEmployerName = "" }
        }
        .onChange(of: employerFilter) { _, _ in selected = [] }
    }

    // MARK: 部品

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// 勤務先で絞り込む（すべて・各勤務先・未設定）
    private var employerChips: some View {
        let hasUnassigned = model.events.contains { isShift($0, model: model) && $0.employerId == nil }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("すべて", count: shiftCount(nil), on: employerFilter == nil) { employerFilter = nil }
                ForEach(model.employers, id: \.id) { e in
                    chip(e.name, count: shiftCount(e.id), on: employerFilter == e.id) { employerFilter = e.id }
                }
                if hasUnassigned {
                    chip("勤務先なし", count: shiftCount(""), on: employerFilter == "") { employerFilter = "" }
                }
                Button { newEmployerPrompt = true } label: {
                    Label("勤務先", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12).frame(minHeight: 34)
                        .background(Capsule().strokeBorder(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2).padding(.vertical, 2)
        }
    }

    private func chip(_ title: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                if count > 0 {
                    Text("\(count)").font(.caption.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(on ? Color.white.opacity(0.25) : Color.orange.opacity(0.18)))
                }
            }
            .font(.subheadline.weight(on ? .semibold : .regular))
            .padding(.horizontal, 12).frame(minHeight: 34)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(Capsule().fill(on ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color(.secondarySystemGroupedBackground))))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// この月の調整中のシフトの数
    private func shiftCount(_ filter: String?) -> Int {
        model.events.filter { isShift($0, model: model) && isShiftPending($0) && matches($0, filter) }.count
    }

    private func matches(_ e: MTEvent, _ filter: String?) -> Bool {
        guard let filter else { return true }
        return filter.isEmpty ? e.employerId == nil : e.employerId == filter
    }

    private func calendarCard(_ monthStart: Date, shifts: [EpochMs: [EventOccurrence]]) -> some View {
        VStack(spacing: 12) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                Spacer()
                Text(monthStart, format: .dateTime.year().month(.wide)).font(.headline)
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            monthGrid(monthStart, shifts: shifts)
            HStack(spacing: 16) {
                legend("調整中") { Image(systemName: "hourglass").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange) }
                legend("シフト") { Circle().fill(Color.orange.opacity(0.6)).frame(width: 7, height: 7) }
                legend("選んだ日") { RoundedRectangle(cornerRadius: 3).fill(Color.accentColor).frame(width: 10, height: 10) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }
    }

    private func legend<I: View>(_ label: String, @ViewBuilder _ icon: () -> I) -> some View {
        HStack(spacing: 5) { icon(); Text(label) }
    }

    private func shiftRow(_ o: EventOccurrence) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: model.eventColor(o.event))).frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(o.title).font(.body.weight(.medium)).lineLimit(1)
                    if let emp = model.employer(o.event.employerId), emp.name != o.title {
                        Text(emp.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text("\(model.time.dayLabel(o.start)) \(model.hm(o.start))〜\(model.hm(o.end))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            if isShiftPending(o.event) { PendingBadge() } else {
                Label("決定", systemImage: "checkmark.circle.fill").font(.caption2.weight(.bold)).foregroundStyle(.green).labelStyle(CompactLabel())
            }
        }
        .padding(.vertical, 8)
    }

    /// 下の操作：選んだ件数と、調整中にする／解除する
    private func actionBar(ids: [String]) -> some View {
        let enabled = !ids.isEmpty
        return VStack(spacing: 6) {
            Text(enabled ? "\(ids.count)件のシフトを選んでいます" : "日を選んでください")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { if model.setShiftPending(ids, pending: true) > 0 { feedback += 1 } } label: {
                    Label("調整中にする", systemImage: "hourglass").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(enabled ? AnyShapeStyle(Color.orange.gradient) : AnyShapeStyle(Color.gray.opacity(0.35))))
                }
                Button { if model.setShiftPending(ids, pending: false) > 0 { feedback += 1 } } label: {
                    Label("決定にする", systemImage: "checkmark.circle").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .foregroundStyle(enabled ? Color.green : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(.separator).opacity(0.5), lineWidth: 0.5))
                }
            }
            .buttonStyle(PressableStyle())
            .disabled(!enabled)
        }
        .padding(.horizontal).padding(.top, 8).padding(.bottom, 6)
        .background(.bar)
    }

    private func shiftMonth(_ n: Int) {
        withAnimation(.snappy) { month = cal.date(byAdding: .month, value: n, to: month) ?? month; selected = [] }
    }

    /// その月（前後の週を含む6週）のシフトを日ごとに（選んだ勤務先だけ）
    private func shiftsByDay(_ monthStart: Date) -> [EpochMs: [EventOccurrence]] {
        let from = model.time.addDays(model.time.ms(monthStart), -7), to = model.time.addDays(model.time.ms(monthStart), 45)
        var out: [EpochMs: [EventOccurrence]] = [:]
        for o in model.visibleEvents(from: from, to: to) where isShift(o.event, model: model) && matches(o.event, employerFilter) {
            out[model.time.startOfDay(o.start), default: []].append(o)
        }
        for k in out.keys { out[k]?.sort { $0.start < $1.start } }
        return out
    }

    private func selectAll(_ shifts: [EpochMs: [EventOccurrence]], monthStart: Date) {
        let m = cal.component(.month, from: monthStart)
        withAnimation(.snappy) { selected = Set(shifts.keys.filter { cal.component(.month, from: model.time.date($0)) == m }) }
    }

    /// 月のカレンダー（日曜はじまり・その月の週だけ）。タップで選ぶ／外す
    private func monthGrid(_ monthStart: Date, shifts: [EpochMs: [EventOccurrence]]) -> some View {
        let first = model.time.ms(monthStart)
        let lead = model.time.weekday(first)
        let gridStart = model.time.addDays(first, -lead)
        let daysInMonth = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let weeks = Int(ceil(Double(lead + daysInMonth) / 7))
        let days = (0..<(weeks * 7)).map { model.time.addDays(gridStart, $0) }
        let m = cal.component(.month, from: monthStart)
        return VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(0..<7, id: \.self) { i in
                    Text(DomainTime.weekdayJa[i]).font(.caption2.weight(.semibold))
                        .foregroundStyle(i == 0 ? .red : i == 6 ? .blue : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { d in
                    let inMonth = cal.component(.month, from: model.time.date(d)) == m
                    if inMonth { dayCell(d, shifts: shifts[d] ?? []) } else { Color.clear.frame(height: 46) }
                }
            }
        }
    }

    private func dayCell(_ d: EpochMs, shifts: [EventOccurrence]) -> some View {
        let on = selected.contains(d)
        let pending = shifts.contains { isShiftPending($0.event) }
        let isToday = model.time.isSameDay(d, model.now)
        return Button {
            withAnimation(.snappy) { if on { selected.remove(d) } else { selected.insert(d) } }
        } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: model.time.date(d)))")
                    .font(.subheadline.weight(isToday || on ? .bold : .regular)).monospacedDigit()
                    .foregroundStyle(on ? Color.white : isToday ? Color.accentColor : shifts.isEmpty ? Color.secondary : Color.primary)
                Group {
                    if pending {
                        Image(systemName: "hourglass").font(.system(size: 9, weight: .bold)).foregroundStyle(on ? .white : .orange)
                    } else if !shifts.isEmpty {
                        Circle().fill(on ? Color.white : Color.orange.opacity(0.6)).frame(width: 6, height: 6)
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 10)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Color.accentColor : pending ? Color.orange.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isToday && !on ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(model.time.dayLabel(d))" + (shifts.isEmpty ? "" : "、シフト\(shifts.count)件") + (pending ? "、調整中" : ""))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
