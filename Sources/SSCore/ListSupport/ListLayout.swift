import Foundation

/// The rows the message list table shows: conversations, the running heads between them (spec §5.8) and the
/// paging footer at the end (spec §5.10). Built once per refresh from the summaries' dates, without AppKit, so
/// the grouping can be tested and timed on its own.
///
/// Conversations keep their own index space (`conversations[i]` in the caller); the layout maps between those
/// indices and table rows, so j/k, selection restore and next-unread work on conversations and simply never
/// land on a head or the footer.
public struct ListLayout: Sendable {
    public enum Item: Hashable, Sendable {
        case head(RunningHead)
        /// An index into the conversations the layout was built from.
        case conversation(Int)
        case footer
    }

    /// A row's identity across refreshes, for `ListDiff`: a head is the same row as long as its group exists.
    public enum ItemID: Hashable, Sendable {
        case head(RunningHead)
        case conversation(ConversationID)
        case footer
    }

    public let items: [Item]
    /// Table row of each conversation, parallel to the conversations.
    public let rowOfConversation: [Int]
    /// How each conversation writes its time: its head's style, or `.relative` when heads are hidden.
    public let timeStyles: [DateFormatting.Style]
    public let showsHeads: Bool

    public var rowCount: Int { items.count }

    public static let empty = ListLayout(items: [], rowOfConversation: [], timeStyles: [], showsHeads: false)

    public init(items: [Item], rowOfConversation: [Int], timeStyles: [DateFormatting.Style], showsHeads: Bool) {
        self.items = items
        self.rowOfConversation = rowOfConversation
        self.timeStyles = timeStyles
        self.showsHeads = showsHeads
    }

    /// Groups `dates` (newest first, as the store orders them) under running heads when `showsHeads`, and ends
    /// the rows with the footer when `showsFooter`. A head is emitted once, where its group starts; a date out
    /// of order (a row that moved while sync ran) stays under the head already open rather than opening a
    /// second copy of an earlier one.
    public static func make(
        dates: [Date],
        showsHeads: Bool,
        showsFooter: Bool,
        reference: DateFormatting.Reference,
        formatter: DateFormatting
    ) -> ListLayout {
        var items: [Item] = []
        items.reserveCapacity(dates.count + (showsHeads ? 8 : 0) + 1)
        var rows: [Int] = []
        rows.reserveCapacity(dates.count)
        var styles: [DateFormatting.Style] = []
        styles.reserveCapacity(dates.count)

        if showsHeads {
            var emitted: Set<RunningHead> = []
            var current: RunningHead?
            // Month heads need the calendar; a sorted list crosses a month boundary rarely, so the interval of
            // the month being walked is kept and the calendar is asked again only once a date leaves it.
            var month: (interval: DateInterval, head: RunningHead)?
            for (index, date) in dates.enumerated() {
                let head: RunningHead
                if date >= reference.startOfLastWeek {
                    head = formatter.runningHead(for: date, reference: reference)
                } else if let cached = month, cached.interval.contains(date) {
                    head = cached.head
                } else {
                    head = formatter.runningHead(for: date, reference: reference)
                    if let interval = formatter.monthInterval(containing: date) { month = (interval, head) }
                }
                if head != current, emitted.insert(head).inserted {
                    items.append(.head(head))
                    current = head
                }
                rows.append(items.count)
                items.append(.conversation(index))
                styles.append((current ?? head).timeStyle)
            }
        } else {
            for index in dates.indices {
                rows.append(items.count)
                items.append(.conversation(index))
                styles.append(.relative)
            }
        }
        if showsFooter { items.append(.footer) }
        return ListLayout(items: items, rowOfConversation: rows, timeStyles: styles, showsHeads: showsHeads)
    }

    /// The conversation index shown at `row`, or nil for a head, the footer or a row out of range.
    public func conversationIndex(atRow row: Int) -> Int? {
        guard items.indices.contains(row), case .conversation(let index) = items[row] else { return nil }
        return index
    }

    public func row(ofConversation index: Int) -> Int? {
        rowOfConversation.indices.contains(index) ? rowOfConversation[index] : nil
    }

    /// Row identities for diffing, given the conversation ids the layout was built from.
    public func itemIDs(conversationIDs: [ConversationID]) -> [ItemID] {
        items.map { item in
            switch item {
            case .head(let head): return .head(head)
            case .conversation(let index): return .conversation(conversationIDs[index])
            case .footer: return .footer
            }
        }
    }

    public var footerRow: Int? {
        guard case .footer? = items.last else { return nil }
        return items.count - 1
    }
}
