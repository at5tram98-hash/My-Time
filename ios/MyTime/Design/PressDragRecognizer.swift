import SwiftUI
import UIKit

/// 長押し→なぞる・タップ・左右のスワイプを、スクロールと取り合わずに受け取る（UIKit のジェスチャー）。
/// SwiftUI の DragGesture をスクロールの中に置くと、iOS 18 以降は上下のスクロールが効かなくなるため、こちらを使う。
/// 置いた場所の大きさの透明な板として使い、位置はその板の中の座標で渡す。
struct PressDragRecognizer: UIViewRepresentable {
    var minimumDuration: Double = 0.45
    var onTap: (() -> Void)? = nil
    /// タップした位置も知りたいとき
    var onTapAt: ((CGPoint) -> Void)? = nil
    var onBegan: ((CGPoint) -> Void)? = nil
    /// 位置・長押しを始めた所からの移動量
    var onChanged: ((CGPoint, CGSize) -> Void)? = nil
    var onEnded: ((CGPoint, CGSize) -> Void)? = nil
    var onCancelled: (() -> Void)? = nil
    /// 左右になぞる（-1：左へ＝次、1：右へ＝前）
    var onSwipe: ((Int) -> Void)? = nil
    /// 横になぞっている間の移動量（指に合わせて動かすとき）。終わりに予測の移動量も渡す
    var onHorizontalPan: ((CGFloat) -> Void)? = nil
    var onHorizontalPanEnded: ((CGFloat, CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isAccessibilityElement = false
        let c = context.coordinator
        if onBegan != nil || onChanged != nil || onEnded != nil {
            let lp = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.press(_:)))
            lp.minimumPressDuration = minimumDuration
            lp.delegate = c
            v.addGestureRecognizer(lp)
        }
        if onTap != nil || onTapAt != nil {
            // 軽く触れただけ・スクロールを止めようと触れただけでは開かない（DeliberateTap）
            let t = DeliberateTapRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
            t.delegate = c
            v.addGestureRecognizer(t)
        }
        if onSwipe != nil {
            for d in [UISwipeGestureRecognizer.Direction.left, .right] {
                let s = UISwipeGestureRecognizer(target: c, action: #selector(Coordinator.swipe(_:)))
                s.direction = d
                s.delegate = c
                v.addGestureRecognizer(s)
            }
        }
        if onHorizontalPan != nil || onHorizontalPanEnded != nil {
            let p = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
            p.delegate = c
            c.hPan = p
            v.addGestureRecognizer(p)
        }
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        context.coordinator.parent = self
        for g in v.gestureRecognizers ?? [] {
            if let lp = g as? UILongPressGestureRecognizer { lp.minimumPressDuration = minimumDuration }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PressDragRecognizer
        var start: CGPoint = .zero
        weak var hPan: UIPanGestureRecognizer?
        init(_ p: PressDragRecognizer) { parent = p }

        @objc func press(_ g: UILongPressGestureRecognizer) {
            let p = g.location(in: g.view)
            let t = CGSize(width: p.x - start.x, height: p.y - start.y)
            switch g.state {
            case .began: start = p; parent.onBegan?(p)
            case .changed: parent.onChanged?(p, t)
            case .ended: parent.onEnded?(p, t)
            case .cancelled, .failed: parent.onCancelled?()
            default: break
            }
        }

        @objc func tap(_ g: UIGestureRecognizer) {
            guard g.state == .ended else { return }
            parent.onTap?()
            parent.onTapAt?(g.location(in: g.view))
        }

        @objc func swipe(_ g: UISwipeGestureRecognizer) { parent.onSwipe?(g.direction == .left ? -1 : 1) }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            let dx = g.translation(in: g.view).x
            switch g.state {
            case .changed: parent.onHorizontalPan?(dx)
            case .ended, .cancelled: parent.onHorizontalPanEnded?(dx, dx + g.velocity(in: g.view).x * 0.15)
            default: break
            }
        }

        /// 横のパンは、横に動かし始めたときだけ受け取る（上下はスクロールに任せる）
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            if g === hPan, let p = g as? UIPanGestureRecognizer {
                let v = p.velocity(in: p.view)
                return abs(v.x) > abs(v.y) * 1.2
            }
            return true
        }

        /// スクロールなど、ほかのジェスチャーと同時に動かしてよい
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}


// MARK: - 押したと分かるタップ

/// 誤って開かないタップ：
/// - 指を置いてから離すまで `TapGuard.minDuration` 秒以上（ふれただけ・こすっただけは数えない）
/// - 8pt より動いたら取り消し（スクロールのつもりの指）
/// - スクロール中・スクロールが止まった直後（`TapGuard.quiet` 秒）に触れたときは数えない（止めるための指で開かない）
final class DeliberateTapRecognizer: UIGestureRecognizer {
    private var began: TimeInterval = 0
    private var origin: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let t = touches.first else { state = .failed; return }
        began = t.timestamp
        origin = t.location(in: view)
        if TapGuard.isScrolling(from: view) { state = .failed }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { return }
        let p = t.location(in: view)
        if hypot(p.x - origin.x, p.y - origin.y) > 8 { state = .failed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first else { state = .failed; return }
        state = t.timestamp - began >= TapGuard.minDuration && !TapGuard.isScrolling(from: view) ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }

    override func reset() { began = 0 }
}

/// 誤タップよけの決まり（今日・カレンダーの札で共通）
enum TapGuard {
    /// 指を置いておく最短の時間
    static let minDuration: TimeInterval = 0.09
    /// スクロールが止まってから、この秒数は札を開かない
    static let quiet: TimeInterval = 0.35
    /// SwiftUI のスクロールが最後に動いた時刻
    static var lastScroll: Date = .distantPast

    static func markScroll() { lastScroll = Date() }

    /// 周りのスクロールが動いている（なぞっている・惰性で動いている）か、止まった直後か
    static func isScrolling(from view: UIView?) -> Bool {
        if Date().timeIntervalSince(lastScroll) < quiet { return true }
        var v = view?.superview
        while let x = v {
            if let sv = x as? UIScrollView, sv.isDragging || sv.isDecelerating { markScroll(); return true }
            v = x.superview
        }
        return false
    }
}

extension View {
    /// 札を開くタップ（少しだけ長く押すと開く。スクロール中・直後は開かない）。
    /// SwiftUI の長押し（最短 TapGuard.minDuration 秒・8pt まで）で受け取り、スクロールの邪魔をしない
    func deliberateTap(_ action: @escaping () -> Void) -> some View {
        onLongPressGesture(minimumDuration: TapGuard.minDuration, maximumDistance: 8) {
            if Date().timeIntervalSince(TapGuard.lastScroll) >= TapGuard.quiet { action() }
        }
    }

    /// このスクロールが動いている間と止まった直後は、札を開かない
    @ViewBuilder
    func guardsTaps() -> some View {
        if #available(iOS 18.0, *) {
            onScrollPhaseChange { _, phase in if phase != .idle { TapGuard.markScroll() } }
        } else {
            self
        }
    }
}
