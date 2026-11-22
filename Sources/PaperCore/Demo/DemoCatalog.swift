import Foundation

/// The people, companies and words the demo mailboxes are made of. Everything is fictional and uses `.test`
/// domains, which can never resolve, so nothing in demo mode can reach a real server or a real person.
enum DemoCatalog {
    struct Person {
        let name: String
        let address: String
        var email: EmailAddress { EmailAddress(name: name, address: address) }
    }

    enum Attachment {
        case photo
        case invoice
        /// Two files on one message, so the reader shows the count line and Download all (spec §5.17).
        case checklist
        /// A brand hand-off pack: a file of every common family on one message, each wearing its file mark (spec §5.57).
        case handoff
    }

    /// A conversation between people, written out. Lines alternate between the counterpart and Alex, starting
    /// with the counterpart unless `alexStarts` is set; a thread longer than the script is cut at a natural point.
    struct Script {
        let subject: String
        let people: [Person]
        let lines: [String]
        var alexStarts = false
        var attachment: Attachment?
        var attachmentOnLine = 0
        var starred = false
        /// Its last message a day or so old, in the inbox: the demo's long thread, so the inbox shows it.
        var isRecent = false
        /// Started this many days ago and kept in the inbox, whatever the random spread would give it.
        var inboxDaysAgo: Double?
    }

    struct Newsletter {
        let sender: Person
        let title: String
        let tagline: String
        let accent: String
        let stories: [(String, String)]
    }

    struct Notification {
        let sender: Person
        let subjects: [String]
        let lines: [String]
        let accent: String
        let button: String
    }

    // MARK: Gmail (personal) side

    static let priya = Person(name: "Priya Raman", address: "priya.raman@demo-mail.test")
    static let jordan = Person(name: "Jordan Lee", address: "jordan@leefamily.test")
    static let sam = Person(name: "Sam Okafor", address: "sam.okafor@demo-mail.test")
    static let linda = Person(name: "Linda Morgan", address: "linda.morgan@demo-mail.test")
    static let diego = Person(name: "Diego Alvarez", address: "diego@alvarez-studio.test")
    static let hannah = Person(name: "Hannah Becker", address: "hannah.becker@demo-mail.test")
    static let theo = Person(name: "Theo Nakamura", address: "theo@nakamura.test")
    static let maya = Person(name: "Maya Chen", address: "maya.chen@demo-mail.test")

    static let gmailPeople = [priya, jordan, sam, linda, diego, hannah, theo, maya]

    static let gmailScripts: [Script] = [
        Script(subject: "Lisbon in March?", people: [priya], lines: [
            "Okay hear me out: Lisbon, second week of March. Flights from SFO are weirdly cheap right now and I found an apartment in Alfama with a terrace.",
            "I'm very in. Can you send the apartment link? I need to check whether I can move the quarterly review but I think it's fine.",
            "Here it is. Two bedrooms, 4 nights, €620 total. Host is super responsive. Should I just book it before it goes?",
            "Book it! I'll Venmo you half tonight. Let's do the tram 28 thing even though everyone says it's a tourist trap.",
            "Booked 🎉 Also Sam wants to come for the weekend part, I told him we'd figure out the couch situation.",
        ], starred: true),
        Script(subject: "Photos from the offsite", people: [diego], lines: [
            "Finally pulled the photos off my camera. This one from the last evening is my favourite, the light over the water was unreal.",
            "That's gorgeous. Can I use it as my desktop background? Also please send the one of the whole group on the steps.",
            "Of course. Group shot coming tomorrow, I need to fix the exposure on that one first.",
        ], attachment: .photo),
        Script(subject: "Sunday dinner", people: [linda], lines: [
            "Hi sweetheart, are you still coming on Sunday? Dad is making the lamb. Let me know if you're bringing anyone.",
            "Yes! Coming around 5. Just me this time. Should I bring dessert?",
            "Dessert would be lovely. Not the lemon tart again though, your father had three slices last time and complained all night.",
            "Ha, noted. I'll bring the plum cake from the bakery on 24th.",
        ]),
        Script(subject: "Re: Climbing Thursday", people: [sam], lines: [
            "Gym on Thursday at 7? They reset the overhang wall and apparently the new purple route is brutal.",
            "I'm in but might be 15 minutes late, I have a call until 6:45.",
            "No worries. I'll warm up on the slab. Bring chalk, I'm out.",
            "Will do. Loser buys tacos after.",
        ]),
        Script(subject: "Book club: next pick", people: [hannah, maya], lines: [
            "We need to decide the next book by Friday. Nominations so far: Tomorrow, and Tomorrow, and Tomorrow; The Overstory; Piranesi.",
            "My vote is Piranesi. It's short and everyone has been busy.",
            "Piranesi it is then. I'll host on the 18th. I'm making that cardamom thing again.",
        ]),
        Script(subject: "Apartment lease renewal", people: [jordan], lines: [
            "Heads up, the landlord emailed about renewal. They want to go up 6%. I think we can push back given the dishwasher saga.",
            "Agreed. Want me to draft a reply? I'll mention the repair took five weeks and ask to keep it at 3%.",
            "Yes please. CC me. I'll pull together the photos of the leak just in case.",
            "Draft sent. Fingers crossed.",
            "They came back with 3.5%. I think we take it?",
            "Take it. Good negotiating, team.",
        ]),
        Script(subject: "Your talk at the meetup", people: [theo], lines: [
            "Really enjoyed your talk on local-first apps last night. Do you have the slides somewhere? A few people on my team asked.",
            "Thank you! I'll clean them up and post them this week. Happy to grab coffee if your team is exploring it.",
            "That would be great. How about next Wednesday near the Ferry Building?",
        ]),
        Script(subject: "Birthday plan for Jordan 🤫", people: [priya, sam], lines: [
            "Jordan's birthday is the 22nd. I'm thinking a surprise dinner at Nopa, 8 people max. Thoughts?",
            "Love it. I can handle the reservation. Do we know if they're free that Saturday?",
            "I'll ask casually. Don't put anything in the shared calendar!",
            "Reservation done for 7:30, under my name. Cake is on me.",
        ], alexStarts: true),
        Script(subject: "Quick favour", people: [maya], lines: [
            "Any chance you could water my plants while I'm away the 10th to the 14th? The fiddle leaf is dramatic, it needs exactly one cup on Mondays.",
            "Sure thing. Leave the key with the front desk. Should I talk to the fiddle leaf too?",
            "Yes. Compliments only.",
        ]),
        Script(subject: "Side project: sync engine idea", people: [theo], lines: [
            "Was thinking more about what you said re: applying writes locally first and replaying them. Do you queue them in SQLite too?",
            "Yes, same transaction as the local change. If the app crashes the outbox is still there, and the next sync replays it in order.",
            "That's clever. What happens when the server state disagrees after a poll?",
            "Pending operations win until the server confirms. Otherwise an archived thread pops back into the inbox for a few seconds, which feels broken.",
        ]),
    ]

    /// Older threads that live only on the demo's server, past the generated window: the download never lists them, so
    /// only a search of the server finds them (spec §5.10). One answers the snapshots' “lisbon” search.
    static let gmailArchiveScripts: [Script] = [
        Script(subject: "Lisbon photos, finally", people: [priya], lines: [
            "Sorry this took a year: the Lisbon photos are finally sorted. The one from the miradouro at sunset is the best of the lot.",
            "These are wonderful. Can you send the tram 28 one at full size? I want to print it for the hallway.",
            "Sending it now. We should do another trip like that. Porto next spring?",
        ]),
        Script(subject: "Tax documents for last year", people: [jordan], lines: [
            "Found the folder with last year's tax documents. The landlord's statement is in there too if you need it for the lease.",
            "Perfect, scan the statement when you get a chance. Everything else can wait until March.",
        ]),
    ]

    static let gmailNewsletters: [Newsletter] = [
        Newsletter(
            sender: Person(name: "The Overnight Brief", address: "brief@overnight-news.test"),
            title: "The Overnight Brief", tagline: "Five things worth knowing before your coffee.", accent: "#1F3A5F",
            stories: [
                ("Rail strike talks resume", "Negotiators returned to the table late Tuesday after a week-long pause, with both sides signalling a deal on scheduling could come within days."),
                ("The quiet comeback of the paper notebook", "Sales of hardcover notebooks are up 18% year on year, and stationers say students are driving it."),
                ("Ocean heat records, explained", "Why this autumn's sea-surface readings surprised even the researchers who predicted them."),
                ("A city that turned parking lots into parks", "Five years on, what the residents actually think."),
            ]
        ),
        Newsletter(
            sender: Person(name: "Frontend Weekly", address: "hello@frontendweekly.test"),
            title: "Frontend Weekly", tagline: "The best of the web platform, every Thursday.", accent: "#7A3EF0",
            stories: [
                ("View transitions land everywhere", "Cross-document view transitions are now available in every major engine. Here is how to adopt them progressively."),
                ("Stop shipping 2 MB of JavaScript", "A practical audit checklist from a team that cut their bundle by 70%."),
                ("CSS anchor positioning in practice", "Tooltips and popovers without a single line of positioning code."),
            ]
        ),
        Newsletter(
            sender: Person(name: "Trailhead Outfitters", address: "news@trailhead-outfitters.test"),
            title: "Trailhead Outfitters", tagline: "Gear up for the weekend.", accent: "#2E7D4F",
            stories: [
                ("Winter layering guide", "Base, mid, shell: what our staff actually wear on cold summits."),
                ("Members save 20% this weekend", "On packs, headlamps and everything in the camp kitchen."),
                ("Trail of the month: Dipsea", "Steps, redwoods and a view of the Pacific at the end."),
            ]
        ),
    ]

    static let gmailNotifications: [Notification] = [
        Notification(
            sender: Person(name: "Forge", address: "notifications@forge.test"),
            subjects: ["[paper-sync] PR #%d: Coalesce list refreshes", "[paper-sync] Issue #%d: Crash when token expires mid-bootstrap", "[paper-sync] PR #%d: Add FTS5 search", "[paper-sync] Release v0.%d published"],
            lines: ["theo-n approved these changes.", "maya-c commented: Looks good, one nit about the batch size.", "CI passed on all 3 jobs.", "theo-n requested changes: Can we add a test for the empty page case?"],
            accent: "#24292F", button: "View on Forge"
        ),
        Notification(
            sender: Person(name: "Lumen Bank", address: "alerts@lumenbank.test"),
            subjects: ["Your statement is ready", "Card purchase of $%d.40 at Blue Bottle Coffee", "Direct deposit received", "Payment to City Utilities scheduled"],
            lines: ["This is an automated alert. No action is needed.", "If you don't recognise this activity, call us at the number on the back of your card."],
            accent: "#0B6E99", button: "Open Lumen"
        ),
        Notification(
            sender: Person(name: "Parcel Post", address: "tracking@parcelpost.test"),
            subjects: ["Your package #%d has shipped", "Out for delivery: order #%d", "Delivered: order #%d"],
            lines: ["Estimated delivery: Thursday by 8 pm.", "Your parcel was left at the front door.", "Track your parcel any time in the Parcel Post app."],
            accent: "#C2410C", button: "Track package"
        ),
        Notification(
            sender: Person(name: "Juniper Air", address: "no-reply@juniperair.test"),
            subjects: ["Your trip to Lisbon: booking JA%d confirmed", "Check-in is open for flight JA%d", "Seat upgrade available on JA%d"],
            lines: ["SFO → LIS · Departs 6:05 pm · Arrives 2:40 pm +1", "Seat 23A · Economy Plus · 1 checked bag included"],
            accent: "#0F766E", button: "Manage booking"
        ),
    ]

    // MARK: Outlook (work) side

    static let rachel = Person(name: "Rachel Kim", address: "rachel.kim@northwind-labs.test")
    static let marcus = Person(name: "Marcus Bell", address: "marcus.bell@northwind-labs.test")
    static let aisha = Person(name: "Aisha Patel", address: "aisha.patel@northwind-labs.test")
    static let tom = Person(name: "Tom Hughes", address: "tom.hughes@northwind-labs.test")
    static let elena = Person(name: "Elena Rossi", address: "elena.rossi@northwind-labs.test")
    static let ben = Person(name: "Ben Carter", address: "ben.carter@contoso-retail.test")
    static let sophie = Person(name: "Sophie Laurent", address: "s.laurent@fabrikam.test")
    static let printShop = Person(name: "Northwind Print Co.", address: "billing@northwind-print.test")

    static let outlookPeople = [rachel, marcus, aisha, tom, elena, ben, sophie]

    static let outlookScripts: [Script] = [
        Script(subject: "Q4 roadmap review", people: [rachel], lines: [
            "Can you have the Q4 roadmap draft ready for Thursday's review? Focus on the sync reliability work and the search improvements, leadership will ask about both.",
            "Yes. I'll circulate a draft Wednesday morning. Do you want the hiring plan in the same doc or separate?",
            "Separate please. Keep the roadmap to two pages.",
            "Draft is in the shared folder. Two pages, plus an appendix with the risk register.",
            "Great work. One comment: move the offline mode milestone to January, we won't have QA capacity in December.",
        ], starred: true),
        Script(subject: "Contoso rollout: go-live checklist", people: [ben, tom], lines: [
            "Hi Alex, attaching our go-live checklist for the 14th. Can your team confirm items 4 through 9 by Friday? Our store managers start training Monday.",
            "Thanks Ben. Items 4 to 7 are done; 8 and 9 depend on your SSO configuration. Could your IT team share the metadata URL?",
            "Forwarded to IT, they'll send it today. Really appreciate the quick turnaround.",
            "Got the metadata. SSO is configured on staging, can someone on your side test a login?",
            "Tested with three accounts, all good. We're green for the 14th!",
        ], attachment: .checklist),
        Script(subject: "Design review: message list density", people: [marcus], lines: [
            "Uploaded the new list density explorations. Option B uses 72pt rows with two lines of snippet. I think it's the right balance.",
            "B looks great. Can we try the unread dot on the left edge instead of next to the subject?",
            "Tried it, it's much easier to scan. Updated the file.",
        ]),
        Script(subject: "Invoice INV-2041", people: [printShop], lines: [
            "Dear Alex, please find attached invoice INV-2041 for the conference print order. Payment is due within 30 days. Kind regards, Northwind Print Co. Accounts",
            "Thanks, forwarding to finance for payment.",
        ], attachment: .invoice),
        Script(subject: "Budget approval for the offsite", people: [elena], lines: [
            "The offsite budget came in at $18,400, about 8% over the plan. Can you share a short justification so I can approve it this week?",
            "Most of the difference is the venue's AV package, which replaces the rental we budgeted separately. Net we're about 2% over.",
            "That makes sense. Approved. Please submit receipts through the usual tool within 14 days of the event.",
        ]),
        Script(subject: "Interview loop for senior engineer", people: [aisha, rachel], lines: [
            "We have a strong candidate for the senior role. Can you take the system design interview on Tuesday at 2?",
            "Yes, put me down. Send over the resume and the take-home review notes.",
            "Done. The candidate built a CRDT-based notes app for the take-home, should be a fun conversation.",
            "Interview went well. Strong hire from me. Detailed notes are in the tracker.",
        ]),
        Script(subject: "Fabrikam renewal and pricing", people: [sophie], lines: [
            "Bonjour Alex, our renewal is coming up in January. Before we sign we'd like to discuss volume pricing for the two new regions.",
            "Hi Sophie, happy to. Would a call next Tuesday at 10am CET work? I'll bring a proposal with tiered pricing.",
            "Tuesday works. Please include the SLA terms as well, our procurement team will ask.",
        ]),
        Script(subject: "Incident follow-up: delayed syncs on Monday", people: [aisha], lines: [
            "Post-mortem draft for Monday's delayed syncs is up. Root cause: the token refresh path retried without backoff and we hit the provider's rate limit.",
            "Thanks for writing this up quickly. Let's add an action item to honour Retry-After everywhere, not only in the batch client.",
            "Added. I also added an alert when the outbox grows past 1,000 operations.",
        ]),
        Script(subject: "Lunch & learn: Swift concurrency", people: [tom], lines: [
            "Would you be up for doing a lunch & learn on Swift concurrency? The mobile team keeps asking about actors.",
            "Sure, I can do 30 minutes on actors, Sendable and the migration path. Thursday the 20th?",
            "Booked the big room. Pizza is on me.",
        ]),
        // The demo's long thread (thirteen messages, three people), last so the threads before it keep the mail they had:
        // Help me write's whole-thread context reads it newest first, older messages shortened (spec §5.56).
        Script(subject: "Team offsite: venue, dates and agenda", people: [elena, aisha], lines: [
            "Kicking off planning for the spring offsite. Two venues are on the shortlist: the Harbour Loft in town and Millbrook Farm, an hour out. Can you two give me your preferences by Friday?",
            "Harbour Loft gets my vote. Nobody has to drive, and the AV is built in. Millbrook is lovely but the travel eats half a day.",
            "Agree on the Loft. One worry: it only seats 40 for dinner, and we're at 46 with the new hires.",
            "Could we split dinner across two tables at the restaurant next door? They did that for the design team last year.",
            "Good idea. I called them: they can take 50 on the 18th or the 25th, not the 11th.",
            "The 18th clashes with the release freeze. The 25th works for engineering if we keep the Monday free for the rollout.",
            "Then let's hold Thursday 25 and Friday 26. I'll put a provisional booking on the Loft for both days.",
            "Booked provisionally. They need the deposit, 20% of the quote, by the 3rd to keep the dates.",
            "On the agenda: I'd like one morning for the roadmap and one for customer stories. Afternoons free for team sessions?",
            "Works for me. I'll draft the roadmap morning. Can someone own the customer stories and invite two customers?",
            "I can ask Contoso and Fabrikam; both offered to talk last quarter. I'll need the travel budget confirmed first.",
            "Travel for two customer guests fits inside the budget we approved, about $1,200 all in.",
            "Great, so we're nearly there. Can you confirm you'll send the deposit before the 3rd, and are you happy to present the roadmap on Thursday morning? Also, should we invite the new hires to the dinner on Wednesday or keep it to the Thursday?",
        ], isRecent: true),
        // A file of every common family on one message (spec §5.57), after the long thread so every thread before it keeps
        // the mail it had; in the inbox a few days back, so it is there to open without leading it.
        Script(subject: DemoComposerSample.handoffSubject, people: [marcus], lines: [
            "Could you send me everything for the brand refresh before you're off next week? I'll take it from there.",
            "Here's the whole hand-off pack: the guidelines, the budget and the attendee list, the agency contract and the launch deck, the review invite, the logo and the hero shot, my voice memo on the photography, and the press kit. The agency's old exports came as a rar, sorry. Release notes are in the txt.",
        ], alexStarts: true, attachment: .handoff, attachmentOnLine: 1, inboxDaysAgo: 3.4),
    ]

    /// The work account's older threads on the demo's server, found only by a search of the server (spec §5.10).
    static let outlookArchiveScripts: [Script] = [
        Script(subject: "Lisbon office visit: agenda", people: [elena], lines: [
            "Here is the agenda for the Lisbon office visit: Monday is the partner workshop, Tuesday the sync engine deep dive.",
            "Looks good. Can we move the deep dive to the morning? The afternoon flights back are the only ones with seats.",
            "Done. Mornings it is. I'll book the room on the fourth floor with the view of the river.",
        ]),
        Script(subject: "Expense report: conference travel", people: [marcus], lines: [
            "Your expense report for the conference is approved. Reimbursement goes out with the next payroll run.",
        ]),
    ]

    static let outlookNewsletters: [Newsletter] = [
        Newsletter(
            sender: Person(name: "Northwind Weekly", address: "comms@northwind-labs.test"),
            title: "Northwind Weekly", tagline: "News from around the company.", accent: "#B91C1C",
            stories: [
                ("Welcome to our new teammates", "Eleven people joined across engineering, design and sales this month. Say hi in #welcome."),
                ("Office move update", "Floor 4 opens on the 1st. Desk booking goes live next week."),
                ("Customer spotlight: Contoso Retail", "How 240 stores moved to the new platform in six weeks."),
            ]
        ),
        Newsletter(
            sender: Person(name: "SaaS Metrics Digest", address: "digest@saasmetrics.test"),
            title: "SaaS Metrics Digest", tagline: "Benchmarks and playbooks for operators.", accent: "#0E7490",
            stories: [
                ("Net revenue retention benchmarks for 2026", "Median NRR fell two points this year. The top quartile did something different."),
                ("Pricing pages that convert", "We looked at 300 of them. Fewer tiers win."),
                ("The hidden cost of annual discounts", "When paying up front stops being a good deal for the vendor."),
            ]
        ),
    ]

    static let outlookNotifications: [Notification] = [
        Notification(
            sender: Person(name: "Trackr", address: "notifications@trackr.test"),
            subjects: ["SYNC-%d: Retry-After not honoured in batch client", "SYNC-%d was moved to In Review", "SRCH-%d: Highlight matches in snippets", "You were mentioned in SYNC-%d"],
            lines: ["Aisha Patel changed the status from In Progress to In Review.", "Marcus Bell commented: Updated the mocks, see attachment.", "Priority changed from Medium to High.", "Tom Hughes assigned this issue to you."],
            accent: "#5B21B6", button: "Open in Trackr"
        ),
        Notification(
            sender: Person(name: "Calendar", address: "calendar@northwind-labs.test"),
            subjects: ["Invitation: 1:1 Alex / Rachel @ Tue %d:00", "Updated invitation: Sprint planning", "Accepted: Design review @ Thu %d:30", "Reminder: All hands starts in 15 minutes"],
            lines: ["Room: Juniper (4th floor) · Video link in the event.", "Rachel Kim has accepted this invitation."],
            accent: "#1D4ED8", button: "View event"
        ),
        Notification(
            sender: Person(name: "Northwind IT", address: "it-helpdesk@northwind-labs.test"),
            subjects: ["Ticket #%d resolved: VPN access", "Scheduled maintenance this Saturday", "Your laptop is due for an OS update"],
            lines: ["If the issue persists, reply to this email to reopen the ticket.", "Maintenance window: Saturday 22:00 to 02:00 PT."],
            accent: "#374151", button: "Open the portal"
        ),
    ]

    // MARK: Generic short threads (both sides)

    static let shortSubjects = [
        "Quick question", "Following up", "Notes from today", "Thanks!", "Re: this week", "Small change to the plan",
        "Coffee next week?", "FYI", "Can you take a look?", "Heads up", "Re: the doc", "Tomorrow's call",
        "Link from earlier", "Weekend plans", "One more thing", "Checking in",
    ]

    static let openers = [
        "Hey Alex, quick one: are we still on for tomorrow?",
        "Just following up on my note from last week, no rush.",
        "Thanks again for your help with this, it made a big difference.",
        "Sharing the link we talked about earlier. Let me know what you think.",
        "Small change: can we push our call to 3:30 instead of 3?",
        "I took some notes during the meeting, pasting them below in case they're useful.",
        "Do you have ten minutes this afternoon to look at something with me?",
        "Heads up that I'll be out Friday, back Monday morning.",
    ]

    static let replies = [
        "Yes, that works for me.",
        "Sounds good, thanks for the heads up!",
        "Perfect, see you then.",
        "Got it. I'll take a look tonight and get back to you.",
        "Thanks! This is really helpful.",
        "Let's do it. I'll send an invite.",
        "No problem at all.",
        "Makes sense. Let me check and confirm by end of day.",
    ]

    /// Mail that arrives while the demo is open, one every ~45 seconds.
    static let liveArrivals: [(personIndex: Int, subject: String, text: String)] = [
        (0, "Did you see this?", "Just saw the news about the new ferry line to Sausalito. Weekend trip?"),
        (2, "Running late", "Running about 10 minutes late, save me a spot!"),
        (1, "Rent split", "Sent you my half of the utilities. Let me know if the number looks off."),
        (4, "Group shot", "Here's the group photo from the steps. Fixed the exposure, everyone looks human now."),
        (5, "Re: Piranesi", "Halfway through and I'm completely lost in the best way."),
        (3, "Call this weekend?", "Your father wants to show you the new garden. Call us Sunday?"),
        (6, "Coffee Wednesday", "Still good for Wednesday at 9? I'll grab a table outside."),
        (7, "Thank you!!", "The plants are thriving. The fiddle leaf says hi."),
    ]

    /// The work mailbox's arrivals, indexed into `outlookPeople`.
    static let liveWorkArrivals: [(personIndex: Int, subject: String, text: String)] = [
        (0, "Quick sync before the review?", "Do you have 10 minutes before Thursday's review? Want to align on the offline mode slide."),
        (2, "PR ready for review", "The Retry-After fix is up for review. Small diff, mostly tests."),
        (5, "Re: go-live", "Store managers loved the training session. Thanks to your whole team!"),
        (1, "New mocks", "Pushed the updated empty states. The \"Inbox zero\" illustration is my favourite."),
        (4, "Receipts reminder", "Friendly reminder to submit offsite receipts by Friday."),
        (6, "Proposal received", "Thanks for the tiered pricing proposal. Procurement will review it this week."),
        (3, "Lunch & learn feedback", "People are still talking about the actors demo. Can we do a part two?"),
    ]
}
