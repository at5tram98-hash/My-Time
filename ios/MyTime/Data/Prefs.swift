import Foundation
import MyTimeCore

/// 「表示と動き」で選べる好み（この端末だけ。UserDefaults）
enum Prefs {
    static let tapSpeed = "pref.tapSpeed"            // 0 はやい・1 ふつう・2 ゆっくり
    static let tabMinimize = "pref.tabMinimize"      // 下にスクロールしたらタブバーを小さく
    static let travelBuffer = "pref.travelBuffer"    // 移動時間の余裕（分）
    static let wakeMargin = "pref.wakeMargin"        // 起きてから準備までのゆとり（分）
    static let wakeLead = "pref.wakeLead"            // 1つ目の起床アラームは何分前
    static let morningLead = "pref.morningLead"      // 朝を最初の予定の何分前に置くか
    static let tickerOn = "pref.tickerOn"            // 今日のお知らせの行
    static let tickerSeconds = "pref.tickerSeconds"  // お知らせが変わる間隔（秒）
    static let otherPeople = "pref.otherPeople"      // ほかの人の予定：faint・normal・hidden
    static let weekFromToday = "pref.weekFromToday"  // 週表示は今日から（オフ：日曜から）
    static let haptics = "pref.haptics"              // 軽い振動

    static func int(_ k: String, _ d: Int) -> Int { UserDefaults.standard.object(forKey: k) as? Int ?? d }
    static func bool(_ k: String, _ d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }
    static func string(_ k: String, _ d: String) -> String { UserDefaults.standard.string(forKey: k) ?? d }

    /// ほかの人の予定をうすく出すか
    static var dimOthers: Bool { string(otherPeople, "faint") == "faint" }
    /// ほかの人の予定を出さないか
    static var hideOthers: Bool { string(otherPeople, "faint") == "hidden" }

    /// コアの決まりに反映する（起動時・変えたとき）
    static func apply() {
        MorningAuto.leadMinutes = int(morningLead, 120)
        MorningAuto.wakeMargin = int(wakeMargin, 30)
        MorningAuto.firstAlarmLead = int(wakeLead, 15)
    }
}
