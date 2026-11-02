import Foundation

/// How the shell names an account to the user without colour (spec §4.2): the domain monogram on its rail tile
/// and the short name the sync line, tooltips and the reader kicker use (“Contoso”, “Gmail”).
///
/// A monogram is the first letter of the address's registrable label (`contoso.com` → C, `fabrikam.co.uk` → F);
/// consumer domains use the provider's letter (`gmail.com` → G, `outlook.com` → O). When two accounts would
/// show the same letter, the derived ones become two letters: the letter plus the first letter of the local
/// part for consumer domains (“Ga”, “Gm”), the label's first two letters for custom domains, and, when even
/// those agree, the first letter where the labels differ. A monogram the user typed in Settings always wins.
public enum AccountMonogram {
    /// Consumer domains and the provider letter and name they show.
    private static let consumer: [String: (letter: String, name: String)] = [
        "gmail.com": ("G", "Gmail"), "googlemail.com": ("G", "Gmail"),
        "outlook.com": ("O", "Outlook"), "hotmail.com": ("O", "Outlook"), "live.com": ("O", "Outlook"),
        "msn.com": ("O", "Outlook"),
    ]

    /// Second-level labels that sit under a two-letter country code as part of the public suffix (`co.uk`).
    private static let secondLevelSuffixes: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "ltd", "plc"]

    // MARK: Names

    /// The account's short name: the provider for consumer domains (“Gmail”, “Outlook”), else the registrable
    /// label with its first letter capitalised (“Contoso”).
    public static func name(for account: Account) -> String {
        let domain = domain(of: account.email)
        if let known = consumer[domain] { return known.name }
        let label = registrableLabel(of: domain)
        guard let first = label.first else { return account.email }
        return first.uppercased() + label.dropFirst()
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

    /// The one-letter monogram an address derives before collisions are resolved.
    public static func letter(for email: String) -> String {
        let domain = domain(of: email)
        if let known = consumer[domain] { return known.letter }
        let source = registrableLabel(of: domain)
        if let first = source.first(where: { $0.isLetter || $0.isNumber }) { return String(first).uppercased() }
        if let first = email.first(where: { $0.isLetter || $0.isNumber }) { return String(first).uppercased() }
        return "?"
    }

    /// The monogram each account shows, in the given order (the rail's): the user's own where set, derived
    /// letters otherwise, two letters where derived ones would collide.
    public static func monograms(for accounts: [Account]) -> [AccountID: String] {
        var result: [AccountID: String] = [:]
        var bases: [AccountID: String] = [:]
        for account in accounts {
            bases[account.id] = Account.normalizedMonogram(account.monogram) ?? letter(for: account.email)
        }
        func key(_ text: String) -> String { text.lowercased() }
        var countByBase: [String: Int] = [:]
        for account in accounts { countByBase[key(bases[account.id] ?? ""), default: 0] += 1 }

        // Accounts that keep their base: custom monograms, and derived letters nobody else shows.
        var taken: Set<String> = []
        var colliding: [Account] = []
        for account in accounts {
            let base = bases[account.id] ?? "?"
            if Account.normalizedMonogram(account.monogram) != nil || countByBase[key(base)] == 1 {
                result[account.id] = base
                taken.insert(key(base))
            } else {
                colliding.append(account)
            }
        }

        // Each group shares one letter; resolve the group together so the choice does not depend on order.
        let groups = Dictionary(grouping: colliding) { key(bases[$0.id] ?? "") }
        for account in colliding {
            let base = bases[account.id] ?? "?"
            let group = groups[key(base)] ?? [account]
            let preferred = preferredTwoLetter(for: account, letter: base, group: group)
            let candidates = [preferred].compactMap { $0 } + fallbackCandidates(for: account, letter: base)
            let pick = candidates.first { !taken.contains(key($0)) } ?? (base + String(colliding.firstIndex(of: account).map { $0 + 1 } ?? 0))
            result[account.id] = pick
            taken.insert(key(pick))
        }
        return result
    }

    /// The monogram `account` shows among `accounts`.
    public static func monogram(for account: Account, among accounts: [Account]) -> String {
        monograms(for: accounts.contains(account) ? accounts : accounts + [account])[account.id] ?? letter(for: account.email)
    }

    /// The spec's two-letter form when it tells the group apart, else the letter where this label first
    /// differs from every other label in the group.
    private static func preferredTwoLetter(for account: Account, letter: String, group: [Account]) -> String? {
        let domain = domain(of: account.email)
        if consumer[domain] != nil {
            guard let initial = localPart(of: account.email).first(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return letter + String(initial).lowercased()
        }
        let label = Array(alphanumerics(registrableLabel(of: domain)))
        let others = group.filter { $0.id != account.id }.map { Array(alphanumerics(registrableLabel(of: self.domain(of: $0.email)))) }
        if label.count >= 2 {
            let firstTwo = letter + String(label[1]).lowercased()
            let clash = others.contains { $0.count >= 2 && $0[1].lowercased() == String(label[1]).lowercased() }
            if !clash { return firstTwo }
        }
        for index in label.indices.dropFirst() {
            let character = String(label[index]).lowercased()
            let unique = others.allSatisfy { other in index >= other.count || String(other[index]).lowercased() != character }
            if unique { return letter + character }
        }
        return nil
    }

    /// Every other two-letter form, in a fixed order, for the rare group the preferred form cannot split.
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
