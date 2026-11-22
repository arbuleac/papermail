import AppKit
@testable import PaperDesign

/// The account-palette analysis of `acct_analysis()` in docs/design/source/build.py, over the runtime inks.
enum PaletteMath {
    struct Closest {
        let distance: Double
        let label: String
    }

    static func accountInks(_ mode: QuireMode) -> [(name: String, color: RGBA)] {
        Quire.AccountInk.allCases.map { ($0.name, TokenResolver.rgba($0.color, mode)) }
    }

    /// The smallest CIEDE2000 between any two inks, over the given visions.
    static func closestPair(_ inks: ArraySlice<(name: String, color: RGBA)>, kinds: [CVDKind]) -> Closest {
        let labs = inks.map { ColorLib.cvdLab($0.color) }
        let names = inks.map(\.name)
        var best = Closest(distance: .infinity, label: "")
        for i in 0..<labs.count {
            for j in (i + 1)..<labs.count {
                for kind in kinds {
                    let d = ColorLib.de2000(labs[i][kind]!, labs[j][kind]!)
                    if d < best.distance { best = Closest(distance: d, label: "\(names[i]) / \(names[j]) (\(kind.rawValue)) \(String(format: "%.2f", d))") }
                }
            }
        }
        return best
    }

    /// The smallest CIEDE2000 between any ink and the colour token `token`, over the given visions.
    static func closestTo(_ token: String, mode: QuireMode, kinds: [CVDKind]) -> Closest {
        let reference = TokenResolver.resolve(token, mode)
        var best = Closest(distance: .infinity, label: "")
        for ink in accountInks(mode) {
            let d = ColorLib.deAll(ink.color, reference)
            for kind in kinds where d[kind]! < best.distance {
                best = Closest(distance: d[kind]!, label: "\(ink.name) vs \(token) (\(kind.rawValue)) \(String(format: "%.2f", d[kind]!))")
            }
        }
        return best
    }
}
