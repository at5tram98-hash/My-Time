import SwiftUI
import MyTimeCore

/// カレンダー。上に月（標準の日付選択）、下に選んだ日の時刻軸。終日の予定は時刻軸の上に並べる
struct CalendarScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var selected = Date()
    @State private var showMonth = true

    var body: some View {
        NavigationStack {
            let day = model.time.startOfDay(model.time.ms(selected))
            let occ = model.visibleEvents(from: model.time.addDays(day, -1), to: model.time.addDays(day, 2))
            let allDay = occ.filter { $0.event.allDay && $0.start < model.time.addDays(day, 1) && $0.end > day }
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                VStack(spacing: 0) {
                    if showMonth {
                        DatePicker("日付", selection: $selected, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .padding(.horizontal)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if !allDay.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(allDay) { o in
                                    Button { router.open(.event(o.id)) } label: {
                                        Label(o.title, systemImage: "sun.max").font(.caption.weight(.semibold))
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .background(Capsule().fill(Color(hex: model.eventColor(o.event)).opacity(0.2)))
                                            .foregroundStyle(Color(hex: model.eventColor(o.event)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical, 6)
                    }
                    Divider()
                    DayTimeline(day: day, now: model.time.ms(ctx.date), events: occ, tasks: model.tasks, mainFraction: nil)
                        .id(day)
                }
            }
            .navigationTitle(model.dayTitle(day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(showMonth ? "月をたたむ" : "月を表示", systemImage: showMonth ? "chevron.up" : "calendar") {
                        withAnimation(Motion.sheet) { showMonth.toggle() }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("今日") { withAnimation(Motion.sheet) { selected = Date() } }
                }
                MainToolbar(addKind: .event)
            }
        }
    }
}
