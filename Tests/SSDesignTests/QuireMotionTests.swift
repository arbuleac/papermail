import AppKit
import XCTest
@testable import SSDesign

@MainActor
final class QuireMotionTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        Quire.Motion.finishAll()
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    func testPlansFollowTheReduceMotionColumn() {
        let normal = Quire.Motion.plan(Quire.Motion.standard, .settle, reduced: .instant, reduceMotion: false)
        XCTAssertEqual(normal, .init(duration: 0.18, curve: .settle, isReduced: false))
        XCTAssertTrue(normal.animatesMovement)
        // Message expand: instant.
        XCTAssertEqual(Quire.Motion.plan(Quire.Motion.standard, .settle, reduced: .instant, reduceMotion: true),
                       .init(duration: 0, curve: .settle, isReduced: true))
        // Toast in: a linear fade over dur.reducedFade.
        let fade = Quire.Motion.plan(Quire.Motion.standard, .settle, reduced: .fade, reduceMotion: true)
        XCTAssertEqual(fade, .init(duration: 0.12, curve: .linear, isReduced: true))
        XCTAssertFalse(fade.animatesMovement)
        // Toast out: fades are kept.
        XCTAssertEqual(Quire.Motion.plan(Quire.Motion.quick, .leave, reduced: .keep, reduceMotion: true),
                       .init(duration: 0.12, curve: .leave, isReduced: true))
        // The environment flag is the default input.
        QuireEnvironment.shared.setOverrides(.init(reduceMotion: true))
        XCTAssertEqual(Quire.Motion.plan(Quire.Motion.slow, .settle, reduced: .instant).duration, 0)
    }

    func testNothingExceedsSlow() {
        // Spec §4.10: nothing animates longer than dur.slow; the long tokens are timers, not animations.
        for d in [Quire.Motion.instant, Quire.Motion.quick, Quire.Motion.standard, Quire.Motion.reducedFade] {
            XCTAssertLessThanOrEqual(d, Quire.Motion.slow)
        }
    }

    func testFinishAllJumpsALayerAnimationToItsEnd() {
        let layer = CALayer()
        layer.opacity = 0
        var completed = 0
        let runner = Quire.Motion.animate(layer, keyPath: "opacity", to: Float(1), duration: Quire.Motion.slow, curve: .settle,
                                          reduced: .fade) { completed += 1 }
        XCTAssertNotNil(runner)
        XCTAssertEqual(layer.opacity, 1, "the model value is final from the start")
        XCTAssertNotNil(layer.animation(forKey: "quire.opacity"))
        XCTAssertEqual(Quire.Motion.runningCount, 1)
        Quire.Motion.finishAll()
        XCTAssertNil(layer.animation(forKey: "quire.opacity"))
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(Quire.Motion.runningCount, 0)
        Quire.Motion.finishAll()
        XCTAssertEqual(completed, 1, "completion runs once")
    }

    func testReducedLayerAnimationSnapsMovement() {
        QuireEnvironment.shared.setOverrides(.init(reduceMotion: true))
        let layer = CALayer()
        var completed = false
        let runner = Quire.Motion.animate(layer, keyPath: "position.y", to: CGFloat(12), duration: Quire.Motion.slow, curve: .settle,
                                          reduced: .fade) { completed = true }
        XCTAssertNil(runner, "a rise cannot cross-fade, so it snaps")
        XCTAssertEqual(layer.position.y, 12)
        XCTAssertTrue(completed)
        XCTAssertNil(layer.animation(forKey: "quire.position.y"))
    }

    func testFinishAllSettlesAnAnimationGroup() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.wantsLayer = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        let child = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        child.wantsLayer = true
        view.addSubview(child)
        var completed = 0
        let group = Quire.Motion.run(Quire.Motion.standard, .glide, reduced: .instant, participants: [child], animations: { plan in
            XCTAssertTrue(plan.animatesMovement)
            child.animator().alphaValue = 0.5
        }, completion: { completed += 1 })
        XCTAssertNotNil(group)
        XCTAssertEqual(Quire.Motion.runningCount, 1)
        Quire.Motion.finishAll()
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(child.alphaValue, 0.5, accuracy: 0.001)
        XCTAssertTrue(child.layer?.animationKeys()?.isEmpty ?? true)
        // The group's own completion arriving later does not run the completion again.
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(completed, 1)
    }

    func testInstantRunAppliesInTheSameFrame() {
        QuireEnvironment.shared.setOverrides(.init(reduceMotion: true))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        var completed = false
        let group = Quire.Motion.run(Quire.Motion.standard, .settle, reduced: .instant, animations: { plan in
            XCTAssertFalse(plan.animates)
            view.animator().frame.size.height = 44
        }, completion: { completed = true })
        XCTAssertNil(group)
        XCTAssertTrue(completed)
        XCTAssertEqual(view.frame.height, 44)
    }

    func testCustomAnimatorsAreFinishedAndHeldWeakly() {
        final class Probe: QuireAnimator {
            var finished = 0
            func finishAnimation() { finished += 1 }
        }
        let probe = Probe()
        Quire.Motion.register(probe)
        do {
            let transient = Probe()
            Quire.Motion.register(transient)
        }
        XCTAssertEqual(Quire.Motion.runningCount, 1, "the released animator is dropped")
        Quire.Motion.finishAll()
        XCTAssertEqual(probe.finished, 1)
        Quire.Motion.finishAll()
        XCTAssertEqual(probe.finished, 1, "finishAll clears the registry")
    }

    // MARK: Frame by frame

    /// The curves stepped frame by frame land where Core Animation's would: from 0 to 1, never back, and at the
    /// documented control points' values (a linear curve is the time itself).
    func testCurveProgressFollowsTheControlPoints() {
        for curve in Quire.Motion.Curve.allCases {
            XCTAssertEqual(curve.progress(at: 0), 0, accuracy: 1e-6, "\(curve)")
            XCTAssertEqual(curve.progress(at: 1), 1, accuracy: 1e-6, "\(curve)")
            XCTAssertEqual(curve.progress(at: -1), 0, accuracy: 1e-6, "clamped")
            XCTAssertEqual(curve.progress(at: 2), 1, accuracy: 1e-6, "clamped")
            var last = 0.0
            for i in 1...100 {
                let p = curve.progress(at: Double(i) / 100)
                XCTAssertGreaterThanOrEqual(p, last - 1e-9, "\(curve) at \(i)%: never back")
                last = p
            }
        }
        XCTAssertEqual(Quire.Motion.Curve.linear.progress(at: 0.3), 0.3, accuracy: 1e-6)
        // ease.settle (0.2, 0.8, 0.2, 1) is most of the way there by half time; ease.leave (0.4, 0, 1, 1) has barely begun.
        XCTAssertGreaterThan(Quire.Motion.Curve.settle.progress(at: 0.5), 0.85)
        XCTAssertLessThan(Quire.Motion.Curve.leave.progress(at: 0.25), 0.1)
    }

    func testAFrameAnimationWithNoTimeToRunStepsToItsEnd() {
        var values: [CGFloat] = []
        var completed = 0
        let loose = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertNil(QuireFrameAnimation.run(from: 0, to: 80, Quire.Motion.standard, .settle, reduced: .instant, in: loose,
                                             step: { values.append($0) }, completion: { completed += 1 }), "no window: at once")
        XCTAssertEqual(values, [80])
        XCTAssertEqual(completed, 1)
        QuireEnvironment.shared.setOverrides(.init(reduceMotion: true))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 40, height: 40), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: window.contentLayoutRect)
        window.contentView = view
        XCTAssertNil(QuireFrameAnimation.run(from: 80, to: 0, Quire.Motion.standard, .settle, reduced: .instant, in: view,
                                             step: { values.append($0) }, completion: { completed += 1 }), "Reduce Motion: at once")
        XCTAssertEqual(values, [80, 0])
        XCTAssertEqual(completed, 2)
    }

    /// In a window it runs on its own, ends where it was going even when no frame comes, and a keystroke's `finishAll()`
    /// jumps it to its end; a cancelled one stops where it is, without its completion.
    func testAFrameAnimationEndsAtItsValueAndIsFinishedByAKeystroke() throws {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 40, height: 40), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: window.contentLayoutRect)
        window.contentView = view
        var last: CGFloat = -1
        var completed = 0
        let running = try XCTUnwrap(QuireFrameAnimation.run(from: 0, to: 80, Quire.Motion.standard, .settle, reduced: .instant,
                                                            in: view, step: { last = $0 }, completion: { completed += 1 }))
        XCTAssertEqual(running.value(after: 0), 0)
        XCTAssertEqual(running.value(after: Quire.Motion.standard), 80)
        XCTAssertGreaterThan(running.value(after: Quire.Motion.standard / 2), 40, "ease.settle is past half way at half time")
        XCTAssertEqual(Quire.Motion.runningCount, 1)
        let deadline = Date().addingTimeInterval(2)
        while !running.isDone, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(running.isDone)
        XCTAssertEqual(last, 80)
        XCTAssertEqual(completed, 1)

        let finished = try XCTUnwrap(QuireFrameAnimation.run(from: 80, to: 0, Quire.Motion.standard, .settle, reduced: .instant,
                                                             in: view, step: { last = $0 }, completion: { completed += 1 }))
        Quire.Motion.finishAll()
        XCTAssertTrue(finished.isDone)
        XCTAssertEqual(last, 0)
        XCTAssertEqual(completed, 2)

        let cancelled = try XCTUnwrap(QuireFrameAnimation.run(from: 0, to: 80, Quire.Motion.standard, .settle, reduced: .instant,
                                                              in: view, step: { last = $0 }, completion: { completed += 1 }))
        cancelled.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(last, 0, "it stops where it was")
        XCTAssertEqual(completed, 2, "and never completes")
        XCTAssertEqual(Quire.Motion.runningCount, 0)
    }
}
