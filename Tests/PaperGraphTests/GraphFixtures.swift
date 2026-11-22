import Foundation

/// Graph JSON shapes as string constants and small builders. Anonymized from real responses.
enum Fixtures {
    static let folderIDs: [String: String] = [
        "inbox": "F-INBOX",
        "sentitems": "F-SENT",
        "drafts": "F-DRAFTS",
        "deleteditems": "F-TRASH",
        "junkemail": "F-JUNK",
        "archive": "F-ARCHIVE",
    ]

    static func folder(_ id: String) -> String {
        #"{"@odata.context":"https://graph.microsoft.com/v1.0/$metadata#users('me')/mailFolders(id)/$entity","id":"\#(id)"}"#
    }

    static let folderList = """
    {"@odata.context":"https://graph.microsoft.com/v1.0/$metadata#users('me')/mailFolders(id,childFolderCount)","value":[
    {"id":"F-INBOX","childFolderCount":0},
    {"id":"F-SENT","childFolderCount":0},
    {"id":"F-DRAFTS","childFolderCount":0},
    {"id":"F-TRASH","childFolderCount":0},
    {"id":"F-JUNK","childFolderCount":0},
    {"id":"F-ARCHIVE","childFolderCount":0},
    {"id":"F-PROJECTS","childFolderCount":2}
    ]}
    """

    static let childFolders = """
    {"value":[{"id":"F-PROJECTS-A","childFolderCount":0},{"id":"F-PROJECTS-B","childFolderCount":0}]}
    """

    static let allFolderIDs: Set<String> = [
        "F-INBOX", "F-SENT", "F-DRAFTS", "F-TRASH", "F-JUNK", "F-ARCHIVE", "F-PROJECTS", "F-PROJECTS-A", "F-PROJECTS-B",
    ]

    static let notFoundError = #"{"error":{"code":"ErrorItemNotFound","message":"The specified object was not found in the store."}}"#
    static let syncStateNotFoundError = #"{"error":{"code":"SyncStateNotFound","message":"The sync state is not found."}}"#
    static let badRequestError = #"{"error":{"code":"BadRequest","message":"Could not find a property named 'contentId'."}}"#

    static let user = """
    {"id":"user-robin-1","displayName":"Robin Example","mail":"robin@example.com","userPrincipalName":"robin_example.com#EXT#@tenant.onmicrosoft.com"}
    """

    static let userWithoutMail = """
    {"displayName":"Robin Example","mail":null,"userPrincipalName":"robin@outlook.com"}
    """

    static func message(
        id: String,
        folder: String,
        conversation: String = "C-1",
        subject: String = "Hello",
        received: String = "2026-11-01T09:30:00Z",
        isRead: Bool = false,
        flagged: Bool = false,
        classification: String = "focused",
        isDraft: Bool = false,
        hasAttachments: Bool = false
    ) -> String {
        """
        {"id":"\(id)","conversationId":"\(conversation)","conversationIndex":"AQHcBKbV","internetMessageId":"<\(id)@example.com>","subject":"\(subject)","bodyPreview":"Preview of \(id)","from":{"emailAddress":{"name":"Sender","address":"sender@example.com"}},"toRecipients":[{"emailAddress":{"name":"Me","address":"me@example.com"}}],"ccRecipients":[],"bccRecipients":[],"replyTo":[],"receivedDateTime":"\(received)","isRead":\(isRead),"flag":{"flagStatus":"\(flagged ? "flagged" : "notFlagged")"},"inferenceClassification":"\(classification)","parentFolderId":"\(folder)","hasAttachments":\(hasAttachments),"changeKey":"CK-\(id)","isDraft":\(isDraft)}
        """
    }

    static let fullMessage = """
    {
      "@odata.etag": "W/\\"CQAAABYAAAA\\"",
      "id": "M-FULL",
      "conversationId": "C-FULL",
      "conversationIndex": "AQHcBKbVxQ==",
      "internetMessageId": "<full@example.com>",
      "subject": "Quarterly numbers",
      "bodyPreview": "Here are the numbers",
      "from": {"emailAddress": {"name": "Alice Example", "address": "alice@example.com"}},
      "toRecipients": [
        {"emailAddress": {"name": "Bob", "address": "bob@example.com"}},
        {"emailAddress": {"name": "", "address": "me@example.com"}}
      ],
      "ccRecipients": [{"emailAddress": {"name": "Carol", "address": "carol@example.com"}}],
      "bccRecipients": [{"emailAddress": {"address": "dave@example.com"}}],
      "replyTo": [{"emailAddress": {"name": "Alice Replies", "address": "replies@example.com"}}],
      "receivedDateTime": "2026-11-01T09:30:00Z",
      "isRead": false,
      "flag": {"flagStatus": "flagged"},
      "inferenceClassification": "other",
      "parentFolderId": "F-INBOX",
      "hasAttachments": true,
      "changeKey": "CQAAABYAAAA",
      "isDraft": false
    }
    """

    static func removed(_ id: String) -> String {
        #"{"id":"\#(id)","@removed":{"reason":"deleted"}}"#
    }

    static func list(_ items: [String], nextLink: String? = nil, deltaLink: String? = nil) -> String {
        var parts = ["\"value\":[\(items.joined(separator: ","))]"]
        if let nextLink { parts.append("\"@odata.nextLink\":\"\(nextLink)\"") }
        if let deltaLink { parts.append("\"@odata.deltaLink\":\"\(deltaLink)\"") }
        return "{\(parts.joined(separator: ","))}"
    }

    static let htmlBody = """
    {"id":"M-1","body":{"contentType":"html","content":"<html><body><p>Hi <img src=\\"cid:img1@example.com\\"></p></body></html>"},"uniqueBody":{"contentType":"html","content":"<p>Hi</p>"},"internetMessageHeaders":[{"name":"In-Reply-To","value":"<parent@example.com>"}]}
    """

    /// A list's message as the body fetch returns it: list and delta calls cannot select headers, so this is where the
    /// list headers arrive, in whatever case the sender wrote their names.
    static let newsletterBody = """
    {"id":"M-3","body":{"contentType":"html","content":"<p>This week</p>"},"internetMessageHeaders":[\
    {"name":"Received","value":"from mx.example.com"},\
    {"name":"LIST-UNSUBSCRIBE","value":" <mailto:leave@news.example.com?subject=unsubscribe>, <https://news.example.com/u/7> "},\
    {"name":"List-Unsubscribe-Post","value":"List-Unsubscribe=One-Click"}]}
    """

    static let textBody = """
    {"id":"M-2","body":{"contentType":"text","content":"Plain words only"},"uniqueBody":{"contentType":"text","content":"Plain words only"}}
    """

    static let attachments = """
    {"value":[
    {"@odata.type":"#microsoft.graph.fileAttachment","id":"A-1","name":"logo.png","contentType":"image/png","size":1234,"isInline":true,"contentId":"<img1@example.com>"},
    {"@odata.type":"#microsoft.graph.fileAttachment","id":"A-2","name":"report.pdf","contentType":"application/pdf","size":98765,"isInline":false,"contentId":null}
    ]}
    """

    static let attachmentsWithoutContentId = """
    {"value":[{"@odata.type":"#microsoft.graph.fileAttachment","id":"A-2","name":"report.pdf","contentType":"application/pdf","size":98765,"isInline":false}]}
    """

    static func attachmentWithBytes(_ data: Data) -> String {
        // Double-pound delimiters because the OData type annotation itself contains `"#`.
        ##"{"@odata.type":"#microsoft.graph.fileAttachment","id":"A-2","name":"report.pdf","contentType":"application/pdf","size":\##(data.count),"isInline":false,"contentBytes":"\##(data.base64EncodedString())"}"##
    }

    static func draft(id: String, conversation: String) -> String {
        #"{"id":"\#(id)","conversationId":"\#(conversation)","subject":"RE: Original","isDraft":true,"parentFolderId":"F-DRAFTS"}"#
    }

    static func original(id: String, conversation: String, cc: [String]) -> String {
        let ccJSON = cc.map { #"{"emailAddress":{"name":"","address":"\#($0)"}}"# }.joined(separator: ",")
        return #"{"id":"\#(id)","conversationId":"\#(conversation)","from":{"emailAddress":{"name":"Alice","address":"alice@example.com"}},"toRecipients":[{"emailAddress":{"name":"Me","address":"me@example.com"}}],"ccRecipients":[\#(ccJSON)]}"#
    }

    struct BatchItem {
        var id: String
        var status: Int
        var headers: [String: String] = [:]
        var body: String? = nil
    }

    static func batch(_ items: [BatchItem]) -> String {
        let encoded = items.map { item -> String in
            var parts = ["\"id\":\"\(item.id)\"", "\"status\":\(item.status)"]
            if !item.headers.isEmpty {
                let headers = item.headers.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
                parts.append("\"headers\":{\(headers)}")
            }
            if let body = item.body { parts.append("\"body\":\(body)") }
            return "{\(parts.joined(separator: ","))}"
        }
        return "{\"responses\":[\(encoded.joined(separator: ","))]}"
    }
}
