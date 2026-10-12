import CoreGraphics
import Foundation

enum UnicodeTyper {
    static func post(_ text: String, chunkDelayMicroseconds: UInt32 = 5_000) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.userData = EventMark.userData
        let pieces = UnicodeChunker.chunks(text)
        for piece in pieces {
            postChunk(piece, source: source)
            if chunkDelayMicroseconds > 0 {
                usleep(chunkDelayMicroseconds)
            }
        }
    }

    static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.userData = EventMark.userData
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        mark(down)
        mark(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func postChunk(_ text: String, source: CGEventSource) {
        var units = Array(text.utf16)
        guard !units.isEmpty,
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return
        }
        units.withUnsafeMutableBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
        }
        down.flags = []
        up.flags = []
        mark(down)
        mark(up)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: EventMark.userData)
    }
}
