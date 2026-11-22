import Foundation
@testable import PaperGmail

/// Anonymized shapes of real Gmail API replies, kept as string constants so the tests need no bundle resources.
enum GmailFixtures {
    static let profile = """
    {"emailAddress":"ada@example.com","messagesTotal":1234,"threadsTotal":500,"historyId":"8675309"}
    """

    static let messageList = """
    {"messages":[{"id":"m1","threadId":"t1"},{"id":"m2","threadId":"t2"}],"nextPageToken":"page-2","resultSizeEstimate":2}
    """

    static let lastMessageList = """
    {"messages":[{"id":"m2","threadId":"t2"}],"resultSizeEstimate":1}
    """

    /// A bootstrap page that lists a Hangouts chat next to real mail.
    static let messageListWithChat = """
    {"messages":[{"id":"m1","threadId":"t1"},{"id":"chat1","threadId":"tc1"}],"resultSizeEstimate":2}
    """

    /// A minimal metadata reply for any id, for tests about which ids are fetched rather than what they say.
    static func metadata(id: String) -> String {
        """
        {"id":"\(id)","threadId":"t-\(id)","labelIds":["INBOX"],"snippet":"","internalDate":"1730462400000",\
        "payload":{"mimeType":"text/plain","headers":[{"name":"Subject","value":"Hello"}],"body":{"size":0}}}
        """
    }

    /// Google's per-user quota refusal, which names its refill time only in the message text.
    static func userRateLimitError(retryAt stamp: String) -> String {
        """
        {"error":{"code":403,"message":"User-rate limit exceeded.  Retry after \(stamp)",\
        "errors":[{"message":"User-rate limit exceeded.  Retry after \(stamp)","domain":"usageLimits","reason":"userRateLimitExceeded"}]}}
        """
    }

    static let searchList = """
    {"messages":[{"id":"s1","threadId":"t1"},{"id":"s2","threadId":"t2"},{"id":"s3","threadId":"t3"}],"resultSizeEstimate":3}
    """

    /// Unread, starred, Primary, replied-to, with every address header populated. 2024-11-01T12:00:00Z.
    static let metadataM1 = """
    {
      "id": "m1",
      "threadId": "t1",
      "labelIds": ["INBOX", "UNREAD", "STARRED", "CATEGORY_PERSONAL", "IMPORTANT"],
      "snippet": "Hello &amp; welcome to the team &#39;Ada&#39; &lt;3",
      "historyId": "8675000",
      "internalDate": "1730462400000",
      "sizeEstimate": 4321,
      "payload": {
        "partId": "",
        "mimeType": "multipart/mixed",
        "filename": "",
        "headers": [
          {"name": "From", "value": "\\"Lovelace, Ada\\" <ada@example.com>"},
          {"name": "To", "value": "Charles Babbage <charles@example.com>, grace@example.com"},
          {"name": "Cc", "value": "\\"Hopper, Grace\\" <grace.h@example.com>"},
          {"name": "Bcc", "value": "secret@example.com"},
          {"name": "Reply-To", "value": "Ada Replies <reply@example.com>"},
          {"name": "Subject", "value": "Analytical Engine \\u2014 notes"},
          {"name": "Date", "value": "Fri, 1 Nov 2024 12:00:00 +0000"},
          {"name": "Message-ID", "value": "<m1@example.com>"},
          {"name": "In-Reply-To", "value": "<m0@example.com>"},
          {"name": "References", "value": "<root@example.com> <m0@example.com>"}
        ],
        "body": {"size": 0}
      }
    }
    """

    /// A list's message as Gmail returns the metadata get: the list headers among the rest, as the sender folded them,
    /// a comment and both a one-click https and a mailto address included.
    static let metadataNewsletter = """
    {
      "id": "n1",
      "threadId": "tn1",
      "labelIds": ["INBOX", "CATEGORY_PROMOTIONS"],
      "snippet": "This week",
      "historyId": "8675002",
      "internalDate": "1730376000000",
      "payload": {
        "partId": "",
        "mimeType": "text/html",
        "filename": "",
        "headers": [
          {"name": "From", "value": "Frontend Weekly <hello@frontendweekly.test>"},
          {"name": "To", "value": "ada@example.com"},
          {"name": "Subject", "value": "Frontend Weekly #128"},
          {"name": "list-unsubscribe", "value": " (one click) <https://frontendweekly.test/u/abc?l=1>,\\r\\n <mailto:leave@frontendweekly.test?subject=unsubscribe> "},
          {"name": "List-Unsubscribe-Post", "value": "List-Unsubscribe=One-Click"}
        ],
        "body": {"size": 0}
      }
    }
    """

    /// Read, Promotions tab, no attachments. 2024-10-31T12:00:00Z.
    static let metadataM2 = """
    {
      "id": "m2",
      "threadId": "t2",
      "labelIds": ["INBOX", "CATEGORY_PROMOTIONS"],
      "snippet": "Big sale",
      "historyId": "8675001",
      "internalDate": "1730376000000",
      "sizeEstimate": 100,
      "payload": {
        "partId": "",
        "mimeType": "text/html",
        "filename": "",
        "headers": [
          {"name": "From", "value": "Shop <shop@example.com>"},
          {"name": "To", "value": "ada@example.com"},
          {"name": "Subject", "value": "Big sale"},
          {"name": "Message-ID", "value": "<m2@example.com>"}
        ],
        "body": {"size": 0}
      }
    }
    """

    /// m2 after Mark as spam landed: SPAM added, INBOX gone (Gmail's answer to the batchModify `apply` sends).
    static let metadataM2Spam = """
    {
      "id": "m2",
      "threadId": "t2",
      "labelIds": ["SPAM", "CATEGORY_PROMOTIONS"],
      "snippet": "Big sale",
      "historyId": "8675330",
      "internalDate": "1730376000000",
      "sizeEstimate": 100,
      "payload": {
        "partId": "",
        "mimeType": "text/html",
        "filename": "",
        "headers": [
          {"name": "From", "value": "Shop <shop@example.com>"},
          {"name": "To", "value": "ada@example.com"},
          {"name": "Subject", "value": "Big sale"},
          {"name": "Message-ID", "value": "<m2@example.com>"}
        ],
        "body": {"size": 0}
      }
    }
    """

    /// The history Gmail records for Mark as spam on m2: one record with SPAM added and INBOX removed.
    static let historyMarkedSpam = """
    {
      "history": [
        {"id": "8675330", "messages": [{"id": "m2", "threadId": "t2"}],
         "labelsAdded": [{"message": {"id": "m2", "threadId": "t2", "labelIds": ["SPAM", "CATEGORY_PROMOTIONS"]}, "labelIds": ["SPAM"]}],
         "labelsRemoved": [{"message": {"id": "m2", "threadId": "t2", "labelIds": ["SPAM", "CATEGORY_PROMOTIONS"]}, "labelIds": ["INBOX"]}]}
      ],
      "historyId": "8675331"
    }
    """

    static let metadataM4 = """
    {
      "id": "m4",
      "threadId": "t4",
      "labelIds": ["INBOX", "UNREAD"],
      "snippet": "New arrival",
      "historyId": "8675310",
      "internalDate": "1730548800000",
      "sizeEstimate": 200,
      "payload": {
        "mimeType": "multipart/alternative",
        "headers": [
          {"name": "From", "value": "Charles Babbage <charles@example.com>"},
          {"name": "Subject", "value": "Re: Analytical Engine"},
          {"name": "Message-ID", "value": "<m4@example.com>"}
        ],
        "body": {"size": 0}
      }
    }
    """

    /// Hangouts history as Gmail stores it: CHAT label, no Subject, no inbox role.
    static let metadataChat = """
    {
      "id": "chat1",
      "threadId": "tc1",
      "labelIds": ["CHAT"],
      "snippet": "brb",
      "historyId": "8675002",
      "internalDate": "1730376000000",
      "sizeEstimate": 60,
      "payload": {
        "mimeType": "text/html",
        "headers": [
          {"name": "From", "value": "Ada Lovelace <ada@example.com>"},
          {"name": "To", "value": "charles@example.com"}
        ],
        "body": {"size": 0}
      }
    }
    """

    /// One record whose only message is a chat.
    static let historyWithChat = """
    {
      "history": [
        {"id": "8675310", "messages": [{"id": "chat1", "threadId": "tc1"}],
         "messagesAdded": [{"message": {"id": "chat1", "threadId": "tc1", "labelIds": ["CHAT"]}}]}
      ],
      "historyId": "8675320"
    }
    """

    /// Four records: an add, a label removal, a deletion and an add whose message is already gone.
    static let history = """
    {
      "history": [
        {"id": "8675310", "messages": [{"id": "m4", "threadId": "t4"}],
         "messagesAdded": [{"message": {"id": "m4", "threadId": "t4", "labelIds": ["INBOX", "UNREAD"]}}]},
        {"id": "8675311", "messages": [{"id": "m2", "threadId": "t2"}],
         "labelsRemoved": [{"message": {"id": "m2", "threadId": "t2", "labelIds": ["INBOX", "CATEGORY_PROMOTIONS"]}, "labelIds": ["UNREAD"]}]},
        {"id": "8675312", "messages": [{"id": "m9", "threadId": "t9"}],
         "messagesDeleted": [{"message": {"id": "m9", "threadId": "t9", "labelIds": ["TRASH"]}}]},
        {"id": "8675313", "messages": [{"id": "m5", "threadId": "t5"}],
         "messagesAdded": [{"message": {"id": "m5", "threadId": "t5", "labelIds": ["INBOX"]}}]}
      ],
      "historyId": "8675320"
    }
    """

    static let historyPageOne = """
    {
      "history": [
        {"id": "8675310", "messages": [{"id": "m4", "threadId": "t4"}],
         "messagesAdded": [{"message": {"id": "m4", "threadId": "t4", "labelIds": ["INBOX", "UNREAD"]}}]}
      ],
      "nextPageToken": "history-page-2",
      "historyId": "8675320"
    }
    """

    static let historyPageTwo = """
    {
      "history": [
        {"id": "8675315", "messages": [{"id": "m2", "threadId": "t2"}],
         "labelsAdded": [{"message": {"id": "m2", "threadId": "t2", "labelIds": ["INBOX"]}, "labelIds": ["STARRED"]}]}
      ],
      "historyId": "8675320"
    }
    """

    static let emptyHistory = """
    {"historyId": "8675330"}
    """

    static let plainText = "Hello, plain text body."
    static let html = "<p>Hello <b>HTML</b> <img src=\"cid:logo@ss\" alt=\"logo\"></p>"

    /// multipart/mixed( multipart/related( multipart/alternative(text, html), inline png ), pdf ).
    static var fullMessage: String {
        """
        {
          "id": "m1",
          "threadId": "t1",
          "labelIds": ["INBOX"],
          "snippet": "Hello HTML",
          "historyId": "8675000",
          "internalDate": "1730462400000",
          "payload": {
            "partId": "",
            "mimeType": "multipart/mixed",
            "filename": "",
            "headers": [{"name": "Content-Type", "value": "multipart/mixed; boundary=\\"mixed\\""}],
            "body": {"size": 0},
            "parts": [
              {
                "partId": "0",
                "mimeType": "multipart/related",
                "filename": "",
                "headers": [{"name": "Content-Type", "value": "multipart/related; boundary=\\"related\\""}],
                "body": {"size": 0},
                "parts": [
                  {
                    "partId": "0.0",
                    "mimeType": "multipart/alternative",
                    "filename": "",
                    "headers": [{"name": "Content-Type", "value": "multipart/alternative; boundary=\\"alt\\""}],
                    "body": {"size": 0},
                    "parts": [
                      {
                        "partId": "0.0.0",
                        "mimeType": "text/plain",
                        "filename": "",
                        "headers": [{"name": "Content-Type", "value": "text/plain; charset=\\"UTF-8\\""}],
                        "body": {"size": \(plainText.utf8.count), "data": "\(Base64URL.encode(Data(plainText.utf8)))"}
                      },
                      {
                        "partId": "0.0.1",
                        "mimeType": "text/html",
                        "filename": "",
                        "headers": [{"name": "Content-Type", "value": "text/html; charset=\\"UTF-8\\""}],
                        "body": {"size": \(html.utf8.count), "data": "\(Base64URL.encode(Data(html.utf8)))"}
                      }
                    ]
                  },
                  {
                    "partId": "0.1",
                    "mimeType": "image/png",
                    "filename": "logo.png",
                    "headers": [
                      {"name": "Content-Type", "value": "image/png; name=\\"logo.png\\""},
                      {"name": "Content-Disposition", "value": "inline; filename=\\"logo.png\\""},
                      {"name": "Content-ID", "value": "<logo@ss>"},
                      {"name": "X-Attachment-Id", "value": "ii_logo"}
                    ],
                    "body": {"attachmentId": "ATT_LOGO", "size": 2048}
                  }
                ]
              },
              {
                "partId": "1",
                "mimeType": "application/pdf",
                "filename": "report.pdf",
                "headers": [
                  {"name": "Content-Type", "value": "application/pdf; name=\\"report.pdf\\""},
                  {"name": "Content-Disposition", "value": "attachment; filename=\\"report.pdf\\""}
                ],
                "body": {"attachmentId": "ATT_PDF", "size": 90210}
              }
            ]
          }
        }
        """
    }

    static let bigHTML = "<p>" + String(repeating: "large ", count: 50) + "</p>"

    /// A text/html part Gmail externalized behind an attachment id, as it does for oversized bodies.
    static var externalizedHTMLMessage: String {
        """
        {
          "id": "m7",
          "threadId": "t7",
          "labelIds": ["INBOX"],
          "snippet": "large",
          "historyId": "8675400",
          "internalDate": "1730462400000",
          "payload": {
            "partId": "",
            "mimeType": "multipart/alternative",
            "filename": "",
            "headers": [{"name": "Content-Type", "value": "multipart/alternative; boundary=\\"alt\\""}],
            "body": {"size": 0},
            "parts": [
              {
                "partId": "0",
                "mimeType": "text/plain",
                "filename": "",
                "headers": [{"name": "Content-Type", "value": "text/plain; charset=\\"UTF-8\\""}],
                "body": {"size": \(plainText.utf8.count), "data": "\(Base64URL.encode(Data(plainText.utf8)))"}
              },
              {
                "partId": "1",
                "mimeType": "text/html",
                "filename": "",
                "headers": [{"name": "Content-Type", "value": "text/html; charset=\\"UTF-8\\""}],
                "body": {"attachmentId": "ATT_HTML", "size": \(bigHTML.utf8.count)}
              }
            ]
          }
        }
        """
    }

    static var externalizedHTMLAttachment: String {
        "{\"attachmentId\":\"ATT_HTML\",\"size\":\(bigHTML.utf8.count),\"data\":\"\(Base64URL.encode(Data(bigHTML.utf8)))\"}"
    }

    /// `%PDF-` as base64url.
    static let attachment = """
    {"attachmentId":"ATT_PDF","size":5,"data":"JVBERi0"}
    """

    static let sendResponse = """
    {"id":"sent-1","threadId":"t1","labelIds":["SENT"]}
    """

    static let unauthorizedError = """
    {"error":{"code":401,"message":"Invalid Credentials","errors":[{"message":"Invalid Credentials","domain":"global","reason":"authError"}],"status":"UNAUTHENTICATED"}}
    """

    static let tooManyRequestsError = """
    {"error":{"code":429,"message":"Too many concurrent requests for user","status":"RESOURCE_EXHAUSTED"}}
    """

    static let userRateLimitError = """
    {"error":{"code":403,"message":"User-rate limit exceeded.  Retry after 2024-11-01T12:00:00.000Z","errors":[{"message":"User-rate limit exceeded.","domain":"usageLimits","reason":"userRateLimitExceeded"}]}}
    """

    static let forbiddenError = """
    {"error":{"code":403,"message":"Insufficient Permission","errors":[{"message":"Insufficient Permission","domain":"global","reason":"insufficientPermissions"}],"status":"PERMISSION_DENIED"}}
    """

    static let invalidPageTokenError = """
    {"error":{"code":400,"message":"Invalid pageToken","errors":[{"message":"Invalid pageToken","domain":"global","reason":"invalidArgument"}],"status":"INVALID_ARGUMENT"}}
    """

    static let notFoundError = """
    {"error":{"code":404,"message":"Requested entity was not found.","errors":[{"message":"Requested entity was not found.","domain":"global","reason":"notFound"}],"status":"NOT_FOUND"}}
    """

    static let serverError = """
    {"error":{"code":500,"message":"Backend Error","status":"INTERNAL"}}
    """
}
