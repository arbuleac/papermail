import Foundation
import PaperCore
import os

/// One signposter for the list so Instruments groups every "list.*" interval under a single category.
enum ListSignposts {
    static let signposter = OSSignposter(subsystem: AppIdentity.bundleIdentifier, category: "list")
}
