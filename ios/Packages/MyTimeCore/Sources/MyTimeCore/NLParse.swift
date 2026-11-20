import Foundation

// Web 版 nlparse.ts の移植：文章からの入力（端末内の規則で解釈する。外部の AI には送らない）。
// - 「明日は課題2つと買い物」のような文章から、予定・タスクの候補を複数作る。保存前に一画面で確認する。
// - 「夕方」「授業後」のような曖昧な時刻は候補とし、推定の根拠を必ず付ける（timeCertain = false）。
// - 「来週のバイト」は検索、「〜を1時間遅らせて」は変更、「今日の課題を移して」は再計画として扱う。
// 解釈できない部分は捨てずにタイトルに残す。

public struct ParseContext {
    public var now: EpochMs
    public var events: [EventOccurrence]
    public var tasks: [MTTask]
    public var subtasks: [MTSubtask]
    public var employers: [MTEmployer]
    public var opts: PlanOptions
    public var time: DomainTime
    public init(now: EpochMs, events: [EventOccurrence] = [], tasks: [MTTask] = [], subtasks: [MTSubtask] = [], employers: [MTEmployer] = [], opts: PlanOptions = .default, time: DomainTime = .current) {
        self.now = now; self.events = events; self.tasks = tasks; self.subtasks = subtasks; self.employers = employers; self.opts = opts; self.time = time
    }
}

public struct CandidateChild: Sendable, Equatable {
    public var title: String
    public var start: EpochMs
    public var end: EpochMs
}

public struct Candidate: Sendable, Equatable, Identifiable {
    public enum Entity: String, Sendable { case event, task }
    public var id: String
    public var entity: Entity
    public var spec: SpecTypeId?
    public var title: String
    public var start: EpochMs?
    public var end: EpochMs?
    /// 締切（「金曜までに」など）
    public var due: EpochMs?
    public var estimateMinutes: Int?
    /// 文章に時刻がはっきり書かれていたか。false は「候補」
    public var timeCertain: Bool
    /// どう読んだか（画面に出す根拠）
    public var reasons: [String]
    public var details: [String: JSONValue]
    public var allDay: Bool
    /// 予定の前に置く準備
    public var prep: [CandidateChild]
    /// 締切までの作業枠
    public var sessions: [CandidateChild]
    public var workplace: String?
    public var employerId: String?
}

public struct SearchQuery: Sendable, Equatable {
    public var from: EpochMs?
    public var to: EpochMs?
    public var words: [String]
    public var spec: SpecTypeId?
    public var label: String
    public var before: String?
}

public enum ParseResult: Sendable, Equatable {
    case create(candidates: [Candidate], notes: [String])
    case search(SearchQuery)
    case shift(target: SearchQuery, deltaMin: Int)
    case move(target: SearchQuery, toDay: EpochMs)
    case replan(day: EpochMs, spec: SpecTypeId?)
}

// MARK: - 文字の正規化

public func normalizeText(_ s: String) -> String {
    var out = ""
    for u in s.unicodeScalars {
        let v = u.value
        if (0xFF10...0xFF19).contains(v) || (0xFF21...0xFF3A).contains(v) || (0xFF41...0xFF5A).contains(v) { out.unicodeScalars.append(Unicode.Scalar(v - 0xFEE0)!) }
        else if u == "：" { out += ":" } else if u == "／" { out += "/" } else if u == "\u{3000}" { out += " " } else if u == "？" { out += "?" }
        else { out.unicodeScalars.append(u) }
    }
    out = Rx("(\\d)\\s*[~～〜－ー−-]\\s*(?=\\d|午)").replaceAll(out, "$1〜")
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

private let KANJI_NUM: [String: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10]
private let WD = Array("日月火水木金土").map(String.init)

private func ymd(_ y: Int, _ m: Int, _ d: Int, _ time: DomainTime) -> EpochMs {
    time.startOfDay(time.ms(time.calendar.date(from: DateComponents(year: y, month: m, day: d))!))
}

// MARK: - 日付

struct DateHit { var day: EpochMs; var label: String; var deadline: Bool; var rest: String }

func takeDate(_ s: String, now: EpochMs, time: DomainTime) -> DateHit? {
    let today = time.startOfDay(now)
    let c = time.calendar.dateComponents([.year, .month], from: time.date(today))
    let year = c.year!, month = c.month!
    let wd = time.weekday(today)
    let tries: [(Rx, (RxMatch) -> (EpochMs, String)?)] = [
        (Rx("(\\d{1,2})月(\\d{1,2})日"), { m in
            guard let mo = Int(m[1]!), let d = Int(m[2]!), (1...12).contains(mo), (1...31).contains(d) else { return nil }
            var t = ymd(year, mo, d, time)
            if t < time.addDays(today, -60) { t = ymd(year + 1, mo, d, time) }
            return (t, m.whole)
        }),
        (Rx("(?<![\\d:])(\\d{1,2})/(\\d{1,2})(?![\\d:])"), { m in
            guard let mo = Int(m[1]!), let d = Int(m[2]!), (1...12).contains(mo), (1...31).contains(d) else { return nil }
            var t = ymd(year, mo, d, time)
            if t < time.addDays(today, -60) { t = ymd(year + 1, mo, d, time) }
            return (t, m.whole)
        }),
        (Rx("(明後日|あさって)"), { m in (time.addDays(today, 2), m.whole) }),
        (Rx("(明日|あした|あす)"), { m in (time.addDays(today, 1), m.whole) }),
        (Rx("(今日|きょう|本日|今夜|今晩)"), { m in (today, m.whole) }),
        (Rx("(再来週|来週|今週)?の?([日月火水木金土])曜日?"), { m in
            let w = WD.firstIndex(of: m[2]!)!
            let ws = time.addDays(today, -wd)
            switch m[1] {
            case "今週": return (time.addDays(ws, w), m.whole)
            case "来週": return (time.addDays(ws, 7 + w), m.whole)
            case "再来週": return (time.addDays(ws, 14 + w), m.whole)
            default: return (time.addDays(today, (w - wd + 7) % 7), m.whole)
            }
        }),
        (Rx("週末"), { m in (time.addDays(today, (6 - wd + 7) % 7), m.whole) }),
        (Rx("(?<![\\d月/])(\\d{1,2})日(?=に|まで|は|の|\\s|$|、)"), { m in
            guard let d = Int(m[1]!), (1...31).contains(d) else { return nil }
            var t = ymd(year, month, d, time)
            if t < today { t = ymd(month == 12 ? year + 1 : year, month == 12 ? 1 : month + 1, d, time) }
            return (t, m.whole)
        }),
    ]
    for (re, f) in tries {
        guard let m = re.match(s), let r = f(m) else { continue }
        let after = m.after
        let deadline = Rx("^\\s*(まで|迄|締切|締め切り|〆切|期限)").test(after)
        let rest = Rx("^\\s*(は|に|の|、)").replaceAll(m.before + Rx("^\\s*(までに|まで|迄に|迄|締切|締め切り|〆切|期限)").replaceAll(after, ""), "")
        return DateHit(day: r.0, label: r.1, deadline: deadline, rest: rest)
    }
    return nil
}

// MARK: - 時刻

struct TimeHit { var startMin: Int; var endMin: Int?; var certain: Bool; var reason: String?; var rest: String }

private let HM = "(午前|午後|朝|夜|夕方)?\\s*(\\d{1,2})(?::(\\d{2})|時(?:(\\d{1,2})分|(半))?)(?!間)"

private func toMin(_ ampm: String?, _ h: String, _ m1: String?, _ m2: String?, _ half: String?) -> (min: Int, guessed: Bool) {
    var hour = Int(h) ?? 0
    var guessed = false
    if (ampm == "午後" || ampm == "夜" || ampm == "夕方") && hour < 12 { hour += 12 }
    else if ampm == nil && (1...6).contains(hour) { hour += 12; guessed = true }
    let minute = m1.flatMap(Int.init) ?? m2.flatMap(Int.init) ?? (half != nil ? 30 : 0)
    return (min(24 * 60, hour * 60 + minute), guessed)
}

func takeTimes(_ s: String) -> TimeHit? {
    if let m = Rx("\(HM)\\s*(?:〜|から|より)\\s*\(HM)(?:まで)?").match(s) {
        let a = toMin(m[1], m[2]!, m[3], m[4], m[5])
        let b = toMin(m[6] ?? (a.min >= 12 * 60 && (Int(m[7]!) ?? 0) < 12 ? "午後" : nil), m[7]!, m[8], m[9], m[10])
        var end = b.min
        if end <= a.min { end += 24 * 60 }
        return TimeHit(startMin: a.min, endMin: end, certain: !a.guessed, reason: a.guessed ? "「\(m[2]!)時」を\(a.min / 60):00と読みました" : nil, rest: m.replacing(with: " "))
    }
    if let m = Rx("\(HM)\\s*(に|から|〜|頃|ごろ|開始|集合)?").match(s) {
        let a = toMin(m[1], m[2]!, m[3], m[4], m[5])
        let approx = Rx("頃|ごろ").test(m[6] ?? "")
        return TimeHit(startMin: a.min, endMin: nil, certain: !a.guessed && !approx,
                       reason: a.guessed ? "「\(m[2]!)時」を\(a.min / 60):00と読みました" : approx ? "「頃」とあるため目安の時刻です" : nil, rest: m.replacing(with: " "))
    }
    return nil
}

/// 曖昧な時間帯
private let VAGUE: [(Rx, Double, Double, String)] = [
    (Rx("午前中"), 9, 12, "午前中"),
    (Rx("(お昼|昼休み|昼)"), 12, 13.5, "お昼"),
    (Rx("朝(?!食)"), 7, 9, "朝"),
    (Rx("午後"), 13, 17, "午後"),
    (Rx("夕方"), 17, 19, "夕方"),
    (Rx("(寝る前|就寝前)"), 22, 23.5, "寝る前"),
    (Rx("(今夜|今晩|夜)"), 19, 22, "夜"),
]

struct VagueHit { var from: EpochMs; var to: EpochMs; var label: String; var rest: String }

private func takeVague(_ s: String, day: EpochMs, ctx: ParseContext) -> VagueHit? {
    let time = ctx.time
    if let a = Rx("(授業|講義|バイト|勤務|仕事)(の)?(後|あと|終わり)|放課後").match(s) {
        let spec: SpecTypeId = Rx("授業|講義|放課後").test(a.whole) ? .class : .shift
        let d1 = time.addDays(day, 1)
        let ref = ctx.events.filter { $0.start >= day && $0.start < d1 && $0.event.specType == spec }.max { $0.end < $1.end }
        if let ref {
            return VagueHit(from: ref.end + EpochMs(ref.event.travelMinutes ?? 0) * MINUTE, to: min(ref.end + 4 * HOUR, day + 23 * HOUR),
                            label: "「\(a.whole)」を「\(ref.title)」の終わり（\(time.hm(ref.end))）以降", rest: a.replacing(with: " "))
        }
        return VagueHit(from: day + 17 * HOUR, to: day + 21 * HOUR, label: "「\(a.whole)」に当たる予定が見つからないため17:00以降", rest: a.replacing(with: " "))
    }
    for (re, a, b, label) in VAGUE {
        if let m = re.match(s) {
            let from = day + EpochMs(a * Double(HOUR)), to = day + EpochMs(b * Double(HOUR))
            return VagueHit(from: from, to: to, label: "「\(label)」を\(time.hm(from))〜\(time.hm(to))", rest: m.replacing(with: " "))
        }
    }
    return nil
}

// MARK: - 時間の長さ・お金

private func takeDuration(_ s: String) -> (minutes: Int, rest: String)? {
    if let m = Rx("(\\d+(?:\\.\\d+)?)\\s*時間(半)?\\s*(ぐらい|くらい|程度|ほど|位)?").match(s) {
        // 長すぎる数（入力の誤り）で落ちないように、最大7日分までに抑える
        let h = min(Double(m[1]!) ?? 0, 24 * 7)
        return (Int((h * 60).rounded()) + (m[2] != nil ? 30 : 0), m.replacing(with: " "))
    }
    if let m = Rx("([一二三四五六七八九十])\\s*時間(半)?").match(s) { return ((KANJI_NUM[m[1]!] ?? 1) * 60 + (m[2] != nil ? 30 : 0), m.replacing(with: " ")) }
    if let m = Rx("(?<!休憩)(?<!休憩\\s)(\\d+)\\s*分\\s*(ぐらい|くらい|程度|ほど|間)?(?!から)").match(s) { return (min(Int(m[1]!) ?? 0, 24 * 7 * 60), m.replacing(with: " ")) }
    if let m = Rx("半日").match(s) { return (240, m.replacing(with: " ")) }
    return nil
}

struct Money: Equatable { var wage: Int?; var transport: Int?; var breakMin: Int?; var amount: Int?
    var isEmpty: Bool { wage == nil && transport == nil && breakMin == nil && amount == nil }
}

private func takeMoney(_ s: String) -> (money: Money, rest: String) {
    var money = Money()
    var rest = s
    let yen = { (x: String) in Int(x.replacingOccurrences(of: ",", with: "")) }
    if let m = Rx("時給\\s*([\\d,]+)\\s*円?").match(rest) { money.wage = yen(m[1]!); rest = m.replacing(with: " ") }
    if let m = Rx("交通費\\s*([\\d,]+)\\s*円?").match(rest) { money.transport = yen(m[1]!); rest = m.replacing(with: " ") }
    if let m = Rx("休憩\\s*(\\d+)\\s*分").match(rest) { money.breakMin = Int(m[1]!); rest = m.replacing(with: " ") }
    if let m = Rx("休憩\\s*(なし|無し|0)").match(rest) { money.breakMin = 0; rest = m.replacing(with: " ") }
    if let m = Rx("([\\d,]{2,})\\s*円").match(rest) { money.amount = yen(m[1]!); rest = m.replacing(with: " ") }
    return (money, rest)
}

// MARK: - タイトルの整形

private let TRAIL = Rx("(を?したい|を?やりたい|したく|をやる|をする|やる|する|します|しなきゃ|しないと|に行く|へ行く|に行きたい|行く|行きたい|予定|ぐらい|くらい|程度|頃|ごろ|かかる|かかりそう|を?入れて|を?追加して|を?追加|がある|ある|です|。|、|\\s)+$")

public func cleanTitle(_ s: String) -> String {
    var t = Rx("\\s+").replaceAll(s, " ").trimmingCharacters(in: .whitespaces)
    for _ in 0..<4 {
        t = Rx("^[はをにでのもと、・\\s]+").replaceAll(t, "")
        t = TRAIL.replaceAll(t, "")
        t = Rx("[はをにでのがもと]$").replaceAll(t, "").trimmingCharacters(in: .whitespaces)
    }
    return t
}

private func defaultTitle(_ spec: SpecTypeId?, _ workplace: String?) -> String {
    switch spec {
    case .shift: return workplace.map { "\($0) 勤務" } ?? "勤務"
    case .outing: return "外出"
    case .shopping: return "買い物"
    case .assignment: return "課題"
    case .chores: return "家事"
    case let s?: return SPEC_BY_ID[s]!.name
    case nil: return "新しい予定"
    }
}

// MARK: - 分割

public func splitItems(_ text: String) -> [String] {
    let marked = Rx("(?<!\\d),(?!\\d)|[\\n。、，;；]+").replaceAll(text, "\u{1F}")
    let parts = marked.components(separatedBy: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    var out: [String] = []
    let count = Rx("\\d+\\s*(つ|個|件)")
    for p in parts {
        let pieces = p.components(separatedBy: "と")
        if pieces.count > 1 && pieces.allSatisfy({ !$0.trimmingCharacters(in: .whitespaces).isEmpty && (detectSpec($0) != nil || count.test($0)) }) {
            out += pieces.map { $0.trimmingCharacters(in: .whitespaces) }
        } else { out.append(p) }
    }
    return out
}

// MARK: - 意図

private func querySpecAndWords(_ s: String) -> (spec: SpecTypeId?, words: [String], before: String?) {
    let bm = Rx("([^\\sのを]+?)(の)?前の").match(s)
    let before = bm?[1]
    let stripped = Rx("^(の|は)").replaceAll(bm?.replacing(with: "") ?? s, "")
    let parts = stripped.components(separatedBy: "の").map(cleanTitle).filter { !$0.isEmpty }
    let head = parts.last ?? ""
    let spec = detectSpec(head)
    return (spec, spec != nil ? [] : head.isEmpty ? [] : [head], before)
}

private func rangeFor(_ s: String, now: EpochMs, time: DomainTime) -> (from: EpochMs?, to: EpochMs?, label: String, rest: String) {
    let today = time.startOfDay(now)
    let ws = time.addDays(today, -time.weekday(today))
    if s.contains("来週") && !Rx("来週の?[日月火水木金土]曜").test(s) { return (time.addDays(ws, 7), time.addDays(ws, 14), "来週", s.replacingOccurrences(of: "来週", with: "")) }
    if s.contains("今週") && !Rx("今週の?[日月火水木金土]曜").test(s) { return (today, time.addDays(ws, 7), "今週", s.replacingOccurrences(of: "今週", with: "")) }
    if s.contains("今月") {
        let c = time.calendar.dateComponents([.year, .month], from: time.date(today))
        return (today, ymd(c.month == 12 ? c.year! + 1 : c.year!, c.month == 12 ? 1 : c.month! + 1, 1, time), "今月", s.replacingOccurrences(of: "今月", with: ""))
    }
    if let d = takeDate(s, now: now, time: time) { return (d.day, time.addDays(d.day, 1), d.label, d.rest) }
    return (nil, nil, "", s)
}

private func query(_ r: (from: EpochMs?, to: EpochMs?, label: String, rest: String), label: String) -> SearchQuery {
    let q = querySpecAndWords(r.rest)
    return SearchQuery(from: r.from, to: r.to, words: q.words, spec: q.spec, label: label, before: q.before)
}

public func parseInput(_ raw: String, ctx: ParseContext) -> ParseResult {
    let text = normalizeText(raw)
    let now = ctx.now, time = ctx.time
    // 変更：〜を1時間遅らせて / 30分早めて
    if let m = Rx("^(.+?)を\\s*(\\d+(?:\\.\\d+)?|[一二三四五])\\s*(時間|分)(半)?\\s*(遅ら|後ろ|後に|ずら|早め|前に|繰り上)").match(text) {
        let n = Double(m[2]!) ?? Double(KANJI_NUM[m[2]!] ?? 1)
        let minutes = Int(m[3] == "時間" ? n * 60 : n) + (m[4] != nil ? 30 : 0)
        let sign = Rx("早め|前に|繰り上").test(m[5]!) ? -1 : 1
        return .shift(target: query(rangeFor(m[1]!, now: now, time: time), label: m[1]!), deltaMin: sign * minutes)
    }
    // 移動：〜を明日に移して
    if let m = Rx("^(.+?)を\\s*(.+?)に\\s*(移|変更|回|ずら|動か)").match(text), let to = takeDate(m[2]!, now: now, time: time) {
        return .move(target: query(rangeFor(m[1]!, now: now, time: time), label: m[1]!), toDay: to.day)
    }
    // 再計画
    if Rx("(急用|予定が変わ|組み直|やり直|再計画|立て直|移して|ずらして|回して|組み替え)").test(text) {
        let r = rangeFor(text, now: now, time: time)
        return .replan(day: r.from ?? time.startOfDay(now), spec: detectSpec(Rx("(急用|予定が変わ\\S*)").replaceAll(text, "")))
    }
    // 検索
    let isQuestion = Rx("(\\?|いつ|探して|見せて|教えて|ある\\?|は\\?$)").test(text)
    let shortRef = Rx("^(今日|明日|明後日|今週|来週|今月|[日月火水木金土]曜日?|\\d{1,2}月\\d{1,2}日|\\d{1,2}/\\d{1,2})の[^\\d:時分]+$").test(text) && !Rx("(したい|やる|する|行く|入れ|追加|まで)").test(text)
    if isQuestion || shortRef {
        let cleaned = Rx("(\\?|はいつ|いつ|を?探して|を?見せて|を?教えて|ある|は$)").replaceAll(text, "")
        return .search(query(rangeFor(cleaned, now: now, time: time), label: text))
    }
    let c = createCandidates(text, ctx: ctx)
    return .create(candidates: c.candidates, notes: c.notes)
}

// MARK: - 作成の候補

private struct RawItem {
    var text: String; var day: EpochMs?; var dayLabel: String?; var ownDate: Bool; var deadline: Bool
    var time: TimeHit?; var vague: VagueHit?; var duration: Int?; var money: Money; var spec: SpecTypeId?; var title: String; var count: Int
}

private func createCandidates(_ text: String, ctx: ParseContext) -> (candidates: [Candidate], notes: [String]) {
    let now = ctx.now, time = ctx.time, opts = ctx.opts
    var notes: [String] = []
    var out: [Candidate] = []
    var sharedDay: (day: EpochMs, label: String)?
    var busy = busyItems(events: ctx.events, tasks: ctx.tasks, subtasks: ctx.subtasks).slots

    var raws: [RawItem] = []
    for seg in splitItems(text) {
        var rest = seg
        let d = takeDate(rest, now: now, time: time)
        if let d { rest = d.rest; if sharedDay == nil { sharedDay = (d.day, d.label) } }
        let money = takeMoney(rest); rest = money.rest
        let tm = takeTimes(rest); if let tm { rest = tm.rest }
        let dur = takeDuration(rest); if let dur { rest = dur.rest }
        let day = d?.day ?? sharedDay?.day
        let vague = tm != nil ? nil : takeVague(rest, day: day ?? time.startOfDay(now), ctx: ctx)
        if let vague { rest = vague.rest }
        var spec = detectSpec(seg)
        var count = 1
        if let qm = Rx("(\\d+|[一二三四五六七八九])\\s*(つ|個|件|コ)").match(rest) {
            count = min(9, Int(qm[1]!) ?? KANJI_NUM[qm[1]!] ?? 1)
            rest = qm.replacing(with: " ")
        }
        if money.money.wage != nil { spec = .shift }
        raws.append(RawItem(text: seg, day: day, dayLabel: d?.label ?? (d == nil ? sharedDay?.label : nil), ownDate: d != nil, deadline: d?.deadline ?? false,
                            time: tm, vague: vague, duration: dur?.minutes, money: money.money, spec: spec, title: cleanTitle(rest), count: count))
    }
    // 属性だけの断片（「時給1,300円」「2時間ぐらい」）は直前の項目に足す
    var merged: [RawItem] = []
    for r in raws {
        let onlyAttr = r.title.isEmpty && r.spec == nil && !r.ownDate && (r.duration != nil || !r.money.isEmpty || r.time != nil)
        if var prev = merged.last, onlyAttr || (r.title.isEmpty && r.money.wage != nil && r.time == nil && !r.ownDate) {
            prev.duration = prev.duration ?? r.duration
            prev.money = Money(wage: r.money.wage ?? prev.money.wage, transport: r.money.transport ?? prev.money.transport, breakMin: r.money.breakMin ?? prev.money.breakMin, amount: r.money.amount ?? prev.money.amount)
            prev.time = prev.time ?? r.time
            if r.money.wage != nil { prev.spec = .shift }
            merged[merged.count - 1] = prev
            continue
        }
        merged.append(r)
    }

    for r in merged {
        var spec = r.spec
        if spec == .assignment && r.text.contains("レポート") && (r.duration ?? 0) >= 240 { spec = .report }
        let def = spec.flatMap { SPEC_BY_ID[$0] }
        let hasTime = r.time != nil || r.vague != nil
        var entity: Candidate.Entity = def.map { $0.isEvent ? .event : .task } ?? (hasTime && !Rx("(したい|やる|する|作業|勉強)").test(r.text) ? .event : .task)
        if def?.isEvent == true && !hasTime && r.day == nil { entity = .task }
        var workplace: String?
        var employerId: String?
        var title = r.title
        if spec == .shift {
            let wp = cleanTitle(SPEC_BY_ID[.shift]!.keywords.replaceAll(title, " "))
            if !wp.isEmpty {
                workplace = wp
                if let hit = ctx.employers.first(where: { $0.name.lowercased() == wp.lowercased() }) { employerId = hit.id; workplace = hit.name }
            }
            title = defaultTitle(.shift, workplace)
        }
        if let spec, spec != .shift, cleanTitle(SPEC_BY_ID[spec]!.keywords.replaceAll(title, " ")).count <= 1 { title = "" }
        for i in 0..<r.count {
            var reasons: [String] = []
            let base = title.isEmpty ? defaultTitle(spec, workplace) : title
            let t = r.count > 1 ? "\(base)\(i + 1)" : base
            var details: [String: JSONValue] = [:]
            if spec == .shift {
                if let workplace { details["workplace"] = workplace.json }
                if let w = r.money.wage { details["hourlyWage"] = .number(Double(w)) }
                details["breakMinutes"] = .number(Double(r.money.breakMin ?? 0))
                if let tr = r.money.transport { details["transportFee"] = .number(Double(tr)) }
            }
            if spec == .payment, let a = r.money.amount { details["amount"] = .number(Double(a)) }
            var start: EpochMs?, end: EpochMs?, due: EpochMs?
            var certain = false
            var allDay = false
            let day = r.day ?? (hasTime ? time.startOfDay(now) : nil)
            if r.deadline, let d = r.day { due = d + 23 * HOUR + 59 * MINUTE; reasons.append("締切を\(r.dayLabel ?? "")の23:59としました") }
            let length = r.duration ?? (entity == .event ? 60 : 30)
            if let tm = r.time, let day {
                start = day + EpochMs(tm.startMin) * MINUTE
                end = tm.endMin.map { day + EpochMs($0) * MINUTE } ?? start! + EpochMs(length) * MINUTE
                certain = tm.certain
                if let reason = tm.reason { reasons.append(reason) }
                if tm.endMin == nil { reasons.append(r.duration != nil ? "長さ\(r.duration!)分" : "終わりの時刻がないため、仮に\(length)分としました") }
            } else if let v = r.vague {
                let slot = findSlots(minutes: length, busy: busy, from: max(now, v.from), until: v.to, opts: opts, time: time).first
                start = slot?.start ?? max(v.from, now)
                end = start! + EpochMs(length) * MINUTE
                reasons.append("\(v.label)として、" + (slot != nil ? "空いている\(time.hm(start!))を仮に選びました" : "\(time.hm(start!))を仮に選びました（空きがありません）"))
            } else if entity == .task, let d = r.day, !r.deadline {
                if let slot = findSlots(minutes: length, busy: busy, from: max(now, d), until: time.addDays(d, 1), opts: opts, time: time).first {
                    start = slot.start; end = slot.end
                    reasons.append("時刻が書かれていないため、\(r.dayLabel ?? "その日")の空き時間\(time.hm(slot.start))〜を候補にしました")
                } else {
                    due = d + 23 * HOUR + 59 * MINUTE
                    reasons.append("\(r.dayLabel ?? "その日")に空きがないため、時刻を決めずに置きます")
                }
            } else if entity == .event, let d = r.day {
                start = d; end = time.addDays(d, 1); allDay = true
                reasons.append("時刻がないため、終日の予定にします")
            }
            if let def { reasons.insert("種類：\(def.name)（\(def.code)）", at: 0) }
            var cand = Candidate(id: "c\(out.count)", entity: entity, spec: spec, title: t, start: start, end: end, due: due, estimateMinutes: r.duration, timeCertain: certain,
                                 reasons: reasons, details: details, allDay: allDay, prep: [], sessions: [], workplace: workplace, employerId: employerId)
            // 予定の前の準備
            if entity == .event, let def, let s = start, !allDay {
                let before = def.prep.filter { $0.place == .before }
                if !before.isEmpty {
                    cand.prep = prepBefore(eventStart: s, travelMinutes: nil, items: before.map { ($0.title, spec == .outing && $0.title == "髪・身支度" ? 30 : $0.minutes) })
                        .map { CandidateChild(title: $0.title, start: $0.start, end: $0.end) }
                    cand.reasons.append("準備の時間は目安です。移動時間は分からないため含めていません")
                }
            }
            // 締切つきで時間のかかるタスク：締切までの空きに作業枠を置く
            if entity == .task, let due, let dur = r.duration, start == nil {
                let per = min(60, dur)
                let n = max(1, Int(ceil(Double(dur) / Double(per))))
                let slots = findSlots(minutes: Int(ceil(Double(dur) / Double(n) / 15)) * 15, busy: busy, from: now, until: due, count: n, opts: opts, time: time)
                let names = sessionNames(n)
                cand.sessions = slots.enumerated().map { CandidateChild(title: names[safe: $0.offset] ?? "作業\($0.offset + 1)", start: $0.element.start, end: $0.element.end) }
                if slots.isEmpty { cand.reasons.append("締切までに空きが見つかりません") }
                else { cand.reasons.append("締切までの空きに\(slots.count)回の作業枠を候補にしました（締切は動かしません）"); busy += slots }
            }
            if let s = start, let e = end, !allDay { busy.append(TimeSlot(start: s, end: e)) }
            out.append(cand)
        }
    }
    if out.isEmpty { notes.append("予定やタスクとして読み取れませんでした。「明日18時から勤務」「金曜までに課題 2時間」のように書いてください") }
    return (out, notes)
}

// MARK: - 検索

public struct SearchHit: Sendable, Equatable, Identifiable {
    public enum Entity: String, Sendable { case event, task }
    public var entity: Entity
    public var id: String
    public var title: String
    public var at: EpochMs?
    public var spec: SpecTypeId?
}

public func searchItems(_ q: SearchQuery, events: [EventOccurrence], tasks: [MTTask]) -> [SearchHit] {
    let words = q.words.map { $0.lowercased() }
    let okWords = { (title: String) in words.isEmpty || words.contains { title.lowercased().contains($0) } }
    let ranged = q.from != nil || q.to != nil
    var hits: [SearchHit] = []
    for e in events {
        let s = e.event.specType
        if let qs = q.spec, s != qs { continue }
        if !okWords(e.title) { continue }
        if ranged && !(e.start < (q.to ?? .max) && e.end > (q.from ?? .min)) { continue }
        hits.append(SearchHit(entity: .event, id: e.id, title: e.title, at: e.start, spec: s))
    }
    for t in tasks {
        let s = t.specType
        if let qs = q.spec, s != qs { continue }
        if !okWords(t.title) { continue }
        let at = t.plannedStart ?? t.checkAt ?? t.deadline
        if ranged {
            guard let at, at >= (q.from ?? .min), at < (q.to ?? .max) else { continue }
        }
        hits.append(SearchHit(entity: .task, id: t.id, title: t.title, at: at, spec: s))
    }
    var out = hits.sorted { ($0.at ?? .max) < ($1.at ?? .max) }
    if let before = q.before {
        let bs = detectSpec(before)
        if let ref = events.first(where: { (bs != nil ? $0.event.specType == bs : $0.title.contains(before)) && (q.from == nil || $0.start >= q.from!) && (q.to == nil || $0.start < q.to!) }) {
            out = out.filter { $0.id != ref.id && $0.at != nil && $0.at! < ref.start }
        }
    }
    return out
}
