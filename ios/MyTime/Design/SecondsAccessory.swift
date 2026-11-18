import SwiftUI

/// 秒の小さな表示。iOS の時計のすぐ下、ステータスバーとナビゲーションバーの間のすき間に置く。
/// iOS の時計・Wi‑Fi・電池・ダイナミックアイランドには一切重ねない（それらは変えられない）。
/// すき間が無い端末（ホームボタンのある iPhone など、上の余白が小さいもの）では出さない。
/// 自分の View だけが毎秒更新する（親の画面は書き換えない）。画面が見えていない間は止まる。
/// VoiceOver は自動で読み上げない（指でさわったときだけ）。
struct SecondsAccessory: View {
    @AppStorage("clock.showSeconds") private var show = true
    @Environment(\.scenePhase) private var phase

    var body: some View {
        GeometryReader { g in
            let top = g.safeAreaInsets.top
            // ダイナミックアイランド・ノッチのある端末だけ（上の余白が 44pt 以上）
            if show && top >= 44 {
                Group {
                    if phase == .active {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in label(ctx.date) }
                    } else {
                        label(Date())
                    }
                }
                // iOS の時計（左上）の中心の下にそろえる
                .frame(width: 40, height: 12)
                .position(x: 74, y: top - 8)
                .ignoresSafeArea()
            }
        }
        .allowsHitTesting(false)
    }

    private func label(_ d: Date) -> some View {
        let s = Calendar.current.component(.second, from: d)
        return Text(String(format: ":%02d", s))
            .font(.system(size: 11, weight: .semibold)).monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityLabel("いまの秒 \(s)")
    }
}
