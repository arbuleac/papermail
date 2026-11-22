import Foundation

/// Replies of Gmail's `users.settings.filters` methods, in the shapes the API documents and returns (ids anonymized).
/// The refusals for a duplicate filter and for the cap on filters follow the shape of Gmail's other `failedPrecondition`
/// replies; their wording is what the provider matches, and could not be recorded against a live mailbox here.
enum GmailFilterFixtures {
    /// Four sender rules (one address with both an archive and a block filter) among filters of every other kind.
    static let list = #"""
    {"filter": [
     {"id": "ANe1BmjSender1", "criteria": {"from": "news@letter.example"}, "action": {"removeLabelIds": ["INBOX"]}},
     {"id": "ANe1BmjSender2", "criteria": {"from": "Deals@Shop.Example"}, "action": {"addLabelIds": ["TRASH"]}},
     {"id": "ANe1BmjSender3", "criteria": {"from": "spam@junk.example", "excludeChats": true},
      "action": {"addLabelIds": ["TRASH"], "removeLabelIds": ["INBOX"]}},
     {"id": "ANe1BmjSender4", "criteria": {"from": "deals@shop.example", "excludeChats": false, "hasAttachment": false},
      "action": {"removeLabelIds": ["INBOX"], "addLabelIds": []}},
     {"id": "ANe1BmjLabel01", "criteria": {"from": "billing@vendor.example"}, "action": {"addLabelIds": ["Label_12"]}},
     {"id": "ANe1BmjSubject", "criteria": {"from": "ci@build.example", "subject": "failed"}, "action": {"removeLabelIds": ["INBOX"]}},
     {"id": "ANe1BmjOrAddrs", "criteria": {"from": "a@x.example OR b@x.example"}, "action": {"removeLabelIds": ["INBOX"]}},
     {"id": "ANe1BmjDomain1", "criteria": {"from": "vendor.example"}, "action": {"removeLabelIds": ["INBOX"]}},
     {"id": "ANe1BmjBraces1", "criteria": {"from": "{a@x.example b@x.example}"}, "action": {"addLabelIds": ["TRASH"]}},
     {"id": "ANe1BmjWildcrd", "criteria": {"from": "*@x.example"}, "action": {"addLabelIds": ["TRASH"]}},
     {"id": "ANe1BmjArchRd1", "criteria": {"from": "digest@news.example"}, "action": {"removeLabelIds": ["INBOX", "UNREAD"]}},
     {"id": "ANe1BmjForward", "criteria": {"from": "boss@work.example"}, "action": {"forward": "me@other.example"}},
     {"id": "ANe1BmjFwdArch", "criteria": {"from": "boss2@work.example"},
      "action": {"removeLabelIds": ["INBOX"], "forward": "me@other.example"}},
     {"id": "ANe1BmjQuery01", "criteria": {"query": "from:x@y.example newsletter"}, "action": {"removeLabelIds": ["INBOX"]}},
     {"id": "ANe1BmjTrashSt", "criteria": {"from": "promo@shop.example"}, "action": {"addLabelIds": ["TRASH", "STARRED"]}},
     {"id": "ANe1BmjAttach1", "criteria": {"from": "scans@printer.example", "hasAttachment": true},
      "action": {"removeLabelIds": ["INBOX"]}},
     {"id": "ANe1BmjNegated", "criteria": {"from": "team@work.example", "negatedQuery": "urgent"},
      "action": {"removeLabelIds": ["INBOX"]}},
     {"id": "ANe1BmjSize001", "criteria": {"from": "big@files.example", "size": 10485760, "sizeComparison": "larger"},
      "action": {"addLabelIds": ["TRASH"]}},
     {"id": "ANe1BmjTo00001", "criteria": {"from": "list@groups.example", "to": "me+lists@gmail.example"},
      "action": {"removeLabelIds": ["INBOX"]}},
     {"id": "ANe1BmjFuture1", "criteria": {"from": "a@future.example", "fromVerified": true}, "action": {"removeLabelIds": ["INBOX"]}},
     {"id": "ANe1BmjNoActn1", "criteria": {"from": "quiet@x.example"}, "action": {}},
     {"id": "ANe1BmjSpamRm1", "criteria": {"from": "friend@x.example"}, "action": {"removeLabelIds": ["SPAM"]}},
     {"id": "ANe1BmjNegFrm1", "criteria": {"from": "-a@x.example"}, "action": {"removeLabelIds": ["INBOX"]}},
     {"criteria": {"from": "noid@x.example"}, "action": {"removeLabelIds": ["INBOX"]}}
    ]}
    """#

    /// A mailbox with no filters: Gmail leaves the list out altogether.
    static let none = "{}"

    static func created(_ id: String, from address: String, archive: Bool) -> String {
        let action = archive ? #"{"removeLabelIds": ["INBOX"]}"# : #"{"addLabelIds": ["TRASH"]}"#
        return #"{"id": "\#(id)", "criteria": {"from": "\#(address)"}, "action": \#(action)}"#
    }

    static let alreadyExists = #"""
    {"error": {"code": 400, "message": "Filter already exists",
     "errors": [{"message": "Filter already exists", "domain": "global", "reason": "failedPrecondition"}],
     "status": "FAILED_PRECONDITION"}}
    """#

    static let tooManyFilters = #"""
    {"error": {"code": 400, "message": "Too many filters",
     "errors": [{"message": "Too many filters", "domain": "global", "reason": "failedPrecondition"}],
     "status": "FAILED_PRECONDITION"}}
    """#

    static let invalidCriteria = #"""
    {"error": {"code": 400, "message": "Invalid filter criteria",
     "errors": [{"message": "Invalid filter criteria", "domain": "global", "reason": "invalidArgument"}],
     "status": "INVALID_ARGUMENT"}}
    """#

    /// A token without `gmail.settings.basic`.
    static let scopeInsufficient = #"""
    {"error": {"code": 403, "message": "Request had insufficient authentication scopes.",
     "errors": [{"message": "Insufficient Permission", "domain": "global", "reason": "insufficientPermissions"}],
     "status": "PERMISSION_DENIED",
     "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
       "domain": "googleapis.com", "metadata": {"service": "gmail.googleapis.com", "method": "caribou.api.proto.MailboxService.ListFilters"}}]}}
    """#

    static let scopeInsufficientDetailsOnly = #"""
    {"error": {"code": 403, "message": "Request had insufficient authentication scopes.", "status": "PERMISSION_DENIED",
     "details": [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
       "domain": "googleapis.com", "metadata": {"service": "gmail.googleapis.com"}}]}}
    """#

    /// A Workspace mailbox whose admin keeps users from managing filters.
    static let forbidden = #"""
    {"error": {"code": 403, "message": "Mail service not enabled",
     "errors": [{"message": "Mail service not enabled", "domain": "global", "reason": "failedPrecondition"}],
     "status": "FAILED_PRECONDITION"}}
    """#

    static let rateLimit = #"""
    {"error": {"code": 403, "message": "User-rate limit exceeded.  Retry after 2099-11-07T10:30:00.000Z",
     "errors": [{"domain": "usageLimits", "reason": "userRateLimitExceeded",
       "message": "User-rate limit exceeded.  Retry after 2099-11-07T10:30:00.000Z"}]}}
    """#

    static let dailyLimit = #"""
    {"error": {"code": 403, "message": "Daily Limit Exceeded",
     "errors": [{"domain": "usageLimits", "reason": "dailyLimitExceeded", "message": "Daily Limit Exceeded"}]}}
    """#

    static let tooManyRequests = #"""
    {"error": {"code": 429, "message": "Too many concurrent requests for user",
     "errors": [{"domain": "global", "reason": "rateLimitExceeded", "message": "Too many concurrent requests for user"}],
     "status": "RESOURCE_EXHAUSTED"}}
    """#

    static let notFound = #"""
    {"error": {"code": 404, "message": "Requested entity was not found.",
     "errors": [{"message": "Requested entity was not found.", "domain": "global", "reason": "notFound"}], "status": "NOT_FOUND"}}
    """#

    static let backendError = #"""
    {"error": {"code": 500, "message": "Backend Error",
     "errors": [{"message": "Backend Error", "domain": "global", "reason": "backendError"}], "status": "INTERNAL"}}
    """#
}
