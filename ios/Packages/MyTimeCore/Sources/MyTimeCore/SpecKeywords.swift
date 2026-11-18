import Foundation

// Web 版 spec.ts の keywords（文章からの種類の判定）と prep（予定の前の準備）

/// 正規表現の小さな道具（NSRegularExpression。ICU なので後読み・先読みも使える）
public struct Rx: @unchecked Sendable {
    public let re: NSRegularExpression
    public init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }
    public func test(_ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// 最初の一致。groups[0] は全体、無い組は nil
    public func match(_ s: String) -> RxMatch? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        var g: [String?] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            g.append(r.location == NSNotFound ? nil : Range(r, in: s).map { String(s[$0]) })
        }
        let whole = Range(m.range, in: s)!
        return RxMatch(groups: g, range: whole, source: s)
    }
    public func replaceAll(_ s: String, _ template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

public struct RxMatch {
    public var groups: [String?]
    public var range: Range<String.Index>
    public var source: String
    public subscript(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
    public var whole: String { groups[0] ?? "" }
    public var before: String { String(source[..<range.lowerBound]) }
    public var after: String { String(source[range.upperBound...]) }
    /// 一致した部分を置き換えた文字列（JS の s.replace(m[0], x) と同じく最初の1か所）
    public func replacing(with x: String) -> String { before + x + after }
}

public struct PrepItem: Sendable, Equatable {
    public enum Place: String, Sendable { case before, inbox }
    public var title: String
    public var minutes: Int
    public var place: Place
}

public extension SpecDef {
    var keywords: Rx { SPEC_KEYWORDS[id]! }
    var prep: [PrepItem] { SPEC_PREP[id] ?? [] }
    /// 種類の既定のタスクの種類（確認タスクか）
    var taskKind: TaskKind { isCheck && !isEvent ? .check : .do }
}

let SPEC_KEYWORDS: [SpecTypeId: Rx] = [
    .shift: Rx("(アルバイト|バイト|パート|出勤|勤務|シフト(?!希望|提出))"),
    .shiftRequest: Rx("(シフト希望|希望シフト|シフト提出|シフトを提出)"),
    .payday: Rx("(給料日|給与日|締め日|給料|給与)"),
    .class: Rx("(授業|講義|ゼミ|[1-7１-７]限)"),
    .assignment: Rx("(課題|宿題|提出物|レポート(?!.*論文))"),
    .exam: Rx("(試験|テスト|中間|期末|小テスト)"),
    .language: Rx("(TOEIC|TOEFL|英検|英語|英単語|語彙|リスニング|語学)", .caseInsensitive),
    .certification: Rx("(資格|検定|簿記|基本情報|宅建)"),
    .report: Rx("(論文|卒論|修論|長いレポート)"),
    .presentation: Rx("(プレゼン|発表|スライド)"),
    .groupWork: Rx("(グループ|班|共同|チーム課題)"),
    .reading: Rx("(読書|読む|読み|ページ|章|教材)"),
    .shopping: Rx("(買い物|買う|購入|補充|スーパー|ドラッグストア)"),
    .appointment: Rx("(病院|歯医者|通院|診察|予約|美容院|クリニック)"),
    .outing: Rx("(出かけ|お出かけ|外出|デート|待ち合わせ|遊びに|会う|ご飯に行)"),
    .trip: Rx("(旅行|出張|帰省|泊|旅)"),
    .transit: Rx("(移動|電車|乗り換え|乗換|バスで|車で)"),
    .routine: Rx("(ルーティン|朝の準備|身支度|寝る準備|就寝|帰宅後)"),
    .chores: Rx("(洗濯|片付け|家事|ゴミ|皿洗い)"),
    .cleaning: Rx("(掃除|清掃)"),
    .morning: Rx("(朝の準備|朝の支度|身支度|起床)"),
    .belongings: Rx("(持ち物|忘れ物|荷物の確認)"),
    .cooking: Rx("(料理|自炊|作り置き|ご飯を作|夕飯を作|お弁当)"),
    .workout: Rx("(運動|筋トレ|ジム|ランニング|ジョギング|ヨガ|ストレッチ)"),
    .project: Rx("(開発|実装|プログラミング|コーディング|制作|アプリ作)"),
    .paperwork: Rx("(申請|手続き|手続|役所|書類|届け出|届出|窓口)"),
    .payment: Rx("(支払い|支払う|払う|振込|振り込み|引き落とし|料金)"),
    .leisure: Rx("(趣味|自由時間|休憩|休む|ゲーム|映画|のんびり|昼寝|散歩)"),
]

let SPEC_PREP: [SpecTypeId: [PrepItem]] = [
    .shift: [.init(title: "出勤の準備", minutes: 20, place: .before)],
    .presentation: [.init(title: "スライド準備", minutes: 90, place: .inbox), .init(title: "原稿", minutes: 60, place: .inbox), .init(title: "リハーサル", minutes: 30, place: .inbox), .init(title: "資料提出", minutes: 10, place: .inbox)],
    // 持ち物は予定の「持ち物」と持ち物の画面で確かめる（準備のタスクを別に作らない）
    .outing: [.init(title: "髪・身支度", minutes: 30, place: .before)],
    .trip: [.init(title: "荷造り", minutes: 45, place: .inbox), .init(title: "事前の手続き", minutes: 15, place: .inbox)],
]

/// 種類の判定順（具体的なものを先に。Web 版と同じ）
/// 廃止した「読書」「朝・帰宅・就寝ルーティン」は判定しない（朝は「朝」、掃除は「清掃」）
let SPEC_ORDER: [SpecTypeId] = [.shiftRequest, .payday, .shift, .groupWork, .report, .exam, .assignment, .presentation, .language, .certification, .class, .shopping, .appointment, .trip, .transit, .belongings, .morning, .outing, .cleaning, .chores, .cooking, .workout, .project, .paperwork, .payment, .leisure]

public func detectSpec(_ s: String) -> SpecTypeId? {
    SPEC_ORDER.first { SPEC_BY_ID[$0]!.keywords.test(s) }
}
