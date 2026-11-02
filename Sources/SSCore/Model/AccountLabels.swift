import Foundation

/// How an account is told apart on screen without colour (spec §4.2): its monogram (rail tile, title menu,
/// quick reply face, Settings row), the letter on the list's account tile, its name (reader kicker, sync line,
/// row VoiceOver labels, tooltips, menus, notifications) and the composer's From title. All of it derives from
/// the address, so nothing new is stored; a monogram the user typed in Settings (`Account.monogram`) wins.
///
/// Every surface asks this one helper, so an account wears the same monogram and name everywhere. Collisions
/// are resolved over the whole set in the rail's order (oldest first), never the caller's, so a dictionary's
/// unordered values give the same answer as the rail's array.
public enum AccountLabels {
    /// Consumer mailboxes have no organisation in their domain: they show the provider's letter and name.
    /// Keyed by the registrable label, so regional domains (hotmail.co.uk, outlook.fr) count too.
    private static let consumerProviders: [String: (letter: String, name: String)] = [
        "gmail": ("G", "Gmail"), "googlemail": ("G", "Gmail"),
        "outlook": ("O", "Outlook"), "hotmail": ("O", "Outlook"), "live": ("O", "Outlook"), "msn": ("O", "Outlook"),
    ]

    /// Second-level labels that sit under a two-letter country code as part of the public suffix (`co.uk`).
    private static let secondLevelSuffixes: Set<String> = [
        "co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "gv", "ltd", "plc",
    ]

    // MARK: Names

    /// The account's name: the provider for a consumer address (“Gmail”, “Outlook”), else the registrable
    /// label as words in title case (“Contoso”, “Demo Outlook” for demo-outlook.test).
    public static func name(for account: Account) -> String {
        let label = registrableLabel(of: domain(of: account.email))
        if let provider = consumerProviders[label] { return provider.name }
        let words = label.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? account.email : words.joined(separator: " ")
    }

    /// The composer's From title (§5.20): “Alex Morgan <alex@contoso.test>”, or the address alone when the
    /// provider reported no name.
    public static func senderTitle(for account: Account) -> String {
        let name = account.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? account.email : "\(name) <\(account.email)>"
    }

    /// The domain part of an address, lowercased.
    public static func domain(of email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return "" }
        return email[email.index(after: at)...].trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The label a person would call the domain by: `mail.contoso.com` → contoso, `fabrikam.co.uk` → fabrikam.
    public static func registrableLabel(of domain: String) -> String {
        let parts = domain.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return parts.first ?? "" }
        let tld = parts[parts.count - 1]
        let second = parts[parts.count - 2]
        if parts.count >= 3, tld.count == 2, secondLevelSuffixes.contains(second) {
            return parts[parts.count - 3]
        }
        return second
    }

    // MARK: Monograms

    /// The one-letter monogram an address derives before collisions are resolved: the provider's letter for a
    /// consumer address, else the registrable label's first letter or digit.
    public static func letter(for email: String) -> String {
        let label = registrableLabel(of: domain(of: email))
        if let provider = consumerProviders[label] { return provider.letter }
        if let first = label.first(where: { $0.isLetter || $0.isNumber }) { return String(first).uppercased() }
        if let first = email.first(where: { $0.isLetter || $0.isNumber }) { return String(first).uppercased() }
        return "?"
    }

    /// The monogram each account shows: the one typed in Settings, else its derived letter. Where derived
    /// letters would collide (with each other or with a typed monogram) they become two letters: the letter
    /// plus the local part's first letter for consumer addresses (“Ga”, “Gm”), the label's first two letters
    /// for custom domains (“Co”, “Cl”), and, when those agree too, the first letter where the labels differ
    /// (“Dg”, “Do” for demo-gmail and demo-outlook). Every derived monogram ends up unique.
    public static func monograms(for accounts: [Account]) -> [AccountID: String] {
        // The rail's order, so the result never depends on the order the caller holds the accounts in.
        let ordered = accounts.sorted { ($0.addedAt, $0.id.rawValue) < ($1.addedAt, $1.id.rawValue) }
        func key(_ text: String) -> String { text.lowercased() }
        var bases: [AccountID: String] = [:]
        for account in ordered {
            bases[account.id] = Account.normalizedMonogram(account.monogram) ?? letter(for: account.email)
        }
        var countByBase: [String: Int] = [:]
        for account in ordered { countByBase[key(bases[account.id] ?? ""), default: 0] += 1 }

        // Accounts that keep their base: typed monograms, and derived letters nobody else shows.
        var result: [AccountID: String] = [:]
        var taken: Set<String> = []
        var colliding: [Account] = []
        for account in ordered {
            let base = bases[account.id] ?? "?"
            if Account.normalizedMonogram(account.monogram) != nil || countByBase[key(base)] == 1 {
                result[account.id] = base
                taken.insert(key(base))
            } else {
                colliding.append(account)
            }
        }

        // Each group shares one letter; its members are compared with each other, not with the whole set.
        let groups = Dictionary(grouping: colliding) { key(bases[$0.id] ?? "") }
        for (index, account) in colliding.enumerated() {
            let base = bases[account.id] ?? "?"
            let group = groups[key(base)] ?? [account]
            let preferred = preferredTwoLetter(for: account, letter: base, group: group)
            let candidates = [preferred].compactMap { $0 } + fallbackCandidates(for: account, letter: base)
            let pick = candidates.first { !taken.contains(key($0)) } ?? base + String(index + 1)
            result[account.id] = pick
            taken.insert(key(pick))
        }
        return result
    }

    /// The monogram `account` shows among `accounts`, its own current version taking the place of any stale
    /// copy in the set.
    public static func monogram(for account: Account, among accounts: [Account]) -> String {
        monograms(for: replacing(account, in: accounts))[account.id] ?? letter(for: account.email)
    }

    /// The monogram `account` derives with its own typed monogram cleared: the Settings field's placeholder,
    /// and what clearing the field returns to. Other accounts' typed monograms still count as taken.
    public static func derivedMonogram(for account: Account, among accounts: [Account]) -> String {
        var cleared = account
        cleared.monogram = nil
        return monogram(for: cleared, among: accounts)
    }

    /// The letter on each account's initial tile in the list (§4.2): the first letter of the monogram it shows.
    public static func initials(for accounts: [Account]) -> [AccountID: String] {
        monograms(for: accounts).mapValues(initial(ofMonogram:))
    }

    /// The first letter of a monogram, upper-cased, as the 16 pt tile shows it.
    public static func initial(ofMonogram monogram: String) -> String {
        monogram.first.map { String($0).uppercased() } ?? "?"
    }

    // MARK: Collisions

    private static func replacing(_ account: Account, in accounts: [Account]) -> [Account] {
        accounts.filter { $0.id != account.id } + [account]
    }

    private static func isConsumer(_ email: String) -> Bool {
        consumerProviders[registrableLabel(of: domain(of: email))] != nil
    }

    /// The spec's two-letter form when it tells the group apart, else the letter where this label first
    /// differs from every other label in the group.
    private static func preferredTwoLetter(for account: Account, letter: String, group: [Account]) -> String? {
        if isConsumer(account.email) {
            guard let initial = localPart(of: account.email).first(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return letter + String(initial).lowercased()
        }
        let label = Array(alphanumerics(registrableLabel(of: domain(of: account.email))).lowercased())
        let others = group.filter { $0.id != account.id }
            .map { Array(alphanumerics(registrableLabel(of: domain(of: $0.email))).lowercased()) }
        if label.count >= 2, !others.contains(where: { $0.count >= 2 && $0[1] == label[1] }) {
            return letter + String(label[1])
        }
        for index in label.indices.dropFirst() {
            let character = label[index]
            if others.allSatisfy({ index >= $0.count || $0[index] != character }) { return letter + String(character) }
        }
        return nil
    }

    /// Every other two-letter form, in a fixed order, for the rare group the preferred form cannot split (two
    /// accounts on one domain, or one address added twice).
    private static func fallbackCandidates(for account: Account, letter: String) -> [String] {
        let label = alphanumerics(registrableLabel(of: domain(of: account.email)))
        let local = alphanumerics(localPart(of: account.email))
        var seen: Set<String> = []
        return (Array(local) + Array(label.dropFirst())).compactMap { character in
            let candidate = letter + String(character).lowercased()
            return seen.insert(candidate.lowercased()).inserted ? candidate : nil
        }
    }

    private static func localPart(of email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return email }
        return String(email[..<at])
    }

    private static func alphanumerics(_ text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber })
    }
}
