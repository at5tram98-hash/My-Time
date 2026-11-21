import SwiftUI
import MyTimeCore

/// 年の表示（純正カレンダーの「< 2026年」）。12か月を3列に並べ、押した月へ戻る。
/// 今の月の名前と今日は赤。予定のある日は数字の下に小さな点
struct YearView: View {
    var year: Int
    var now: EpochMs
    var onPick: (Date) -> Void

    @Environment(AppModel.self) private var model
    @State private var shownYear: Int = 0

    private var cal: Calendar { model.time.calendar }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach((year - 1)...(year + 2), id: \.self) { y in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(verbatim: "\(y)年")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundStyle(y == cal.component(.year, from: Date()) ? Color.red : Color.primary)
                                .padding(.horizontal, 16)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3), alignment: .leading, spacing: 22) {
                                ForEach(1...12, id: \.self) { m in
                                    let start = cal.date(from: DateComponents(year: y, month: m, day: 1)) ?? Date()
                                    Button { onPick(start) } label: { MiniMonth(start: start, now: now) }
                                        .buttonStyle(PressableStyle())
                                        // 月が順にふわっと出る
                                        .appearIn(delay: 0.025 * Double(m - 1), rise: 8)
                                        .accessibilityLabel(start.formatted(.dateTime.year().month(.wide)))
                                }
                            }
                            .padding(.horizontal, 14)
                            Divider().padding(.top, 4)
                        }
                        .id(y)
                    }
                }
                .padding(.vertical, 8)
                .padding(.bottom, 100)
            }
            .onAppear {
                proxy.scrollTo(year, anchor: .top)
                // 描き終わってからもう一度（はじめの位置がずれないように）
                DispatchQueue.main.async { proxy.scrollTo(year, anchor: .top) }
            }
        }
    }
}

/// 小さな月（年の表示の1マス）
private struct MiniMonth: View {
    var start: Date
    var now: EpochMs
    @Environment(AppModel.self) private var model

    var body: some View {
        let cal = model.time.calendar
        let first = model.time.ms(start)
        let lead = model.time.weekday(first)
        let days = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        let isNowMonth = cal.isDate(start, equalTo: model.time.date(now), toGranularity: .month)
        let busy = Set(model.myEvents(from: first, to: model.time.addDays(first, days)).filter { !$0.event.allDay }.map { model.time.startOfDay($0.start) })
        VStack(alignment: .leading, spacing: 4) {
            Text(start.formatted(.dateTime.month(.wide)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.headline)
                .foregroundStyle(isNowMonth ? Color.red : Color.primary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(0..<(lead + days), id: \.self) { i in
                    if i < lead {
                        Color.clear.frame(height: 13)
                    } else {
                        let d = model.time.addDays(first, i - lead)
                        let today = model.time.isSameDay(d, now)
                        Text(verbatim: "\(i - lead + 1)")
                            .font(.system(size: 8.5, weight: today ? .bold : .medium)).monospacedDigit()
                            .foregroundStyle(today ? Color.white : Color.primary)
                            .frame(width: 13, height: 13)
                            .background { if today { Circle().fill(Color.red) } }
                            .overlay(alignment: .bottom) {
                                if busy.contains(d) && !today { Circle().fill(Color.secondary).frame(width: 2, height: 2).offset(y: 2) }
                            }
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }
}
