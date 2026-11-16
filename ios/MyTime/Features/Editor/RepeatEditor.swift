import SwiftUI
import MyTimeCore

/// 繰り返しの説明（Web 版 describeRule と同じ言い方）
func describeRule(_ r: RecurrenceRule?) -> String {
    guard let r else { return "しない" }
    if r.freq == .weekly, r.interval == 1, let w = r.byWeekday, Set(w) == [1, 2, 3, 4, 5] { return "平日" + (r.until != nil ? "・期限あり" : "") }
    let every = r.interval > 1
        ? "\(r.interval)\(r.freq == .daily ? "日" : r.freq == .weekly ? "週" : "か月")ごと"
        : (r.freq == .daily ? "毎日" : r.freq == .weekly ? "毎週" : "毎月")
    let days = r.freq == .weekly ? (r.byWeekday.map { w in w.isEmpty ? "" : "（" + w.sorted().map { DomainTime.weekdayJa[$0] }.joined(separator: "・") + "）" } ?? "") : ""
    return every + days + (r.until != nil ? "・期限あり" : "")
}

/// 繰り返しを選ぶ画面。よく使う形と、自分で決める（間隔・曜日・終わる日）
struct RepeatEditor: View {
    @Binding var rule: RecurrenceRule?
    var start: Date
    @Environment(AppModel.self) private var model
    @State private var custom = false

    private var wd: Int { model.time.weekday(model.time.ms(start)) }

    private var presets: [(String, RecurrenceRule?)] {
        [("しない", nil),
         ("毎日", RecurrenceRule(freq: .daily)),
         ("毎週（\(DomainTime.weekdayJa[wd])曜日）", RecurrenceRule(freq: .weekly, byWeekday: [wd])),
         ("平日（月〜金）", RecurrenceRule(freq: .weekly, byWeekday: [1, 2, 3, 4, 5])),
         ("隔週（\(DomainTime.weekdayJa[wd])曜日）", RecurrenceRule(freq: .weekly, interval: 2, byWeekday: [wd])),
         ("毎月（\(Calendar.current.component(.day, from: start))日）", RecurrenceRule(freq: .monthly))]
    }

    private func same(_ a: RecurrenceRule?, _ b: RecurrenceRule?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.freq == b.freq && a.interval == b.interval && Set(a.byWeekday ?? []) == Set(b.byWeekday ?? [])
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(presets.enumerated()), id: \.offset) { _, p in
                    Button {
                        withAnimation(.snappy) {
                            var r = p.1
                            r?.until = rule?.until
                            rule = r
                            custom = false
                        }
                    } label: {
                        HStack {
                            Text(p.0).foregroundStyle(.primary)
                            Spacer()
                            if !custom && same(rule, p.1) { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    withAnimation(.snappy) {
                        custom = true
                        if rule == nil { rule = RecurrenceRule(freq: .weekly, byWeekday: [wd]) }
                    }
                } label: {
                    HStack {
                        Text("カスタム").foregroundStyle(.primary)
                        Spacer()
                        if custom || (rule != nil && !presets.contains { same($0.1, rule) }) {
                            Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let r = rule, custom || !presets.contains(where: { same($0.1, rule) }) {
                Section {
                    Picker("単位", selection: Binding(get: { r.freq }, set: { f in
                        rule?.freq = f
                        rule?.byWeekday = f == .weekly ? (r.byWeekday?.isEmpty == false ? r.byWeekday : [wd]) : nil
                    })) {
                        Text("日").tag(RecurrenceFreq.daily)
                        Text("週").tag(RecurrenceFreq.weekly)
                        Text("月").tag(RecurrenceFreq.monthly)
                    }
                    .pickerStyle(.segmented)
                    Stepper(value: Binding(get: { r.interval }, set: { rule?.interval = $0 }), in: 1...99) {
                        Text("\(r.interval)\(r.freq == .daily ? "日" : r.freq == .weekly ? "週" : "か月")ごと").monospacedDigit()
                    }
                    if r.freq == .weekly {
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { i in
                                let on = r.byWeekday?.contains(i) ?? false
                                Button {
                                    var w = r.byWeekday ?? []
                                    if on { w.removeAll { $0 == i } } else { w.append(i) }
                                    rule?.byWeekday = w.isEmpty ? [wd] : w.sorted()
                                } label: {
                                    Text(DomainTime.weekdayJa[i])
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity, minHeight: 38)
                                        .background(Circle().fill(on ? Color.accentColor : Color(.tertiarySystemFill)))
                                        .foregroundStyle(on ? Color.white : i == 0 ? .red : i == 6 ? .blue : .primary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(DomainTime.weekdayJa[i])曜日")
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                    }
                } header: {
                    Text("カスタム")
                } footer: {
                    Text(describeRule(rule))
                }
            }

            if rule != nil {
                Section {
                    Toggle("終わる日を決める", isOn: Binding(get: { rule?.until != nil }, set: { on in
                        withAnimation(.snappy) {
                            rule?.until = on ? model.time.addDays(model.time.startOfDay(model.time.ms(start)), 90) + 86_400_000 - 1 : nil
                        }
                    }))
                    if let u = rule?.until {
                        DatePicker("この日まで", selection: Binding(get: { model.time.date(u) }, set: { d in
                            rule?.until = model.time.startOfDay(model.time.ms(d)) + 86_400_000 - 1
                        }), in: start..., displayedComponents: .date)
                        .datePickerStyle(.graphical)
                    }
                } footer: {
                    if rule?.until == nil { Text("終わる日を決めないと、ずっと繰り返します。") }
                }
            }
        }
        .navigationTitle("繰り返し")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { custom = rule != nil && !presets.contains { same($0.1, rule) } }
    }
}
