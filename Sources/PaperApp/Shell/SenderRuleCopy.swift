import Foundation
import PaperCore

/// The words of sender rules now that they live on the server (spec §5.52): each names where the rule lives, in the
/// provider's own word for it (a Gmail filter, an Outlook rule), because the server, not this Mac, runs it. The menus'
/// commands and the undo's names stay `MailActionCopy`'s.
enum SenderRuleCopy {
    /// The service that keeps the account's rules: Microsoft 365 and Outlook.com alike call theirs Outlook rules.
    static func service(_ kind: ProviderKind) -> String {
        kind == .gmail ? "Gmail" : "Outlook"
    }

    /// The server's word for its rules, plural: “filters”, “rules”.
    static func rules(_ kind: ProviderKind) -> String {
        kind == .gmail ? "filters" : "rules"
    }

    /// The toast a new rule leaves: “Gmail will archive mail from news@letter.example”, “Outlook will block
    /// deals@shop.example”. The server does it from now on, so it is said in the future and names the server; the
    /// address goes last, so a long one loses its end to the slip's truncation and the verb stays.
    static func toast(_ action: SenderRule.Action, address: String, kind: ProviderKind) -> String {
        switch action {
        case .archive: return "\(service(kind)) will archive mail from \(address)"
        case .trash: return "\(service(kind)) will block \(address)"
        }
    }

    /// What a rule does, beside its address in Senders.
    static func detail(_ action: SenderRule.Action) -> String {
        switch action {
        case .archive: return "Archived"
        case .trash: return "Blocked"
        }
    }

    /// Where a row stands while the server does not have it as shown yet; nil for a saved one.
    static func state(of rule: SenderRule, kind: ProviderKind) -> String? {
        guard rule.isPending else { return nil }
        switch rule.sync {
        case .creating, .replacing: return "Saving to \(service(kind))…"
        case .deleting: return "Removing…"
        case .saved: return nil
        }
    }

    /// The Senders caption: whose rules these are, where they live and what they do.
    static func caption(for account: Account) -> String {
        "\(service(account.kind)) \(rules(account.kind)) for \(account.email): mail from these senders is archived or moved to "
            + "the Trash as it arrives, on every device."
    }

    /// The foot while the first read of this run is out: “Reading Gmail filters…”.
    static func reading(_ kind: ProviderKind) -> String {
        "Reading \(service(kind)) \(rules(kind))…"
    }

    /// The server's rules this app does not show, counted: “12 other filters in Gmail”; nil for none, since there is
    /// nothing to point at.
    static func others(_ count: Int, kind: ProviderKind) -> String? {
        guard count > 0 else { return nil }
        let noun = count == 1 ? String(rules(kind).dropLast()) : rules(kind)
        return "\(count.formatted()) other \(noun) in \(service(kind))"
    }

    /// The foot's link to the provider's own list of rules.
    static func openSettings(_ kind: ProviderKind) -> String {
        "Open \(service(kind)) Settings"
    }

    /// The notice while the account has not granted the rules permission, which is all the sheet shows then: the server's
    /// rules cannot be read, and rules kept on this Mac from before 1.14 are no rules until the server holds them, so they
    /// are counted, never listed.
    static func needsPermission(_ kind: ProviderKind, uploading count: Int) -> String {
        let ask = "Allow Paper to read and save \(service(kind)) \(rules(kind))."
        switch count {
        case 0: return ask
        case 1: return ask + " Your sender rule from this Mac moves to \(service(kind)) then."
        default: return ask + " Your \(count.formatted()) sender rules from this Mac move to \(service(kind)) then."
        }
    }

    /// The notice while that permission's sign-in waits for the browser.
    static func waitingForBrowser(_ kind: ProviderKind) -> String {
        "Waiting for your browser to allow \(service(kind)) \(rules(kind))."
    }

    /// The provider's web page that lists every rule of the account, the ones this app does not show among them. Gmail
    /// names the account by its address (`authuser`), so a browser signed in to several opens this one. Microsoft has
    /// one page for personal accounts and one for work or school accounts, told apart by the address's domain: the UI
    /// reads no Keychain, where the tenant the account signed in through is kept, and Outlook.com's own domains are few
    /// (a personal account on another domain lands on the work page, which sends it to sign in).
    static func webSettingsURL(for account: Account) -> URL? {
        switch account.kind {
        case .gmail:
            // A “+” left as it is would reach Google as a space.
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "+&=")
            guard let user = account.email.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return URL(string: "https://mail.google.com/mail/u/?authuser=\(user)#settings/filters")
        case .microsoft:
            return URL(string: isPersonalMicrosoft(account.email)
                ? "https://outlook.live.com/mail/0/options/mail/rules"
                : "https://outlook.office.com/mail/options/mail/rules")
        }
    }

    /// Outlook.com's domains, whatever the country: outlook.com, hotmail.co.uk, live.fr, msn.com, passport.com.
    static func isPersonalMicrosoft(_ email: String) -> Bool {
        guard let domain = email.split(separator: "@").last?.lowercased(), let first = domain.split(separator: ".").first else {
            return false
        }
        return ["outlook", "hotmail", "live", "msn", "passport", "windowslive"].contains(String(first))
    }
}
