import SSCore
import SSDesign

/// What each account's face draws (Quire §5.55): the stored choice resolved for the design layer, which knows the faces.
/// Nothing chosen, or a face the art no longer has, is the paper face the account's ink slot picks; Monogram is the letters
/// `AccountLabels` derives, or the ones the user typed.
enum AccountFaces {
    static func face(for account: Account, monogram: String) -> QuireAccountFace {
        switch account.face {
        case .monogram:
            return .monogram(monogram)
        case .paper(let id):
            return .paper(Quire.PaperFace(rawValue: id) ?? .automatic(forSlot: account.inkSlot))
        case .automatic:
            return .paper(.automatic(forSlot: account.inkSlot))
        }
    }

    /// Every account's face, its monogram worked out among `accounts` as the rail shows them.
    static func faces(for accounts: [Account]) -> [AccountID: QuireAccountFace] {
        let monograms = AccountLabels.monograms(for: accounts)
        return Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, face(for: $0, monogram: monograms[$0.id] ?? "?")) })
    }

    /// The choice a face picker tile stands for: a paper face, or the monogram.
    static func choice(_ face: QuireAccountFace) -> AccountFace {
        switch face {
        case .monogram: return .monogram
        case .paper(let paper): return .paper(paper.rawValue)
        }
    }
}
