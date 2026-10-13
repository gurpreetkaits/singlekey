import os

private let logger = Logger(subsystem: "io.github.gurpreetkaits.singlekey", category: "app")

/// Diagnostics, visible with: log stream --predicate 'subsystem == "io.github.gurpreetkaits.singlekey"'
func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
}
