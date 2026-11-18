import Foundation

// Web 版 spec.ts の fields（種類ごとの専用の入力項目）。packages/domain/src/spec.ts から生成。

public struct SpecField: Sendable, Equatable {
    public enum Kind: String, Sendable { case text, multiline, number, money, minutes, date, datetime, url, select, toggle, list, checklist, slots, members, steps }
    public var key: String
    public var label: String
    public var kind: Kind
    public var unit: String?
    public var options: [String]
    public var placeholder: String?
    public var hint: String?
}

public extension SpecDef { var fields: [SpecField] { SPEC_FIELDS[id] ?? [] } }

let SPEC_FIELDS: [SpecTypeId: [SpecField]] = [
    .shift: [
        .init(key: "workplace", label: "勤務先", kind: .text, unit: nil, options: [], placeholder: "例：GU", hint: nil),
        .init(key: "hourlyWage", label: "時給", kind: .money, unit: "円", options: [], placeholder: nil, hint: nil),
        .init(key: "breakMinutes", label: "休憩", kind: .minutes, unit: "分", options: [], placeholder: nil, hint: nil),
        .init(key: "transportFee", label: "交通費", kind: .money, unit: "円", options: [], placeholder: nil, hint: "給与とは別に扱います")
    ],
    .shiftRequest: [
        .init(key: "workplace", label: "勤務先", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "wishes", label: "希望の勤務枠", kind: .slots, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "unavailable", label: "出られない日", kind: .list, unit: nil, options: [], placeholder: "例：11/22（ゼミ）", hint: nil),
        .init(key: "status", label: "状態", kind: .select, unit: nil, options: ["未提出", "提出済み"], placeholder: nil, hint: nil)
    ],
    .payday: [
        .init(key: "workplace", label: "勤務先", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "closingDay", label: "締め日", kind: .number, unit: "日", options: [], placeholder: nil, hint: "月末締めは 0"),
        .init(key: "actualAmount", label: "実際の入金額", kind: .money, unit: "円", options: [], placeholder: nil, hint: nil),
        .init(key: "received", label: "入金を確認した", kind: .toggle, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .`class`: [
        .init(key: "period", label: "時限", kind: .text, unit: nil, options: [], placeholder: "例：2限", hint: nil),
        .init(key: "room", label: "教室", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "termEnd", label: "開講の終わり", kind: .date, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "quizAt", label: "小テストの日", kind: .datetime, unit: nil, options: [], placeholder: nil, hint: "次の小テストの日時"),
        .init(key: "quizScope", label: "小テストの範囲", kind: .text, unit: nil, options: [], placeholder: "例：第5〜6回", hint: nil),
        .init(key: "bring", label: "持ち物", kind: .list, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .assignment: [
        .init(key: "course", label: "授業", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "dueAt", label: "提出期限", kind: .datetime, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "submitUrl", label: "提出URL", kind: .url, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .exam: [
        .init(key: "examAt", label: "試験日時", kind: .datetime, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "course", label: "科目", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "scope", label: "範囲", kind: .multiline, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "goal", label: "目標", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "reviewCount", label: "復習の回数", kind: .number, unit: "回", options: [], placeholder: nil, hint: nil),
        .init(key: "dailyMinutes", label: "1日の学習", kind: .minutes, unit: "分", options: [], placeholder: nil, hint: nil)
    ],
    .language: [
        .init(key: "targetScore", label: "目標点", kind: .number, unit: "点", options: [], placeholder: nil, hint: nil),
        .init(key: "mockDate", label: "模試・本番の日", kind: .date, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "areas", label: "学習する分野", kind: .list, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "dailyMinutes", label: "1日の目安", kind: .minutes, unit: "分", options: [], placeholder: nil, hint: nil)
    ],
    .certification: [
        .init(key: "examDate", label: "受験日", kind: .date, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "material", label: "教材", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "units", label: "単元", kind: .checklist, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "dailyMinutes", label: "1日の学習", kind: .minutes, unit: "分", options: [], placeholder: nil, hint: nil)
    ],
    .report: [
        .init(key: "dueAt", label: "締切", kind: .datetime, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "format", label: "提出形式", kind: .text, unit: nil, options: [], placeholder: "例：Word 4000字", hint: nil),
        .init(key: "sources", label: "資料", kind: .list, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .presentation: [
        .init(key: "talkMinutes", label: "持ち時間", kind: .minutes, unit: "分", options: [], placeholder: nil, hint: nil),
        .init(key: "materialDue", label: "資料の期限", kind: .datetime, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .groupWork: [
        .init(key: "members", label: "分担", kind: .members, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "shareUrl", label: "共有リンク", kind: .url, unit: nil, options: [], placeholder: nil, hint: "My Time から共有先へは書き込みません")
    ],
    .reading: [
        .init(key: "totalPages", label: "全体", kind: .number, unit: "ページ", options: [], placeholder: nil, hint: nil),
        .init(key: "currentPage", label: "今のページ", kind: .number, unit: "ページ", options: [], placeholder: nil, hint: nil),
        .init(key: "targetDate", label: "読み終える目標日", kind: .date, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .shopping: [
        .init(key: "items", label: "買う物", kind: .checklist, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "store", label: "お店", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "storeHours", label: "営業時間", kind: .text, unit: nil, options: [], placeholder: "分からなければ空欄", hint: "空欄のときは「未確認」と表示します")
    ],
    .appointment: [
        .init(key: "bring", label: "持ち物", kind: .list, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "prep", label: "事前にすること", kind: .multiline, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "arriveEarly", label: "早めに着く", kind: .minutes, unit: "分", options: [], placeholder: nil, hint: nil)
    ],
    .outing: [
        .init(key: "companions", label: "一緒に行く人", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "meetPlace", label: "集合場所", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "purpose", label: "目的", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "prepMinutes", label: "身支度", kind: .minutes, unit: "分", options: [], placeholder: nil, hint: nil)
    ],
    .trip: [
        .init(key: "transport", label: "交通", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "lodging", label: "宿泊", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "meetTime", label: "集合時刻", kind: .datetime, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "destTimeZone", label: "現地のタイムゾーン", kind: .select, unit: nil, options: ["Asia/Tokyo", "Asia/Seoul", "Asia/Shanghai", "Asia/Taipei", "Asia/Singapore", "Asia/Bangkok", "Europe/London", "Europe/Paris", "America/New_York", "America/Los_Angeles", "Pacific/Honolulu", "Australia/Sydney"], placeholder: nil, hint: nil),
        .init(key: "packing", label: "持ち物", kind: .checklist, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .transit: [
        .init(key: "from", label: "出発", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "to", label: "到着", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "mode", label: "手段", kind: .select, unit: nil, options: ["徒歩", "電車", "バス", "車", "自転車", "飛行機"], placeholder: nil, hint: nil),
        .init(key: "minutes", label: "所要時間", kind: .minutes, unit: "分", options: [], placeholder: nil, hint: "未入力のまま0分として予定を詰めません")
    ],
    .routine: [
        .init(key: "steps", label: "工程", kind: .steps, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .chores: [
        .init(key: "area", label: "場所・内容", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .cooking: [
        .init(key: "dish", label: "料理", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "ingredients", label: "材料（持っている物にチェック）", kind: .checklist, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .workout: [
        .init(key: "activity", label: "種目", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "perWeek", label: "週の回数", kind: .number, unit: "回", options: [], placeholder: nil, hint: nil),
        .init(key: "restDays", label: "休む日", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .project: [
        .init(key: "deliverable", label: "成果物", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "issueUrl", label: "Issue / PR の URL", kind: .url, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "testResult", label: "テスト結果", kind: .select, unit: nil, options: ["未記録", "成功", "失敗"], placeholder: nil, hint: "実行した結果だけを記録します")
    ],
    .paperwork: [
        .init(key: "office", label: "提出先", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "dueAt", label: "提出期限", kind: .datetime, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "windowHours", label: "窓口の受付時間", kind: .text, unit: nil, options: [], placeholder: "例：平日 8:30〜17:15", hint: nil),
        .init(key: "docs", label: "必要な書類", kind: .checklist, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .payment: [
        .init(key: "payee", label: "支払先", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "amount", label: "金額", kind: .money, unit: "円", options: [], placeholder: nil, hint: nil),
        .init(key: "paid", label: "支払った（自分で確認）", kind: .toggle, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .leisure: [
        .init(key: "wish", label: "やりたいこと", kind: .text, unit: nil, options: [], placeholder: nil, hint: nil)
    ],
    .belongings: [
        .init(key: "items", label: "持ち物", kind: .checklist, unit: nil, options: [], placeholder: nil, hint: nil),
        .init(key: "destination", label: "行き先", kind: .text, unit: nil, options: [], placeholder: "例：大学・バイト先", hint: nil)
    ],
]
