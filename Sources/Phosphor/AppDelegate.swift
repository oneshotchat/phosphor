import AppKit
import MetalKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var renderer: Renderer!
    private let controller = ChatController()
    private var snapshotActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this machine")
        }
        let view = PhosphorView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), device: device)
        do {
            renderer = try Renderer(view: view, controller: controller)
        } catch {
            fatalError("Renderer setup failed: \(error)")
        }
        view.renderer = renderer
        view.controller = controller
        view.delegate = renderer
        controller.onEvent = { [renderer] room, event in renderer?.handle(event, in: room) }
        controller.onRoomReloaded = { [renderer] room in renderer?.reload(room) }
        controller.onOwnMessage = { [renderer] room, message, edited in renderer?.ownMessage(message, in: room, edited: edited) }
        controller.onActiveChanged = { [renderer] old, new in renderer?.activeChanged(from: old, to: new) }

        window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Phosphor"
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = view
        window.center()
        let env = ProcessInfo.processInfo.environment
        if env["PHOSPHOR_SNAPSHOT"] != nil || env["PHOSPHOR_FPS"] != nil {
            // Dev runs open behind everything and never take focus, so they can't steal
            // keystrokes from a Phosphor (or anything else) the user is using.
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
            // Full screen by default; leaving it (⌃⌘F or the green button) is remembered.
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "fullScreen") as? Bool ?? true { window.toggleFullScreen(nil) }
            for (name, value) in [(NSWindow.didEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    UserDefaults.standard.set(value, forKey: "fullScreen")
                }
            }
        }

        // Room: first argument or PHOSPHOR_ROOM, else #lobby.
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--demo") || env["PHOSPHOR_DEMO"] != nil {
            controller.startDemo(speakers: env["PHOSPHOR_DEMO_SPEAKERS"].flatMap(Int.init) ?? 3)
            if let index = env["PHOSPHOR_ACTIVE"].flatMap(Int.init) { controller.activate(index: index) }
        } else {
            let room = args.first(where: { !$0.hasPrefix("-") }) ?? env["PHOSPHOR_ROOM"]
            let server = env["PHOSPHOR_SERVER"].flatMap(URL.init(string:))
            if let server { controller.start(room: room, server: server) } else { controller.start(room: room) }
        }
        DevInput.startIfRequested(controller: controller)

        // Dev: open the room browser at launch, with an optional filter.
        if env["PHOSPHOR_BROWSE"] != nil {
            view.toggleBrowser()
            if let query = env["PHOSPHOR_BROWSE_QUERY"] { controller.browser.setQuery(query) }
            // …move the selection down this many places after a delay (the listing loads first).
            if let moves = env["PHOSPHOR_BROWSE_MOVE"].flatMap(Int.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [controller] in
                    for _ in 0..<moves { controller.browser.move(1) }
                }
            }
            // …and press Enter on the selection after a delay.
            if let delay = env["PHOSPHOR_BROWSE_JOIN"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [controller] in controller.browser.submit("") }
            }
        }

        // Dev: switch to the next room after a delay, to capture the transition.
        if let delay = env["PHOSPHOR_SWITCH"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [controller] in controller.cycle(1) }
        }

        // Snapshot runs drive frames themselves: macOS stops a covered window's display
        // callback, and the snapshot would never be taken.
        if env["PHOSPHOR_SNAPSHOT"] != nil || env["PHOSPHOR_FPS"] != nil {
            snapshotActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "snapshot")
            view.isPaused = true
            view.enableSetNeedsDisplay = false
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
                MainActor.assumeIsolated { view.draw() }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func toggleReading(_ sender: Any?) { renderer.readingMode.toggle() }
    @objc func nextTheme(_ sender: Any?) { renderer.nextTheme() }
    @objc func jumpToLatest(_ sender: Any?) { renderer.jumpToLatest() }
    @objc func resetView(_ sender: Any?) { renderer.resetView() }
    @objc func toggleCRT(_ sender: Any?) { renderer.crtEnabled.toggle() }
    @objc func toggleBrowser(_ sender: Any?) { (window.contentView as? PhosphorView)?.toggleBrowser() }
    @objc func toggleLayout(_ sender: Any?) { renderer.layout = renderer.layout == .ring ? .row : .ring }
    @objc func leaveRoom(_ sender: Any?) { controller.leaveActive() }
    @objc func toggleSigning(_ sender: Any?) { controller.signByDefault.toggle() }

    /// Keeps toggle items' checkmarks current.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSigning(_:)) { item.state = controller.signByDefault ? .on : .off }
        return true
    }
    @objc func nextRoom(_ sender: Any?) { controller.cycle(1) }
    @objc func previousRoom(_ sender: Any?) { controller.cycle(-1) }
    @objc func goToRoom(_ sender: NSMenuItem) { controller.activate(index: sender.tag) }

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = target
            return i
        }
        submenu("Phosphor", [
            item("Sign Messages", #selector(toggleSigning(_:)), "", target: self),
            NSMenuItem.separator(),
            item("Quit Phosphor", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [item("Paste", #selector(PhosphorView.paste(_:)), "v")])
        submenu("View", [
            item("Reading Mode", #selector(toggleReading(_:)), "r", target: self),
            item("Jump to Latest", #selector(jumpToLatest(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), target: self),
            item("Reset View", #selector(resetView(_:)), "0", target: self),
            item("Next Theme", #selector(nextTheme(_:)), "t", target: self),
            item("CRT Effects", #selector(toggleCRT(_:)), "e", target: self),
            item("Ring / Row Layout", #selector(toggleLayout(_:)), "g", target: self),
            NSMenuItem.separator(),
            {
                let i = NSMenuItem(title: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
                i.keyEquivalentModifierMask = [.control, .command]
                return i
            }(),
        ])
        let arrow = { (key: Int) in String(UnicodeScalar(key)!) }
        submenu("Rooms", [
            item("Room Browser", #selector(toggleBrowser(_:)), "l", target: self),
            item("Leave Room", #selector(leaveRoom(_:)), "w", target: self),
            NSMenuItem.separator(),
            item("Next Room", #selector(nextRoom(_:)), arrow(NSRightArrowFunctionKey), target: self),
            item("Previous Room", #selector(previousRoom(_:)), arrow(NSLeftArrowFunctionKey), target: self),
            NSMenuItem.separator(),
        ] + (1...9).map { n in
            let i = item("Room \(n)", #selector(goToRoom(_:)), "\(n)", target: self)
            i.tag = n - 1
            return i
        })
        NSApp.mainMenu = main
    }
}
