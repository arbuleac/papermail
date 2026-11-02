import Foundation

/// How the reader names an account in words and in a monogram (spec §4.2, §5.12, §5.18): the kicker says
/// "Contoso" for alex@contoso.com and "Gmail" for a gmail.com address, and the quick reply's face carries the
/// account's rail monogram, the one the user typed in Settings or else the one derived from the domain.
public enum ReaderAccountLabel {
    private static let gmailDomains: Set<String> = ["gmail.com", "googlemail.com"]
    private static let outlookDomains: Set<String> = ["outlook.com", "hotmail.com", "live.com", "msn.com"]
    /// Second-level suffixes under which the registrable label is one further to the left.
    private static let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"]

    public static func domain(of account: Account) -> String {
        account.email.split(separator: "@").last.map { $0.lowercased() } ?? ""
    }

    /// The label a domain is registered under: "contoso" for mail.contoso.com, "fabrikam" for fabrikam.co.uk.
    public static func registrableLabel(_ domain: String) -> String {
        let labels = domain.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return labels.first ?? domain }
        if labels.count >= 3, secondLevel.contains(labels[labels.count - 2]), labels[labels.count - 1].count == 2 {
            return labels[labels.count - 3]
        }
        return labels[labels.count - 2]
    }

    private static func isConsumer(_ account: Account) -> Bool {
        let domain = domain(of: account)
        return gmailDomains.contains(domain) || outlookDomains.contains(domain)
    }

    /// The account's name in the kicker: the provider for consumer domains, else the domain's label set as
    /// words ("demo-outlook.test" reads "Demo Outlook").
    public static func name(of account: Account) -> String {
        let domain = domain(of: account)
        if gmailDomains.contains(domain) { return "Gmail" }
        if outlookDomains.contains(domain) { return "Outlook" }
        let label = registrableLabel(domain)
        let words = label.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }
        return words.isEmpty ? account.email : words.joined(separator: " ")
    }

    /// The monogram the account's rail face shows (spec §4.2), so the quick reply's face is the same face: the
    /// user's own; else the first letter of the registrable label, or the provider's letter for consumer
    /// domains. When another account already shows that letter it becomes two letters: the letter plus the
    /// first letter of the address's local part for consumer domains ("Ga", "Gm"), else the label's second
    /// letter, or the first letter where the colliding labels differ ("Do" and "Dg" for demo-outlook and
    /// demo-gmail).
    public static func monogram(of account: Account, among accounts: [Account]) -> String {
        if let typed = Account.normalizedMonogram(account.monogram) { return typed }
        let letter = baseLetter(account)
        let others = accounts.filter { $0.id != account.id }
        let shown = others.map { (Account.normalizedMonogram($0.monogram) ?? baseLetter($0)).lowercased() }
        guard shown.contains(letter.lowercased()) else { return letter }
        if isConsumer(account) {
            let local = account.email.split(separator: "@").first.flatMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
            return letter + (local.map { String($0).lowercased() } ?? "")
        }
        let label = Array(alphanumerics(registrableLabel(domain(of: account))).lowercased())
        let rivals = others
            .filter { Account.normalizedMonogram($0.monogram) == nil && !isConsumer($0) && baseLetter($0).lowercased() == letter.lowercased() }
            .map { Array(alphanumerics(registrableLabel(domain(of: $0))).lowercased()) }
        for index in label.indices.dropFirst() {
            let character = label[index]
            if rivals.allSatisfy({ index >= $0.count || $0[index] != character }) { return letter + String(character) }
        }
        return label.count > 1 ? letter + String(label[1]) : letter
    }

    private static func baseLetter(_ account: Account) -> String {
        let domain = domain(of: account)
        if gmailDomains.contains(domain) { return "G" }
        if outlookDomains.contains(domain) { return "O" }
        let label = registrableLabel(domain)
        if let first = label.first(where: { $0.isLetter || $0.isNumber }) { return String(first).uppercased() }
        return account.email.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?"
    }

    private static func alphanumerics(_ text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber })
    }
}
