import SwiftUI
import MyTimeCore

/// 人のしるし（カレンダー＝人）。人の色の丸に人の形。純正「連絡先」の丸い写真の代わり。
/// 「自分」「みお」のように人ごとに分けたカレンダーを、色だけでなく形でも見分けられるようにする。
struct PersonAvatar: View {
    var calendar: MTCalendar?
    var size: CGFloat = 22

    var body: some View {
        let tint = Color(hex: calendar?.color ?? "#8E8E93")
        ZStack {
            Circle().fill(tint.gradient)
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.56, weight: .semibold))
                .foregroundStyle(.white)
                .offset(y: size * 0.04)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: size >= 20 ? 1.5 : 1))
        .accessibilityHidden(true)
    }
}

/// 人のしるしと名前（予定の詳細・作成画面・カレンダーの絞り込み）
struct PersonLabel: View {
    var calendar: MTCalendar?
    var size: CGFloat = 22
    var body: some View {
        HStack(spacing: 6) {
            PersonAvatar(calendar: calendar, size: size)
            Text(calendar?.name ?? "未設定")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(calendar?.name ?? "未設定")の予定")
    }
}

/// 人を選ぶ・表示を切り替える丸いボタンの列。
/// `selected` は選んでいる人（作成画面）。`selected` が nil のときは `dimmed`（隠している人）を薄く出し、押すと表示・非表示を切り替える（カレンダーの絞り込み）
struct PersonPicker: View {
    var calendars: [MTCalendar]
    var selected: String?
    var dimmed: Set<String> = []
    var onTap: (MTCalendar) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(calendars, id: \.id) { c in
                let on = selected == nil ? !dimmed.contains(c.id) : selected == c.id
                Button { onTap(c) } label: {
                    HStack(spacing: 6) {
                        PersonAvatar(calendar: c, size: 24)
                            .saturation(on ? 1 : 0)
                            .opacity(on ? 1 : 0.5)
                        Text(c.name).font(.subheadline.weight(on ? .semibold : .regular))
                            .foregroundStyle(on ? Color.primary : Color.secondary)
                    }
                    .padding(.leading, 4).padding(.trailing, 12).padding(.vertical, 4)
                    .background(Capsule().fill(on ? Color(hex: c.color).opacity(0.14) : Color(.tertiarySystemFill)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(c.name)
                .accessibilityValue(selected == nil ? (on ? "表示中" : "非表示") : "")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(Motion.pop, value: dimmed)
        .animation(Motion.pop, value: selected)
    }
}
