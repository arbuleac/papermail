import Foundation

/// What an account's face shows (spec §5.55, §4.2): one of the paper faces, or its letter monogram. A plain value, so
/// SSDesign never sees the mail model: the app resolves the account's stored choice (automatic included) into one of these.
public enum QuireAccountFace: Hashable, Sendable {
    /// The monogram, one or two letters, on the account ink's face wash, as before paper faces.
    case monogram(String)
    case paper(Quire.PaperFace)
}

extension Quire.PaperFace {
    /// The face an account wears until its user chooses one: the faces in order by ink slot, so the ten slots wear ten
    /// different faces and an account keeps its face when another is added or removed.
    public static func automatic(forSlot slot: Int) -> Quire.PaperFace {
        let faces = allCases
        return faces[((slot % faces.count) + faces.count) % faces.count]
    }
}
