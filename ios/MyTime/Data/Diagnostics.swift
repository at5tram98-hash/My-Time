import Foundation

/// 診断の記録（保存・通知・アラーム・ロック画面の表示の失敗や件数）。
/// 個人の情報（予定の名前など）は入れない。種類・時刻・件数・エラーの種類だけ。最新100件を端末に残す。
@MainActor
enum Diagnostics {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var at: Date
        var area: String      // save / notification / alarm / live / cleanup / link
        var ok: Bool
        var message: String
    }

    private static let key = "diagnostics.entries"
    private static let countsKey = "diagnostics.counts"

    static var entries: [Entry] {
        guard let d = UserDefaults.standard.data(forKey: key), let x = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return x
    }

    static func record(_ area: String, ok: Bool, _ message: String) {
        var x = entries
        x.insert(Entry(at: Date(), area: area, ok: ok, message: message), at: 0)
        if x.count > 100 { x.removeLast(x.count - 100) }
        if let d = try? JSONEncoder().encode(x) { UserDefaults.standard.set(d, forKey: key) }
    }

    static func failure(_ area: String, _ error: Error, context: String) {
        record(area, ok: false, "\(context)：\(describe(error))")
    }

    /// 種類ごとの最新の件数（予約したアラーム数など）
    static func setCount(_ name: String, _ n: Int) {
        var c = counts
        c[name] = n
        UserDefaults.standard.set(c, forKey: countsKey)
    }
    static var counts: [String: Int] { (UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int]) ?? [:] }

    static func lastSuccess(_ area: String) -> Date? { entries.first { $0.area == area && $0.ok }?.at }
    static func lastFailure(_ area: String) -> Entry? { entries.first { $0.area == area && !$0.ok } }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// エラーの種類だけ（中身に個人情報が入ることがあるので、型名とコードに限る）
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
