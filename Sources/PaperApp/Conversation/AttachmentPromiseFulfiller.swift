import Foundation
import PaperCore

/// Writes a dragged attachment where a drop outside the app asked for it (spec §5.17): the bytes from this Mac's attachment
/// cache, or downloaded through the engine as Download does (the UI never calls a provider), then delivered quarantined
/// under the attachment's own name (`AttachmentSafety.deliver`). Everything here runs off the main thread; `events` tells
/// the reader, which hops to the main thread, so the chip can show the download and say when it failed.
///
/// Promises are kept one at a time, in the order they were asked for (`line`), as Download all saves: a drop of twenty
/// files holds one file in memory, never twenty, and asks the account's provider for one at a time.
struct AttachmentPromiseFulfiller: Sendable {
    /// Why a promise could not be kept: the file never arrived, or it arrived and could not be written there.
    typealias Failure = AttachmentDragFailure

    enum Event: Sendable {
        /// The fetch started.
        case began(MailAttachmentReference)
        /// A fraction of the download, 0 to 1, as the engine reports it.
        case progress(MailAttachmentReference, Double)
        /// The promise ended: written (nil), or how it failed.
        case ended(MailAttachmentReference, Failure?)
    }

    typealias Fetch = @Sendable (MailAttachmentReference, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Data

    let fetch: Fetch
    let events: @Sendable (Event) -> Void
    /// The quarantine mark; tests replace it.
    var mark: @Sendable (URL) throws -> Void = { try AttachmentSafety.quarantine($0) }
    /// Where a promise waits its turn: one for the whole app, so drags from any reader take turns too.
    var line: AttachmentPromiseLine = .shared

    init(fetch: @escaping Fetch, events: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.fetch = fetch
        self.events = events
    }

    /// The engine's attachment cache, which holds a file once it has been fetched and shares a download already under way.
    static func engine(_ client: MailClient, events: @escaping @Sendable (Event) -> Void) -> AttachmentPromiseFulfiller {
        let engine = EngineHandle(client: client)
        return AttachmentPromiseFulfiller(fetch: { reference, progress in
            try await engine.client.attachmentData(for: reference.message, attachmentID: reference.info.id,
                                                   expectedSize: reference.info.sizeBytes, progress: progress)
        }, events: events)
    }

    /// Fetches the file and writes it at `url` (another free name beside it when that one is taken), once the promises
    /// asked for before it are kept. Returns where it is. The chip shows its download from the start of the wait.
    @discardableResult
    func fulfil(_ reference: MailAttachmentReference, at url: URL) async throws -> URL {
        events(.began(reference))
        return try await line.run { try await keep(reference, at: url) }
    }

    private func keep(_ reference: MailAttachmentReference, at url: URL) async throws -> URL {
        let data: Data
        do {
            data = try await fetch(reference) { [events] fraction in events(.progress(reference, fraction)) }
        } catch {
            Self.log(error, "fetch")
            events(.ended(reference, .unfetched))
            throw Failure.unfetched
        }
        do {
            let written = try AttachmentSafety.deliver(data, to: url, mark: mark)
            events(.ended(reference, nil))
            return written
        } catch {
            Self.log(error, "write")
            events(.ended(reference, .unwritten))
            throw Failure.unwritten
        }
    }

    /// A Cocoa file error names the attachment and the folder it was dropped in: only the domain and code are public.
    private static func log(_ error: Error, _ step: String) {
        let failure = error as NSError
        ConversationSignposts.log.error("dragged attachment \(step, privacy: .public) failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
        ConversationSignposts.log.debug("dragged attachment failed: \(String(describing: error), privacy: .private)")
    }
}

/// The engine is safe to call from any thread (`MailEngine` is Sendable); the `MailClient` protocol does not say so.
private struct EngineHandle: @unchecked Sendable {
    let client: MailClient
}

/// Runs the work it is handed one piece at a time, first come first served.
actor AttachmentPromiseLine {
    static let shared = AttachmentPromiseLine()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        await take()
        do {
            let value = try await work()
            pass()
            return value
        } catch {
            pass()
            throw error
        }
    }

    private func take() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// The next in line goes on with the line still taken; with nobody waiting the line is free.
    private func pass() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
