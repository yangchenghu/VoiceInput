import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
enum VoiceInputMain {
    nonisolated(unsafe) private static var retainedDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        // 菜单栏应用不会出现系统菜单栏，但文本框的 ⌘V / ⌘C 等快捷键仍要靠主菜单里的「编辑」项派发。
        app.mainMenu = editMenu()
        app.run()
    }

    private static func editMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "轻语")
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        editItem.submenu = edit
        main.addItem(editItem)

        edit.addItem(item("撤销", action: Selector(("undo:")), key: "z"))
        edit.addItem(item("重做", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("剪切", action: #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("复制", action: #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("粘贴", action: #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(.separator())
        edit.addItem(item("全选", action: #selector(NSText.selectAll(_:)), key: "a"))
        return main
    }

    private static func item(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }
}
