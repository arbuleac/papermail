import Combine
import SwiftUI

/// The root of every hosted SwiftUI tree (spec §4.16): it follows `QuireEnvironment`'s theme, Graphite and Increase
/// Contrast and passes them down the environment, so every `QuireColorStyle` below redraws in place on a change, keeping
/// the subtree's identity, its `@State` and keyboard focus. Settings hosts each tab in one.
public struct QuireThemeRoot<Content: View>: View {
    private let content: Content
    @State private var snapshot = QuireThemeRoot.read()

    public init(_ content: Content) {
        self.content = content
    }

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .environment(\.quireTheme, snapshot.theme)
            .environment(\.quireDrawingFlags, snapshot.flags)
            .onReceive(NotificationCenter.default.publisher(for: QuireEnvironment.didChangeNotification)) { _ in
                let fresh = QuireThemeRoot.read()
                if fresh != snapshot { snapshot = fresh }
            }
    }

    private struct Drawn: Equatable {
        var theme: QuireTheme
        var flags: QuireDrawingFlags
    }

    private static func read() -> Drawn {
        let s = QuireEnvironment.shared.snapshot
        return Drawn(theme: s.theme, flags: QuireDrawingFlags(isGraphite: s.isGraphite, increaseContrast: s.increaseContrast))
    }
}
