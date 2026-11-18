import SwiftUI
import MyTimeCore

/// ロック画面・ダイナミックアイランドの見本（8種類）。本物の Live Activity は始めない
struct LivePreviewView: View {
    @State private var showActive = false

    var body: some View {
        List {
            Section {
                Picker("見本の段階", selection: $showActive) {
                    Text("開始前").tag(false)
                    Text("進行中・終了後").tag(true)
                }
                .pickerStyle(.segmented)
            } footer: { Text("見本の表示です（本物の表示は始めません）。実際にどれをダイナミックアイランドに出すかは iPhone が決めます。") }
            ForEach(Self.samples(), id: \.kind) { s in
                Section(kindLabel(s.kind)) {
                    VStack(alignment: .leading, spacing: 12) {
                        // ダイナミックアイランド（Compact：左右の短い表示）
                        HStack(spacing: 0) {
                            HStack(spacing: 3) {
                                Image(systemName: s.state.symbol).foregroundStyle(accent(s.state))
                                if let l = s.state.compactLeading { Text(l).font(.caption.weight(.semibold)).lineLimit(1) }
                            }
                            .frame(width: 70, alignment: .leading)
                            Spacer(minLength: 60)
                            Group {
                                if let t = s.state.compactTrailing, phase(s.state, stale: false) == .run { Text(t) }
                                else { TimeValue(state: s.state, stale: showActive, compact: true) }
                            }
                            .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(accent(s.state))
                            .frame(width: 52, alignment: .trailing)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(Capsule().fill(.black))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("ダイナミックアイランドの見本")
                        // ロック画面
                        LockScreenView(kind: s.kind, state: s.state, stale: showActive)
                            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(.secondarySystemBackground)))
                            .environment(\.colorScheme, .dark)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .allowsHitTesting(false)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }
        }
        .navigationTitle("表示の見本")
        .navigationBarTitleDisplayMode(.inline)
    }

    struct Sample { var kind: String; var state: MyTimeActivityAttributes.ContentState }

    static func samples() -> [Sample] {
        let now = Date()
        func st(_ title: String, headline: String? = nil, detail: String? = nil, to: Date? = nil, ends: Date? = nil, from: Date? = nil,
                done: Int? = nil, total: Int? = nil, next: String? = nil, status: String? = nil, tint: String, symbol: String,
                lead: String? = nil, trail: String? = nil, phase: String, canComplete: Bool = false, token: String? = nil) -> MyTimeActivityAttributes.ContentState {
            .init(title: title, headline: headline, detail: detail, countdownTo: to, elapsedFrom: from, progressDone: done, progressTotal: total,
                  next: next, status: status, endsAt: ends, tint: tint, symbol: symbol, url: "mytime://", canComplete: canComplete,
                  token: token, compactLeading: lead, compactTrailing: trail, phase: phase)
        }
        let m = 60.0
        return [
            Sample(kind: "classNext", state: st("マクロ経済学", headline: "5302教室", detail: "10:45〜12:15", to: now + 8 * m, ends: now + 98 * m, status: "小テストあり", tint: "#5E5CE6", symbol: "graduationcap.fill", lead: "5302", phase: "before")),
            Sample(kind: "shift", state: st("GU勤務", headline: "18:30 出勤", detail: "18:30〜22:00", to: now + 15 * m, ends: now + 225 * m, tint: "#FF9F0A", symbol: "briefcase.fill", lead: "GU", phase: "before")),
            Sample(kind: "morning", state: st("洗顔", detail: "顔・全11工程中 2工程目", from: now - 6 * m, done: 1, total: 11, next: "化粧水・乳液", tint: "#FF9F0A", symbol: "sunrise.fill", lead: "洗顔", trail: "2/11", phase: "run", canComplete: true, token: "sample:1")),
            Sample(kind: "cleaning", state: st("清掃", headline: "浴室・排水口", detail: "残り 5箇所", from: now - 12 * m, done: 3, total: 8, tint: "#30B0C7", symbol: "bubbles.and.sparkles.fill", trail: "3/8", phase: "run")),
            Sample(kind: "transit", state: st("ゼミへ出発", headline: "16:25発", detail: "本館・16:50開始", to: now + 5 * m, ends: now + 10 * m, tint: "#0A84FF", symbol: "figure.walk", lead: "16:25", phase: "before")),
            Sample(kind: "study", state: st("統計学：第3章", detail: "21:00までの予定", from: now - 25 * m, status: "集中", tint: "#5E5CE6", symbol: "book.fill", phase: "run", token: "sample")),
            Sample(kind: "task", state: st("レポートの下書き", detail: "17:00までの予定", from: now - 40 * m, status: "実行中", tint: "#34C759", symbol: "checklist", phase: "run", token: "sample")),
            Sample(kind: "checkpoint", state: st("バスに乗る", headline: "12:45", to: now + 10 * m, ends: now + 10 * m, tint: "#FF9F0A", symbol: "flag.checkered", phase: "before")),
        ]
    }
}
