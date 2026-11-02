#if DEBUG
import AppKit
import SSDesign

/// Small marks and quiet states: badges, avatars, keycaps, empty states, progress and rules.
extension DesignGalleryCards {
    // MARK: Badges and tags (§5.28)

    static func badges() -> DesignGalleryCard {
        DesignGalleryCard("Badges and tags", code: "layout.badge · tag",
                          caption: "Counts are SF Pro Rounded 11 Semibold, tabular, capped at 99+. Tags are 11 pt sentence case.",
                          span: 4) { block in
            block.labelWidth = 120
            block.row("Unread count", [QuireBadge(.unread(3)), QuireBadge(.unread(21)), QuireBadge(.unread(128))], gap: 8)
            let selected = S.surface(.qSelWash, size: NSSize(width: 30, height: 22), radius: 4, centring: QuireBadge(.messageCount(4)))
            block.row("Message count", [QuireBadge(.messageCount(2)), QuireBadge(.messageCount(14)), selected], gap: 8, ann: "on selection")
            block.row("", [QuireBadge(.messageCount(1_204))], gap: 8, ann: "exact, in the locale's grouping")
            block.row("Dot · attention", [QuireBadge(.dot), QuireBadge(.attention)], gap: 8)
            let tagOnSelection = S.surface(.qSelWash, size: NSSize(width: 52, height: 22), radius: 4, centring: QuireTag("Other"))
            block.row("Tags", [QuireTag("Other"), QuireTag("Gmail"), QuireTag("Microsoft 365"), tagOnSelection], gap: 8)
            // The rail tile's badge cuts a 2 pt ring of `spine` where it overlaps the tile.
            let tile = DesignGalleryFlippedView(frame: NSRect(x: 0, y: 0, width: 38, height: 38))
            tile.fill = .qRaised
            tile.cornerRadius = 11
            let cut = QuireBadge(.unread(7), cutoutColor: .qSpine)
            let rail = S.surface(.qSpine, size: NSSize(width: 64, height: 50), radius: 6, [(tile, NSPoint(x: 10, y: 8)), (cut, NSPoint(x: 34, y: 4))])
            block.row("Cut-out", [rail], ann: "2 pt spine ring where the count overlaps a rail tile")
            block.row("Dock", [], ann: "System red badge, unified Inbox unread count (system-drawn).")
        }
    }

    // MARK: Avatars (§5.29)

    static func avatars() -> DesignGalleryCard {
        DesignGalleryCard("Avatars", code: "layout.avatar",
                          caption: "New York monograms on eight soft tints, by address hash. Faces never take account colour; the "
                              + "account shows as a ring.",
                          span: 4) { block in
            block.labelWidth = 0
            // The specimen picks these three tints by hand; rows pick by address hash (the tint row below).
            block.row(nil, [
                DesignGalleryAvatar(.tinted(initials: "AM", tint: .sea), diameter: 24),
                DesignGalleryAvatar(.tinted(initials: "PR", tint: .heather), diameter: 30),
                DesignGalleryAvatar(.tinted(initials: "BC", tint: .slate), diameter: 36),
            ], gap: 6, caption: "24 / 30 / 36; initials 0.42 × d, never below 10 pt; initials only, no photos")
            let railTile = S.surface(.qSpine, size: NSSize(width: 38, height: 38), radius: 8,
                                     centring: DesignGalleryAvatar(.account(monogram: "C", slot: 0), diameter: 30, ring: 0))
            block.row(nil, [
                DesignGalleryAvatar(.tinted(initials: "PR", tint: .heather), diameter: 30, ring: 1),
                railTile,
                DesignGalleryAvatar(.account(monogram: "Ga", slot: 4), diameter: 30, ring: 4),
                DesignGalleryAvatar(.account(monogram: "C", slot: 0), diameter: 24, ring: 0),
                DesignGalleryAvatar(.account(monogram: "Ga", slot: 4), diameter: 24, ring: 4),
            ], gap: 12, caption: "row avatar: cached face, ring drawn per row, gap = row fill · rail account face · account faces "
                + "30 and 24, one and two letters")
            let tints = Quire.AvatarTint.allCases.map { tint -> NSView in
                // One sample address per tint, found by the same hash rows use.
                let address = (0..<500).lazy.map { "person\($0)@example.test" }
                    .first { Quire.avatarTint(forAddress: $0) == tint } ?? "person@example.test"
                let initials = String(tint.name.prefix(2)).capitalized
                return DesignGalleryAvatar(.sender(initials: initials, address: address), diameter: 30)
            }
            block.row(nil, tints, gap: 6, caption: Quire.avatarTintNames.joined(separator: " · "))
        }
    }

    // MARK: Keycaps (§5.36)

    static func keycaps() -> DesignGalleryCard {
        DesignGalleryCard("Keycaps", code: "layout.kbd",
                          caption: "Every single-key command shows its keycap once in its natural place. ? or ⌘/ opens the cheat "
                              + "sheet.",
                          span: 3) { block in
            block.labelWidth = 0
            var caps: [NSView] = ["E", "#", "⌘↩", "⇧⌘R", "esc", "G"].map { QuireKeycap($0) }
            caps.append(DesignGalleryText("then", role: .meta, color: .qInk3))
            caps.append(QuireKeycap("I"))
            caps.append(QuireKeycap("J", style: .large))
            caps.append(QuireKeycap("K", style: .large))
            block.row(nil, caps, gap: 10, caption: "standard 18 · large 24 (cheat sheet)")
            let highlighted = QuireKeycap("⌘Z", style: .onSlip)
            highlighted.isHighlighted = true
            let slip = S.surface(.qSlip, size: NSSize(width: 84, height: 28), radius: 8,
                                 [(QuireKeycap("Z", style: .onSlip), NSPoint(x: 10, y: 5)), (highlighted, NSPoint(x: 38, y: 5))])
            let field = S.surface(.qSheet, size: NSSize(width: 40, height: 26), radius: 6, centring: QuireKeycap("/", style: .inField))
            block.row(nil, [field, slip], gap: 12, caption: "in field (search) · on slip · on slip, highlighted (action hovered)")
        }
    }

    // MARK: Empty states (§5.9)

    static func emptyStates() -> DesignGalleryCard {
        DesignGalleryCard("Empty states", code: "layout.emptyState",
                          caption: "One serif sentence and one hint. Only inbox zero shows the sparrow.",
                          span: 4) { block in
            block.labelWidth = 0
            let width = block.width
            @MainActor func empty(_ view: QuireEmptyStateView, height: CGFloat) -> QuireEmptyStateView {
                view.setFrameSize(NSSize(width: width, height: height))
                return view
            }
            block.full(empty(QuireEmptyStateView(sentence: "Nothing left to read.", hint: "New mail will land here.", glyph: .sparrow), height: 92))
            block.full(empty(QuireEmptyStateView(sentence: "No results for “lisbon flat”",
                                                 hint: "Search looks at subjects, people and message text."), height: 50))
            block.full(empty(QuireEmptyStateView(sentence: "Nothing in Focused",
                                                 hint: "Mail from people lands here; newsletters and notifications go to Other."), height: 64))
            let none = QuireEmptyStateView(sentence: "No conversation selected",
                                           hint: [.keys(["J", "K"]), .text("to move ·"), .keys(["↩"]), .text("to open")])
            none.setFrameSize(NSSize(width: width, height: 74))
            block.full(S.surface(.qCanvas, size: NSSize(width: width, height: 74), radius: 8, centring: none))
            block.full(empty(QuireEmptyStateView(sentence: "You're offline", hint: "Mail will appear when you reconnect.", glyph: .offline),
                             height: 86))
        }
    }

    // MARK: Skeleton, progress, contrail (§5.10, §5.37)

    static func progress() -> DesignGalleryCard {
        DesignGalleryCard("Skeleton, progress, contrail", code: "layout.skeleton · progress",
                          caption: "Skeletons appear only on a first sync, after 300 ms, and never shimmer. Spinners appear after "
                              + "150 ms and never in rows.",
                          span: 4) { block in
            block.labelWidth = 0
            let listWidth: CGFloat = min(364, block.width)
            let list = DesignGalleryFlippedView(frame: NSRect(x: 0, y: 0, width: listWidth, height: Quire.Layout.Row.height * 2 + 2))
            list.fill = .qRule
            list.cornerRadius = 8
            let paper = DesignGalleryFlippedView(frame: list.bounds.insetBy(dx: 1, dy: 1))
            paper.fill = .qPaper
            paper.cornerRadius = 7
            list.addSubview(paper)
            for index in 0..<2 {
                let row = QuireSkeleton(.row(index: index))
                row.frame = NSRect(x: 0, y: CGFloat(index) * Quire.Layout.Row.height, width: paper.bounds.width, height: Quire.Layout.Row.height)
                row.reveal(after: 0)
                paper.addSubview(row)
            }
            let divider = QuireHairline()
            divider.frame = NSRect(x: 0, y: Quire.Layout.Row.height - 1, width: paper.bounds.width, height: 1)
            paper.addSubview(divider)
            block.full(list)

            let compact = QuireSkeleton(.compactRow(index: 1))
            compact.frame = NSRect(x: 0, y: 0, width: listWidth, height: Quire.Layout.RowCompact.height)
            compact.reveal(after: 0)
            let body = QuireSkeleton(.body)
            body.frame = NSRect(x: 0, y: 0, width: 220, height: QuireSkeleton.height(of: .body) ?? 40)
            body.reveal(after: 0)
            block.row(nil, [compact], caption: "compact row (48 pt)")
            block.row(nil, [body], caption: "body loading")

            // The bars stack beside the spinners, as in the specimen.
            let stack = DesignGalleryFlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
            let bar = QuireProgressBar(mode: .determinate(0.6))
            bar.frame = NSRect(x: 0, y: 0, width: 200, height: 4)
            let contrail = QuireContrailView(mode: .determinate(0.6))
            contrail.frame = NSRect(x: 0, y: 14, width: 160, height: 4)
            let sweep = QuireContrailView(mode: .indeterminate)
            sweep.frame = NSRect(x: 0, y: 28, width: 180, height: 4)
            [bar, contrail, sweep].forEach(stack.addSubview)
            block.row(nil, [S.spinner(.small), S.spinner(.medium), S.spinner(.large), stack], gap: 12,
                      caption: "spinner 12 · 16 · 32 · determinate bar · determinate contrail · indeterminate contrail")
            let countdown = QuireProgressBar(mode: .countdown(duration: 5, remaining: 2.5))
            countdown.isPaused = true
            countdown.frame = NSRect(x: 0, y: 0, width: 160, height: 4)
            let countdownTrail = QuireContrailView(mode: .countdown(duration: 5, remaining: 2.5))
            countdownTrail.isPaused = true
            countdownTrail.frame = NSRect(x: 0, y: 0, width: 160, height: 4)
            block.row(nil, [countdown, countdownTrail], gap: 16, caption: "countdown bar · countdown contrail (paused at half)")
        }
    }

    // MARK: Rules, margin rule, scrim (§4.7, §2, §5.32)

    static func rules() -> DesignGalleryCard {
        DesignGalleryCard("Rules, margin rule, scrim", code: "border · scrim",
                          caption: "Hairlines are one device pixel: 1 pt at 1×, 0.5 pt at 2×. The margin rule marks the selection: "
                              + "selRule while the window is key, selRuleIdle when it is not.",
                          span: 4) { block in
            let hairline = QuireHairline()
            hairline.frame = NSRect(x: 0, y: 0, width: 160, height: 1)
            let strong = QuireHairline(color: .qRuleStrong)
            strong.frame = NSRect(x: 0, y: 0, width: 160, height: 1)
            block.row("Hairline", [hairline], ann: "rule")
            block.row("", [strong], ann: "ruleStrong")
            let vertical = QuireHairline(.vertical)
            vertical.frame = NSRect(x: 0, y: 0, width: 1, height: 28)
            block.row("Vertical", [vertical])
            let key = QuireMarginRule(height: Quire.Layout.Row.marginRuleHeight)
            key.windowKeyOverride = true
            let idle = QuireMarginRule(height: Quire.Layout.Row.marginRuleHeight)
            idle.windowKeyOverride = false
            let keyRow = S.surface(.qSelWash, size: NSSize(width: 90, height: 44), radius: 0, [(key, NSPoint(x: 0, y: 4))])
            let idleRow = S.surface(.qSelWashIdle, size: NSSize(width: 90, height: 44), radius: 0, [(idle, NSPoint(x: 0, y: 4))])
            block.row("Margin rule", [keyRow, idleRow], gap: 12, ann: "key · not key")

            let behind = S.surface(.qCanvas, size: NSSize(width: 150, height: 52), radius: 6,
                                   centring: QuireButton(title: "Behind", variant: .primary))
            let scrim = QuireScrimView(frame: behind.bounds)
            behind.addSubview(scrim)
            block.row("Scrim", [behind], ann: "cheat sheet scrim (scrimSolid under Reduce Transparency)")
        }
    }
}
#endif
