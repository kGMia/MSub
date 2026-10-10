import Foundation
import os

enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "app.huz.msub"

    static let bookmarks = Logger(subsystem: subsystem, category: "bookmarks")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let processing = Logger(subsystem: subsystem, category: "processing")
    static let api = Logger(subsystem: subsystem, category: "api")
}
