import Foundation
import os

/// 只记录状态、耗时和错误类别。调用方不得传入音频、转写全文、密钥或带密钥的 URL。
enum AppLog {
    private static let logger = Logger(subsystem: "com.qingyu.voiceinput", category: "app")

    static func event(_ name: String, _ fields: String = "") {
        logger.info("\(name, privacy: .public) \(fields, privacy: .public)")
    }

    static func error(_ name: String, _ fields: String = "") {
        logger.error("\(name, privacy: .public) \(fields, privacy: .public)")
    }
}
