import Foundation

// MARK: - 勤務先の給与条件
//
// 勤務先（MTEmployer）のレコードに `pay` として足して保存する（Web 版は知らない項目を残したまま無視する）。
// 法令の最低限（労働基準法の休憩）と、勤務先独自の計算条件（端数・割増・交通費）は分けて扱う：
// 計算には勤務先の条件を使い、法令の最低限は「下回っていないか」の確認だけに使う。

public enum PayRounding: String, Codable, CaseIterable, Sendable {
    case floor, round, ceil
    public var label: String { self == .floor ? "切り捨て" : self == .round ? "四捨五入" : "切り上げ" }
    func apply(_ v: Double) -> Double { self == .floor ? v.rounded(.down) : self == .ceil ? v.rounded(.up) : v.rounded() }
}

public enum TransportMode: String, Codable, CaseIterable, Sendable {
    case none, perShift, oneWay, roundTrip, monthly
    public var label: String {
        switch self {
        case .none: return "なし"
        case .perShift: return "1勤務ごとに定額"
        case .oneWay: return "片道の運賃"
        case .roundTrip: return "往復の運賃"
        case .monthly: return "月ごとに定額"
        }
    }
}

/// 勤務が overMinutes を超えたら breakMinutes の休憩（いちばん長い時間に当てはまる条件を使う）
public struct BreakRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var overMinutes: Int
    public var breakMinutes: Int
    public init(id: String = UUID().uuidString, overMinutes: Int, breakMinutes: Int) { self.id = id; self.overMinutes = overMinutes; self.breakMinutes = breakMinutes }
}

/// 割増（勤務先の条件として登録する。率は 0.25 = 25%増し）
public struct PremiumRule: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case overtime, night, weekday
        public var label: String { self == .overtime ? "時間外（1日の実働が超えた分）" : self == .night ? "深夜（時間帯）" : "曜日（土日など）" }
    }
    public var id: String
    public var kind: Kind
    public var rate: Double
    /// overtime：この分数を超えた実働
    public var thresholdMinutes: Int
    /// night：この時間帯（0時からの分。from > to は日をまたぐ）
    public var fromMinute: Int
    public var toMinute: Int
    /// weekday：0=日〜6=土
    public var weekdays: [Int]
    public init(id: String = UUID().uuidString, kind: Kind, rate: Double, thresholdMinutes: Int = 480, fromMinute: Int = 22 * 60, toMinute: Int = 5 * 60, weekdays: [Int] = [0, 6]) {
        self.id = id; self.kind = kind; self.rate = rate; self.thresholdMinutes = thresholdMinutes; self.fromMinute = fromMinute; self.toMinute = toMinute; self.weekdays = weekdays
    }
}

public struct PayProfile: Codable, Hashable, Sendable {
    public var hourlyWage: Double?
    public var transportMode: TransportMode = .none
    /// 円（片道・往復のときは片道の運賃）
    public var transportAmount: Int = 0
    public var breakRules: [BreakRule] = []
    /// 締め日（0 = 月末、1〜28）
    public var closingDay: Int = 0
    /// 支給日（0 = 月末、1〜31）と、締めから何か月後か（翌月 = 1）
    public var paydayDay: Int = 25
    public var paydayMonthOffset: Int = 1
    /// 実働を何分単位にそろえるか（1 = 1分単位）
    public var unitMinutes: Int = 1
    public var unitRounding: PayRounding = .floor
    /// 円の端数
    public var yenRounding: PayRounding = .floor
    public var premiums: [PremiumRule] = []
    public var color: String = "#FF9F0A"
    public var symbol: String = "briefcase.fill"
    public var address: String = ""
    public var latitude: Double?
    public var longitude: Double?
    public var memo: String = ""
    /// 勤務の何分前から Live Activity・通知で案内するか
    public var noticeMinutes: Int = 15

    public init() {}

    enum CodingKeys: String, CodingKey {
        case hourlyWage, transportMode, transportAmount, breakRules, closingDay, paydayDay, paydayMonthOffset, unitMinutes, unitRounding, yenRounding, premiums, color, symbol, address, latitude, longitude, memo, noticeMinutes
    }

    /// 保存済みのデータに無い項目は既定値にする（古いデータ・Web 版のデータも読める）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hourlyWage = try c.decodeIfPresent(Double.self, forKey: .hourlyWage)
        transportMode = (try? c.decodeIfPresent(TransportMode.self, forKey: .transportMode)) ?? .none
        transportAmount = (try? c.decodeIfPresent(Int.self, forKey: .transportAmount)) ?? 0
        breakRules = (try? c.decodeIfPresent([BreakRule].self, forKey: .breakRules)) ?? []
        closingDay = (try? c.decodeIfPresent(Int.self, forKey: .closingDay)) ?? 0
        paydayDay = (try? c.decodeIfPresent(Int.self, forKey: .paydayDay)) ?? 25
        paydayMonthOffset = (try? c.decodeIfPresent(Int.self, forKey: .paydayMonthOffset)) ?? 1
        unitMinutes = max(1, (try? c.decodeIfPresent(Int.self, forKey: .unitMinutes)) ?? 1)
        unitRounding = (try? c.decodeIfPresent(PayRounding.self, forKey: .unitRounding)) ?? .floor
        yenRounding = (try? c.decodeIfPresent(PayRounding.self, forKey: .yenRounding)) ?? .floor
        premiums = (try? c.decodeIfPresent([PremiumRule].self, forKey: .premiums)) ?? []
        color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? "#FF9F0A"
        symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? "briefcase.fill"
        address = (try? c.decodeIfPresent(String.self, forKey: .address)) ?? ""
        latitude = try? c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try? c.decodeIfPresent(Double.self, forKey: .longitude)
        memo = (try? c.decodeIfPresent(String.self, forKey: .memo)) ?? ""
        noticeMinutes = (try? c.decodeIfPresent(Int.self, forKey: .noticeMinutes)) ?? 15
    }
}

public extension MTEmployer {
    /// 勤務先の給与条件（未登録なら既定値）
    var pay: PayProfile {
        guard let v = raw["pay"], let p = try? JSONValue.decode(PayProfile.self, from: v) else { return PayProfile() }
        return p
    }
}

/// 法令（労働基準法第34条）の休憩の最低限：6時間を超えると45分、8時間を超えると60分
public func legalMinimumBreak(scheduledMinutes m: Int) -> Int { m > 480 ? 60 : m > 360 ? 45 : 0 }

/// 1回の勤務の計算結果
public struct ShiftPayResult: Equatable, Sendable {
    /// 予定（または実績）の拘束時間
    public var scheduledMinutes: Int
    public var breakMinutes: Int
    /// 単位の端数処理をしたあとの実働
    public var workMinutes: Int
    public var basePay: Int
    public var premiumPay: Int
    /// 給与（交通費を除く）
    public var pay: Int
    public var transport: Int
    public var total: Int { pay + transport }
    /// 勤務先の休憩が法令の最低限を下回る（計算は勤務先の条件のまま。確認を促すだけ）
    public var belowLegalBreak: Bool
}

public enum PayCalculator {
    /// 1回の勤務。breakOverride：その予定に休憩が入力されていればそれを使う
    public static func shift(start: EpochMs, end: EpochMs, profile p: PayProfile, breakOverride: Int? = nil, time: DomainTime = .current) -> ShiftPayResult? {
        guard end > start else { return nil }
        let scheduled = Int((end - start) / MINUTE)
        let ruleBreak = p.breakRules.filter { scheduled > $0.overMinutes }.max { $0.overMinutes < $1.overMinutes }?.breakMinutes ?? 0
        let brk = min(scheduled, max(0, breakOverride ?? ruleBreak))
        let unit = max(1, p.unitMinutes)
        let work = Int(p.unitRounding.apply(Double(scheduled - brk) / Double(unit))) * unit
        let transport: Int
        switch p.transportMode {
        case .none, .monthly: transport = 0
        case .perShift, .oneWay: transport = p.transportAmount
        case .roundTrip: transport = p.transportAmount * 2
        }
        guard let wage = p.hourlyWage, wage >= 0 else {
            return ShiftPayResult(scheduledMinutes: scheduled, breakMinutes: brk, workMinutes: work, basePay: 0, premiumPay: 0, pay: 0, transport: transport, belowLegalBreak: brk < legalMinimumBreak(scheduledMinutes: scheduled))
        }
        let perMinute = wage / 60
        let base = perMinute * Double(work)
        var premium = 0.0
        for r in p.premiums {
            switch r.kind {
            case .overtime:
                premium += perMinute * Double(max(0, work - r.thresholdMinutes)) * r.rate
            case .night:
                // 深夜の時間帯と勤務の重なり（休憩はどこで取るか分からないため差し引かない）
                premium += perMinute * Double(min(work, nightOverlap(start: start, end: end, from: r.fromMinute, to: r.toMinute, time: time))) * r.rate
            case .weekday:
                if r.weekdays.contains(time.weekday(start)) { premium += base * r.rate }
            }
        }
        let pay = Int(p.yenRounding.apply(base + premium))
        return ShiftPayResult(scheduledMinutes: scheduled, breakMinutes: brk, workMinutes: work, basePay: Int(p.yenRounding.apply(base)),
                              premiumPay: pay - Int(p.yenRounding.apply(base)), pay: pay, transport: transport,
                              belowLegalBreak: brk < legalMinimumBreak(scheduledMinutes: scheduled))
    }

    /// 勤務と、毎日の時間帯（from〜to。from > to は日をまたぐ）が重なる分数
    static func nightOverlap(start: EpochMs, end: EpochMs, from: Int, to: Int, time: DomainTime) -> Int {
        var total: EpochMs = 0
        var day = time.addDays(time.startOfDay(start), -1)
        while day < end {
            let s = day + EpochMs(from) * MINUTE
            let e = from < to ? day + EpochMs(to) * MINUTE : time.addDays(day, 1) + EpochMs(to) * MINUTE
            total += max(0, min(end, e) - max(start, s))
            day = time.addDays(day, 1)
        }
        return Int(total / MINUTE)
    }
}

// MARK: - 締め日と支給日

public struct PayPeriod: Equatable, Hashable, Sendable {
    /// 期間の始まり（含む）と締め日の翌日0時（含まない）
    public var from: EpochMs
    public var to: EpochMs
    /// 締め日（その日の0時）
    public var closing: EpochMs
    public var payday: EpochMs
}

public enum PaySchedule {
    /// その月の d 日（0 = 月末。月の日数を超えたら月末）
    static func dayOfMonth(_ monthAnyDay: EpochMs, _ d: Int, time: DomainTime) -> EpochMs {
        let date = time.date(monthAnyDay)
        let comps = time.calendar.dateComponents([.year, .month], from: date)
        let first = time.calendar.date(from: comps)!
        let days = time.calendar.range(of: .day, in: .month, for: first)!.count
        let day = d <= 0 ? days : min(d, days)
        return time.ms(time.calendar.date(byAdding: .day, value: day - 1, to: first)!)
    }

    /// その日の勤務が入る締めの期間
    public static func period(containing t: EpochMs, profile p: PayProfile, time: DomainTime = .current) -> PayPeriod {
        let day = time.startOfDay(t)
        var closing = dayOfMonth(day, p.closingDay, time: time)
        if day > closing { closing = dayOfMonth(time.addMonths(dayOfMonth(day, 1, time: time), 1), p.closingDay, time: time) }
        let prevClosing = dayOfMonth(time.addMonths(dayOfMonth(closing, 1, time: time), -1), p.closingDay, time: time)
        let payMonth = time.addMonths(dayOfMonth(closing, 1, time: time), p.paydayMonthOffset)
        return PayPeriod(from: time.addDays(prevClosing, 1), to: time.addDays(closing, 1), closing: closing,
                         payday: dayOfMonth(payMonth, p.paydayDay, time: time))
    }

    /// now 以降で最初の支給日の期間（今日が支給日なら今日）
    public static func nextPayPeriod(after now: EpochMs, profile p: PayProfile, time: DomainTime = .current) -> PayPeriod {
        let today = time.startOfDay(now)
        // 支給は締めの数か月後なので、何か月か前の期間から順に探す
        var probe = time.addMonths(today, -(p.paydayMonthOffset + 1))
        for _ in 0..<(p.paydayMonthOffset + 4) {
            let per = period(containing: probe, profile: p, time: time)
            if per.payday >= today { return per }
            probe = per.to
        }
        return period(containing: today, profile: p, time: time)
    }
}

/// 給与明細などで確定した額（期間＝締め日で1件）
public struct ConfirmedPay: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(employerId)@\(closing)" }
    public var employerId: String
    public var closing: EpochMs
    public var amount: Int
    public var confirmedAt: EpochMs
    public init(employerId: String, closing: EpochMs, amount: Int, confirmedAt: EpochMs) { self.employerId = employerId; self.closing = closing; self.amount = amount; self.confirmedAt = confirmedAt }
}

/// 1回の勤務の見込みと実績
public struct ShiftLine: Equatable, Sendable, Identifiable {
    public var id: String
    public var employerId: String
    public var title: String
    public var start: EpochMs
    public var end: EpochMs
    public var planned: ShiftPayResult
    public var best: ShiftPayResult { planned }
}

public struct PayrollSummary: Equatable, Sendable {
    public var total: Int
    public var workMinutes: Int
    public var shifts: Int
}

public enum Payroll {
    /// 勤務先の勤務（予定）を計算する
    public static func lines(occurrences: [EventOccurrence], employers: [MTEmployer], time: DomainTime = .current) -> [ShiftLine] {
        let byId = Dictionary(uniqueKeysWithValues: employers.map { ($0.id, $0) })
        return occurrences.compactMap { o in
            guard let eid = o.event.employerId, let emp = byId[eid] else { return nil }
            let p = emp.pay
            let brk = o.event.extra?["spec"]?["details"]?["breakMinutes"]?.intValue.map(Int.init)
            guard let planned = PayCalculator.shift(start: o.start, end: o.end, profile: p, breakOverride: brk, time: time) else { return nil }
            return ShiftLine(id: o.id, employerId: eid, title: o.title, start: o.start, end: o.end, planned: planned)
        }
    }

    public static func summary(_ lines: [ShiftLine]) -> PayrollSummary {
        PayrollSummary(total: lines.reduce(0) { $0 + $1.best.total },
                              workMinutes: lines.reduce(0) { $0 + $1.best.workMinutes }, shifts: lines.count)
    }

    /// 期間の合計。月ごとの定額の交通費は、期間に勤務が1回でもあれば1回だけ足す
    public static func periodTotal(_ lines: [ShiftLine], profile: PayProfile) -> Int {
        let s = summary(lines).total
        return s + (profile.transportMode == .monthly && !lines.isEmpty ? profile.transportAmount : 0)
    }
}

// MARK: - MyMoney など外部へ渡すための形（いまは書き出しだけ。自動送信はしない）

public struct PayrollExport: Codable, Equatable, Sendable {
    public struct Employer: Codable, Equatable, Sendable {
        public var id: String; public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    public struct Shift: Codable, Equatable, Sendable {
        public var id: String; public var employerId: String; public var start: EpochMs; public var end: EpochMs
        public var workMinutes: Int; public var pay: Int; public var transport: Int
        public init(id: String, employerId: String, start: EpochMs, end: EpochMs, workMinutes: Int, pay: Int, transport: Int) {
            self.id = id; self.employerId = employerId; self.start = start; self.end = end; self.workMinutes = workMinutes; self.pay = pay; self.transport = transport
        }
    }
    public struct Period: Codable, Equatable, Sendable {
        public var employerId: String; public var closing: EpochMs; public var payday: EpochMs
        public var predicted: Int; public var confirmedAmount: Int?
        public init(employerId: String, closing: EpochMs, payday: EpochMs, predicted: Int, confirmedAmount: Int?) {
            self.employerId = employerId; self.closing = closing; self.payday = payday; self.predicted = predicted; self.confirmedAmount = confirmedAmount
        }
    }
    public var schema = "mytime.payroll.v1"
    public var exportedAt: EpochMs
    public var employers: [Employer]
    public var shifts: [Shift]
    public var periods: [Period]
    public init(exportedAt: EpochMs, employers: [Employer], shifts: [Shift], periods: [Period]) {
        self.exportedAt = exportedAt; self.employers = employers; self.shifts = shifts; self.periods = periods
    }
}
