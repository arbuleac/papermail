import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// Renders every row state of spec §5.7–5.10 with the app's own row views, laid out like the specimen's
/// Conversation row card, in light and dark: `dist/apply-list-states-light.png` and `-dark.png`. The main
/// window snapshot (`--snapshot`) only shows the states the demo mailbox happens to have; this shows the rest
/// (hover, idle and multi-selection, failed, queued, initials, Drafts, Sent, compact, heads, footer, scripts,
/// empty states). Opt-in, because it writes files: `SS_UI_TESTS=1 swift test --filter ConversationRowStatesRenderTests`.
@MainActor
final class ConversationRowStatesRenderTests: XCTestCase {
    private let width: CGFloat = 380
    private let formatter = DateFormatting(locale: Locale(identifier: "en_GB"))
    private lazy var reference = formatter.reference()
    private let account = ListTestSupport.accountA.id

    func testRenderRowStates() throws {
        guard ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1" else {
            throw XCTSkip("set SS_UI_TESTS=1 to render the row states")
        }
        let dist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("dist", isDirectory: true)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        // Light and dark are the review boards; Increase Contrast and Graphite check the same states under the
        // token substitutions (spec §3.1, §3.3), which the window snapshot cannot be asked for.
        let environment = QuireEnvironment.shared
        let saved = environment.overrides
        defer { environment.setOverrides(saved) }
        let variants: [(mode: QuireMode, graphite: Bool, name: String)] = [
            (.light, false, "light"), (.dark, false, "dark"), (.lightHC, false, "lightHC"), (.darkHC, false, "darkHC"),
            (.light, true, "graphite-light"), (.dark, true, "graphite-dark"),
        ]
        for variant in variants {
            var overrides = saved
            overrides.isGraphite = variant.graphite
            environment.setOverrides(overrides)
            let board = makeBoard(mode: variant.mode)
            // The footer's spinner and words appear only after their 150 ms delay.
            ListTestSupport.spin(for: 0.4)
            let bitmap = try XCTUnwrap(QuireOffscreenRenderer.render(mode: variant.mode, scale: 2) { board })
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: dist.appendingPathComponent("apply-list-states-\(variant.name).png"))
        }
    }

    // MARK: Board

    private func makeBoard(mode: QuireMode) -> NSView {
        let columns: [[NSView]] = [
            [label("Read · unread · hover · selected · selected (window not key) · multi-selection · no subject")] + columnOne(),
            [label("Starred · attachment · count · queued · failed · initials · Drafts · Sent")] + columnTwo(),
            [label("Compact density · square account mark · with initials on, the tile replaces the square")] + columnThree()
                + [label("Running heads · hidden in search and in views under 8 conversations")] + headsCard()
                + [label("Scripts New York lacks fall back to subjectSans; line height stays 18 pt")] + scriptsCard(),
            [label("List tail · loading and failed")] + footerCard() + [label("Empty states (spec §5.9)")] + emptyCard(),
        ]
        let gap: CGFloat = 24
        let height = columns.map { $0.reduce(0) { $0 + $1.frame.height } + CGFloat($0.count) * 8 }.max() ?? 0
        let board = BoardView(frame: NSRect(x: 0, y: 0, width: gap + CGFloat(columns.count) * (width + gap), height: height + 2 * gap))
        var x = gap
        for column in columns {
            var y = gap
            for view in column {
                view.setFrameOrigin(NSPoint(x: x, y: y))
                board.addSubview(view)
                y += view.frame.height + 8
            }
            x += width + gap
        }
        return board
    }

    private func columnOne() -> [NSView] {
        let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")
        let rachel = EmailAddress(name: "Rachel Kim", address: "rachel@contoso.test")
        let rows: [RowSpec] = [
            RowSpec(summary(sender: "Diego Alvarez", subject: "Photos from the offsite", snippet: "Of course. Group shot coming tomorrow.",
                            minutesAgo: 400), slot: 1),
            RowSpec(summary(sender: "Priya Raman", subject: "Lisbon in March?", snippet: "Booked the flat near Príncipe Real.",
                            minutesAgo: 90, unread: true), slot: 2),
            RowSpec(summary(sender: "Theo Nakamura", subject: "Heads up", snippet: "Do you have ten minutes this afternoon?", minutesAgo: 600),
                    slot: 2, hovered: true),
            RowSpec(summary(participants: [ben, EmailAddress(name: "Alex Morgan", address: "alex@contoso.test"),
                                           EmailAddress(name: "Tom Hughes", address: "tom@contoso.test")],
                            subject: "Contoso rollout: go-live checklist", snippet: "Tested with three accounts, all good.",
                            minutesAgo: 20, unread: true, count: 4), latest: ben, slot: 0, selected: true, key: true),
            RowSpec(summary(participants: [ben], subject: "Contoso rollout: go-live checklist", snippet: "Tested with three accounts, all good.",
                            minutesAgo: 20, unread: true, count: 4, starred: true), latest: ben, slot: 0, selected: true, key: false),
            RowSpec(summary(participants: [rachel], subject: "Q4 roadmap review", snippet: "Great work. One comment on offline mode.",
                            minutesAgo: 380, count: 2, attachment: true), slot: 0, selected: true, key: true),
            RowSpec(summary(participants: [rachel], subject: "", snippet: "Sending the photos from Friday.", minutesAgo: 450, unread: true),
                    slot: 0),
        ]
        return [card(rows)]
    }

    private func columnTwo() -> [NSView] {
        let me = EmailAddress(name: "Alex Morgan", address: "alex@contoso.test")
        let rows: [RowSpec] = [
            RowSpec(summary(sender: "Linda Morgan", subject: "Sunday dinner", snippet: "Ha, noted. I will bring the plum cake.",
                            minutesAgo: 200, count: 4, starred: true, attachment: true, pending: true), slot: 1),
            RowSpec(summary(sender: "Forge", subject: "[sparrow-sync] PR #2657", snippet: "maya-c commented: one nit about the retry budget.",
                            minutesAgo: 60, failed: .archive), slot: 2),
            RowSpec(summary(sender: "Northwind Weekly", subject: "Issue #182: Quiet software", snippet: "This week: the case for fewer notifications.",
                            minutesAgo: 900, other: true), slot: 1),
            RowSpec(summary(sender: "Calendar", subject: "Accepted: Design review @ Thu 15:30", snippet: "Room: Juniper (4th floor)",
                            minutesAgo: 700, other: true), slot: 0, initials: true),
            RowSpec(summary(participants: [me], subject: "Re: Contoso rollout", snippet: "Thanks for running the checks. I have forwarded the runbook.",
                            minutesAgo: 10), slot: 0, unified: false, kind: .draft,
                    recipients: [EmailAddress(name: "Ben Carter", address: "ben@contoso.test")]),
            RowSpec(summary(participants: [me], subject: "Lisbon in March?", snippet: "Count me in for the weekend, I will book the train.",
                            minutesAgo: 70, attachment: true), slot: 0, unified: false, kind: .sent,
                    recipients: [EmailAddress(name: "Priya Raman", address: "priya@contoso.test")]),
        ]
        return [card(rows)]
    }

    private func columnThree() -> [NSView] {
        let rows: [RowSpec] = [
            RowSpec(summary(sender: "Priya Raman", subject: "Lisbon in March?", snippet: "Booked the flat near Príncipe Real.", minutesAgo: 90,
                            unread: true, count: 3, starred: true), slot: 1, density: .compact),
            RowSpec(summary(sender: "Ben Carter, Alex Morgan", subject: "Contoso rollout: go-live checklist",
                            snippet: "Tested with three accounts.", minutesAgo: 20, count: 4, attachment: true), slot: 0, selected: true,
                    key: true, density: .compact),
            RowSpec(summary(sender: "Forge", subject: "[sparrow-sync] PR #2657", snippet: "maya-c commented.", minutesAgo: 60), slot: 2,
                    initials: true, density: .compact),
        ]
        var views: [NSView] = []
        let container = CardView(frame: .zero)
        var y: CGFloat = 0
        for (index, spec) in rows.enumerated() {
            let row = makeRow(spec, nextSelected: index + 1 < rows.count && rows[index + 1].selected)
            row.setFrameOrigin(NSPoint(x: 0, y: y))
            container.addSubview(row)
            y += row.frame.height
        }
        let head = makeHead(.lastWeek, density: .compact)
        head.setFrameOrigin(NSPoint(x: 0, y: y))
        container.addSubview(head)
        y += head.frame.height
        let skeleton = ListSkeletonView(frame: NSRect(x: 0, y: y, width: width, height: Quire.Layout.RowCompact.height))
        skeleton.density = .compact
        container.addSubview(skeleton)
        y += skeleton.frame.height
        let footer = makeFooter(.loading)
        footer.setFrameOrigin(NSPoint(x: 0, y: y))
        container.addSubview(footer)
        y += footer.frame.height
        container.setFrameSize(NSSize(width: width, height: y))
        views.append(container)
        return views
    }

    private func headsCard() -> [NSView] {
        let container = CardView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        var y: CGFloat = 0
        for head in [RunningHead.earlierThisWeek, .month(year: reference.year, month: 10), .month(year: reference.year - 1, month: 10)] {
            let view = makeHead(head, density: .standard)
            view.setFrameOrigin(NSPoint(x: 0, y: y))
            container.addSubview(view)
            y += view.frame.height
        }
        container.setFrameSize(NSSize(width: width, height: y))
        return [container]
    }

    private func scriptsCard() -> [NSView] {
        let samples: [(String, String, String)] = [
            ("Kenji Sato", "来週の打ち合わせについて", "資料を添付しました。ご確認ください。"),
            ("Layla Haddad", "اجتماع الفريق يوم الخميس", "سأرسل جدول الأعمال قبل الاجتماع."),
            ("Somchai P.", "สรุปการประชุมประจำสัปดาห์", "รายละเอียดอยู่ในไฟล์แนบ"),
            ("Anika Rao", "साप्ताहिक बैठक का सारांश", "कृपया संलग्न दस्तावेज़ देखें।"),
            ("Olga Petrova", "Встреча в четверг", "Повестка во вложении."),
        ]
        let rows = samples.enumerated().map { index, sample in
            RowSpec(summary(sender: sample.0, subject: sample.1, snippet: sample.2, minutesAgo: 300 + Double(index) * 20), slot: 0, unified: false)
        }
        return [card(rows)]
    }

    private func footerCard() -> [NSView] {
        let container = CardView(frame: NSRect(x: 0, y: 0, width: width, height: 2 * Quire.Layout.ListFooter.height + 1))
        let loading = makeFooter(.loading)
        container.addSubview(loading)
        let failed = makeFooter(.failed)
        failed.setFrameOrigin(NSPoint(x: 0, y: Quire.Layout.ListFooter.height + 1))
        container.addSubview(failed)
        return [container]
    }

    private func emptyCard() -> [NSView] {
        let states: [(String, String, QuireEmptyStateView.Glyph?)] = [
            ("Nothing left to read.", "New mail will land here.", .brandMark),
            ("No starred conversations", "Press S to star one.", nil),
            ("No results for “lisbon flat”", "Search looks at subjects, people and message text.", nil),
            ("You're offline", "Mail will appear when you reconnect.", .offline),
        ]
        return states.map { sentence, hint, glyph in
            let container = CardView(frame: NSRect(x: 0, y: 0, width: width, height: 170))
            let view = QuireEmptyStateView(sentence: sentence, hint: hint, glyph: glyph)
            view.frame = container.bounds
            container.addSubview(view)
            return container
        }
    }

    // MARK: Rows

    private struct RowSpec {
        var summary: ConversationSummary
        var latest: EmailAddress?
        var slot: Int
        var unified = true
        var hovered = false
        var selected = false
        var key = true
        var initials = false
        var density = AppSettings.ListDensity.standard
        var kind = ConversationRowText.Kind.received
        var recipients: [EmailAddress] = []

        init(_ summary: ConversationSummary, latest: EmailAddress? = nil, slot: Int, unified: Bool = true, hovered: Bool = false,
             selected: Bool = false, key: Bool = true, initials: Bool = false,
             density: AppSettings.ListDensity = .standard, kind: ConversationRowText.Kind = .received, recipients: [EmailAddress] = []) {
            self.summary = summary
            self.latest = latest
            self.slot = slot
            self.unified = unified
            self.hovered = hovered
            self.selected = selected
            self.key = key
            self.initials = initials
            self.density = density
            self.kind = kind
            self.recipients = recipients
        }
    }

    private func card(_ rows: [RowSpec]) -> NSView {
        let container = CardView(frame: .zero)
        var y: CGFloat = 0
        for (index, spec) in rows.enumerated() {
            let row = makeRow(spec, nextSelected: index + 1 < rows.count && rows[index + 1].selected)
            row.setFrameOrigin(NSPoint(x: 0, y: y))
            container.addSubview(row)
            y += row.frame.height
        }
        container.setFrameSize(NSSize(width: width, height: y))
        return container
    }

    private func makeRow(_ spec: RowSpec, nextSelected: Bool) -> NSView {
        let metrics = QuireRowMetrics(textSize: .default, compact: spec.density == .compact)
        let row = ConversationRowView(frame: NSRect(x: 0, y: 0, width: width, height: metrics.height))
        row.metrics = metrics
        row.isSelected = spec.selected
        row.isNextRowSelected = nextSelected
        row.windowKeyOverride = spec.key
        row.isHovered = spec.hovered
        let context = ConversationRowText.Context(
            kind: spec.kind,
            timeStyle: .timeOfDay,
            ownAddresses: ["alex@contoso.test"],
            latestSender: spec.latest,
            recipients: spec.recipients,
            accountName: "Contoso"
        )
        let text = ConversationRowText(summary: spec.summary, reference: reference, formatter: formatter, context: context)
        let cell = ConversationCellView(frame: row.bounds)
        let initial = ["C", "G", "F"][spec.slot % 3]
        cell.configure(with: ConversationRowContent(text: text),
                       mark: ConversationCellView.AccountMark(inkSlot: spec.slot, initial: initial, isUnified: spec.unified, showsInitial: spec.initials),
                       metrics: metrics)
        row.addSubview(cell)
        return row
    }

    private func makeHead(_ head: RunningHead, density: AppSettings.ListDensity) -> NSView {
        let height = density == .compact ? Quire.Layout.RunningHead.compactHeight : Quire.Layout.RunningHead.height
        let view = RunningHeadRowView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.title = RunningHeadRowView.title(formatter.title(for: head, reference: reference))
        view.density = density
        return view
    }

    private func makeFooter(_ phase: ListFooterRowView.Phase) -> NSView {
        let footer = ListFooterRowView(frame: NSRect(x: 0, y: 0, width: width, height: Quire.Layout.ListFooter.height))
        footer.phase = phase
        return footer
    }

    private func summary(sender: String? = nil, participants: [EmailAddress]? = nil, subject: String, snippet: String, minutesAgo: Double,
                         unread: Bool = false, count: Int = 1, starred: Bool = false, attachment: Bool = false, pending: Bool = false,
                         failed: OperationKind? = nil, other: Bool = false) -> ConversationSummary {
        let people = participants ?? [EmailAddress(name: sender, address: (sender ?? "x").lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com")]
        let id = "row-\(subject.hashValue)-\(minutesAgo)"
        return ConversationSummary(
            id: ConversationID(accountID: account, providerID: id),
            subject: subject,
            snippet: snippet,
            participants: people,
            latestDate: reference.now.addingTimeInterval(-minutesAgo * 60),
            messageCount: count,
            unreadCount: unread ? 1 : 0,
            isStarred: starred,
            hasAttachments: attachment,
            inInbox: true,
            inboxSection: other ? .other : .focused,
            latestMessageID: MessageID(accountID: account, providerID: id + "-m"),
            hasPendingOperations: pending,
            failedOperation: failed
        )
    }

    private func label(_ text: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = QuireFont.font(.meta)
        field.textColor = .qInk3
        field.preferredMaxLayoutWidth = width
        field.frame = NSRect(x: 0, y: 0, width: width, height: 30)
        return field
    }

    /// The page behind the cards: `canvas`, as the specimen sets its cards on.
    private final class BoardView: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.qCanvas.setFill()
            bounds.fill()
        }
    }

    /// A card: `paper` with a `rule` edge, the list's own surface.
    private final class CardView: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.qPaper.setFill()
            bounds.fill()
        }
    }
}
