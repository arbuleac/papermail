import CoreGraphics

extension QuireWindowChrome {
    /// What the shell reads from a configured window, in points from the content view's top-leading corner.
    public struct Metrics: Equatable, Sendable {
        /// Where the zoom light ends (`lightsEnd`, §3.2): its drawn edge, which can sit inside its button frame.
        public var lightsEnd: CGFloat
        /// The close button's vertical centre (`lightsCenterY`): 26 on every supported release.
        public var lightsCenterY: CGFloat

        public init(lightsEnd: CGFloat, lightsCenterY: CGFloat) {
            self.lightsEnd = lightsEnd
            self.lightsCenterY = lightsCenterY
        }

        /// The rail width these lights call for (`QuireWindowChrome.railWidth(lightsEnd:)`).
        public var railWidth: CGFloat { QuireWindowChrome.railWidth(lightsEnd: lightsEnd) }

        /// The title-bar zone: twice the lights' centre line (52 while the centre is 26).
        public var titlebarZone: CGFloat { (2 * lightsCenterY).rounded() }

        /// Where the masthead starts while the rail is hidden: clear of the would-be rail by 8 pt.
        public var mastheadMinimalX: CGFloat { railWidth + Quire.Layout.ListHeader.mastheadMinimalGap }
    }
}
