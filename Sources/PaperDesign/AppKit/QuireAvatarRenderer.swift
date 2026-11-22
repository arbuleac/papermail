import AppKit
import CoreText
import os

/// Monogram faces (spec §4.3, §5.29, §5.7): sender avatars, New York Semibold initials (`monogramSans` under the
/// SF Pro font) in a tint's ink on its face, and account faces, the domain monogram in `ink` on the account ink
/// at 0.14 over `sheet`, or one of the paper faces (spec §5.55).
///
/// Faces are cached, rings are drawn. A face bitmap holds the disc and the letters only, never the account
/// ring, and is keyed on `QuireEnvironment.cacheKey` (mode, contrast, Graphite, typeface) + size + initials +
/// tint, never
/// on row or window state, so hover and selection never miss the cache. The ring is stroked over the row's own
/// fill with `drawRing(around:color:)`, its gap left undrawn so the fill shows through. Faces render off the
/// main thread on request; until one lands, `drawFace` draws the same face synchronously, so a row never shows
/// an empty circle.
public final class QuireAvatarRenderer: @unchecked Sendable {
    public static let shared = QuireAvatarRenderer()

    private let cache = NSCache<NSString, NSImage>()
    /// Paper faces by face, size, backing scale and Light or Dark. A handful of sizes are drawn (12 to 48 pt), so the
    /// table stays small; it is not an NSCache because a row asks for its tile on every draw, and a struct key costs
    /// nothing to build where a string key would.
    private let paperImages = LockedCache<PaperKey, CGImage?>()
    private let paperRenders = OSAllocatedUnfairLock(initialState: 0)
    private let queue = DispatchQueue(label: "Quire.avatar-render", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var waiters: [String: [@MainActor @Sendable (NSImage) -> Void]] = [:]

    public init() {
        // A few thousand distinct senders is a large address book; past that the oldest re-render. The cost
        // is the bitmap's bytes, so faces at a large size or scale count for what they hold.
        cache.countLimit = 4_000
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    /// The avatar diameters in use: 24 (stack, autocomplete), 30 (rows), 36 (message header).
    public static let sizes: [CGFloat] = Quire.Layout.Avatar.sizes

    // MARK: Initials and tints

    /// At most two letters: the first letters of the first and last words of the display name, or, without a
    /// name, the first letter or digit of the address (spec §4.3). Uppercased in `locale`; "?" when nothing
    /// yields a letter.
    public static func initials(displayName: String?, address: String, locale: Locale = .current) -> String {
        let words = (displayName ?? "")
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .compactMap { word in word.first(where: { $0.isLetter || $0.isNumber }) }
        if let first = words.first {
            let letters = words.count > 1 ? String(first) + String(words[words.count - 1]) : String(first)
            return letters.uppercased(with: locale)
        }
        let local = address.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? address
        if let letter = local.first(where: { $0.isLetter || $0.isNumber }) ?? address.first(where: { $0.isLetter || $0.isNumber }) {
            return String(letter).uppercased(with: locale)
        }
        return "?"
    }

    /// The tint for a sender: FNV-1a of the lowercased address, modulo 8, the same in every account.
    public static func tint(forAddress address: String) -> Quire.AvatarTint {
        Quire.avatarTint(forAddress: address)
    }

    // MARK: Sizes

    /// Initials on an avatar: 0.42 × the diameter, never below 10 pt (10 / 12.5 / 15 at 24 / 30 / 36); under the
    /// SF Pro font 0.39 × (10 / 11.5 / 14).
    public static func initialsSize(diameter: CGFloat) -> CGFloat {
        QuireFont.monogramSize(diameter: diameter)
    }

    /// A domain monogram on an account face: 14 / 12 pt (one / two letters) on a 30 pt face, 11 / 10 pt on a
    /// 24 pt face (§5.2, §5.18, §5.29), scaled to the twin under the SF Pro font; other diameters follow the
    /// avatar ratio.
    public static func monogramSize(for monogram: String, diameter: CGFloat) -> CGFloat {
        let twoLetters = monogram.count > 1
        switch diameter {
        case Quire.Layout.Rail.face:
            return QuireFont.monogramSize(named: twoLetters ? Quire.Layout.Rail.monogramTwoLetter : Quire.Layout.Rail.monogram)
        case Quire.Layout.QuickReply.face:
            return QuireFont.monogramSize(named: twoLetters ? Quire.Layout.QuickReply.faceMonogramTwoLetter : Quire.Layout.QuickReply.faceMonogram)
        default:
            return initialsSize(diameter: diameter)
        }
    }

    // MARK: Cache keys

    /// The face cache key: the environment's colour key for `appearance`, the size and the backing scale it
    /// was rendered at (a 1× face is blurry on a 2× row), the tint and the initials.
    public static func cacheKey(initials: String, tint: Quire.AvatarTint, diameter: CGFloat, appearance: NSAppearance,
                                scale: CGFloat = 2) -> String {
        "\(QuireEnvironment.cacheKey(for: appearance))|\(diameter)@\(scale)|t\(tint.rawValue)|\(initials)"
    }

    /// The account face cache key: as a sender's, plus the theme, because an account face draws `sheet` and `ink`
    /// (spec §4.16); a sender's face draws only the avatar palette, which no theme changes.
    public static func accountCacheKey(monogram: String, slot: Int, diameter: CGFloat, appearance: NSAppearance,
                                       scale: CGFloat = 2) -> String {
        "\(QuireEnvironment.cacheKey(for: appearance))|th\(QuireEnvironment.theme.rawValue)|\(diameter)@\(scale)|a\(slot)|\(monogram)"
    }

    // MARK: Faces

    private struct Recipe: @unchecked Sendable {
        let text: String
        let face: [CGColor]
        let ink: CGColor
        let font: NSFont
        let diameter: CGFloat
        let scale: CGFloat
    }

    private static func recipe(initials: String, tint: Quire.AvatarTint, diameter: CGFloat, appearance: NSAppearance, scale: CGFloat) -> Recipe {
        let mode = QuireMode(appearance)
        let (face, ink) = mode.performAsCurrent { (tint.face.cgColor, tint.ink.cgColor) }
        return Recipe(text: initials, face: [face], ink: ink, font: QuireFont.monogramFont(diameter: diameter), diameter: diameter, scale: scale)
    }

    private static func accountRecipe(monogram: String, slot: Int, diameter: CGFloat, appearance: NSAppearance, scale: CGFloat) -> Recipe {
        let mode = QuireMode(appearance)
        let colors = mode.performAsCurrent {
            (NSColor.qSheet.cgColor, NSColor.qAccount(slot).withAlphaComponent(Quire.Layout.Rail.faceAlpha).cgColor, NSColor.qInk.cgColor)
        }
        // Cached by QuireFont per face and size: rows and tiles draw faces in place on every redraw.
        let font = QuireFont.monogramFont(size: monogramSize(for: monogram, diameter: diameter))
        return Recipe(text: monogram, face: [colors.0, colors.1], ink: colors.2, font: font, diameter: diameter, scale: scale)
    }

    /// A sender's face, ring-less, from the cache or rendered now.
    public func face(initials: String, tint: Quire.AvatarTint, diameter: CGFloat, appearance: NSAppearance, scale: CGFloat = 2) -> NSImage {
        let key = QuireAvatarRenderer.cacheKey(initials: initials, tint: tint, diameter: diameter, appearance: appearance, scale: scale)
        return image(for: key) {
            QuireAvatarRenderer.recipe(initials: initials, tint: tint, diameter: diameter, appearance: appearance, scale: scale)
        }
    }

    /// An account face (rail tile, Settings row, quick reply), ring-less.
    public func accountFace(monogram: String, slot: Int, diameter: CGFloat, appearance: NSAppearance, scale: CGFloat = 2) -> NSImage {
        let key = QuireAvatarRenderer.accountCacheKey(monogram: monogram, slot: slot, diameter: diameter, appearance: appearance,
                                                      scale: scale)
        return image(for: key) {
            QuireAvatarRenderer.accountRecipe(monogram: monogram, slot: slot, diameter: diameter, appearance: appearance, scale: scale)
        }
    }

    /// The cached face, if it has been rendered.
    public func cachedFace(initials: String, tint: Quire.AvatarTint, diameter: CGFloat, appearance: NSAppearance,
                           scale: CGFloat = 2) -> NSImage? {
        cache.object(forKey: QuireAvatarRenderer.cacheKey(initials: initials, tint: tint, diameter: diameter, appearance: appearance,
                                                          scale: scale) as NSString)
    }

    /// Returns the cached face at once, or nil after scheduling one render off the main thread (however many
    /// callers ask meanwhile); `ready` runs on the main thread when it lands.
    @MainActor
    public func face(initials: String, tint: Quire.AvatarTint, diameter: CGFloat, appearance: NSAppearance, scale: CGFloat = 2,
                     ready: @escaping @MainActor @Sendable (NSImage) -> Void) -> NSImage? {
        let key = QuireAvatarRenderer.cacheKey(initials: initials, tint: tint, diameter: diameter, appearance: appearance, scale: scale)
        if let image = cache.object(forKey: key as NSString) { return image }
        lock.lock()
        let pending = waiters[key] != nil
        waiters[key, default: []].append(ready)
        lock.unlock()
        guard !pending else { return nil }
        // Colours are resolved here, on the main thread, under the appearance; the render needs only CG.
        let recipe = QuireAvatarRenderer.recipe(initials: initials, tint: tint, diameter: diameter, appearance: appearance, scale: scale)
        queue.async { [self] in
            let image = QuireAvatarRenderer.render(recipe)
            cache.setObject(image, forKey: key as NSString, cost: QuireAvatarRenderer.cost(of: recipe))
            lock.lock()
            let callbacks = waiters.removeValue(forKey: key) ?? []
            lock.unlock()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for callback in callbacks { callback(image) }
                }
            }
        }
        return nil
    }

    /// Forgets every face (after a memory warning, or when tints change).
    public func removeAll() {
        cache.removeAllObjects()
        paperImages.removeAll()
    }

    private func image(for key: String, recipe: () -> Recipe) -> NSImage {
        if let image = cache.object(forKey: key as NSString) { return image }
        let r = recipe()
        let image = QuireAvatarRenderer.render(r)
        cache.setObject(image, forKey: key as NSString, cost: QuireAvatarRenderer.cost(of: r))
        return image
    }

    /// The bitmap's bytes: RGBA at the recipe's pixel size.
    private static func cost(of r: Recipe) -> Int {
        let pixels = Int((r.diameter * r.scale).rounded())
        return pixels * pixels * 4
    }

    // MARK: Rendering

    /// Core Graphics and Core Text only, so it runs on any queue. The letters are centred on their cap height,
    /// which puts uppercase initials optically in the middle of the disc.
    private static func render(_ r: Recipe) -> NSImage {
        let size = NSSize(width: r.diameter, height: r.diameter)
        let pixels = Int((r.diameter * r.scale).rounded())
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: size) }
        context.scaleBy(x: r.scale, y: r.scale)
        drawFace(r, in: CGRect(origin: .zero, size: size), context: context, flipped: false)
        guard let cgImage = context.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: cgImage, size: size)
    }

    private static func drawFace(_ r: Recipe, in rect: CGRect, context: CGContext, flipped: Bool) {
        for color in r.face {
            context.setFillColor(color)
            context.fillEllipse(in: rect)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): r.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): r.ink,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: r.text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let capHeight = r.font.capHeight
        context.saveGState()
        if flipped {
            // Core Text draws y-up; flip around the face so the text is upright in a flipped view.
            context.translateBy(x: 0, y: rect.minY + rect.maxY)
            context.scaleBy(x: 1, y: -1)
        }
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: rect.midX - CGFloat(width) / 2, y: rect.midY - capHeight / 2)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: Paper faces (spec §5.55)

    private struct PaperKey: Hashable {
        let face: Quire.PaperFace
        let diameter: CGFloat
        let scale: CGFloat
        let dark: Bool
    }

    /// A face's cut-outs parsed into paths in the art's units, once per face for the process: drawing a size it has not
    /// drawn before scales these, it never parses again.
    private struct PaperArt: @unchecked Sendable {
        let ground: Quire.Paper
        let layers: [(path: CGPath, paper: Quire.Paper, lift: Int)]
    }

    private static let paperArt = LockedCache<Quire.PaperFace, PaperArt>()

    private static func art(_ face: Quire.PaperFace) -> PaperArt {
        paperArt.value(for: face) {
            PaperArt(ground: face.ground, layers: face.layers.map { layer in
                do {
                    return (try QuireSVGPath.parse(layer.path), layer.paper, layer.lift)
                } catch {
                    // The paths are generated from tokens.json and parsed by PaperFaceTests, so this is a build defect.
                    assertionFailure("\(face.rawValue): \(error)")
                    return (CGMutablePath(), layer.paper, layer.lift)
                }
            })
        }
    }

    /// A paper face as a bitmap `diameter` points across at `scale` pixels a point, its papers in Light or Dark, from the
    /// cache or drawn now. Ring-less, like every face: the ring is drawn by the surface.
    public func paperFace(_ face: Quire.PaperFace, diameter: CGFloat, scale: CGFloat, dark: Bool) -> CGImage? {
        guard diameter > 0, scale > 0 else { return nil }
        // A size that cannot be drawn is remembered as nil, so it is not tried again on every draw.
        return paperImages.value(for: PaperKey(face: face, diameter: diameter, scale: scale, dark: dark)) {
            paperRenders.withLock { $0 += 1 }
            return QuireAvatarRenderer.renderPaper(face, diameter: diameter, scale: scale, dark: dark)
        }
    }

    /// How many paper face bitmaps this renderer has drawn: the tests' proof that rows and tiles draw the cached one.
    public var paperFaceRenderCount: Int {
        paperRenders.withLock { $0 }
    }

    /// The papers as Core Graphics colours, straight from their values: they follow Light and Dark only, never a theme,
    /// so there is nothing to resolve.
    private static func paperColor(_ paper: Quire.Paper, dark: Bool) -> CGColor {
        cgColor(rgba: dark ? paper.values.dark : paper.values.light)
    }

    /// 0xRRGGBBAA in sRGB.
    private static func cgColor(rgba v: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
    }

    /// The disc filled with the ground, then each cut-out bottom first, clipped to the disc, with its lift's shadow. The
    /// shadow's offset and blur are given at `shadowReference` pt and grow with the diameter; Core Graphics takes them in
    /// device pixels, whatever the transform. Core Graphics only, so it runs on any thread.
    private static func renderPaper(_ face: Quire.PaperFace, diameter: CGFloat, scale: CGFloat, dark: Bool) -> CGImage? {
        let pixels = Int((diameter * scale).rounded())
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let p = Quire.Layout.PaperFaces.self
        let art = art(face)
        let pixelsPerPoint = CGFloat(pixels) / diameter
        let rect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        context.scaleBy(x: pixelsPerPoint, y: pixelsPerPoint)
        context.addEllipse(in: rect)
        context.clip()
        context.setFillColor(paperColor(art.ground, dark: dark))
        context.fill(rect)
        let growth = diameter / p.shadowReference
        let shadow = QuireAvatarRenderer.cgColor(rgba: QuireDraw.rgba(hex: dark ? p.shadowDark : p.shadowLight))
        for layer in art.layers {
            context.saveGState()
            if layer.lift > 0, layer.lift < p.shadowY.count {
                // Base space is y-up in a bitmap context: a negative height falls below the paper.
                context.setShadow(offset: CGSize(width: 0, height: -p.shadowY[layer.lift] * growth * pixelsPerPoint),
                                  blur: p.shadowBlur[layer.lift] * growth * pixelsPerPoint, color: shadow)
            }
            // The art is y-down in its own square.
            context.translateBy(x: 0, y: diameter)
            context.scaleBy(x: diameter / p.artBox, y: -diameter / p.artBox)
            context.addPath(layer.path)
            context.setFillColor(paperColor(layer.paper, dark: dark))
            context.fillPath(using: .winding)
            context.restoreGState()
        }
        return context.makeImage()
    }

    /// Pixels a point in `context`: its backing scale on screen, the bitmap's in a snapshot. Rounded to a half so a
    /// rounding error in the transform never makes a new cache entry. Public for the surfaces whose face depends on it
    /// (the title menu's, §5.55).
    public static func deviceScale(of context: CGContext) -> CGFloat {
        let t = context.userSpaceToDeviceSpaceTransform
        let scale = (t.a * t.a + t.b * t.b).squareRoot()
        return min(4, max(1, (scale * 2).rounded() / 2))
    }

    /// Draws a paper face in the current context from the cache, in the drawing appearance's Light or Dark: what the rail,
    /// the list, the quick reply and the title menu do in `draw(_:)`, so scrolling draws a bitmap and never a path.
    @MainActor
    public static func drawPaperFace(_ face: Quire.PaperFace, in rect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let cg = context.cgContext
        let dark = QuireMode(NSAppearance.currentDrawing()).isDark
        guard let image = shared.paperFace(face, diameter: rect.width, scale: deviceScale(of: cg), dark: dark) else { return }
        cg.saveGState()
        if context.isFlipped {
            cg.translateBy(x: 0, y: rect.minY + rect.maxY)
            cg.scaleBy(x: 1, y: -1)
        }
        cg.interpolationQuality = .high
        cg.draw(image, in: rect)
        cg.restoreGState()
    }

    /// Draws an account's face in the current context: a paper face from the cache, a monogram as `drawAccountFace(monogram:
    /// slot:in:)` does.
    @MainActor
    public static func drawAccountFace(_ face: QuireAccountFace, slot: Int, in rect: NSRect) {
        switch face {
        case .monogram(let monogram): drawAccountFace(monogram: monogram, slot: slot, in: rect)
        case .paper(let paper): drawPaperFace(paper, in: rect)
        }
    }

    // MARK: Drawing in place

    /// Draws a sender's face synchronously in the current context: what a row shows until its cached face
    /// lands.
    @MainActor
    public static func drawFace(initials: String, tint: Quire.AvatarTint, in rect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let r = recipe(initials: initials, tint: tint, diameter: rect.width, appearance: NSAppearance.currentDrawing(), scale: 1)
        drawFace(r, in: rect, context: context.cgContext, flipped: context.isFlipped)
    }

    /// Draws an account face synchronously in the current context.
    @MainActor
    public static func drawAccountFace(monogram: String, slot: Int, in rect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        let r = accountRecipe(monogram: monogram, slot: slot, diameter: rect.width, appearance: NSAppearance.currentDrawing(), scale: 1)
        drawFace(r, in: rect, context: context.cgContext, flipped: context.isFlipped)
    }

    /// The square the ring reaches: the face grown by the 2 pt gap and the 2 pt ring (§4.7, `border.accountRing`).
    public static func ringBounds(around faceRect: NSRect) -> NSRect {
        let grow = Quire.Border.AccountRing.gap + Quire.Border.AccountRing.width
        return faceRect.insetBy(dx: -grow, dy: -grow)
    }

    /// Strokes the account ring around a face in the current context: a circle of radius face / 2 + gap +
    /// ring / 2, 2 pt wide, in the account ink. The gap is not drawn, so whatever fill is under the face (the
    /// row's `paper`, hover wash or selection) shows through, and one cached face serves every row state.
    @MainActor
    public static func drawRing(around faceRect: NSRect, color: NSColor) {
        let ring = Quire.Border.AccountRing.self
        let radius = faceRect.width / 2 + ring.gap + ring.width / 2
        let circle = NSRect(x: faceRect.midX - radius, y: faceRect.midY - radius, width: 2 * radius, height: 2 * radius)
        let path = NSBezierPath(ovalIn: circle)
        path.lineWidth = ring.width
        color.setStroke()
        path.stroke()
    }

    /// `drawRing(around:color:)` in the ink of account slot `slot`.
    @MainActor
    public static func drawRing(around faceRect: NSRect, accountSlot slot: Int) {
        drawRing(around: faceRect, color: .qAccount(slot))
    }
}
