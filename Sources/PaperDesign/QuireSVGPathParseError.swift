extension QuireSVGPath {
    /// Why path data could not be read, and where.
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let message: String
        /// Byte offset into the path data.
        public let offset: Int

        public init(message: String, offset: Int) {
            self.message = message
            self.offset = offset
        }

        public var description: String { "SVG path: \(message) at \(offset)" }
    }
}
