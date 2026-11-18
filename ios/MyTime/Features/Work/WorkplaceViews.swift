import SwiftUI
import MyTimeCore

// MARK: - 勤務先の一覧

struct EmployersView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var newName = ""
    @State private var confirmDelete: MTEmployer?

    var body: some View {
        List {
            Section {
                NavigationLink { PayrollView() } label: {
                    HStack(spacing: 12) {
                        RowIcon(symbol: "yensign.circle.fill", tint: .green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("給与の見込み")
                            Text(nextPaySummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            Section {
                ForEach(model.employers, id: \.id) { e in
                    NavigationLink { EmployerEditor(employerId: e.id) } label: { employerRow(e) }
                        .swipeActions { Button("削除", systemImage: "trash", role: .destructive) { confirmDelete = e } }
                        .contextMenu {
                            Button("削除", systemImage: "trash", role: .destructive) { confirmDelete = e }
                        }
                }
                Button { newName = ""; adding = true } label: { Label("勤務先を追加", systemImage: "plus.circle.fill") }
            } header: { Text("勤務先") } footer: {
                Text("勤務の予定に勤務先を選ぶと、ここで決めた時給・休憩・交通費・締め日で給与の見込みを出します。登録できる数に上限はありません。")
            }
        }
        .navigationTitle("勤務先と給与")
        .alert("勤務先を追加", isPresented: $adding) {
            TextField("例：GU", text: $newName)
            Button("追加") { model.perform { _ = try model.repo.saveEmployer(name: newName) } }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("「\(confirmDelete?.name ?? "")」を削除しますか？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("削除", role: .destructive) {
                guard let e = confirmDelete else { return }
                let snapshot = e.json
                model.perform("勤務先を削除しました", undo: { try model.repo.restoreEmployer(snapshot) }) { try model.repo.deleteEmployer(e.id) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("勤務の予定は消えません（勤務先なしになります）。間違えたときは iPhone を振ると戻せます。") }
    }

    private var nextPaySummary: String {
        let list = PayrollMath.nextPayments(model: model)
        guard let first = list.min(by: { $0.period.payday < $1.period.payday }) else { return "勤務先を登録すると表示します" }
        return "次の支給 \(model.time.dayLabel(first.period.payday))・\(yen(list.filter { $0.period.payday == first.period.payday }.reduce(0) { $0 + $1.amount }))"
    }

    private func employerRow(_ e: MTEmployer) -> some View {
        let p = e.pay
        return HStack(spacing: 12) {
            Image(systemName: p.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(Color(hex: p.color).gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name)
                Text(p.hourlyWage.map { "時給 \(yen(Int($0)))" } ?? "時給 未設定").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 勤務先の編集

struct EmployerEditor: View {
    var employerId: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var p = PayProfile()
    @State private var loaded = false
    @State private var saved = 0

    private static let symbols = ["briefcase.fill", "bag.fill", "cart.fill", "cup.and.saucer.fill", "fork.knife", "storefront.fill", "building.2.fill", "book.fill", "graduationcap.fill", "shippingbox.fill", "tshirt.fill", "car.fill"]
    private static let colors = ["#FF9F0A", "#FF453A", "#FF375F", "#BF5AF2", "#5E5CE6", "#0A84FF", "#64D2FF", "#30B0C7", "#34C759", "#A2845E", "#8E8E93"]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: p.symbol).font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(Color(hex: p.color).gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    TextField("勤務先の名前", text: $name).font(.title3.weight(.semibold))
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Self.symbols, id: \.self) { s in
                            Button { p.symbol = s } label: {
                                Image(systemName: s).frame(width: 36, height: 36)
                                    .background(Circle().fill(p.symbol == s ? Color(hex: p.color).opacity(0.25) : Color(.tertiarySystemFill)))
                            }
                            .buttonStyle(.plain).accessibilityLabel(s)
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Self.colors, id: \.self) { c in
                        Button { p.color = c } label: {
                            Circle().fill(Color(hex: c)).frame(width: 26, height: 26)
                                .overlay { if p.color == c { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                        }
                        .buttonStyle(.plain).accessibilityLabel("色 \(c)")
                    }
                }
                .padding(.vertical, 2)
                }
            }
            Section {
                LabeledContent("時給") {
                    TextField("円", value: $p.hourlyWage, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
                Picker("計算の単位", selection: $p.unitMinutes) {
                    ForEach([1, 5, 10, 15, 30], id: \.self) { Text($0 == 1 ? "1分単位" : "\($0)分単位").tag($0) }
                }
                if p.unitMinutes > 1 {
                    Picker("単位の端数", selection: $p.unitRounding) { ForEach(PayRounding.allCases, id: \.self) { Text($0.label).tag($0) } }
                }
                Picker("円の端数", selection: $p.yenRounding) { ForEach(PayRounding.allCases, id: \.self) { Text($0.label).tag($0) } }
            } header: { Text("給与") } footer: {
                // 例：18:30〜22:00 の勤務でいくらになるか（条件を変えるとすぐ変わる）
                let d0 = model.time.startOfDay(model.now)
                if let r = PayCalculator.shift(start: d0 + 18 * HOUR + 30 * MINUTE, end: d0 + 22 * HOUR, profile: p, time: model.time), p.hourlyWage != nil {
                    Text("例：18:30〜22:00 の勤務なら 給与 \(yen(r.pay))＋交通費 \(yen(r.transport))＝\(yen(r.total))")
                        .contentTransition(.numericText())
                } else {
                    Text("時給を入れると、18:30〜22:00 の勤務でいくらになるかをここに出します。")
                }
            }
            Section {
                Picker("交通費", selection: $p.transportMode) { ForEach(TransportMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                if p.transportMode != .none {
                    LabeledContent(p.transportMode == .oneWay || p.transportMode == .roundTrip ? "片道の運賃" : "金額") {
                        TextField("円", value: $p.transportAmount, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                }
            } header: { Text("交通費") }
            Section {
                ForEach($p.breakRules) { $r in
                    HStack {
                        Stepper("\(r.overMinutes / 60)時間\(r.overMinutes % 60 == 0 ? "" : "\(r.overMinutes % 60)分")を超えたら", value: $r.overMinutes, in: 0...720, step: 30)
                    }
                    Stepper("休憩 \(r.breakMinutes)分", value: $r.breakMinutes, in: 0...180, step: 5)
                }
                .onDelete { p.breakRules.remove(atOffsets: $0) }
                Button("条件を追加", systemImage: "plus") { p.breakRules.append(BreakRule(overMinutes: 360, breakMinutes: 45)) }
            } header: { Text("休憩") } footer: {
                Text("勤務時間が長いほうの条件を使います。予定に休憩を入力したときはそちらを優先します。法律では6時間を超えると45分、8時間を超えると60分以上の休憩が必要です（下回る勤務には印を出します）。")
            }
            Section {
                ForEach($p.premiums) { $r in
                    Picker("種類", selection: $r.kind) { ForEach(PremiumRule.Kind.allCases, id: \.self) { Text($0.label).tag($0) } }
                    Stepper("割増 \(Int((r.rate * 100).rounded()))%", value: $r.rate, in: 0...1, step: 0.05)
                    switch r.kind {
                    case .overtime: Stepper("実働 \(r.thresholdMinutes / 60)時間を超えた分", value: $r.thresholdMinutes, in: 60...720, step: 30)
                    case .night:
                        Stepper("\(r.fromMinute / 60)時から", value: $r.fromMinute, in: 0...(23 * 60), step: 60)
                        Stepper("\(r.toMinute / 60)時まで", value: $r.toMinute, in: 0...(23 * 60), step: 60)
                    case .weekday:
                        WeekdayChips(selection: $r.weekdays)
                    }
                }
                .onDelete { p.premiums.remove(atOffsets: $0) }
                Button("割増を追加", systemImage: "plus") { p.premiums.append(PremiumRule(kind: .night, rate: 0.25)) }
            } header: { Text("割増") } footer: { Text("勤務先の決まりに合わせて登録します（自動では足しません）。") }
            Section {
                Picker("締め日", selection: $p.closingDay) {
                    Text("月末").tag(0)
                    ForEach(1...28, id: \.self) { Text("\($0)日").tag($0) }
                }
                Picker("支給", selection: $p.paydayMonthOffset) {
                    Text("当月").tag(0); Text("翌月").tag(1); Text("翌々月").tag(2)
                }
                Picker("支給日", selection: $p.paydayDay) {
                    Text("月末").tag(0)
                    ForEach(1...31, id: \.self) { Text("\($0)日").tag($0) }
                }
            } header: { Text("締め日と支給日") } footer: {
                let per = PaySchedule.period(containing: model.now, profile: p, time: model.time)
                Text("いまの勤務は \(model.time.dayLabel(per.from))〜\(model.time.dayLabel(per.closing)) の分として、\(model.time.dayLabel(per.payday)) に支給されます。")
            }
            Section {
                Picker("勤務の何分前に知らせる", selection: $p.noticeMinutes) {
                    ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0)分前").tag($0) }
                }
            } header: { Text("案内") } footer: { Text("ロック画面とダイナミックアイランドに、この時刻から勤務の終わりまで出します。") }
            Section("場所とメモ") {
                TextField("住所・場所", text: $p.address)
                TextField("メモ", text: $p.memo, axis: .vertical).lineLimit(2...6)
            }
        }
        .navigationTitle(name.isEmpty ? "勤務先" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.fontWeight(.semibold) }
        }
        .sensoryFeedback(.success, trigger: saved)
        .onAppear {
            guard !loaded, let e = model.employer(employerId) else { return }
            name = e.name; p = e.pay; loaded = true
        }
    }

    private func save() {
        guard let before = model.employer(employerId) else { return }
        let prevName = before.name, prevPay = before.pay
        if model.perform("勤務先を保存しました", undo: { try model.repo.updateEmployer(employerId, name: prevName, pay: prevPay) }, {
            try model.repo.updateEmployer(employerId, name: name, pay: p)
        }) {
            saved += 1
            dismiss()
        }
    }
}

/// 曜日を選ぶ（0=日〜6=土）
struct WeekdayChips: View {
    @Binding var selection: [Int]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { d in
                let on = selection.contains(d)
                Button {
                    if on { selection.removeAll { $0 == d } } else { selection.append(d); selection.sort() }
                } label: {
                    Text(DomainTime.weekdayJa[d]).font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(on ? .white : (d == 0 ? .red : d == 6 ? .blue : .primary))
                        .background(Circle().fill(on ? Color.accentColor : Color(.tertiarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(DomainTime.weekdayJa[d])曜日")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 給与の計算（画面用）

@MainActor
enum PayrollMath {
    struct Payment {
        var employer: MTEmployer; var period: PayPeriod; var amount: Int; var confirmed: Int?; var lines: [ShiftLine]
        var key: String { "\(employer.id)@\(period.closing)" }
    }

    static func lines(model: AppModel, from: EpochMs, to: EpochMs) -> [ShiftLine] {
        Payroll.lines(occurrences: expandAll(model.events, from: from, to: to, time: model.time).filter { !$0.event.allDay && !$0.isStruck }, employers: model.employers, time: model.time)
    }

    static func payment(model: AppModel, employer e: MTEmployer, period per: PayPeriod) -> Payment {
        let ls = lines(model: model, from: per.from, to: per.to).filter { $0.employerId == e.id }
        let confirmed = model.confirmedPays.first { $0.employerId == e.id && $0.closing == per.closing }?.amount
        return Payment(employer: e, period: per, amount: Payroll.periodTotal(ls, profile: e.pay), confirmed: confirmed, lines: ls)
    }

    /// 勤務先ごとの次の支給
    static func nextPayments(model: AppModel) -> [Payment] {
        model.employers.map { payment(model: model, employer: $0, period: PaySchedule.nextPayPeriod(after: model.now, profile: $0.pay, time: model.time)) }
    }

    /// 次の支給と、いまの締め期間（支給がその後のとき）を、支給日の順に
    static func upcomingPayments(model: AppModel) -> [Payment] {
        model.employers.flatMap { e -> [Payment] in
            let next = PaySchedule.nextPayPeriod(after: model.now, profile: e.pay, time: model.time)
            let cur = PaySchedule.period(containing: model.now, profile: e.pay, time: model.time)
            return (cur.closing == next.closing ? [next] : [next, cur]).map { payment(model: model, employer: e, period: $0) }
        }
        .sorted { ($0.period.payday, $0.employer.name) < ($1.period.payday, $1.employer.name) }
    }
}

// MARK: - 給与の見込み

struct PayrollView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: PayrollMath.Payment?
    @State private var amountText = ""

    var body: some View {
        let t = model.time
        let now = model.now
        let d0 = t.startOfDay(now)
        let weekStart = t.addDays(d0, -t.weekday(now))
        let monthStart = t.ms(t.calendar.date(from: t.calendar.dateComponents([.year, .month], from: t.date(now)))!)
        let today = Payroll.summary(PayrollMath.lines(model: model, from: d0, to: t.addDays(d0, 1)))
        let week = Payroll.summary(PayrollMath.lines(model: model, from: weekStart, to: t.addDays(weekStart, 7)))
        let monthLines = PayrollMath.lines(model: model, from: monthStart, to: t.addMonths(monthStart, 1))
        let month = Payroll.summary(monthLines)
        let next = PayrollMath.upcomingPayments(model: model)
        List {
            Section {
                HStack(spacing: 10) {
                    tile("今日", today)
                    tile("今週", week)
                    tile("今月", month)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } footer: { Text("予定の勤務時間から計算した見込み（交通費を含む）。給与明細を受け取ったら、下の支給の行を押して金額を入れると「確定」になります。") }

            Section("これからの支給") {
                if next.isEmpty {
                    ContentUnavailableView {
                        Label("勤務先がありません", systemImage: "briefcase")
                    } description: { Text("勤務先と時給を登録すると、ここに支給の見込みが出ます。") } actions: {
                        NavigationLink("勤務先を登録") { EmployersView() }.buttonStyle(.borderedProminent)
                    }
                }
                ForEach(next, id: \.key) { p in
                    Button { editing = p; amountText = p.confirmed.map(String.init) ?? "" } label: {
                        HStack(spacing: 12) {
                            Image(systemName: p.employer.pay.symbol).foregroundStyle(Color(hex: p.employer.pay.color)).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.employer.name).foregroundStyle(.primary)
                                Text("\(t.dayLabel(p.period.payday))支給・\(t.dayLabel(p.period.from))〜\(t.dayLabel(p.period.closing))締め・\(p.lines.count)回")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                if let c = p.confirmed {
                                    Text(yen(c)).font(.headline).monospacedDigit().foregroundStyle(.green)
                                    Text("確定（見込み \(yen(p.amount))）").font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    Text(yen(p.amount)).font(.headline).monospacedDigit().foregroundStyle(.primary)
                                    Text("見込み").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("給与明細の金額を入力して確定します")
                }
            }

            Section("今月の勤務先ごと") {
                ForEach(model.employers, id: \.id) { e in
                    let ls = monthLines.filter { $0.employerId == e.id }
                    let s = Payroll.summary(ls)
                    let all = max(1, Payroll.summary(monthLines).total)
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent {
                            Text(yen(s.total)).monospacedDigit()
                        } label: {
                            Label("\(e.name)（\(s.shifts)回・\(s.workMinutes / 60)時間\(s.workMinutes % 60)分）", systemImage: e.pay.symbol)
                                .foregroundStyle(Color(hex: e.pay.color), .primary)
                        }
                        // 今月の合計に占める割合
                        GeometryReader { g in
                            Capsule().fill(Color(.tertiarySystemFill))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Color(hex: e.pay.color).gradient).frame(width: g.size.width * CGFloat(s.total) / CGFloat(all))
                                }
                        }
                        .frame(height: 6)
                    }
                }
            }

            Section {
                ForEach(monthLines.sorted { $0.start < $1.start }) { l in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(t.dayLabel(l.start)) \(t.hm(l.start))〜\(t.hm(l.end))").font(.subheadline.weight(.semibold)).monospacedDigit()
                            Spacer()
                            Text(yen(l.best.total)).font(.subheadline).monospacedDigit()
                        }
                        HStack(spacing: 6) {
                            Text(model.employer(l.employerId)?.name ?? l.title)
                            Text("予定 \(l.planned.workMinutes)分")
                            if l.best.breakMinutes > 0 { Text("休憩 \(l.best.breakMinutes)分") }
                            if l.best.belowLegalBreak { Label("休憩が法定未満", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } header: { Text("今月の勤務") }

            Section {
                ShareLink(item: exportText(), preview: SharePreview("給与データ（JSON）")) {
                    Label("給与データを書き出す", systemImage: "square.and.arrow.up")
                }
            } footer: { Text("MyMoney などで使えるように、勤務・見込み・確定額を JSON で書き出します。自動では送りません。") }
        }
        .navigationTitle("給与の見込み")
        .alert("給与明細の金額", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("円", text: $amountText).keyboardType(.numberPad)
            Button("確定") {
                guard let p = editing, let v = Int(amountText) else { return }
                model.confirmPay(ConfirmedPay(employerId: p.employer.id, closing: p.period.closing, amount: v, confirmedAt: model.now))
            }
            if editing?.confirmed != nil {
                Button("確定を取り消す", role: .destructive) {
                    if let p = editing { model.confirmPay(nil, removing: "\(p.employer.id)@\(p.period.closing)") }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("明細で受け取った額を入れると「確定」になります。見込みはそのまま残ります。") }
    }

    private func tile(_ title: String, _ s: PayrollSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(yen(s.total)).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(Motion.value, value: s.total)
            Text("\(s.shifts)回").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func exportText() -> String {
        let t = model.time
        let from = t.addMonths(t.startOfDay(model.now), -3), to = t.addMonths(t.startOfDay(model.now), 2)
        let ls = PayrollMath.lines(model: model, from: from, to: to)
        var periods: [PayrollExport.Period] = []
        for e in model.employers {
            var seen = Set<EpochMs>()
            for l in ls where l.employerId == e.id {
                let per = PaySchedule.period(containing: l.start, profile: e.pay, time: t)
                guard seen.insert(per.closing).inserted else { continue }
                let inPer = ls.filter { $0.employerId == e.id && $0.start >= per.from && $0.start < per.to }
                periods.append(.init(employerId: e.id, closing: per.closing, payday: per.payday, predicted: Payroll.periodTotal(inPer, profile: e.pay),
                                     confirmedAmount: model.confirmedPays.first { $0.employerId == e.id && $0.closing == per.closing }?.amount))
            }
        }
        let x = PayrollExport(exportedAt: model.now, employers: model.employers.map { .init(id: $0.id, name: $0.name) },
                              shifts: ls.map { .init(id: $0.id, employerId: $0.employerId, start: $0.start, end: $0.end, workMinutes: $0.best.workMinutes, pay: $0.best.pay, transport: $0.best.transport) },
                              periods: periods)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: enc.encode(x), encoding: .utf8)) ?? "{}"
    }
}

// MARK: - 予定の詳細：勤務（給与の内訳）

struct ShiftWorkSection: View {
    var event: MTEvent
    var start: EpochMs
    var end: EpochMs
    @Environment(AppModel.self) private var model

    var body: some View {
        let emp = model.employer(event.employerId)
        Section {
            if let emp {
                let brk = event.extra?["spec"]?["details"]?["breakMinutes"]?.intValue.map(Int.init)
                if let r = PayCalculator.shift(start: start, end: end, profile: emp.pay, breakOverride: brk, time: model.time) {
                    if emp.pay.hourlyWage == nil {
                        NavigationLink { EmployerEditor(employerId: emp.id) } label: {
                            Label("時給を入れると給与を計算します", systemImage: "yensign.circle").foregroundStyle(Color.accentColor)
                        }
                    }
                    // 大きな数字＋内訳（休憩を引いた実働 × 時給 ＋ 交通費）
                    VStack(alignment: .leading, spacing: 4) {
                        Text("合計の見込み").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(yen(r.total)).font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit()
                            .contentTransition(.numericText())
                        Text("実働 \(hm(r.workMinutes))（予定 \(hm(r.scheduledMinutes)) − 休憩 \(r.breakMinutes)分）" + (r.transport > 0 ? "・交通費 \(yen(r.transport))" : ""))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    if r.belowLegalBreak { Label("休憩が法律の最低限より短い条件です", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
                }
            } else {
                Label("勤務先を選ぶと給与を計算します（右上の「編集」› 勤務先）", systemImage: "info.circle").font(.subheadline).foregroundStyle(.secondary)
            }
        } header: {
            Label(emp?.name ?? "勤務", systemImage: emp?.pay.symbol ?? "briefcase.fill").foregroundStyle(Color(hex: emp?.pay.color ?? "#FF9F0A")).textCase(nil)
        }
    }

    private func hm(_ m: Int) -> String { m % 60 == 0 ? "\(m / 60)時間" : "\(m / 60)時間\(m % 60)分" }
}
