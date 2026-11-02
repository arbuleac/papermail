import Foundation

/// The words and letters that identify an account on screen (spec §4.2): its name (“Contoso”, “Personal”) and
/// its monogram (“C”, or “Ga” / “Gm” when two would collide). Derived from the address, so nothing new is
/// stored; a monogram the user typed in Settings (`Account.monogram`) always wins.
public enum AccountLabels {
    /// Consumer domains have no organisation in them: their monogram is the provider's letter and their name is
    /// “Personal”.
    static let consumerLetters: [String: String] = [
        "gmail": "G", "googlemail": "G",
        "outlook": "O", "hotmail": "O", "live": "O", "msn": "O",
    ]

    /// Second-level labels under a country code (`fabrikam.co.uk`), skipped to reach the registrable label.
    private static let secondLevels: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "gv"]

    /// The label that names the organisation: `contoso` for alex@contoso.com, `fabrikam` for fabrikam.co.uk.
    static func registrableLabel(of address: String) -> String {
        let domain = address.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        let parts = domain.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return parts.first ?? "" }
        if parts.count >= 3, parts[parts.count - 1].count == 2, secondLevels.contains(parts[parts.count - 2]) {
            return parts[parts.count - 3]
        }
        return parts[parts.count - 2]
    }

    static func isConsumer(_ account: Account) -> Bool {
        consumerLetters[registrableLabel(of: account.email)] != nil
    }

    /// The account's name: the organisation's label in title case (“Contoso”, “Demo Gmail” for demo-gmail.test),
    /// or “Personal” for a consumer address.
    public static func name(for account: Account) -> String {
        let label = registrableLabel(of: account.email)
        if consumerLetters[label] != nil || label.isEmpty { return "Personal" }
        return label.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The one-letter monogram before collisions are resolved.
    static func baseLetter(for account: Account) -> String {
        let label = registrableLabel(of: account.email)
        if let letter = consumerLetters[label] { return letter }
        return label.first.map { String($0).uppercased() } ?? "?"
    }

    /// The two-letter monogram used on a collision: the provider letter plus the local part's first letter for
    /// consumer addresses (“Ga”, “Gm”), the label's first two letters for organisations; hyphenated labels take
    /// the next word's first letter instead, so `demo-gmail` and `demo-outlook` read “Dg” and “Do”.
    static func twoLetters(for account: Account) -> String {
        let first = baseLetter(for: account)
        let second: Character?
        if isConsumer(account) {
            second = account.email.first
        } else {
            let words = registrableLabel(of: account.email).split(separator: "-")
            second = words.count > 1 ? words[1].first : words.first?.dropFirst().first
        }
        return first + (second.map { String($0).lowercased() } ?? "")
    }

    /// The monograms derived for each account, ignoring any typed in Settings except as letters already taken:
    /// what a cleared Monogram field returns to (its placeholder).
    public static func derivedMonograms(for accounts: [Account]) -> [AccountID: String] {
        var counts: [String: Int] = [:]
        for account in accounts where Account.normalizedMonogram(account.monogram) == nil {
            counts[baseLetter(for: account), default: 0] += 1
        }
        var result: [AccountID: String] = [:]
        for account in accounts {
            let letter = baseLetter(for: account)
            let typedByOthers = accounts.contains { other in
                other.id != account.id && Account.normalizedMonogram(other.monogram)?.uppercased() == letter.uppercased()
            }
            let ownCount = Account.normalizedMonogram(account.monogram) == nil ? 0 : 1
            let collides = (counts[letter] ?? 0) + ownCount > 1 || typedByOthers
            result[account.id] = collides ? twoLetters(for: account) : letter
        }
        return result
    }

    /// The monogram each account shows: the one typed in Settings, else the derived one.
    public static func monograms(for accounts: [Account]) -> [AccountID: String] {
        let derived = derivedMonograms(for: accounts)
        var result: [AccountID: String] = [:]
        for account in accounts {
            result[account.id] = Account.normalizedMonogram(account.monogram) ?? derived[account.id] ?? baseLetter(for: account)
        }
        return result
    }
}
