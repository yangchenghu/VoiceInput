import Foundation

enum ASRResultParser {
    /// `result.text` 在 result_type=full 时是当前全量文本，调用方应覆盖而不是拼接。
    static func text(from payload: Data) -> String? {
        guard !payload.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: payload) else {
            return nil
        }
        if let object = json as? [String: Any] {
            return text(fromResult: object["result"])
        }
        return nil
    }

    private static func text(fromResult result: Any?) -> String? {
        if let object = result as? [String: Any], let text = object["text"] as? String {
            return text
        }
        if let list = result as? [[String: Any]] {
            let parts = list.compactMap { $0["text"] as? String }
            if parts.isEmpty { return nil }
            return parts.joined()
        }
        return nil
    }
}
