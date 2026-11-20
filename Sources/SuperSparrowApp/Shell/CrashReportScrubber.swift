import Foundation
import Sentry

/// The last look at a report before it leaves the Mac (`Options.beforeSend`, `beforeBreadcrumb`): every string a
/// report can carry goes through `CrashRedactor`, and what names the Mac or its user goes entirely. The SDK has
/// already left out what `sendDefaultPii` covers (the IP address); this holds even if a later SDK version adds more.
enum CrashReportScrubber {
    /// Device context keys that name the Mac rather than describe it.
    static let identifyingDeviceKeys: Set<String> = ["name", "host_name", "computer_name"]

    static func scrub(_ event: Event, with redactor: CrashRedactor) -> Event {
        event.serverName = nil
        event.request = nil
        if let user = event.user {
            // Only the SDK's random installation id stays, which counts crash-free sessions.
            let anonymous = User()
            anonymous.userId = user.userId
            event.user = anonymous
        }
        if let message = event.message {
            let scrubbed = SentryMessage(formatted: redactor.redact(message.formatted))
            scrubbed.message = message.message.map(redactor.redact)
            scrubbed.params = message.params?.map(redactor.redact)
            event.message = scrubbed
        }
        event.transaction = event.transaction.map(redactor.redact)
        event.tags = event.tags?.mapValues(redactor.redact)
        event.extra = event.extra.map { redactor.redact($0) as? [String: Any] ?? [:] }
        if var contexts = event.context {
            if var device = contexts["device"] {
                identifyingDeviceKeys.forEach { device.removeValue(forKey: $0) }
                contexts["device"] = device
            }
            event.context = contexts.mapValues { redactor.redact($0) as? [String: Any] ?? [:] }
        }
        for exception in event.exceptions ?? [] {
            exception.value = exception.value.map(redactor.redact)
            exception.type = exception.type.map(redactor.redact)
            if let mechanism = exception.mechanism {
                mechanism.desc = mechanism.desc.map(redactor.redact)
                mechanism.data = mechanism.data.map { redactor.redact($0) as? [String: Any] ?? [:] }
            }
            scrub(exception.stacktrace, with: redactor)
        }
        for thread in event.threads ?? [] {
            thread.name = thread.name.map(redactor.redact)
            scrub(thread.stacktrace, with: redactor)
        }
        scrub(event.stacktrace, with: redactor)
        for image in event.debugMeta ?? [] {
            image.codeFile = image.codeFile.map(redactor.redact)
        }
        event.breadcrumbs = event.breadcrumbs?.compactMap { scrub($0, with: redactor) }
        return event
    }

    static func scrub(_ breadcrumb: Breadcrumb, with redactor: CrashRedactor) -> Breadcrumb? {
        breadcrumb.message = breadcrumb.message.map(redactor.redact)
        for (key, value) in breadcrumb.data ?? [:] {
            breadcrumb.setData(value: redactor.redact(value), key: key)
        }
        return breadcrumb
    }

    private static func scrub(_ stacktrace: SentryStacktrace?, with redactor: CrashRedactor) {
        for frame in stacktrace?.frames ?? [] {
            frame.package = frame.package.map(redactor.redact)
            frame.fileName = frame.fileName.map(redactor.redact)
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
            frame.vars = nil
        }
    }
}
