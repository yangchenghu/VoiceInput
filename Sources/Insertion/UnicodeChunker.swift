import Foundation

enum UnicodeChunker {
    static func chunks(_ text: String, maxUTF16Units: Int = 20) -> [String] {
        guard !text.isEmpty else { return [] }
        let limit = max(1, maxUTF16Units)
        var result: [String] = []
        var current = ""
        var currentUnits = 0
        for character in text {
            let units = character.utf16.count
            if units > limit {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                    currentUnits = 0
                }
                result.append(String(character))
                continue
            }
            if currentUnits + units > limit {
                result.append(current)
                current = String(character)
                currentUnits = units
            } else {
                current.append(character)
                currentUnits += units
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
