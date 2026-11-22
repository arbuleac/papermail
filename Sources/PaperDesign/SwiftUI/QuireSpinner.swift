import SwiftUI

/// The Quire spinner, drawn natively to match `QuireSpinnerView` and the reader's `.ss-spin` (spec §5.37): a
/// circle inset by half the stroke, stroked from 0 to 0.75 (a ¾ arc, butt caps), turning once per
/// `dur.spinnerTurn`, linearly, for as long as it is shown. It appears only after `dur.spinnerDelay` (150 ms)
/// and never if it leaves sooner, then fades in over `dur.quick`. Reduce Motion keeps it turning: it is small
/// and essential.
///
/// The words beside a spinner carry the state, so the spinner itself is hidden from accessibility.
public struct QuireSpinner: View {
    let size: QuireSpinnerSize
    let color: Color?
    let delay: TimeInterval

    @State private var isShown: Bool

    /// - Parameters:
    ///   - color: `ink3` by default; pass the label colour inside filled buttons (`onAccent`, `onDanger`), or
    ///     nil to take the current foreground style.
    ///   - delay: 150 ms by default. Zero shows it at once, without the fade (galleries, snapshots).
    public init(_ size: QuireSpinnerSize = .small, color: Color? = .qInk3, delay: TimeInterval = Quire.Motion.spinnerDelay) {
        self.size = size
        self.color = color
        self.delay = delay
        _isShown = State(initialValue: delay <= 0)
    }

    public var body: some View {
        // The timeline pauses while the spinner is waiting out its delay; SwiftUI also stops it off screen,
        // which is the "removes its animation when hidden or off-window" of the AppKit spinner.
        TimelineView(.animation(paused: !isShown)) { context in
            // No colour inherits the foreground style; setting `.foreground` itself would reset it to the
            // default ink rather than the label colour of the button around it.
            if let color {
                QuireSpinnerArc(size: size, angle: QuireSpinner.angle(at: context.date)).foregroundStyle(color)
            } else {
                QuireSpinnerArc(size: size, angle: QuireSpinner.angle(at: context.date))
            }
        }
        .frame(width: size.diameter, height: size.diameter)
        .opacity(isShown ? 1 : 0)
        .accessibilityHidden(true)
        .task {
            guard !isShown else { return }
            // A cancelled sleep means the work ended (the view left) before the delay: never show.
            guard (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
            withAnimation(.quire(Quire.Motion.quick, .settle)) { isShown = true }
        }
    }

    /// The rotation, in degrees, at `date`: one turn per `dur.spinnerTurn`, continuous across views so every
    /// spinner on screen turns in step.
    static func angle(at date: Date) -> Double {
        let turn = Quire.Motion.spinnerTurn
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: turn) / turn * 360
    }
}

/// The ¾ arc at one rotation.
struct QuireSpinnerArc: View {
    let size: QuireSpinnerSize
    let angle: Double

    var body: some View {
        Circle()
            .inset(by: size.stroke / 2)
            .trim(from: 0, to: Quire.Layout.Progress.spinnerArc)
            .stroke(style: StrokeStyle(lineWidth: size.stroke, lineCap: .butt))
            .rotationEffect(.degrees(angle))
    }
}
