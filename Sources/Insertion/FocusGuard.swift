import AppKit
import ApplicationServices
import Foundation

enum FocusDecision: Equatable {
    case same
    case applicationChanged
    case elementChanged
    case ownApp
    case modifiersHeld
}

struct FocusSnapshot: Equatable, @unchecked Sendable {
    var pid: pid_t
    var bundleID: String?
    var hasElement: Bool
    fileprivate var elementToken: AXUIElement?

    static func == (lhs: FocusSnapshot, rhs: FocusSnapshot) -> Bool {
        lhs.pid == rhs.pid && lhs.bundleID == rhs.bundleID && lhs.hasElement == rhs.hasElement
    }
}

enum FocusGuard {
    static let ownBundleID = "com.qingyu.voiceinput"

    static func capture() -> FocusSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        let element = focusedElement()
        return FocusSnapshot(
            pid: app?.processIdentifier ?? 0,
            bundleID: app?.bundleIdentifier,
            hasElement: element != nil,
            elementToken: element
        )
    }

    static func evaluate(_ snapshot: FocusSnapshot) -> FocusDecision {
        if modifiersHeld() { return .modifiersHeld }
        let app = NSWorkspace.shared.frontmostApplication
        if app?.bundleIdentifier == ownBundleID { return .ownApp }
        if app?.processIdentifier != snapshot.pid { return .applicationChanged }
        guard snapshot.hasElement, let original = snapshot.elementToken, let current = focusedElement() else {
            return .same
        }
        if !CFEqual(original, current) { return .elementChanged }
        return .same
    }

    static func frontmostIsOwnApp() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownBundleID
    }

    static func modifiersHeld() -> Bool {
        let flags = CGEventSource.flagsState(.hidSystemState)
        return flags.contains(.maskCommand)
            || flags.contains(.maskShift)
            || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
    }

    static func waitForModifiersReleased(timeout: TimeInterval = 0.6) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !modifiersHeld() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return !modifiersHeld()
    }

    private static func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focusedApp)
        guard appResult == .success, let focusedApp else { return nil }
        let appElement = focusedApp as! AXUIElement
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focused else { return nil }
        return focused as! AXUIElement
    }
}
