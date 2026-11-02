import Combine
import SwiftUI

/// Redraws a SwiftUI tree when `QuireEnvironment` changes: Graphite turned on or off, or an Increase Contrast,
/// Reduce Motion or Reduce Transparency override. SwiftUI tracks light, dark and the system's contrast
/// itself, but the Quire colour providers also read `QuireEnvironment`, which SwiftUI cannot see, so without
/// this a Graphite switch leaves Iron Gall on screen until something else redraws (verified: a primary button
/// kept `#1E5468` after the switch).
///
/// It rebuilds the subtree (a new identity per change), which also resets its view state: apply it at the
/// Settings root, where an accent change while a field is being edited is rare and cheap to lose.
public struct QuireEnvironmentRefresh: ViewModifier {
    @State private var revision = 0

    public init() {}

    public func body(content: Content) -> some View {
        content
            .id(revision)
            .onReceive(NotificationCenter.default.publisher(for: QuireEnvironment.didChangeNotification)) { _ in
                revision &+= 1
            }
    }
}

extension View {
    /// Redraws this subtree when `QuireEnvironment` changes (see `QuireEnvironmentRefresh`).
    public func quireRefreshesOnEnvironmentChange() -> some View {
        modifier(QuireEnvironmentRefresh())
    }
}
