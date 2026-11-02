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
}
