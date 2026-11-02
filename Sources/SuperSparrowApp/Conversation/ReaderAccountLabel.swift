import Foundation
import SSCore

/// How the reader names an account in words and in a monogram (spec §4.2, §5.12, §5.18): the kicker says
/// "Contoso" for alex@contoso.com and "Gmail" for a gmail.com address, and the quick reply's face carries the
/// account's monogram, the one the user typed in Settings or else one derived from the domain.
enum ReaderAccountLabel {
    private static let gmailDomains: Set<String> = ["gmail.com", "googlemail.com"]
    private static let outlookDomains: Set<String> = ["outlook.com", "hotmail.com", "live.com", "msn.com"]
    /// Second-level suffixes under which the registrable label is one further to the left.
    private static let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"]

    static func domain(of account: Account) -> String {
        account.email.split(separator: "@").last.map { $0.lowercased() } ?? ""
    }

    /// The label a domain is registered under: "contoso" for mail.contoso.com, "fabrikam" for fabrikam.co.uk.
    static func registrableLabel(_ domain: String) -> String {
        let labels = domain.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return labels.first ?? domain }
        if labels.count >= 3, secondLevel.contains(labels[labels.count - 2]), labels[labels.count - 1].count == 2 {
            return labels[labels.count - 3]
        }
        return labels[labels.count - 2]
    }

    /// The account's name in the kicker: the provider for consumer domains, else the domain's label set as
    /// words ("demo-outlook.test" reads "Demo Outlook").
    static func name(of account: Account) -> String {
        let domain = domain(of: account)
        if gmailDomains.contains(domain) { return "Gmail" }
        if outlookDomains.contains(domain) { return "Outlook" }
        let label = registrableLabel(domain)
        let words = label.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }
        return words.isEmpty ? account.email : words.joined(separator: " ")
    }

    /// The monogram the face shows: the user's own, else the domain's (spec §4.2). A hyphenated label is
    /// read by its last word, so "demo-gmail" gives G, the way a domain named for its provider should.
    static func monogram(of account: Account, among accounts: [Account]) -> String {
        if let typed = account.monogram, !typed.isEmpty { return typed }
        let mine = derivedLetter(account)
        let clashes = accounts.contains { $0.id != account.id && $0.monogram == nil && derivedLetter($0) == mine }
        guard clashes else { return mine }
        let local = account.email.split(separator: "@").first.flatMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
        return mine + (local.map { String($0).lowercased() } ?? "")
    }

    private static func derivedLetter(_ account: Account) -> String {
        let domain = domain(of: account)
        if gmailDomains.contains(domain) { return "G" }
        if outlookDomains.contains(domain) { return "O" }
        let label = registrableLabel(domain)
        let word = label.split(whereSeparator: { $0 == "-" || $0 == "_" }).last.map(String.init) ?? label
        return word.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "?"
    }
}
