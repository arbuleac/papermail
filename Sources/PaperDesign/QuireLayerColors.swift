import AppKit
import QuartzCore

/// Keeps a layer-backed view's `CGColor`s in step with its appearance and with `QuireEnvironment` (spec §8.2).
///
/// `CALayer` colours are plain `CGColor`s: they do not follow appearance or Graphite the way a dynamic
/// `NSColor` does when AppKit draws it. A view owns one `QuireLayerColors`, binds each layer colour to a token
/// once, and calls `refresh()` from `viewDidChangeEffectiveAppearance()`; environment changes refresh it
/// automatically. Every colour is resolved under the view's own effective appearance, so a view with an
/// explicit appearance (a dark slip in a light window) gets its own values.
@MainActor
public final class QuireLayerColors: NSObject {
    private struct Key: Hashable {
        let layer: ObjectIdentifier?
        let keyPath: AnyKeyPath?
        let name: String?
    }

    private struct Binding {
        let color: NSColor?
        let isAlive: @MainActor () -> Bool
        let apply: @MainActor (CGColor?) -> Void
    }

    public weak var view: NSView?
    private var bindings: [Key: Binding] = [:]
    private var order: [Key] = []

    public init(view: NSView) {
        self.view = view
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    /// Binds `layer[keyPath: keyPath]` to `color` and applies it now. Binding the same layer and key path
    /// again replaces the colour; nil clears it and stops tracking.
    public func set<L: CALayer>(_ color: NSColor?, for keyPath: ReferenceWritableKeyPath<L, CGColor?>, of layer: L) {
        let key = Key(layer: ObjectIdentifier(layer), keyPath: keyPath, name: nil)
        guard let color else {
            remove(key)
            withoutActions { layer[keyPath: keyPath] = nil }
            return
        }
        store(key, Binding(color: color, isAlive: { [weak layer] in layer != nil },
                           apply: { [weak layer] cg in layer?[keyPath: keyPath] = cg }))
    }

    /// Binds a colour to an arbitrary consumer (gradient stops, a shadow, an attributed string), keyed by a
    /// name so it can be replaced or removed.
    public func bind(_ name: String, _ color: NSColor, apply: @escaping @MainActor (CGColor) -> Void) {
        store(Key(layer: nil, keyPath: nil, name: name), Binding(color: color, isAlive: { true }, apply: { cg in
            if let cg { apply(cg) }
        }))
    }

    public func unbind(_ name: String) {
        remove(Key(layer: nil, keyPath: nil, name: name))
    }

    /// Re-resolves every bound colour under the view's current appearance. Call it from the view's
    /// `viewDidChangeEffectiveAppearance()`.
    public func refresh() {
        order.removeAll { key in
            guard let b = bindings[key], b.isAlive() else {
                bindings[key] = nil
                return true
            }
            return false
        }
        withoutActions {
            for key in order {
                guard let b = bindings[key] else { continue }
                b.apply(b.color.map(resolve))
            }
        }
    }

    /// `color` as a `CGColor` under the view's effective appearance (the app's when the view is gone).
    public func resolve(_ color: NSColor) -> CGColor {
        let appearance = view?.effectiveAppearance ?? NSAppearance.currentDrawing()
        var cg: CGColor = color.cgColor
        appearance.performAsCurrentDrawingAppearance {
            cg = color.cgColor
        }
        return cg
    }

    public var count: Int { order.count }

    private func store(_ key: Key, _ binding: Binding) {
        if bindings[key] == nil { order.append(key) }
        bindings[key] = binding
        withoutActions { binding.apply(binding.color.map(resolve)) }
    }

    private func remove(_ key: Key) {
        bindings[key] = nil
        order.removeAll { $0 == key }
    }

    /// Colour swaps happen in one frame: an appearance change must not fade every layer over 0.25 s.
    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    @objc private func environmentDidChange(_ note: Notification) {
        refresh()
    }
}
