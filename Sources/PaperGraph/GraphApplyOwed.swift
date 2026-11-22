import Foundation
import PaperCore

/// What one `GraphProvider.apply` still owes when it ends, and why: the messages whose parts the service kept failing,
/// those Graph refused, and those never sent because the call stopped.
struct GraphApplyOwed {
    var failing: [String] = []
    var refused: [String] = []
    var unsent: [String] = []
    /// The parts that answered 404 and the status, which a move into a missing Archive folder turns into a refusal.
    var missing: (status: Int, ids: [String])?

    private var unauthorized = false
    private var throttle: ProviderError?
    private var requestFailure: ProviderError?
    private var serviceFailure: ProviderError?
    private var refusal: ProviderError?

    /// A refused token, a throttle or a request that failed whole: the batches after it would meet the same.
    var stopsTheCall: Bool {
        unauthorized || throttle != nil || requestFailure != nil
    }

    mutating func stop(_ error: ProviderError) {
        switch error {
        case .unauthorized:
            unauthorized = true
        case .throttled(let retryAfter):
            if case .throttled(let earlier)? = throttle, let earlier {
                throttle = .throttled(retryAfter: max(earlier, retryAfter ?? 0))
            } else {
                throttle = error
            }
        default:
            requestFailure = requestFailure ?? error
        }
    }

    mutating func note(serviceFailure error: ProviderError) {
        serviceFailure = serviceFailure ?? error
    }

    mutating func refuse(_ ids: [String], _ error: ProviderError) {
        refused += ids
        refusal = refusal ?? error
    }

    /// The error the call throws when it owes anything: the gravest it met, since that is what the outbox's policy
    /// should follow (wait for sign-in, wait out the throttle, back off, or count towards a give-up).
    var gravest: ProviderError? {
        guard !failing.isEmpty || !refused.isEmpty || !unsent.isEmpty else { return nil }
        if unauthorized { return .unauthorized }
        if let throttle { return throttle }
        if let requestFailure { return requestFailure }
        if !failing.isEmpty, let serviceFailure { return serviceFailure }
        return refusal ?? serviceFailure ?? .network("apply left messages unchanged")
    }
}
