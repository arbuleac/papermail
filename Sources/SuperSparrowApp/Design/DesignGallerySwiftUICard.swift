import AppKit
import SSDesign
import SwiftUI

/// The SwiftUI half of the gallery: `QuireSettingsGallery`, the Settings controls in every state, hosted in
/// one full-width card. It rebuilds on Graphite and contrast overrides, as the Settings root will.
@MainActor
enum DesignGallerySwiftUICard {
    static func make() -> DesignGalleryCard {
        DesignGalleryCard("Settings controls", code: "SwiftUI · §8.3 · §5.40",
                          caption: "Settings is SwiftUI: system window and tabs, Quire-drawn controls. States are forced with "
                              + "quireForcedStates, disabled and controlActiveState; each caption names them in order.",
                          span: 12, surface: .canvas) { block in
            block.labelWidth = 0
            let hosting = NSHostingView(rootView: QuireSettingsGallery().quireRefreshesOnEnvironmentChange())
            // The gallery sizes itself; the card only gives it a place.
            hosting.setFrameSize(hosting.fittingSize)
            block.full(hosting)
        }
    }
}
