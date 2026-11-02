#if DEBUG
import AppKit
import SSDesign

/// An avatar face or an account face, with an optional account ring, drawn the way a row will draw it: the
/// cached face from `QuireAvatarRenderer`, the ring per draw. The frame leaves room for the ring.
@MainActor
final class DesignGalleryAvatar: NSView {
    enum Face {
        case sender(initials: String, address: String)
        case tinted(initials: String, tint: Quire.AvatarTint)
        case account(monogram: String, slot: Int)
    }

    private let face: Face
    private let diameter: CGFloat
    private let ring: Int?

    init(_ face: Face, diameter: CGFloat, ring: Int? = nil) {
        self.face = face
        self.diameter = diameter
        self.ring = ring
        let side = QuireAvatarRenderer.ringBounds(around: NSRect(x: 0, y: 0, width: diameter, height: diameter)).width
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(side), height: ceil(side)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: (bounds.width - diameter) / 2, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
        let appearance = NSAppearance.currentDrawing()
        let image: NSImage
        switch face {
        case .sender(let initials, let address):
            image = QuireAvatarRenderer.shared.face(initials: initials, tint: QuireAvatarRenderer.tint(forAddress: address),
                                                    diameter: diameter, appearance: appearance)
        case .tinted(let initials, let tint):
            image = QuireAvatarRenderer.shared.face(initials: initials, tint: tint, diameter: diameter, appearance: appearance)
        case .account(let monogram, let slot):
            image = QuireAvatarRenderer.shared.accountFace(monogram: monogram, slot: slot, diameter: diameter, appearance: appearance)
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if let ring { QuireAvatarRenderer.drawRing(around: rect, accountSlot: ring) }
    }
}
#endif
