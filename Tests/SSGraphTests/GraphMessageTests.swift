import Foundation
import SSCore
import XCTest
@testable import SSGraph

final class GraphMessageTests: GraphTestCase {
    func testMetadataMapsEveryField() async throws {
        route { request in
            if let reply = self.wellKnownFolderReply(request) { return reply }
            return self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 200, body: Fixtures.fullMessage) }
        }

        let messages = try await makeProvider().metadata(for: ["M-FULL"])

        XCTAssertEqual(messages.count, 1)
        let m = try XCTUnwrap(messages.first)
        XCTAssertEqual(m.id, MessageID(accountID: accountID, providerID: "M-FULL"))
        XCTAssertEqual(m.conversationID, ConversationID(accountID: accountID, providerID: "C-FULL"))
        XCTAssertEqual(m.internetMessageID, "<full@example.com>")
        XCTAssertNil(m.inReplyTo)
        XCTAssertEqual(m.references, [])
        XCTAssertEqual(m.subject, "Quarterly numbers")
        XCTAssertEqual(m.snippet, "Here are the numbers")
        XCTAssertEqual(m.from, EmailAddress(name: "Alice Example", address: "alice@example.com"))
        XCTAssertEqual(m.to, [EmailAddress(name: "Bob", address: "bob@example.com"), EmailAddress(name: nil, address: "me@example.com")])
        XCTAssertEqual(m.cc, [EmailAddress(name: "Carol", address: "carol@example.com")])
        XCTAssertEqual(m.bcc, [EmailAddress(name: nil, address: "dave@example.com")])
        XCTAssertEqual(m.replyTo, [EmailAddress(name: "Alice Replies", address: "replies@example.com")])
        XCTAssertEqual(m.date, now.addingTimeInterval(-30 * 60))
        XCTAssertEqual(m.roles, [.inbox])
        XCTAssertFalse(m.isRead)
        XCTAssertTrue(m.isStarred)
        XCTAssertEqual(m.inboxSection, .other)
        XCTAssertTrue(m.hasAttachments)
        XCTAssertEqual(m.labelIDs, [])
        XCTAssertEqual(m.folderID, "F-INBOX")
        XCTAssertEqual(m.providerVersion, "CQAAABYAAAA")
        XCTAssertNil(m.sizeBytes)

        let inner = innerBatchRequests()
        XCTAssertEqual(inner.count, 1)
        XCTAssertEqual(inner[0]["method"] as? String, "GET")
        XCTAssertEqual(inner[0]["url"] as? String, "/me/messages/M-FULL?$select=\(GraphProvider.metadataSelect)")
        XCTAssertEqual((inner[0]["headers"] as? [String: String])?["Prefer"], "IdType=\"ImmutableId\"")
    }

    func testMetadataOmitsUnknownIDsKeepsOrderAndCachesFolders() async throws {
        route { request in
            if let reply = self.wellKnownFolderReply(request) { return reply }
            return self.batchReply(request) { id, url in
                if url.contains("missing") { return Fixtures.BatchItem(id: id, status: 404, body: Fixtures.notFoundError) }
                let messageID = url.split(separator: "/")[2].split(separator: "?")[0]
                return Fixtures.BatchItem(id: id, status: 200, body: Fixtures.message(id: String(messageID), folder: "F-SENT"))
            }
        }
        let provider = makeProvider()

        let first = try await provider.metadata(for: ["a", "missing", "b"])
        XCTAssertEqual(first.map(\.id.providerID), ["a", "b"])
        XCTAssertEqual(first.map(\.roles), [[.sent], [.sent]])

        StubURLProtocol.clearRequests()
        let second = try await provider.metadata(for: ["c"])
        XCTAssertEqual(second.map(\.id.providerID), ["c"])
        XCTAssertEqual(requests.map(\.path), ["/v1.0/$batch"], "system folder ids are cached after the first lookup")
    }

    /// A message Graph will not return on its own (403 ErrorAccessDenied, or a 500 for that one part) is left out like
    /// an unknown one: a server search keeps its other hits. A lookup says which ones, so a reconcile keeps them.
    func testMetadataLeavesOutAMessageGraphWillNotReturn() async throws {
        route { request in
            if let reply = self.wellKnownFolderReply(request) { return reply }
            return self.batchReply(request) { id, url in
                if url.contains("denied") {
                    return Fixtures.BatchItem(id: id, status: 403, body: #"{"error":{"code":"ErrorAccessDenied","message":"Access is denied."}}"#)
                }
                if url.contains("broken") {
                    return Fixtures.BatchItem(id: id, status: 500, body: #"{"error":{"code":"ErrorInternalServerError","message":""}}"#)
                }
                if url.contains("missing") { return Fixtures.BatchItem(id: id, status: 404, body: Fixtures.notFoundError) }
                let messageID = url.split(separator: "/")[2].split(separator: "?")[0]
                return Fixtures.BatchItem(id: id, status: 200, body: Fixtures.message(id: String(messageID), folder: "F-INBOX"))
            }
        }
        let provider = makeProvider()

        let found = try await provider.metadata(for: ["a", "denied", "broken", "b"])
        XCTAssertEqual(found.map(\.id.providerID), ["a", "b"])

        let lookup = try await provider.lookUpMetadata(for: ["a", "denied", "missing", "broken"])
        XCTAssertEqual(lookup.messages.map(\.id.providerID), ["a"])
        XCTAssertEqual(Set(lookup.unreadable), ["denied", "broken"], "an unknown id is neither found nor unreadable")
    }

    /// A throttle in a part is the mailbox's, not the message's: the lookup still fails.
    func testMetadataStillFailsOnAThrottledPart() async {
        route { request in
            if let reply = self.wellKnownFolderReply(request) { return reply }
            return self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 429, headers: ["Retry-After": "3"]) }
        }
        await expectProviderError({ try await self.makeProvider().metadata(for: ["a"]) }) { $0.retryAfter == 3 }
    }

    func testMetadataSplitsIntoBatchesOfTwenty() async throws {
        route { request in
            if let reply = self.wellKnownFolderReply(request) { return reply }
            return self.batchReply(request) { id, _ in Fixtures.BatchItem(id: id, status: 200, body: Fixtures.message(id: "x", folder: "F-INBOX")) }
        }
        let ids = (1...41).map { "id-\($0)" }
        let result = try await makeProvider().metadata(for: ids)
        XCTAssertEqual(result.count, 41)
        XCTAssertEqual(requests(to: "/v1.0/$batch").map { ($0.json()["requests"] as? [Any])?.count }, [20, 20, 1])
    }

    func testMapperFallbacks() throws {
        let mapper = GraphMessageMapper(accountID: accountID, folders: GraphWellKnownFolders(ids: Fixtures.folderIDs))
        let minimal = try GraphJSON.decode(GraphMessage.self, from: Data(#"{"id":"M-MIN","isDraft":true,"parentFolderId":"F-DRAFTS","inferenceClassification":"focused","flag":{"flagStatus":"notFlagged"}}"#.utf8))

        let m = mapper.metadata(from: minimal)

        XCTAssertEqual(m.conversationID.providerID, "M-MIN", "a draft without a conversation threads to itself")
        XCTAssertEqual(m.roles, [.drafts])
        XCTAssertEqual(m.subject, "")
        XCTAssertEqual(m.snippet, "")
        XCTAssertNil(m.from)
        XCTAssertTrue(m.isRead)
        XCTAssertFalse(m.isStarred)
        XCTAssertEqual(m.inboxSection, .focused)
        XCTAssertFalse(m.hasAttachments)
        XCTAssertEqual(m.date, Date(timeIntervalSince1970: 0))

        let trash = try GraphJSON.decode(GraphMessage.self, from: Data(Fixtures.message(id: "t", folder: "F-TRASH", classification: "weird").utf8))
        XCTAssertEqual(mapper.metadata(from: trash).roles, [.trash])
        XCTAssertEqual(mapper.metadata(from: trash).inboxSection, .unknown)
        let junk = try GraphJSON.decode(GraphMessage.self, from: Data(Fixtures.message(id: "j", folder: "F-JUNK").utf8))
        XCTAssertEqual(mapper.metadata(from: junk).roles, [.spam])
    }

    func testBodyWithInlineAttachmentAndContentID() async throws {
        route { request in
            guard request.method == "GET" else { return nil }
            switch request.path {
            case "/v1.0/me/messages/M-1": return .json(Fixtures.htmlBody)
            case "/v1.0/me/messages/M-1/attachments": return .json(Fixtures.attachments)
            default: return nil
            }
        }

        let body = try await makeProvider().body(for: "M-1")

        XCTAssertEqual(body.html, "<html><body><p>Hi <img src=\"cid:img1@example.com\"></p></body></html>")
        XCTAssertNil(body.text)
        XCTAssertEqual(body.attachments, [
            AttachmentInfo(id: "A-1", filename: "logo.png", mimeType: "image/png", sizeBytes: 1234, contentID: "img1@example.com", isInline: true),
            AttachmentInfo(id: "A-2", filename: "report.pdf", mimeType: "application/pdf", sizeBytes: 98765, contentID: nil, isInline: false),
        ])
        let messageRequest = try XCTUnwrap(requests(to: "/v1.0/me/messages/M-1").first)
        XCTAssertEqual(messageRequest.query["$select"], "body,uniqueBody,internetMessageHeaders")
        XCTAssertEqual(messageRequest.header("Prefer"), "IdType=\"ImmutableId\", outlook.body-content-type=\"html\"")
        let attachmentRequest = try XCTUnwrap(requests(to: "/v1.0/me/messages/M-1/attachments").first)
        XCTAssertEqual(attachmentRequest.query["$select"], "id,name,contentType,size,isInline,microsoft.graph.fileAttachment/contentId")
    }

    /// The body fetch is Graph's only way to the list headers (roadmap Q2.4): they come back with the body, trimmed, for
    /// the store to write on the message. A body whose message has none carries none, and metadata never does.
    func testTheBodyFetchCapturesTheListHeaders() async throws {
        route { request in
            switch request.path {
            case "/v1.0/me/messages/M-3": return .json(Fixtures.newsletterBody)
            case "/v1.0/me/messages/M-3/attachments", "/v1.0/me/messages/M-1/attachments": return .json(Fixtures.list([]))
            case "/v1.0/me/messages/M-1": return .json(Fixtures.htmlBody)
            default: return nil
            }
        }
        let body = try await makeProvider().body(for: "M-3")
        XCTAssertEqual(body.html, "<p>This week</p>")
        XCTAssertEqual(body.listUnsubscribe, "<mailto:leave@news.example.com?subject=unsubscribe>, <https://news.example.com/u/7>")
        XCTAssertEqual(body.listUnsubscribePost, "List-Unsubscribe=One-Click")
        XCTAssertEqual(UnsubscribeMethod(listUnsubscribe: body.listUnsubscribe, post: body.listUnsubscribePost),
                       .oneClick(URL(string: "https://news.example.com/u/7")!))
        XCTAssertEqual(try XCTUnwrap(requests(to: "/v1.0/me/messages/M-3").first).query["$select"], "body,uniqueBody,internetMessageHeaders")

        let other = try await makeProvider().body(for: "M-1")
        XCTAssertNil(other.listUnsubscribe, "headers without the list ones")
        XCTAssertNil(other.listUnsubscribePost)
        XCTAssertFalse(GraphProvider.metadataSelect.contains("internetMessageHeaders"), "list calls cannot carry them")
    }

    func testBodyTextOnly() async throws {
        route { request in
            switch request.path {
            case "/v1.0/me/messages/M-2": return .json(Fixtures.textBody)
            case "/v1.0/me/messages/M-2/attachments": return .json(Fixtures.list([]))
            default: return nil
            }
        }
        let body = try await makeProvider().body(for: "M-2")
        XCTAssertNil(body.html)
        XCTAssertEqual(body.text, "Plain words only")
        XCTAssertTrue(body.attachments.isEmpty)
    }

    /// `contentId` exists only on fileAttachment, so the base collection rejects selecting it by its bare
    /// name. When even the derived-type form is refused, images are looked up one by one: without their
    /// Content-ID, `cid:` references in the body could never resolve.
    func testAttachmentListFallsBackWhenContentIdIsRejected() async throws {
        let listing = """
        {"value":[
        {"@odata.type":"#microsoft.graph.fileAttachment","id":"A-1","name":"logo.png","contentType":"image/png","size":1234,"isInline":true},
        {"@odata.type":"#microsoft.graph.fileAttachment","id":"A-2","name":"report.pdf","contentType":"application/pdf","size":98765,"isInline":false}
        ]}
        """
        route { request in
            switch request.path {
            case "/v1.0/me/messages/M-2": return .json(Fixtures.textBody)
            case "/v1.0/me/messages/M-2/attachments":
                let select = request.query["$select"] ?? ""
                return select.contains("contentId") ? .json(Fixtures.badRequestError, status: 400) : .json(listing)
            case "/v1.0/me/messages/M-2/attachments/A-1":
                return .json(##"{"@odata.type":"#microsoft.graph.fileAttachment","id":"A-1","contentId":"<img1@example.com>"}"##)
            default: return nil
            }
        }
        let body = try await makeProvider().body(for: "M-2")
        XCTAssertEqual(body.attachments.map(\.id), ["A-1", "A-2"])
        XCTAssertEqual(body.attachments.map(\.contentID), ["img1@example.com", nil])
        XCTAssertEqual(requests(to: "/v1.0/me/messages/M-2/attachments").map { $0.query["$select"] }, [
            "id,name,contentType,size,isInline,microsoft.graph.fileAttachment/contentId",
            "id,name,contentType,size,isInline",
        ])
        XCTAssertEqual(requests(to: "/v1.0/me/messages/M-2/attachments/A-1").count, 1)
        XCTAssertTrue(requests(to: "/v1.0/me/messages/M-2/attachments/A-2").isEmpty, "only images are looked up")
    }

    func testAttachmentBytesFromValueEndpoint() async throws {
        let bytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D])
        route { request in request.path == "/v1.0/me/messages/M-1/attachments/A-2/$value" ? .bytes(bytes) : nil }

        let data = try await makeProvider().attachment(messageID: "M-1", attachmentID: "A-2")

        XCTAssertEqual(data, bytes)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.header("Accept"), "*/*")
    }

    func testAttachmentBytesFallBackToContentBytes() async throws {
        let bytes = Data([9, 8, 7, 6, 5])
        route { request in
            switch request.path {
            case "/v1.0/me/messages/M-1/attachments/A-2/$value": return .json(Fixtures.notFoundError, status: 404)
            case "/v1.0/me/messages/M-1/attachments/A-2": return .json(Fixtures.attachmentWithBytes(bytes))
            default: return nil
            }
        }

        let data = try await makeProvider().attachment(messageID: "M-1", attachmentID: "A-2")

        XCTAssertEqual(data, bytes)
        XCTAssertEqual(requests.map(\.path), ["/v1.0/me/messages/M-1/attachments/A-2/$value", "/v1.0/me/messages/M-1/attachments/A-2"])
    }

    func testDateParsing() throws {
        XCTAssertEqual(GraphDate.parse("2026-11-01T10:00:00Z"), now)
        XCTAssertEqual(try XCTUnwrap(GraphDate.parse("2026-11-01T10:00:00.5Z")).timeIntervalSince1970, now.timeIntervalSince1970 + 0.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(GraphDate.parse("2026-11-01T10:00:00.1234567Z")).timeIntervalSince1970, now.timeIntervalSince1970 + 0.123, accuracy: 0.001)
        XCTAssertNil(GraphDate.parse("yesterday"))
        XCTAssertEqual(GraphDate.string(now), nowString)
    }

    func testSearchSendsQuotedTextAndReturnsIDsInOrder() async throws {
        route { request in
            guard request.method == "GET", request.path == "/v1.0/me/messages" else { return nil }
            return .json(Fixtures.list([#"{"id":"s-2"}"#, #"{"id":"s-1"}"#]))
        }

        let ids = try await makeProvider().search("invoice \"paid\"", limit: 25)

        XCTAssertEqual(ids, ["s-2", "s-1"])
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.query["$search"], "\"invoice \\\"paid\\\"\"")
        XCTAssertEqual(request.query["$top"], "25")
        XCTAssertEqual(request.query["$select"], "id")
    }

    /// Graph reads a bare '+' in a query as a space, so it goes as %2B; a trailing backslash is escaped so it cannot
    /// escape the closing quote.
    func testSearchSendsPlusSignsAndBackslashesAsTyped() async throws {
        route { request in
            guard request.method == "GET", request.path == "/v1.0/me/messages" else { return nil }
            return .json(Fixtures.list([#"{"id":"s-1"}"#]))
        }

        _ = try await makeProvider().search(#"c++ from:me+news@contoso.com foo\"#, limit: 25)

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.query["$search"], #""c++ from:me+news@contoso.com foo\\""#)
        let raw = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        XCTAssertTrue(raw.hasPrefix("$search=%22c%2B%2B%20from:me%2Bnews@contoso.com%20foo%5C%5C%22&"), raw)
        XCTAssertFalse(raw.contains("+"), raw)
    }

    /// The engine's search of the server (Q3.1) asks for 50; a larger ask is held to `$search`'s page size.
    func testSearchHoldsTheLimitToTheSearchPageSize() async throws {
        route { request in
            guard request.method == "GET", request.path == "/v1.0/me/messages" else { return nil }
            return .json(Fixtures.list([#"{"id":"s-1"}"#]))
        }

        _ = try await makeProvider().search("lisbon", limit: 5_000)

        XCTAssertEqual(requests.first?.query["$top"], "250")
    }

    /// A throttled search reaches the engine as a throttle with Graph's retry time.
    func testAThrottledSearchIsThrottledWithItsRetryAfter() async {
        route { request in
            guard request.path == "/v1.0/me/messages" else { return nil }
            return .json(#"{"error":{"code":"TooManyRequests","message":"slow down"}}"#, status: 429, headers: ["Retry-After": "7"])
        }
        await expectProviderError({ try await self.makeProvider().search("lisbon", limit: 50) }) { $0.retryAfter == 7 }
    }

    func testSearchWithBlankTextMakesNoRequest() async throws {
        let ids = try await makeProvider().search("   ", limit: 25)
        XCTAssertTrue(ids.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }

    func testProfileUsesMailThenPrincipalName() async throws {
        route { _ in .json(Fixtures.user) }
        let withMail = try await makeProvider().profile()
        XCTAssertEqual(withMail, AccountProfile(email: "robin@example.com", displayName: "Robin Example"))
        XCTAssertEqual(requests.first?.query["$select"], "displayName,mail,userPrincipalName")

        route { _ in .json(Fixtures.userWithoutMail) }
        let withoutMail = try await makeProvider().profile()
        XCTAssertEqual(withoutMail, AccountProfile(email: "robin@outlook.com", displayName: "Robin Example"))
    }
}
