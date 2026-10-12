import Foundation

enum ClipboardRestorePolicy {
    static func shouldRestore(writtenChangeCount: Int, currentChangeCount: Int) -> Bool {
        writtenChangeCount == currentChangeCount
    }
}
