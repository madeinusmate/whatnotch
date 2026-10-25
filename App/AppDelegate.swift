import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let shared = AppDelegate()
    private var model: AppModel?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = shared
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        do {
            let paths = try AppPaths.make()
            let model = AppModel(paths: paths)
            self.model = model
            model.start(script: paths.sidecarScript)
        } catch {
            fputs("Whatnotch could not start.\n", stderr)
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    /// Accessory apps have no menu bar. WebKit still needs these items so
    /// Command-C, Command-V, and the rest reach the focused text.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        let add = { (title: String, action: Selector, key: String, mods: NSEvent.ModifierFlags) in
            let item = edit.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
        }
        add("Undo", Selector(("undo:")), "z", .command)
        add("Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), "x", .command)
        add("Copy", #selector(NSText.copy(_:)), "c", .command)
        add("Paste", #selector(NSText.paste(_:)), "v", .command)
        add("Select All", #selector(NSText.selectAll(_:)), "a", .command)
        let main = NSMenu()
        let top = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        top.submenu = edit
        main.addItem(top)
        NSApp.mainMenu = main
    }
}
