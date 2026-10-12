import Foundation

enum CorrectionPolicy {
    static func choose(original: String, modelOutput: String?, failed: Bool) -> String {
        if failed { return original }
        guard var output = modelOutput?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty else {
            return original
        }
        output = stripFence(output).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty { return original }
        if looksLikeExplanation(output) { return original }
        if isSuspiciouslyDifferent(original: original, corrected: output) { return original }
        return output
    }

    static func stripFence(_ text: String) -> String {
        guard text.contains("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return lines.joined(separator: "\n")
    }

    private static func looksLikeExplanation(_ text: String) -> Bool {
        let prefixes = ["纠正后", "以下是", "好的", "修改说明", "说明："]
        return prefixes.contains { text.hasPrefix($0) }
    }

    private static func isSuspiciouslyDifferent(original: String, corrected: String) -> Bool {
        let originalCount = original.count
        let correctedCount = corrected.count
        if originalCount >= 8 && correctedCount > originalCount * 2 + 16 {
            return true
        }
        if originalCount >= 12 && correctedCount * 3 < originalCount {
            return true
        }
        return false
    }
}

enum CorrectionResponseParser {
    static func content(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        if let text = message["content"] as? String {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }
}

struct CorrectionConfig: Equatable, Sendable {
    var baseURL: String
    var model: String
    var apiKey: String
}

enum CorrectionEndpoint {
    static func url(from base: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }
        let path = components.path
        if !path.hasSuffix("/chat/completions") {
            components.path = path + "/chat/completions"
        }
        return components.url
    }
}
