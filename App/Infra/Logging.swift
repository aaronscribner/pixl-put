import Foundation
import os

/// Lightweight logging façade. Uses Apple's `os.Logger` so logs land in the
/// unified logging system + optional rotating file destination at
/// `~/Library/Application Support/DisplayMaid-Next/logs/`.
///
/// Default-level (info) statements MUST redact identifiers per project
/// constitution §IV — browser tab URLs and document paths are sensitive.
/// Use `.private(_:)` for any URL / path; that marks the value as
/// PII-class and prevents it leaking to the system log unless the user
/// has explicitly enabled debug-level capture.
public struct LoggerFacade {

    public enum Level {
        case debug, info, notice, warning, error
    }

    private let logger: Logger
    public let category: String

    public init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: "co.cerebraljuice.pixlput", category: category)
    }

    public func log(_ level: Level, _ message: String) {
        switch level {
        case .debug:    logger.debug("\(message, privacy: .public)")
        case .info:     logger.info("\(message, privacy: .public)")
        case .notice:   logger.notice("\(message, privacy: .public)")
        case .warning:  logger.warning("\(message, privacy: .public)")
        case .error:    logger.error("\(message, privacy: .public)")
        }
    }

    /// Log a message that contains a sensitive URL or path. The URL string
    /// is marked `.private` so unified logging redacts it.
    public func logPrivate(_ level: Level, _ message: String, sensitive: String) {
        switch level {
        case .debug:    logger.debug("\(message, privacy: .public): \(sensitive, privacy: .private)")
        case .info:     logger.info("\(message, privacy: .public): \(sensitive, privacy: .private)")
        case .notice:   logger.notice("\(message, privacy: .public): \(sensitive, privacy: .private)")
        case .warning:  logger.warning("\(message, privacy: .public): \(sensitive, privacy: .private)")
        case .error:    logger.error("\(message, privacy: .public): \(sensitive, privacy: .private)")
        }
    }
}

public enum LoggerRegistry {
    public static let app          = LoggerFacade(category: "app")
    public static let ax           = LoggerFacade(category: "ax")
    public static let snapshot     = LoggerFacade(category: "snapshot")
    public static let restore      = LoggerFacade(category: "restore")
    public static let identity     = LoggerFacade(category: "identity")
    public static let display      = LoggerFacade(category: "display")
    public static let triggers     = LoggerFacade(category: "triggers")
    public static let permissions  = LoggerFacade(category: "permissions")
    public static let updates      = LoggerFacade(category: "updates")
}
