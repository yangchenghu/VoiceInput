import AppKit

@MainActor
final class InsertDelegate: NSObject, NSApplicationDelegate {
    private let cases: [(String, String)] = [
        ("中文和标点", "你好，轻语。今天把这句话写进 Cursor。"),
        ("英文和符号", "Hello, VoiceInput! (test) — 100%."),
        ("Emoji 和组合字符", "家庭 👨‍👩‍👧‍👦 ，重音 e\u{0301} ，中文。"),
        ("多行（不按 Return）", "第一行\n第二行\n这是换行字符，不是 Return 键。"),
        ("长文本 2000 字", String(repeating: "测", count: 2000))
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cursor 输入验证"
        window.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let intro = NSTextField(wrappingLabelWithString: "点按钮后有 2 秒，请点进 Cursor 的输入框。每种都试一次：普通输入、先选中一段再输入（看会不会替换选区）、中文输入法开着、英文输入法开着。下面会显示剪贴板 changeCount 是否变化。")
        intro.preferredMaxLayoutWidth = 480
        stack.addArrangedSubview(intro)
        let status = NSTextField(labelWithString: "尚未发送")
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 4
        status.preferredMaxLayoutWidth = 480
        for item in cases {
            let button = NSButton(title: item.0, target: nil, action: nil)
            button.bezelStyle = .rounded
            let text = item.1
            button.target = self
            button.action = #selector(send(_:))
            objc_setAssociatedObject(button, &InsertBox.key, InsertBox(text: text, label: status), .OBJC_ASSOCIATION_RETAIN)
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(status)
        window.contentView = stack
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    @objc private func send(_ sender: NSButton) {
        guard let box = objc_getAssociatedObject(sender, &InsertBox.key) as? InsertBox else { return }
        box.label.stringValue = "2 秒后输入「\(sender.title)」。请现在点进 Cursor。"
        let before = NSPasteboard.general.changeCount
        let text = box.text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            UnicodeTyper.post(text)
            let after = NSPasteboard.general.changeCount
            let clipboard = before == after ? "剪贴板 changeCount 没变（\(after)）" : "剪贴板 changeCount 变了：\(before) -> \(after)"
            box.label.stringValue = "已发送 \(text.count) 个字符，\(UnicodeChunker.chunks(text).count) 片。\(clipboard)。请在 Cursor 里核对内容，本工具不能代替你看编辑器。"
        }
    }
}

private final class InsertBox: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0
    let text: String
    let label: NSTextField
    init(text: String, label: NSTextField) {
        self.text = text
        self.label = label
    }
}

@main
enum InsertSpikeMain {
    nonisolated(unsafe) private static var retained: InsertDelegate?

    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = InsertDelegate()
            retained = delegate
            app.setActivationPolicy(.regular)
            app.delegate = delegate
            app.run()
        }
    }
}
