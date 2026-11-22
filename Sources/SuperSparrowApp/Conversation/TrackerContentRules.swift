import Foundation
import SSCore
import WebKit

/// Block trackers' network layer (spec §5.60): `TrackerRules.endpoints` as a WebKit content blocker, which the reader's
/// pools, reader windows and the print view add to their user content controller while Block trackers is on. It stops a
/// known pixel in every body, one stored before the sanitizer marked trackers included, and whatever a body fetches
/// outside an `<img>` (a stylesheet's `url()`), at the moment WebKit would fetch it. It only ever removes requests.
///
/// Compiled once, and only once something asks for it (so never at launch with the setting off, and never in a
/// conversation's open: a pool asks when it is made or when the setting turns on, and a render does not wait). Even the
/// rules' JSON is written only then: the pools and the printer reach `shared` lazily, so with the setting off nothing
/// here runs at all. WebKit
/// compiles on a queue of its own and keeps the result on disk under an identifier carrying the rules' version and digest
/// (`TrackerRules.contentRuleListIdentifier`), so a later launch looks it up instead. A compilation that fails is logged
/// and given up for the run: the sanitizer's marks still hold every tracker in a body stored since v24.
@MainActor
final class TrackerContentRules {
    /// The app's, kept in WebKit's default store.
    static let shared = TrackerContentRules(store: WKContentRuleListStore.default())

    private let store: WKContentRuleListStore?
    private let scheme: String
    /// The rules as WebKit reads them, and the identifier derived from that same text, written on the first ask.
    private lazy var json = TrackerRules.contentRuleListJSON(scheme: scheme)
    private lazy var identifier = TrackerRules.contentRuleListIdentifier(json: json)
    private var compiled: WKContentRuleList?
    private var gaveUp = false
    private var waiters: [(WKContentRuleList?) -> Void] = []

    /// `scheme` is the address scheme the rules match, `https?`; the tests give their stand-in for the network, and a store
    /// of their own.
    init(store: WKContentRuleListStore?, scheme: String = "https?") {
        self.store = store
        self.scheme = scheme
    }

    /// The list once it is known, else nil (before the first compilation ends, or after one failed).
    var current: WKContentRuleList? { compiled }

    /// Hands `completion` the compiled list, on the main thread: at once when it is known, else once WebKit has looked it
    /// up or compiled it; nil when it cannot be had.
    func list(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let compiled { return completion(compiled) }
        guard !gaveUp, let store else { return completion(nil) }
        waiters.append(completion)
        guard waiters.count == 1 else { return }
        let identifier = self.identifier
        store.lookUpContentRuleList(forIdentifier: identifier) { [weak self] found, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let found { return self.finish(found) }
                self.compile(in: store)
            }
        }
    }

    private func compile(in store: WKContentRuleListStore) {
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { [weak self] list, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let error {
                    ConversationSignposts.log.error("tracker rules did not compile: \(String(describing: error), privacy: .public)")
                }
                self.finish(list)
                if list != nil { self.removeStale(in: store) }
            }
        }
    }

    private func finish(_ list: WKContentRuleList?) {
        compiled = list
        gaveUp = list == nil
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter(list) }
    }

    /// Earlier builds' compilations of these rules, which nothing will ask for again.
    private func removeStale(in store: WKContentRuleListStore) {
        let current = identifier
        store.getAvailableContentRuleListIdentifiers { identifiers in
            for stale in identifiers ?? [] where stale.hasPrefix(TrackerRules.contentRuleListPrefix) && stale != current {
                store.removeContentRuleList(forIdentifier: stale) { _ in }
            }
        }
    }
}
