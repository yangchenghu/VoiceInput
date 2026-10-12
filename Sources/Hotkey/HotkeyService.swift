import CoreGraphics
import Foundation

final class HotkeyService {
    var onAction: (HotkeyOutput) -> Void = { _ in }
    var onCapture: (HotkeyCaptureResult) -> Void = { _ in }
    var shouldCancelOnEscape: () -> Bool = { false }
    private(set) var tapInstalled = false

    private var machine: HotkeyStateMachine
    private var capture = HotkeyCaptureMachine()
    private var capturing = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(mode: RecordMode, binding: HotkeyBinding) {
        machine = HotkeyStateMachine(mode: mode, binding: binding)
    }

    func start() -> Bool {
        if tap != nil { return tapInstalled }
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
                service.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            tapInstalled = false
            AppLog.error("hotkey.tap", "unavailable")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tapInstalled = true
        AppLog.event("hotkey.tap", "installed")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        tapInstalled = false
    }

    func setPaused(_ paused: Bool) {
        machine.paused = paused
    }

    func setBusy(_ busy: Bool) {
        machine.busy = busy
    }

    func apply(mode: RecordMode, binding: HotkeyBinding) {
        machine.mode = mode
        machine.binding = binding
        machine.resetGesture()
    }

    func setCapturing(_ capturing: Bool) {
        self.capturing = capturing
        if capturing {
            capture = HotkeyCaptureMachine()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == EventMark.userData {
            return
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if capturing {
            handleCapture(type: type, keyCode: keyCode, isRepeat: isRepeat, event: event)
            return
        }
        guard let input = input(type: type, keyCode: keyCode, isRepeat: isRepeat, event: event) else { return }
        if case .escape = input {
            let output = machine.handle(.escape)
            if output == .none, shouldCancelOnEscape() {
                onAction(.cancel)
            } else if output != .none {
                onAction(output)
            }
            return
        }
        let output = machine.handle(input)
        if output != .none {
            onAction(output)
        }
    }

    private func handleCapture(type: CGEventType, keyCode: UInt16, isRepeat: Bool, event: CGEvent) {
        guard let input = input(type: type, keyCode: keyCode, isRepeat: isRepeat, event: event) else { return }
        let result = capture.handle(input)
        if case .none = result { return }
        capturing = false
        onCapture(result)
    }

    private func input(type: CGEventType, keyCode: UInt16, isRepeat: Bool, event: CGEvent) -> HotkeyInput? {
        switch type {
        case .flagsChanged:
            let raw = event.flags.rawValue
            return .flags(
                rightCommand: raw & 0x10 != 0,
                leftCommand: raw & 0x08 != 0,
                shift: event.flags.contains(.maskShift),
                option: event.flags.contains(.maskAlternate),
                control: event.flags.contains(.maskControl)
            )
        case .keyDown:
            if isRepeat { return nil }
            if keyCode == 53 { return .escape }
            if Self.modifierKeyCodes.contains(keyCode) { return nil }
            return .keyDown(keyCode)
        case .keyUp:
            if keyCode == 53 || Self.modifierKeyCodes.contains(keyCode) { return nil }
            return .keyUp(keyCode)
        default:
            return nil
        }
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
}
