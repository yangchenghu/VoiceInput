import Foundation

enum RecordMode: String, Codable, Equatable, Sendable {
    case hold
    case toggle
}

struct HotkeyBinding: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt16?
    var modifiers: UInt8
    var requireRightCommand: Bool

    static let commandBit: UInt8 = 1 << 0
    static let shiftBit: UInt8 = 1 << 1
    static let optionBit: UInt8 = 1 << 2
    static let controlBit: UInt8 = 1 << 3

    static let defaultRightCommand = HotkeyBinding(
        keyCode: nil,
        modifiers: commandBit,
        requireRightCommand: true
    )

    var displayName: String {
        if self == Self.defaultRightCommand {
            return "右 Command"
        }
        var parts: [String] = []
        if modifiers & Self.controlBit != 0 { parts.append("⌃") }
        if modifiers & Self.optionBit != 0 { parts.append("⌥") }
        if modifiers & Self.shiftBit != 0 { parts.append("⇧") }
        if modifiers & Self.commandBit != 0 {
            parts.append(requireRightCommand ? "右⌘" : "⌘")
        }
        if let keyCode {
            parts.append(Self.keyName(keyCode))
        }
        return parts.isEmpty ? "未设置" : parts.joined()
    }

    static func keyName(_ keyCode: UInt16) -> String {
        keyNames[keyCode] ?? "键\(keyCode)"
    }

    private static let keyNames: [UInt16: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F",
        0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L",
        0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
        0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0",
        0x31: "空格", 0x24: "Return", 0x30: "Tab", 0x33: "Delete", 0x35: "Esc",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑"
    ]
}

struct ModifierSnapshot: Equatable {
    var rightCommand = false
    var leftCommand = false
    var shift = false
    var option = false
    var control = false
    var keys: Set<UInt16> = []

    func matches(_ binding: HotkeyBinding) -> Bool {
        if !modifiersMatch(binding) { return false }
        if let key = binding.keyCode {
            return keys == [key]
        }
        return keys.isEmpty
    }

    func coreHeld(_ binding: HotkeyBinding) -> Bool {
        if binding.modifiers & HotkeyBinding.commandBit != 0 {
            if binding.requireRightCommand {
                if !rightCommand { return false }
            } else if !(rightCommand || leftCommand) {
                return false
            }
        }
        if binding.modifiers & HotkeyBinding.shiftBit != 0 && !shift { return false }
        if binding.modifiers & HotkeyBinding.optionBit != 0 && !option { return false }
        if binding.modifiers & HotkeyBinding.controlBit != 0 && !control { return false }
        if let key = binding.keyCode, !keys.contains(key) { return false }
        return true
    }

    private func modifiersMatch(_ binding: HotkeyBinding) -> Bool {
        let commandDown = rightCommand || leftCommand
        if binding.modifiers & HotkeyBinding.commandBit != 0 {
            if binding.requireRightCommand {
                if !rightCommand || leftCommand { return false }
            } else if !commandDown {
                return false
            }
        } else if commandDown {
            return false
        }
        if (binding.modifiers & HotkeyBinding.shiftBit != 0) != shift { return false }
        if (binding.modifiers & HotkeyBinding.optionBit != 0) != option { return false }
        if (binding.modifiers & HotkeyBinding.controlBit != 0) != control { return false }
        return true
    }
}
