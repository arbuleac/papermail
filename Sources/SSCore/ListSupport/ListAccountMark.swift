import Foundation

/// What a list row needs to name an account without colour (spec §4.2): the letter on the optional initial
/// tile and the account's name at the end of the row's VoiceOver label.
///
/// Both come from the address's domain as the monogram rule says: the first letter of the registrable label
/// (`contoso.com` → C, `fabrikam.co.uk` → F), or the provider's letter for consumer domains (G, O). The tile
/// shows one letter, so collisions, which only change a monogram's second letter, never matter here.
public enum ListAccountMark {
    private static let gmailDomains: Set<String> = ["gmail.com", "googlemail.com"]
    private static let outlookDomains: Set<String> = ["outlook.com", "hotmail.com", "live.com", "msn.com"]
    /// Second-level labels under which the registrable label sits one further left (`co.uk`, `com.au`).
    private static let secondLevelLabels: Set<String> = ["co", "com", "net", "org", "ac", "gov", "edu", "ne", "or"]

    /// The tile's letter: the first letter of the monogram the user set, else of the derived one.
    public static func initial(email: String, monogram: String?) -> String {
        if let monogram, let first = monogram.trimmingCharacters(in: .whitespacesAndNewlines).first {
            return String(first).uppercased()
        }
        guard let letter = name(email: email).first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(letter).uppercased()
    }

    /// The account's name: "Gmail" and "Outlook" for consumer addresses, otherwise the registrable label with
    /// its first letter capitalised ("Contoso").
    public static func name(email: String) -> String {
        let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        if gmailDomains.contains(domain) { return "Gmail" }
        if outlookDomains.contains(domain) { return "Outlook" }
        let label = registrableLabel(of: domain)
        guard let first = label.first else { return email }
        return first.uppercased() + label.dropFirst()
    }

    static func registrableLabel(of domain: String) -> String {
        let labels = domain.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return labels.first ?? domain }
        let second = labels[labels.count - 2]
        if labels.count >= 3, labels[labels.count - 1].count == 2, secondLevelLabels.contains(second) {
            return labels[labels.count - 3]
        }
        return second
    }
}
