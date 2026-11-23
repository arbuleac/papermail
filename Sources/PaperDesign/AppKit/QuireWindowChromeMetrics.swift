import CoreGraphics

extension QuireWindowChrome {
    /// What the shell reads from a configured window, in points from the content view's top-leading corner.
    public struct Metrics: Equatable, Sendable {
        /// Where the close light starts (`lightsStart`, §3.2): its drawn edge, which can sit inside its button frame.
        public var lightsStart: CGFloat
        /// Where the zoom light ends (`lightsEnd`, §3.2): its drawn edge, which can sit inside its button frame.
        public var lightsEnd: CGFloat
        /// The close button's vertical centre (`lightsCenterY`): 26 on every supported release.
        public var lightsCenterY: CGFloat

        public init(lightsStart: CGFloat, lightsEnd: CGFloat, lightsCenterY: CGFloat) {
            self.lightsStart = lightsStart
            self.lightsEnd = lightsEnd
            self.lightsCenterY = lightsCenterY
        }

        /// The lights' horizontal centre, which the rail's tiles sit under.
        public var lightsCenterX: CGFloat { (lightsStart + lightsEnd) / 2 }

        /// The rail width these lights call for (`QuireWindowChrome.railWidth(lightsStart:lightsEnd:)`): the rail
        /// showing its tiles alone. With names it is `Quire.Layout.Rail.namesWidth`, whatever the lights.
        public var railWidth: CGFloat { QuireWindowChrome.railWidth(lightsStart: lightsStart, lightsEnd: lightsEnd) }

        /// The first x clear of the lights (`QuireWindowChrome.lightsClearX(lightsEnd:)`).
        public var lightsClearX: CGFloat { QuireWindowChrome.lightsClearX(lightsEnd: lightsEnd) }

        /// The title-bar zone: twice the lights' centre line (52 while the centre is 26).
        public var titlebarZone: CGFloat { (2 * lightsCenterY).rounded() }

        /// Where the masthead starts while the rail is hidden, and a reader window's kicker at the least: 8 pt past
        /// the lights' clear line, whatever the rail's width.
        public var mastheadMinimalX: CGFloat { lightsClearX + Quire.Layout.ListHeader.mastheadMinimalGap }
    }
}
