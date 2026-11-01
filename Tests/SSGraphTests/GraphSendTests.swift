import Foundation
import SSCore
import XCTest
@testable import SSGraph

final class GraphSendTests: GraphTestCase {
    private let html = "<p>See attached <img src=\"cid:img1\"></p>"

    private var message: OutgoingMessage {
        OutgoingMessage(
            accountID: accountID,
            to: [EmailAddress(name: "Alice", address: "alice@example.com")],
            cc: [EmailAddress(address: "carol@example.com")],
            bcc: [EmailAddress(name: "Dave", address: "dave@example.com")],
            subject: "Numbers",
            html: html,
            text: "See attached",
            attachments: [
                OutgoingAttachment(filename: "chart.png", mimeType: "image/png", data: Data([1, 2, 3]), contentID: "img1"),
                OutgoingAttachment(filename: "numbers.pdf", mimeType: "application/pdf", data: Data([4, 5, 6, 7])),
            ]
        )
    }

    private func routeReplyFlow(originalCC: [String], action: String) {
        route { request in
            switch (request.method, request.path) {
            case ("GET", "/v1.0/me/messages/ORIG"):
                return .json(Fixtures.original(id: "ORIG", conversation: "C-ORIG", cc: originalCC))
            case ("POST", "/v1.0/me/messages/ORIG/\(action)"):
                return .json(Fixtures.draft(id: "DRAFT-1", conversation: "C-ORIG"), status: 201)
            case ("PATCH", "/v1.0/me/messages/DRAFT-1"):
                return .json(Fixtures.draft(id: "DRAFT-1", conversation: "C-ORIG"))
            case ("POST", "/v1.0/me/messages/DRAFT-1/attachments"):
                return .json(#"{"id":"ATT"}"#, status: 201)
            case ("POST", "/v1.0/me/messages/DRAFT-1/send"):
                return .status(202)
            default:
                return nil
            }
        }
    }

    func testSendMailBodyJSON() async throws {
        route { request in request.method == "POST" && request.path == "/v1.0/me/sendMail" ? .status(202) : nil }

        let receipt = try await makeProvider().send(message)

        XCTAssertNil(receipt.providerMessageID)
        XCTAssertNil(receipt.providerConversationID)
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        let json = request.json()
        XCTAssertEqual(json["saveToSentItems"] as? Bool, true)
        let m = try XCTUnwrap(json["message"] as? [String: Any])
        XCTAssertEqual(m["subject"] as? String, "Numbers")
        XCTAssertEqual(m["body"] as? [String: String], ["contentType": "html", "content": html])
        XCTAssertEqual(m["toRecipients"] as? [[String: [String: String]]], [["emailAddress": ["name": "Alice", "address": "alice@example.com"]]])
        XCTAssertEqual(m["ccRecipients"] as? [[String: [String: String]]], [["emailAddress": ["address": "carol@example.com"]]])
        XCTAssertEqual(m["bccRecipients"] as? [[String: [String: String]]], [["emailAddress": ["name": "Dave", "address": "dave@example.com"]]])
        let attachments = try XCTUnwrap(m["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.count, 2)
        XCTAssertEqual(attachments[0]["@odata.type"] as? String, "#microsoft.graph.fileAttachment")
        XCTAssertEqual(attachments[0]["name"] as? String, "chart.png")
        XCTAssertEqual(attachments[0]["contentType"] as? String, "image/png")
        XCTAssertEqual(attachments[0]["contentBytes"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(attachments[0]["isInline"] as? Bool, true)
        XCTAssertEqual(attachments[0]["contentId"] as? String, "img1")
        XCTAssertEqual(attachments[1]["name"] as? String, "numbers.pdf")
        XCTAssertEqual(attachments[1]["contentBytes"] as? String, "BAUGBw==")
        XCTAssertEqual(attachments[1]["isInline"] as? Bool, false)
        XCTAssertNil(attachments[1]["contentId"])
    }

    func testReplyAllFlowWhenRecipientsCoverOriginalCC() async throws {
        routeReplyFlow(originalCC: ["carol@example.com"], action: "createReplyAll")
        var reply = message
        reply.inReplyTo = MessageID(accountID: accountID, providerID: "ORIG")
        reply.subject = "RE: Original"

        let receipt = try await makeProvider().send(reply)

        XCTAssertEqual(receipt.providerMessageID, "DRAFT-1")
        XCTAssertEqual(receipt.providerConversationID, "C-ORIG")
        XCTAssertEqual(requests.map { "\($0.method) \($0.path)" }, [
            "GET /v1.0/me/messages/ORIG",
            "POST /v1.0/me/messages/ORIG/createReplyAll",
            "PATCH /v1.0/me/messages/DRAFT-1",
            "POST /v1.0/me/messages/DRAFT-1/attachments",
            "POST /v1.0/me/messages/DRAFT-1/attachments",
            "POST /v1.0/me/messages/DRAFT-1/send",
        ])
        XCTAssertEqual(requests[0].query["$select"], "id,conversationId,from,toRecipients,ccRecipients")
        XCTAssertEqual(requests[1].body, Data("{}".utf8))
        let patch = requests[2].json()
        XCTAssertEqual(patch["subject"] as? String, "RE: Original")
        XCTAssertEqual(patch["body"] as? [String: String], ["contentType": "html", "content": html])
        XCTAssertNil(patch["attachments"], "attachments are posted separately, never inlined in the PATCH")
        XCTAssertEqual(patch["toRecipients"] as? [[String: [String: String]]], [["emailAddress": ["name": "Alice", "address": "alice@example.com"]]])
        XCTAssertEqual(patch["ccRecipients"] as? [[String: [String: String]]], [["emailAddress": ["address": "carol@example.com"]]])
        XCTAssertEqual(patch["bccRecipients"] as? [[String: [String: String]]], [["emailAddress": ["name": "Dave", "address": "dave@example.com"]]])
        let inline = requests[3].json()
        XCTAssertEqual(inline["@odata.type"] as? String, "#microsoft.graph.fileAttachment")
        XCTAssertEqual(inline["name"] as? String, "chart.png")
        XCTAssertEqual(inline["contentId"] as? String, "img1")
        XCTAssertEqual(inline["isInline"] as? Bool, true)
        XCTAssertEqual(requests[4].json()["name"] as? String, "numbers.pdf")
        XCTAssertNil(requests[5].body)
    }

    func testReplyFlowUsesCreateReplyWhenCCNotCovered() async throws {
        routeReplyFlow(originalCC: ["carol@example.com", "erin@example.com"], action: "createReply")
        var reply = message
        reply.inReplyTo = MessageID(accountID: accountID, providerID: "ORIG")
        reply.attachments = []

        let receipt = try await makeProvider().send(reply)

        XCTAssertEqual(receipt.providerMessageID, "DRAFT-1")
        XCTAssertEqual(requests.map { "\($0.method) \($0.path)" }, [
            "GET /v1.0/me/messages/ORIG",
            "POST /v1.0/me/messages/ORIG/createReply",
            "PATCH /v1.0/me/messages/DRAFT-1",
            "POST /v1.0/me/messages/DRAFT-1/send",
        ])
    }

    func testReplyToVanishedOriginalFallsBackToSendMail() async throws {
        route { request in
            switch (request.method, request.path) {
            case ("GET", "/v1.0/me/messages/ORIG"): return .json(Fixtures.notFoundError, status: 404)
            case ("POST", "/v1.0/me/sendMail"): return .status(202)
            default: return nil
            }
        }
        var reply = message
        reply.inReplyTo = MessageID(accountID: accountID, providerID: "ORIG")

        let receipt = try await makeProvider().send(reply)

        XCTAssertNil(receipt.providerMessageID)
        XCTAssertEqual(requests.map { "\($0.method) \($0.path)" }, ["GET /v1.0/me/messages/ORIG", "POST /v1.0/me/sendMail"])
    }

    func testReplyToAnotherAccountsMessageIsSentFresh() async throws {
        route { request in request.path == "/v1.0/me/sendMail" ? .status(202) : nil }
        var reply = message
        reply.inReplyTo = MessageID(accountID: AccountID("someone-else"), providerID: "ORIG")

        _ = try await makeProvider().send(reply)

        XCTAssertEqual(requests.map(\.path), ["/v1.0/me/sendMail"])
    }

    func testCoversOriginalCCRules() throws {
        let original = try GraphJSON.decode(GraphMessage.self, from: Data(Fixtures.original(id: "ORIG", conversation: "C", cc: ["Carol@Example.com"]).utf8))
        var outgoing = message
        XCTAssertTrue(GraphProvider.coversOriginalCC(outgoing, original: original), "case-insensitive address match")
        outgoing.cc = []
        XCTAssertFalse(GraphProvider.coversOriginalCC(outgoing, original: original))
        outgoing.to.append(EmailAddress(address: "carol@example.com"))
        XCTAssertTrue(GraphProvider.coversOriginalCC(outgoing, original: original), "cc members moved to the To line still count")
        let noCC = try GraphJSON.decode(GraphMessage.self, from: Data(Fixtures.original(id: "ORIG", conversation: "C", cc: []).utf8))
        XCTAssertFalse(GraphProvider.coversOriginalCC(outgoing, original: noCC), "nothing to cover means a plain reply")
    }
}
