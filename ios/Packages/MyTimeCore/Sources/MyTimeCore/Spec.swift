import Foundation

/// 専門の種類（S01〜S25）。Web 版 `packages/domain/src/spec.ts` と同じ ID・名前・レーン。
/// アイコンは iOS では SF Symbols（Apple の公式シンボル）を使う。
public enum SpecTypeId: String, CaseIterable, Sendable {
    case shift, shiftRequest, payday, `class`, assignment, exam, language, certification, report, presentation
    case groupWork, reading, shopping, appointment, outing, trip, transit, routine, chores, cooking
    case workout, project, paperwork, payment, leisure
    /// iOS 版で追加（S26 清掃・S27 朝）。Web 版は知らない種類を「種類なし」として扱う
    case cleaning, morning
    /// S28 持ち物チェック（出かける前に持ち物を1つずつ確認する）
    case belongings
}

public enum SpecGroup: String, CaseIterable, Sendable {
    case work, school, outing, life, money, `self`
    public var label: String {
        switch self {
        case .work: return "仕事"
        case .school: return "学校・勉強"
        case .outing: return "外出・移動"
        case .life: return "生活"
        case .money: return "お金・手続き"
        case .self: return "自分の時間"
        }
    }
}

public struct SpecDef: Sendable, Identifiable {
    public var id: SpecTypeId
    public var code: String
    public var name: String
    public var group: SpecGroup
    public var symbol: String
    public var color: String
    public var isEvent: Bool
    public var isCheck: Bool
    public var blurb: String
}

public let SPEC_DEFS: [SpecDef] = [
    .init(id: .shift, code: "S01", name: "勤務シフト", group: .work, symbol: "briefcase.fill", color: "#FF9F0A", isEvent: true, isCheck: false, blurb: "勤務時間と時給から給与見込みを出します"),
    .init(id: .shiftRequest, code: "S02", name: "シフト希望・提出", group: .work, symbol: "calendar.badge.clock", color: "#FF9F0A", isEvent: false, isCheck: true, blurb: "希望の勤務枠と出られない日をまとめます"),
    .init(id: .payday, code: "S03", name: "給与日・締め日", group: .money, symbol: "yensign.circle.fill", color: "#34C759", isEvent: true, isCheck: true, blurb: "締め日までの勤務から見込み額を出します"),
    .init(id: .class, code: "S04", name: "大学の授業", group: .school, symbol: "graduationcap.fill", color: "#5E5CE6", isEvent: true, isCheck: false, blurb: "曜日・時限・教室と小テストを登録します"),
    .init(id: .assignment, code: "S05", name: "大学の課題", group: .school, symbol: "doc.text.fill", color: "#FF375F", isEvent: false, isCheck: false, blurb: "締切・見積時間・進み具合をまとめます"),
    .init(id: .exam, code: "S06", name: "定期試験", group: .school, symbol: "target", color: "#FF453A", isEvent: false, isCheck: false, blurb: "試験日から逆算して学習計画を立てます"),
    .init(id: .language, code: "S07", name: "TOEIC・語学試験", group: .school, symbol: "character.bubble.fill", color: "#64D2FF", isEvent: false, isCheck: false, blurb: "目標点と本番の日から、分野を回す学習計画を立てます"),
    .init(id: .certification, code: "S08", name: "資格試験・検定", group: .school, symbol: "star.fill", color: "#BF5AF2", isEvent: false, isCheck: false, blurb: "受験日まで、残りの単元を割り振る学習計画を立てます"),
    .init(id: .report, code: "S09", name: "レポート・論文制作", group: .school, symbol: "books.vertical.fill", color: "#AC8E68", isEvent: false, isCheck: false, blurb: "調査から提出までを段階に分けて進めます"),
    .init(id: .presentation, code: "S10", name: "プレゼン・発表", group: .school, symbol: "lightbulb.fill", color: "#FF9F0A", isEvent: true, isCheck: false, blurb: "本番の予定と準備をつなげます"),
    .init(id: .groupWork, code: "S11", name: "グループ課題", group: .school, symbol: "person.3.fill", color: "#30B0C7", isEvent: false, isCheck: false, blurb: "自分の担当と待っている工程を分けます"),
    .init(id: .reading, code: "S12", name: "読書・教材消化", group: .school, symbol: "book.fill", color: "#A2845E", isEvent: false, isCheck: false, blurb: "残りのページを目標日まで割り振ります"),
    .init(id: .shopping, code: "S13", name: "買い物・日用品補充", group: .life, symbol: "cart.fill", color: "#34C759", isEvent: false, isCheck: false, blurb: "買う物の一覧と行く店をまとめます"),
    .init(id: .appointment, code: "S14", name: "通院・予約", group: .life, symbol: "heart.fill", color: "#FF2D55", isEvent: true, isCheck: false, blurb: "移動時間から出発の目安を出します"),
    .init(id: .outing, code: "S15", name: "デート・同行外出", group: .outing, symbol: "person.fill", color: "#FF375F", isEvent: true, isCheck: false, blurb: "集合時刻から身支度と移動を並べます"),
    .init(id: .trip, code: "S16", name: "旅行・出張", group: .outing, symbol: "airplane", color: "#0A84FF", isEvent: true, isCheck: false, blurb: "日別の行程と持ち物をつなげます"),
    .init(id: .transit, code: "S17", name: "移動・乗換", group: .outing, symbol: "tram.fill", color: "#8E8E93", isEvent: true, isCheck: false, blurb: "予定と予定の間に移動の時間を確保します"),
    .init(id: .routine, code: "S18", name: "朝・帰宅・就寝ルーティン", group: .life, symbol: "sun.max.fill", color: "#FFD60A", isEvent: false, isCheck: false, blurb: "工程から始める時刻と終わる見込みを出します"),
    .init(id: .chores, code: "S19", name: "掃除・家事", group: .life, symbol: "sparkles", color: "#30D158", isEvent: false, isCheck: false, blurb: "頻度と目安の時間で次の回を置きます"),
    .init(id: .cooking, code: "S20", name: "料理・食事準備", group: .life, symbol: "frying.pan.fill", color: "#FF9F0A", isEvent: false, isCheck: false, blurb: "足りない材料だけを買い物に回します"),
    .init(id: .workout, code: "S21", name: "運動・トレーニング", group: .self, symbol: "figure.run", color: "#32ADE6", isEvent: false, isCheck: false, blurb: "週の回数と前回の日を示します"),
    .init(id: .project, code: "S22", name: "個人開発・制作", group: .self, symbol: "laptopcomputer", color: "#5E5CE6", isEvent: false, isCheck: false, blurb: "調査・実装・テスト・公開を分けます"),
    .init(id: .paperwork, code: "S23", name: "申請・提出・行政手続", group: .money, symbol: "doc.on.clipboard.fill", color: "#8E8E93", isEvent: false, isCheck: false, blurb: "期限と窓口の受付時間を分けて示します"),
    .init(id: .payment, code: "S24", name: "支払い・口座確認", group: .money, symbol: "creditcard.fill", color: "#34C759", isEvent: false, isCheck: true, blurb: "支払ったことは自分で記録します"),
    .init(id: .leisure, code: "S25", name: "自由時間・趣味・休息", group: .self, symbol: "music.note", color: "#BF5AF2", isEvent: false, isCheck: false, blurb: "空いた時間に候補を出すだけです"),
    .init(id: .cleaning, code: "S26", name: "清掃", group: .life, symbol: "bubbles.and.sparkles.fill", color: "#30B0C7", isEvent: false, isCheck: false, blurb: "場所を選び、箇所ごとに Yes・No・対象外を記録します"),
    .init(id: .morning, code: "S27", name: "朝", group: .life, symbol: "sunrise.fill", color: "#FF9F0A", isEvent: false, isCheck: false, blurb: "起床アラームと身支度の工程を順に案内します"),
    .init(id: .belongings, code: "S28", name: "持ち物チェック", group: .life, symbol: "bag.fill", color: "#5E5CE6", isEvent: false, isCheck: false, blurb: "出かける前に、持ち物を1つずつ確認します"),
]

/// 種類を選ぶ画面に出すもの（読書と「朝・帰宅・就寝ルーティン」は廃止。朝は S27「朝」に一本化。既存のデータは読めるように定義は残す）
public let SPEC_PICKABLE: [SpecDef] = SPEC_DEFS.filter { $0.id != .reading && $0.id != .routine }

/// 試験系（学習計画を立てる）
public extension SpecTypeId { var isExamLike: Bool { self == .exam || self == .language || self == .certification } }

public let SPEC_BY_ID: [SpecTypeId: SpecDef] = Dictionary(uniqueKeysWithValues: SPEC_DEFS.map { ($0.id, $0) })

/// S01：時給×実働（休憩を除く）。税引前・交通費別。時給がなければ nil
public func shiftPay(start: EpochMs, end: EpochMs, hourlyWage: Double?, breakMinutes: Int = 0) -> (pay: Int, workMinutes: Int)? {
    guard let w = hourlyWage, w >= 0, end > start else { return nil }
    let work = max(0, Int((end - start) / MINUTE) - max(0, breakMinutes))
    return (Int((w * Double(work) / 60).rounded()), work)
}

/// S05：見積と実績から残り時間。実績がなければ見積そのもの（暫定）
public func remainingWork(_ t: MTTask, now: EpochMs) -> (remaining: Int, worked: Int, provisional: Bool)? {
    guard let est = t.estimateMinutes else { return nil }
    let worked = Int((Double(workedMs(t, at: now)) / Double(MINUTE)).rounded())
    return (max(0, est - worked), worked, worked == 0)
}

public func yen(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "ja_JP")
    return "\(f.string(from: NSNumber(value: n)) ?? "\(n)")円"
}
