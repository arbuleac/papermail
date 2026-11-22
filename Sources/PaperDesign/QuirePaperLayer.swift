import Foundation

/// One cut-out of a paper face (spec §5.55): its outline as SVG path data in the art's square (y down), the paper it is cut
/// from and its lift, 0 for a sheet glued flat, 1 laid on, 2 stood off on a foam dot. The lift picks the shadow under it.
public struct QuirePaperLayer: Equatable, Sendable {
    public let path: String
    public let paper: Quire.Paper
    public let lift: Int

    public init(path: String, paper: Quire.Paper, lift: Int) {
        self.path = path
        self.paper = paper
        self.lift = lift
    }
}
