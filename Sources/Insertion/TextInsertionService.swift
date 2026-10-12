import AppKit
import Foundation

struct ClipboardSnapshot: Sendable {
    var items: [[String: Data]]
}

enum ClipboardPaste {
    static func capture() -> ClipboardSnapshot? {
        let pasteboard = NSPasteboard.general
        guard let items = pasteboard.pasteboardItems else {
            return ClipboardSnapshot(items: [])
        }
        if items.isEmpty {
            return ClipboardSnapshot(items: [])
        }
        var snapshot: [[String: Data]] = []
        for item in items {
            var entries: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                entries[type.rawValue] = data
            }
            snapshot.append(entries)
        }
        return ClipboardSnapshot(items: snapshot)
    }

    static func writeText(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    static func changeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    static func restore(_ snapshot: ClipboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let objects: [NSPasteboardItem] = snapshot.items.map { entries in
            let item = NSPasteboardItem()
            for (type, data) in entries {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(objects)
    }
}

enum InsertOutcome: Equatable {
    case inserted
    case blocked(String)
    case failed(String)
}

final class TextInsertionService {
    var pausedHotkeys: (Bool) -> Void = { _ in }

    func insertAutomatic(_ text: String, mode: InsertionMode, focus: FocusSnapshot) async -> InsertOutcome {
        guard await FocusGuard.waitForModifiersReleased() else {
            return .blocked("修饰键仍被按住，已保留结果。")
        }
        let decision = await MainActor.run { FocusGuard.evaluate(focus) }
        switch decision {
        case .same:
            break
        case .applicationChanged:
            return .blocked("前台应用变了，已保留结果，没有输入到新应用。")
        case .elementChanged:
            return .blocked("输入位置变了，已保留结果。请重新定位后再输入。")
        case .ownApp:
            return .blocked("焦点在轻语窗口里，已保留结果。")
        case .modifiersHeld:
            return .blocked("修饰键仍被按住，已保留结果。")
        }
        return await perform(text, mode: mode)
    }

    func insertManual(_ text: String, mode: InsertionMode) async -> InsertOutcome {
        guard await FocusGuard.waitForModifiersReleased() else {
            return .blocked("修饰键仍被按住。")
        }
        let ownApp = await MainActor.run { FocusGuard.frontmostIsOwnApp() }
        if ownApp {
            return .blocked("请先点到目标输入框。")
        }
        return await perform(text, mode: mode)
    }

    private func perform(_ text: String, mode: InsertionMode) async -> InsertOutcome {
        pausedHotkeys(true)
        defer { pausedHotkeys(false) }
        switch mode {
        case .unicode:
            await Task.detached(priority: .userInitiated) {
                UnicodeTyper.post(text)
            }.value
            return .inserted
        case .clipboard:
            return await paste(text)
        }
    }

    private func paste(_ text: String) async -> InsertOutcome {
        let snapshot = await MainActor.run { ClipboardPaste.capture() }
        guard let snapshot else {
            return .failed("读不到当前剪贴板，已停止兼容粘贴，没有覆盖。")
        }
        let written = await MainActor.run { ClipboardPaste.writeText(text) }
        UnicodeTyper.postCommandV()
        try? await Task.sleep(nanoseconds: UInt64(SessionLimits.pasteSettleMilliseconds) * 1_000_000)
        let current = await MainActor.run { ClipboardPaste.changeCount() }
        if ClipboardRestorePolicy.shouldRestore(writtenChangeCount: written, currentChangeCount: current) {
            await MainActor.run { ClipboardPaste.restore(snapshot) }
        }
        return .inserted
    }
}
