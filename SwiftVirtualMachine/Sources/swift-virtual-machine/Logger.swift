import Foundation

enum VMLogLevel: String, CaseIterable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

struct VMLogger {
    static let shared = VMLogger()

    var minLevel: VMLogLevel = {
        switch ProcessInfo.processInfo.environment["SVM_LOG_LEVEL"]?.lowercased() {
        case "debug":
            return .debug
        case "info", nil:
            return .info
        case "warn", "warning":
            return .warning
        case "error":
            return .error
        default:
            return .info
        }
    }()

    private let levelOrder: [VMLogLevel] = [.debug, .info, .warning, .error]

    private func shouldLog(_ level: VMLogLevel) -> Bool {
        guard let minIndex = levelOrder.firstIndex(of: minLevel),
              let levelIndex = levelOrder.firstIndex(of: level) else {
            return true
        }
        return levelIndex >= minIndex
    }

    func log(_ level: VMLogLevel, _ message: String) {
        guard shouldLog(level) else { return }
        NSLog("[\(level.rawValue)] \(message)")
    }

    func debug(_ message: String) { log(.debug, message) }
    func info(_ message: String) { log(.info, message) }
    func warn(_ message: String) { log(.warning, message) }
    func error(_ message: String) { log(.error, message) }
}

func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    return formatter.string(fromByteCount: Int64(bytes))
}
