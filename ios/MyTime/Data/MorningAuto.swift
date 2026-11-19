import Foundation
import MyTimeCore

/// 朝の自動配置（今日と明日。一番初めの予定の2時間前に「朝の準備」を置く）
extension AppModel {
    private static let skipKey = "morningAutoSkip"

    /// 手で消した日は置き直さない
    func skipAutoMorning(_ t: MTTask) {
        guard let k = MorningPlace.dayKey(t) else { return }
        var s = UserDefaults.standard.stringArray(forKey: Self.skipKey) ?? []
        if !s.contains(k) { s.append(k) }
        UserDefaults.standard.set(Array(s.suffix(30)), forKey: Self.skipKey)
    }

    /// 置き直したら true
    func placeMorningsIfNeeded() -> Bool {
        let today = time.startOfDay(now)
        let days = [today, time.addDays(today, 1)]
        let occ = expandAll(events.filter { !$0.isArchived }, from: today, to: time.addDays(today, 2), time: time)
        let est = morning.estimate().minutes
        let skip = Set(UserDefaults.standard.stringArray(forKey: Self.skipKey) ?? [])
        let n = (try? repo.placeMornings(days: days, occurrences: occ, minutes: est > 0 ? est : 60, now: now, time: time, skip: skip)) ?? 0
        return n > 0
    }
}
