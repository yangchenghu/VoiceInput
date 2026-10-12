import Foundation

enum HotkeyCaptureResult: Equatable {
    case none
    case committed(HotkeyBinding)
    case rejected(String)
    case cancelled
}

struct HotkeyCaptureMachine: Equatable {
    private var snapshot = ModifierSnapshot()
    private var tracking = false
    private var dirtyKey = false
    private var seenRight = false
    private var seenLeft = false
    private var seenShift = false
    private var seenOption = false
    private var seenControl = false
    private var finished = false

    mutating func handle(_ input: HotkeyInput) -> HotkeyCaptureResult {
        if finished { return .none }
        switch input {
        case .escape:
            finished = true
            return .cancelled
        case let .keyDown(code):
            guard !Self.modifierKeyCodes.contains(code) else { return .none }
            dirtyKey = true
            tracking = true
            let binding = chordBinding(keyCode: code)
            if binding.modifiers == 0 {
                return .rejected("请至少带一个修饰键，例如右 Command，或 Control + 字母。")
            }
            finished = true
            return .committed(binding)
        case let .keyUp(code):
            snapshot.keys.remove(code)
            return finishIfReleased()
        case let .flags(rightCommand, leftCommand, shift, option, control):
            snapshot.rightCommand = rightCommand
            snapshot.leftCommand = leftCommand
            snapshot.shift = shift
            snapshot.option = option
            snapshot.control = control
            if rightCommand || leftCommand || shift || option || control {
                tracking = true
            }
            if rightCommand { seenRight = true }
            if leftCommand { seenLeft = true }
            if shift { seenShift = true }
            if option { seenOption = true }
            if control { seenControl = true }
            return finishIfReleased()
        }
    }

    private func chordBinding(keyCode: UInt16) -> HotkeyBinding {
        var mods: UInt8 = 0
        if snapshot.rightCommand || snapshot.leftCommand { mods |= HotkeyBinding.commandBit }
        if snapshot.shift { mods |= HotkeyBinding.shiftBit }
        if snapshot.option { mods |= HotkeyBinding.optionBit }
        if snapshot.control { mods |= HotkeyBinding.controlBit }
        let requireRight = snapshot.rightCommand && !snapshot.leftCommand && mods & HotkeyBinding.commandBit != 0
        return HotkeyBinding(keyCode: keyCode, modifiers: mods, requireRightCommand: requireRight)
    }

    private mutating func finishIfReleased() -> HotkeyCaptureResult {
        let anyModifier = snapshot.rightCommand || snapshot.leftCommand || snapshot.shift || snapshot.option || snapshot.control
        if anyModifier || !snapshot.keys.isEmpty || !tracking || dirtyKey {
            return .none
        }
        var mods: UInt8 = 0
        if seenRight || seenLeft { mods |= HotkeyBinding.commandBit }
        if seenShift { mods |= HotkeyBinding.shiftBit }
        if seenOption { mods |= HotkeyBinding.optionBit }
        if seenControl { mods |= HotkeyBinding.controlBit }
        guard mods != 0 else { return .none }
        let requireRight = seenRight && !seenLeft && mods & HotkeyBinding.commandBit != 0
        finished = true
        return .committed(HotkeyBinding(keyCode: nil, modifiers: mods, requireRightCommand: requireRight))
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63, 57]
}
