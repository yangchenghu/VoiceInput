import AppKit

@MainActor
final class SpikeDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var service: HotkeyService?
    private var text = NSTextView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "右 Command 验证"
        window.center()
        let scroll = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        text.autoresizingMask = [.width]
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = """
        请逐项试，并看下面的日志：
        1. 按下再松开右 Command：应出现 beginCandidate，然后 endAndSubmit。
        2. 按下再松开左 Command：不应出现 beginCandidate。
        3. 按住右 Command 再按 C：应出现 beginCandidate，然后 cancel。系统的复制应仍然有效。
        4. 按住右 Command 再按 V、Tab：同样应 cancel，不能出现 endAndSubmit。
        5. 快速连按右 Command：不应成对重复触发。
        如果系统弹出输入监控或辅助功能授权，允许后重新启动本窗口。

        """
        scroll.documentView = text
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        let hotkey = HotkeyService(mode: .hold, binding: .defaultRightCommand)
        hotkey.onAction = { [weak self] output in
            self?.log("动作 \(output)")
        }
        let installed = hotkey.start()
        log(installed ? "监听已安装" : "监听没有安装。请在系统设置的输入监控里允许 HotkeySpike。")
        service = hotkey
    }

    private func log(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        text.string += "[\(stamp)] \(line)\n"
        text.scrollToEndOfDocument(nil)
    }
}

@main
enum HotkeySpikeMain {
    nonisolated(unsafe) private static var retained: SpikeDelegate?

    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = SpikeDelegate()
            retained = delegate
            app.setActivationPolicy(.regular)
            app.delegate = delegate
            app.run()
        }
    }
}
