import Foundation

/// One message of a demo mailbox: metadata as a provider would report it plus the body it serves.
struct DemoRecord: Sendable {
    var metadata: MessageMetadata
    var body: MessageBody
}

/// Generates a demo mailbox: the same threads, people and flags for a given profile and seed, with dates laid
/// out over the 60 days before `reference`.
struct DemoMailboxBuilder {
    static let photoAttachmentID = "att-photo-sunset"
    static let photoContentID = "offsite-sunset@demo.test"
    static let invoiceAttachmentID = "att-invoice-2041"
    static let historyDays = 60

    let profile: DemoProfile
    let accountID: AccountID
    let reference: Date

    private var random: DemoRandom
    private var records: [DemoRecord] = []
    private var threadCounter = 0
    private var messageCounter = 0

    init(profile: DemoProfile, accountID: AccountID, reference: Date) {
        self.profile = profile
        self.accountID = accountID
        self.reference = reference
        self.random = DemoRandom(seed: profile.seed)
    }

    var isGmail: Bool { profile.kind == .gmail }

    // MARK: Ids

    func messageProviderID(_ n: Int) -> String {
        isGmail ? String(format: "18c%013x", 0x4a1_0000 + n) : String(format: "AAMkADemo%06d", n)
    }

    func threadProviderID(_ n: Int) -> String {
        isGmail ? String(format: "18b%013x", 0x2f0_0000 + n) : String(format: "AAQkADemo%06d", n)
    }

    // MARK: Build

    mutating func build() -> [DemoRecord] {
        let scripts = isGmail ? DemoCatalog.gmailScripts : DemoCatalog.outlookScripts
        let letters = isGmail ? DemoCatalog.gmailNewsletters : DemoCatalog.outlookNewsletters
        let families = isGmail ? DemoCatalog.gmailNotifications : DemoCatalog.outlookNotifications
        let people = isGmail ? DemoCatalog.gmailPeople : DemoCatalog.outlookPeople

        // Scripted threads are spread over the whole window, a few of them very recent so the inbox opens on them.
        for (index, script) in scripts.enumerated() {
            let day = index < 3 ? Double(index) * 0.6 : random.unit() * Double(Self.historyDays - 5)
            addScript(script, startDaysAgo: day, style: quoteStyle(for: script))
        }
        // Newsletters arrive weekly, on a fixed weekday per sender.
        for (letterIndex, letter) in letters.enumerated() {
            for week in 0..<9 {
                let daysAgo = Double(week * 7 + letterIndex * 2) + 0.3
                guard daysAgo < Double(Self.historyDays) else { continue }
                addNewsletter(letter, issue: 120 + (8 - week), daysAgo: daysAgo)
            }
        }
        var toggle = false
        while records.count < profile.messageCount {
            let remaining = profile.messageCount - records.count
            toggle.toggle()
            if toggle {
                addNotificationThread(random.pick(families), maxLength: remaining)
            } else {
                addShortThread(people: people, maxLength: remaining)
            }
        }
        return records
    }

    /// Older mail that lives only on the demo's server (`DemoCatalog.gmailArchiveScripts`): a year and more back,
    /// archived, never listed by the download, found only by a search of the server (spec §5.10). Call it after
    /// `build()` on the same builder, so its ids carry on from the mailbox's and never collide with them.
    mutating func buildArchive() -> [DemoRecord] {
        let scripts = isGmail ? DemoCatalog.gmailArchiveScripts : DemoCatalog.outlookArchiveScripts
        let mailbox = records
        records = []
        defer { records = mailbox }
        for (index, script) in scripts.enumerated() {
            addScript(script, startDaysAgo: 400 + Double(index) * 120, style: quoteStyle(for: script), inInbox: false)
        }
        return records
    }

    private func quoteStyle(for script: DemoCatalog.Script) -> DemoHTML.QuoteStyle {
        let outlookPeople: Set<String> = [DemoCatalog.theo.address]
        let gmailPeople: Set<String> = [DemoCatalog.ben.address, DemoCatalog.sophie.address]
        if isGmail { return script.people.contains { outlookPeople.contains($0.address) } ? .outlook : .gmail }
        return script.people.contains { gmailPeople.contains($0.address) } ? .gmail : .outlook
    }

    // MARK: Dates and flags

    /// Message dates for a thread starting `daysAgo` before the reference, nudged back if it would run into
    /// the future.
    private mutating func dates(count: Int, startDaysAgo daysAgo: Double) -> [Date] {
        let dayStart = reference.addingTimeInterval(-daysAgo * 86_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var first = calendar.startOfDay(for: dayStart).addingTimeInterval(Double(random.int(7 * 60...21 * 60)) * 60)
        if daysAgo < 1 { first = dayStart }
        var result = [first]
        for _ in 1..<max(count, 1) {
            let gap = random.chance(0.7) ? Double(random.int(8...180)) * 60 : Double(random.int(4...30)) * 3_600
            result.append(result.last!.addingTimeInterval(gap))
        }
        let latestAllowed = reference.addingTimeInterval(-Double(random.int(2...40)) * 60)
        if let last = result.last, last > latestAllowed {
            let shift = last.timeIntervalSince(latestAllowed)
            result = result.map { $0.addingTimeInterval(-shift) }
        }
        return Array(result.prefix(count))
    }

    private mutating func isRead(date: Date, fromMe: Bool, bulk: Bool) -> Bool {
        if fromMe { return true }
        let age = reference.timeIntervalSince(date) / 86_400
        if age < 1.5 { return !random.chance(bulk ? 0.5 : 0.6) }
        if age < 7 { return !random.chance(bulk ? 0.3 : 0.2) }
        return !random.chance(0.03)
    }

    private mutating func staysInInbox(latest: Date) -> Bool {
        let age = reference.timeIntervalSince(latest) / 86_400
        if age < 8 { return true }
        if age < 25 { return random.chance(0.45) }
        return random.chance(0.2)
    }

    // MARK: Records

    private mutating func nextIDs() -> (MessageID, String) {
        messageCounter += 1
        let providerID = messageProviderID(messageCounter)
        return (MessageID(accountID: accountID, providerID: providerID), "<\(providerID).\(profile.seed)@mail.\(isGmail ? "demo-gmail" : "demo-outlook").test>")
    }

    private mutating func nextConversation() -> ConversationID {
        threadCounter += 1
        return ConversationID(accountID: accountID, providerID: threadProviderID(threadCounter))
    }

    private func labels(roles: Set<MailboxRole>, read: Bool, starred: Bool, section: InboxSection, bulk: Bool) -> (labels: [String], folder: String?) {
        if isGmail {
            var labels: [String] = []
            if roles.contains(.inbox) { labels.append("INBOX") }
            if roles.contains(.sent) { labels.append("SENT") }
            if !read { labels.append("UNREAD") }
            if starred { labels.append("STARRED") }
            if !roles.contains(.sent) {
                labels.append(section == .focused ? "CATEGORY_PERSONAL" : (bulk ? "CATEGORY_PROMOTIONS" : "CATEGORY_UPDATES"))
            }
            return (labels, nil)
        }
        let folder = roles.contains(.sent) ? "sentitems" : (roles.contains(.inbox) ? "inbox" : "archive")
        return ([], folder)
    }

    private mutating func append(
        id: MessageID,
        internetID: String,
        conversation: ConversationID,
        subject: String,
        from: EmailAddress,
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        date: Date,
        inInbox: Bool,
        read: Bool,
        starred: Bool,
        section: InboxSection,
        bulk: Bool,
        previous: [String],
        html: String,
        text: String,
        attachments: [AttachmentInfo],
        listUnsubscribe: String? = nil
    ) {
        let fromMe = from.address == profile.email
        var roles: Set<MailboxRole> = []
        if fromMe { roles.insert(.sent) } else if inInbox { roles.insert(.inbox) }
        let flags = labels(roles: roles, read: read, starred: starred, section: section, bulk: bulk)
        let newText = text.components(separatedBy: "\n\nOn ").first ?? text
        let snippet = String(newText.replacingOccurrences(of: "\n", with: " ").prefix(160))
        let metadata = MessageMetadata(
            id: id,
            conversationID: conversation,
            internetMessageID: internetID,
            inReplyTo: previous.last,
            references: previous,
            subject: subject,
            snippet: snippet,
            from: from,
            to: to,
            cc: cc,
            date: date,
            roles: roles,
            isRead: read,
            isStarred: starred,
            inboxSection: fromMe ? .unknown : section,
            hasAttachments: !attachments.isEmpty,
            labelIDs: flags.labels,
            folderID: flags.folder,
            providerVersion: "1",
            sizeBytes: html.utf8.count + attachments.reduce(0) { $0 + $1.sizeBytes },
            listUnsubscribe: listUnsubscribe,
            listUnsubscribePost: listUnsubscribe == nil ? nil : UnsubscribeMethod.oneClickPostValue
        )
        records.append(DemoRecord(metadata: metadata, body: MessageBody(html: html, text: text, attachments: attachments)))
    }

    private mutating func addScript(_ script: DemoCatalog.Script, startDaysAgo: Double, style: DemoHTML.QuoteStyle,
                                    inInbox forcedInbox: Bool? = nil) {
        let conversation = nextConversation()
        let messageDates = dates(count: script.lines.count, startDaysAgo: startDaysAgo)
        let inInbox = forcedInbox ?? staysInInbox(latest: messageDates.last ?? reference)
        let me = profile.me
        var references: [String] = []
        var quoted: DemoHTML.Quoted?
        for (index, line) in script.lines.enumerated() {
            let fromMe = (index % 2 == 0) == script.alexStarts
            let counterpart = script.people[index / 2 % script.people.count].email
            let from = fromMe ? me : counterpart
            var to = fromMe ? script.people.map(\.email) : [me]
            var cc: [EmailAddress] = []
            if !fromMe, script.people.count > 1 {
                cc = script.people.map(\.email).filter { $0 != counterpart }
                to = [me]
            }
            let subject = index == 0 ? script.subject : (script.subject.hasPrefix("Re: ") ? script.subject : "Re: " + script.subject)
            var attachments: [AttachmentInfo] = []
            var cid: String?
            if let attachment = script.attachment, index == script.attachmentOnLine {
                switch attachment {
                case .photo:
                    cid = Self.photoContentID
                    attachments.append(AttachmentInfo(
                        id: Self.photoAttachmentID, filename: "sunset.png", mimeType: "image/png",
                        sizeBytes: DemoAssets.offsitePhotoPNG.count, contentID: Self.photoContentID, isInline: true
                    ))
                case .invoice:
                    attachments.append(AttachmentInfo(
                        id: Self.invoiceAttachmentID, filename: "INV-2041.pdf", mimeType: "application/pdf",
                        sizeBytes: DemoAssets.invoicePDF.count, isInline: false
                    ))
                }
            }
            let rendered = DemoHTML.personal(text: line, style: style, quoted: quoted, inlineImageCID: cid)
            let (id, internetID) = nextIDs()
            let date = messageDates[index]
            let isLastFromThem = !fromMe && !script.lines.indices.contains(where: { $0 > index && (($0 % 2 == 0) != script.alexStarts) })
            append(
                id: id, internetID: internetID, conversation: conversation, subject: subject,
                from: from, to: to, cc: cc, date: date, inInbox: inInbox,
                read: isRead(date: date, fromMe: fromMe, bulk: false),
                starred: script.starred && isLastFromThem,
                section: .focused, bulk: false, previous: references,
                html: rendered.html, text: rendered.text, attachments: attachments
            )
            references.append(internetID)
            quoted = DemoHTML.Quoted(
                from: from, to: to.first ?? me, date: date, subject: subject, fragment: rendered.fragment, text: rendered.text
            )
        }
    }

    private mutating func addNewsletter(_ letter: DemoCatalog.Newsletter, issue: Int, daysAgo: Double) {
        let conversation = nextConversation()
        let date = dates(count: 1, startDaysAgo: daysAgo)[0]
        var stories = letter.stories
        // Rotate so consecutive issues do not lead with the same story.
        let rotation = issue % stories.count
        stories = Array(stories[rotation...] + stories[..<rotation])
        let rendered = DemoHTML.newsletter(letter, issue: issue, date: date, stories: stories)
        let (id, internetID) = nextIDs()
        let subject = "\(letter.title) #\(issue): \(stories[0].0)"
        // A list's headers as real senders write them: a one-click URI first, a mailto beside it. The demo's senders
        // have no server, so the engine sends nothing for them (`OperationRunner`).
        let domain = letter.sender.address.split(separator: "@").last.map(String.init) ?? "demo.test"
        append(
            id: id, internetID: internetID, conversation: conversation, subject: subject,
            from: letter.sender.email, to: [profile.me], date: date,
            inInbox: staysInInbox(latest: date), read: isRead(date: date, fromMe: false, bulk: true),
            starred: false, section: .other, bulk: true, previous: [],
            html: rendered.html, text: rendered.text, attachments: [],
            listUnsubscribe: "<https://\(domain)/unsubscribe/\(id.providerID)>, <mailto:unsubscribe@\(domain)?subject=unsubscribe>"
        )
    }

    private mutating func addNotificationThread(_ family: DemoCatalog.Notification, maxLength: Int) {
        let conversation = nextConversation()
        let length = min(maxLength, random.chance(0.35) ? random.int(2...4) : 1)
        let daysAgo = pow(random.unit(), 1.4) * Double(Self.historyDays - 1)
        let messageDates = dates(count: length, startDaysAgo: daysAgo)
        let number = random.int(100...9_999)
        let template = random.pick(family.subjects)
        // "%d:00" is a meeting hour; any other placeholder is a ticket, order or PR number.
        let value = (template.contains("%d:00") || template.contains("%d:30")) ? 9 + number % 9
            : template.contains("v0.%d") ? number % 40
            : template.contains("$%d") ? 3 + number % 120 : number
        let subject = template.contains("%d") ? String(format: template, value) : template
        let inInbox = staysInInbox(latest: messageDates.last ?? reference)
        let calendarLike = family.sender.address.hasPrefix("calendar@")
        var references: [String] = []
        for index in 0..<length {
            let line = random.pick(family.lines)
            let rendered = DemoHTML.notification(family, subject: subject, line: line)
            let (id, internetID) = nextIDs()
            let date = messageDates[index]
            append(
                id: id, internetID: internetID, conversation: conversation,
                subject: index == 0 ? subject : "Re: " + subject,
                from: family.sender.email, to: [profile.me], date: date, inInbox: inInbox,
                read: isRead(date: date, fromMe: false, bulk: true), starred: false,
                section: calendarLike ? .focused : .other, bulk: true, previous: references,
                html: rendered.html, text: rendered.text, attachments: []
            )
            references.append(internetID)
        }
    }

    private mutating func addShortThread(people: [DemoCatalog.Person], maxLength: Int) {
        let conversation = nextConversation()
        let person = random.pick(people)
        let length = min(maxLength, random.int(1...3))
        let daysAgo = pow(random.unit(), 1.3) * Double(Self.historyDays - 1)
        let messageDates = dates(count: length, startDaysAgo: daysAgo)
        let baseSubject = random.pick(DemoCatalog.shortSubjects)
        let inInbox = staysInInbox(latest: messageDates.last ?? reference)
        let style: DemoHTML.QuoteStyle = isGmail ? .gmail : .outlook
        let me = profile.me
        var references: [String] = []
        var quoted: DemoHTML.Quoted?
        let starred = random.chance(0.04)
        for index in 0..<length {
            let fromMe = index % 2 == 1
            let line = index == 0 ? random.pick(DemoCatalog.openers) : random.pick(DemoCatalog.replies)
            let signed = fromMe ? line + "\nAlex" : line + "\n" + (person.name.split(separator: " ").first.map(String.init) ?? person.name)
            let rendered = DemoHTML.personal(text: signed, style: style, quoted: quoted, inlineImageCID: nil)
            let (id, internetID) = nextIDs()
            let from = fromMe ? me : person.email
            let to = fromMe ? [person.email] : [me]
            let subject = index == 0 ? baseSubject : (baseSubject.hasPrefix("Re: ") ? baseSubject : "Re: " + baseSubject)
            let date = messageDates[index]
            append(
                id: id, internetID: internetID, conversation: conversation, subject: subject,
                from: from, to: to, date: date, inInbox: inInbox,
                read: isRead(date: date, fromMe: fromMe, bulk: false),
                starred: starred && index == 0, section: .focused, bulk: false, previous: references,
                html: rendered.html, text: rendered.text, attachments: []
            )
            references.append(internetID)
            quoted = DemoHTML.Quoted(from: from, to: to[0], date: date, subject: subject, fragment: rendered.fragment, text: rendered.text)
        }
    }

    // MARK: Live arrivals

    /// The `n`th message that "arrives" while the demo runs. Derived from `n` alone so a body can be served
    /// for it after a relaunch.
    static func liveRecord(profile: DemoProfile, accountID: AccountID, n: Int, providerID: String, date: Date) -> DemoRecord {
        let people = profile.kind == .gmail ? DemoCatalog.gmailPeople : DemoCatalog.outlookPeople
        let arrivals = profile.kind == .gmail ? DemoCatalog.liveArrivals : DemoCatalog.liveWorkArrivals
        let arrival = arrivals[n % arrivals.count]
        let person = people[arrival.personIndex % people.count]
        let firstName = person.name.split(separator: " ").first.map(String.init) ?? person.name
        let text = arrival.text + "\n" + firstName
        let rendered = DemoHTML.personal(text: text, style: profile.kind == .gmail ? .gmail : .outlook, quoted: nil, inlineImageCID: nil)
        let metadata = MessageMetadata(
            id: MessageID(accountID: accountID, providerID: providerID),
            conversationID: ConversationID(accountID: accountID, providerID: "live-thread-" + providerID),
            internetMessageID: "<\(providerID)@mail.demo.test>",
            subject: arrival.subject,
            snippet: String(text.replacingOccurrences(of: "\n", with: " ").prefix(160)),
            from: person.email,
            to: [profile.me],
            date: date,
            roles: [.inbox],
            isRead: false,
            isStarred: false,
            inboxSection: .focused,
            hasAttachments: false,
            labelIDs: profile.kind == .gmail ? ["INBOX", "UNREAD", "CATEGORY_PERSONAL"] : [],
            folderID: profile.kind == .gmail ? nil : "inbox",
            providerVersion: "1",
            sizeBytes: rendered.html.utf8.count
        )
        return DemoRecord(metadata: metadata, body: MessageBody(html: rendered.html, text: rendered.text))
    }
}
