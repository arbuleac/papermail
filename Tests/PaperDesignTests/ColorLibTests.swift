import XCTest
@testable import PaperDesign

/// Cross-checks the Swift port of colorlib.py (and the stack compositing of build.py) against values computed
/// by the python build itself, so the generated contrast and palette tests mean what the tuning meant.
/// Reference values: `B.ratio(...)`, `c.de_all(...)`, `c.simulate(...)`, `c.rgb2lab(...)` from
/// docs/design/source at Quire 1.3.0, rounded to 4 decimals; compared here at 2.
final class ColorLibTests: XCTestCase {
    override func setUp() {
        super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() {
        QuireTestEnvironment.reset()
        super.tearDown()
    }

    private func assertRatios(_ fg: [String], _ bg: [String], _ expected: [Double], file: StaticString = #filePath, line: UInt = #line) {
        for (mode, want) in zip(QuireMode.allCases, expected) {
            let got = TokenResolver.ratio(fg: fg, bg: bg, mode)
            XCTAssertEqual(got, want, accuracy: 0.005, "\(fg) on \(bg) [\(mode)]", file: file, line: line)
        }
    }

    func testContrastRatiosMatchPython() {
        assertRatios(["ink"], ["paper"], [16.4513, 14.2329, 18.817, 18.8615])
        assertRatios(["ink2"], ["paper", "hover", "fill"], [6.2134, 5.7696, 8.5207, 7.1342])
        assertRatios(["ink"], ["sheet", "fill", "pressed"], [12.6993, 7.9791, 12.4631, 7.5])
        assertRatios(["account:Lilac"], ["spine", "hover"], [3.2556, 10.7547, 3.5551, 10.6121])
        assertRatios(["account:Jade"], ["selWash"], [5.3015, 4.0524, 5.9567, 3.5223])
        assertRatios(["ink"], ["accountFace:Persimmon", "pressed"], [11.9129, 8.3562, 12.2537, 8.8226])
        assertRatios(["avatarInk:Wheat"], ["avatarFace:Wheat"], [6.0596, 8.1656, 7.8538, 8.4592])
        // A translucent foreground, composited over its background before the ratio.
        assertRatios(["onSlipEdge"], ["slip"], [3.969, 3.4269, 5.3632, 4.7373])
        // Graphite pairs, which name the substituted tokens.
        assertRatios(["ink"], ["selWashIdle"], [13.9047, 11.9968, 13.5577, 13.6982])
        assertRatios(["ink"], ["paper", "hover"], [15.0027, 12.4519, 16.3609, 15.017])
        assertRatios(["account:Persimmon"], ["selWashIdle"], [3.5142, 3.85, 3.7943, 4.4694])
    }

    func testColourDistancesMatchPython() {
        func check(_ a: String, _ b: String, _ want: [CVDKind: Double], file: StaticString = #filePath, line: UInt = #line) {
            let got = ColorLib.deAll(ColorLib.hex2rgba(a), ColorLib.hex2rgba(b))
            for (kind, value) in want {
                XCTAssertEqual(got[kind]!, value, accuracy: 0.005, "\(a) / \(b) \(kind)", file: file, line: line)
            }
        }
        // Persimmon / Fern and Indigo / Iris (light and Dark IC), Jade / Umber (light and Dark IC).
        check("#C6590D", "#60825C", [.normal: 41.0408, .protan: 14.0089, .deutan: 16.7409, .tritan: 45.1627])
        check("#E6732B", "#D3E5D0", [.normal: 40.4291, .protan: 31.748, .deutan: 27.0491, .tritan: 42.9099])
        check("#26365C", "#5C42B5", [.normal: 16.6906, .protan: 15.3212, .deutan: 14.6524, .tritan: 15.7829])
        check("#8E91B2", "#B797FF", [.normal: 14.6438, .protan: 13.5587, .deutan: 13.3496, .tritan: 13.7799])
        check("#006356", "#562B1C", [.normal: 40.3333, .protan: 16.4364, .deutan: 18.5021, .tritan: 45.9112])
        check("#589D89", "#BD8674", [.normal: 38.7137, .protan: 5.7395, .deutan: 13.1405, .tritan: 46.6133])
    }

    func testSimulationAndLabMatchPython() {
        let cases: [(String, [CVDKind: String], [Double])] = [
            ("#C6590D", [.protan: "#796A00", .deutan: "#938305", .tritan: "#DA3F4C"], [50.9009, 40.0608, 57.2777]),
            ("#027ECB", [.protan: "#5882CE", .deutan: "#3B72CA", .tritan: "#00919B"], [50.9714, -0.1559, -47.8056]),
            ("#1E5468", [.protan: "#495269", .deutan: "#3F4B68", .tritan: "#005A5A"], [33.1689, -10.6236, -16.7378]),
        ]
        for (hex, sims, lab) in cases {
            let c = ColorLib.hex2rgba(hex)
            for (kind, want) in sims { XCTAssertEqual(ColorLib.rgb2hex(ColorLib.simulate(c, kind)), want, "\(hex) \(kind)") }
            let got = ColorLib.rgb2lab(c)
            XCTAssertEqual(got.L, lab[0], accuracy: 0.0001)
            XCTAssertEqual(got.a, lab[1], accuracy: 0.0001)
            XCTAssertEqual(got.b, lab[2], accuracy: 0.0001)
        }
    }

    func testPaletteAnalysisMatchesPython() {
        // acct_analysis(): first-six minimum over all visions, ten-ink normal minimum, distances from accent,
        // danger (any vision), info and star, per mode.
        let expected: [QuireMode: [Double]] = [
            .light: [14.0089, 16.6906, 15.6737, 10.3844, 12.1619, 20.5569],
            .dark: [14.1706, 14.8851, 16.0484, 10.2237, 11.7353, 25.7493],
            .lightHC: [13.1321, 15.3289, 15.513, 10.3404, 10.2217, 17.5619],
            .darkHC: [13.3496, 13.167, 16.7295, 10.1228, 10.685, 23.8184],
        ]
        for (mode, want) in expected {
            let inks = PaletteMath.accountInks(mode)
            let got = [
                PaletteMath.closestPair(inks.prefix(6), kinds: CVDKind.allCases).distance,
                PaletteMath.closestPair(inks[...], kinds: [.normal]).distance,
                PaletteMath.closestTo("accent", mode: mode, kinds: [.normal]).distance,
                PaletteMath.closestTo("danger", mode: mode, kinds: CVDKind.allCases).distance,
                PaletteMath.closestTo("info", mode: mode, kinds: [.normal]).distance,
                PaletteMath.closestTo("star", mode: mode, kinds: [.normal]).distance,
            ]
            for (g, w) in zip(got, want) { XCTAssertEqual(g, w, accuracy: 0.005, "\(mode)") }
        }
    }

    func testCompositingIsGammaSpaceOver() {
        // hover over paper, light: #1D1B18 at 0x0C over #FBFAF6, written out by hand.
        let paper = ColorLib.hex2rgba("#FBFAF6")
        let hover = ColorLib.hex2rgba("#1D1B180C")
        let c = ColorLib.over(hover, paper)
        let a = 12.0 / 255
        XCTAssertEqual(c.r, (29.0 / 255) * a + (251.0 / 255) * (1 - a), accuracy: 1e-12)
        XCTAssertEqual(c.a, 1)
        XCTAssertEqual(ColorLib.stack([paper, hover]), c)
    }
}
