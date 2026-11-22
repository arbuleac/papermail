import Foundation
import PaperCore

/// The user's Write and Check, as the app's handlers make them: every provider call in these tests is one of them.
let pressedWrite = AIUserAction(userPressed: .write)
let pressedCheck = AIUserAction(userPressed: .check)

/// What `AIEgress` saw, from any thread.
final class ContactLog: @unchecked Sendable {
    private let lock = NSLock()
    private var contacts: [String] = []

    var all: [String] { lock.withLock { contacts } }

    func append(_ contact: String) { lock.withLock { contacts.append(contact) } }
}
