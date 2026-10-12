import Foundation

enum HotkeyInput: Equatable {
    case flags(rightCommand: Bool, leftCommand: Bool, shift: Bool, option: Bool, control: Bool)
    case keyDown(UInt16)
    case keyUp(UInt16)
    case escape
}

enum HotkeyOutput: Equatable {
    case none
    case beginCandidate
    case endAndSubmit
    case cancel
    case toggleStart
    case toggleStop
    case busyIgnored
}

struct HotkeyStateMachine: Equatable {
    var mode: RecordMode
    var binding: HotkeyBinding
    var paused = false
    var busy = false

    private(set) var snapshot = ModifierSnapshot()
    private var hold = false
    private var suppress = false
    private var armed = false
    private var dirty = false
    private var toggleOn = false

    init(mode: RecordMode = .hold, binding: HotkeyBinding = .defaultRightCommand) {
        self.mode = mode
        self.binding = binding
    }

    mutating func resetGesture() {
        hold = false
        suppress = false
        armed = false
        dirty = false
        toggleOn = false
    }

    mutating func handle(_ input: HotkeyInput) -> HotkeyOutput {
        if case .escape = input {
            return handleEscape()
        }
        let previous = snapshot
        apply(input)
        if paused { return .none }
        switch mode {
        case .hold:
            return handleHold(previous: previous)
        case .toggle:
            return handleToggle(previous: previous)
        }
    }

    private mutating func apply(_ input: HotkeyInput) {
        switch input {
        case let .flags(rightCommand, leftCommand, shift, option, control):
            snapshot.rightCommand = rightCommand
            snapshot.leftCommand = leftCommand
            snapshot.shift = shift
            snapshot.option = option
            snapshot.control = control
        case let .keyDown(code):
            snapshot.keys.insert(code)
        case let .keyUp(code):
            snapshot.keys.remove(code)
        case .escape:
            break
        }
    }

    private mutating func handleEscape() -> HotkeyOutput {
        let active = hold || toggleOn || armed
        hold = false
        suppress = false
        armed = false
        dirty = false
        toggleOn = false
        return active ? .cancel : .none
    }

    private mutating func handleHold(previous: ModifierSnapshot) -> HotkeyOutput {
        if suppress {
            if !snapshot.coreHeld(binding) && !snapshot.matches(binding) {
                suppress = false
            }
            return .none
        }
        if !hold {
            if !previous.matches(binding) && snapshot.matches(binding) {
                if busy { return .busyIgnored }
                hold = true
                return .beginCandidate
            }
            return .none
        }
        if snapshot.matches(binding) { return .none }
        if snapshot.coreHeld(binding) {
            hold = false
            suppress = true
            return .cancel
        }
        hold = false
        return .endAndSubmit
    }

    private mutating func handleToggle(previous: ModifierSnapshot) -> HotkeyOutput {
        if !armed && !dirty && !previous.matches(binding) && snapshot.matches(binding) {
            armed = true
            return .none
        }
        if armed {
            if snapshot.matches(binding) { return .none }
            if snapshot.coreHeld(binding) {
                armed = false
                dirty = true
                return .none
            }
            armed = false
            if toggleOn {
                toggleOn = false
                return .toggleStop
            }
            if busy { return .busyIgnored }
            toggleOn = true
            return .toggleStart
        }
        if dirty && !snapshot.coreHeld(binding) && !snapshot.matches(binding) {
            dirty = false
        }
        return .none
    }
}
