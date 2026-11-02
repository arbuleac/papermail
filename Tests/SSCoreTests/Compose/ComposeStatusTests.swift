import XCTest
@testable import SSCore

final class ComposeStatusTests: XCTestCase {
    func testCopyMatchesTheSpec() {
        XCTAssertEqual(ComposeStatus.loadingOriginal.text, "Loading original message…")
        XCTAssertEqual(ComposeStatus.originalGone.text, "The original message is no longer available.")
        XCTAssertEqual(ComposeStatus.originalFailed.text, "Couldn't load the original message; it won't be quoted.")
        XCTAssertEqual(ComposeStatus.attachmentsFailed(count: 1).text, "One attachment couldn't be loaded.")
        XCTAssertEqual(ComposeStatus.attachmentsFailed(count: 2).text, "2 attachments couldn't be loaded.")
        XCTAssertEqual(ComposeStatus.saved.text, "Draft saved")
        XCTAssertEqual(ComposeStatus.saving.text, "Saving…")
        XCTAssertEqual(ComposeStatus.offline.text, "Will send when you're back online")
    }

    func testRejectedDropCopy() {
        let folder = ComposeStatus.rejectedDrop(.init(folders: ["Project Files"]))
        XCTAssertEqual(folder.text, "Folders can't be attached: “Project Files”.")
        XCTAssertNil(folder.tooltip)
        let file = ComposeStatus.rejectedDrop(.init(unreadable: ["budget.xlsx"]))
        XCTAssertEqual(file.text, "“budget.xlsx” couldn't be read, so it wasn't attached.")
        let several = ComposeStatus.rejectedDrop(.init(folders: ["A", "B"], unreadable: ["c.pdf"]))
        XCTAssertEqual(several.text, "3 items weren't attached: folders and unreadable files are skipped.")
        XCTAssertEqual(several.tooltip, "A\nB\nc.pdf")
    }

    func testGlyphsAndTones() {
        XCTAssertTrue(ComposeStatus.loadingOriginal.showsSpinner)
        XCTAssertEqual(ComposeStatus.originalGone.symbolName, "info.circle")
        XCTAssertEqual(ComposeStatus.originalGone.tone, .info)
        XCTAssertEqual(ComposeStatus.originalFailed.tone, .warning)
        XCTAssertEqual(ComposeStatus.saved.symbolName, "checkmark")
        XCTAssertNil(ComposeStatus.saving.symbolName)
        XCTAssertEqual(ComposeStatus.offline.symbolName, "wifi.slash")
    }

    func testANewerStatusReplacesAnOlderOne() {
        var board = ComposeStatusBoard()
        board.post(.originalGone)
        board.post(.saving)
        XCTAssertEqual(board.current, .saving)
        board.post(.saved)
        XCTAssertEqual(board.current, .saved)
    }

    func testWarningsStayUntilTheBodyIsEdited() {
        var board = ComposeStatusBoard()
        board.post(.rejectedDrop(.init(folders: ["X"])))
        board.post(.saving)
        board.post(.saved)
        XCTAssertEqual(board.current, .rejectedDrop(.init(folders: ["X"])))
        board.edited()
        XCTAssertEqual(board.current, .rejectedDrop(.init(folders: ["X"])))
        board.bodyEdited()
        XCTAssertNil(board.current)
        board.post(.saved)
        XCTAssertEqual(board.current, .saved)
    }

    func testANewWarningReplacesAHeldOne() {
        var board = ComposeStatusBoard()
        board.post(.originalFailed)
        board.post(.attachmentsFailed(count: 2))
        XCTAssertEqual(board.current, .attachmentsFailed(count: 2))
    }

    func testLoadingAndOfflineOutrankTheDraftsOwnStatus() {
        var board = ComposeStatusBoard()
        board.post(.loadingOriginal)
        board.post(.saved)
        XCTAssertEqual(board.current, .loadingOriginal)
        board.finishLoadingOriginal()
        XCTAssertEqual(board.current, .saved)
        board.setOffline(true)
        XCTAssertEqual(board.current, .offline)
        board.setOffline(false)
        XCTAssertEqual(board.current, .saved)
        board.edited()
        XCTAssertNil(board.current)
    }
}
