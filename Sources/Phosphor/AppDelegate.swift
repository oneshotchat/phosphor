import AppKit
import MetalKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var renderer: Renderer!
    private let controller = ChatController()

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
        controller.onEvent = { [renderer] event in renderer?.scene.handle(event) }
        controller.onRoomChanged = { [renderer] in renderer?.scene.reset() }

        window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Phosphor"
        window.backgroundColor = .black
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        // Room: first argument or PHOSPHOR_ROOM, else #lobby.
        let env = ProcessInfo.processInfo.environment
        let args = CommandLine.arguments.dropFirst()
        if args.contains("--demo") || env["PHOSPHOR_DEMO"] != nil {
            controller.startDemo(speakers: env["PHOSPHOR_DEMO_SPEAKERS"].flatMap(Int.init) ?? 3)
        } else {
            let room = args.first(where: { !$0.hasPrefix("-") }) ?? env["PHOSPHOR_ROOM"] ?? "lobby"
            let server = env["PHOSPHOR_SERVER"].flatMap(URL.init(string:))
            if let server { controller.start(room: room, server: server) } else { controller.start(room: room) }
        }
        DevInput.startIfRequested(controller: controller)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func toggleReading(_ sender: Any?) { renderer.readingMode.toggle() }
    @objc func nextTheme(_ sender: Any?) { renderer.nextTheme() }
    @objc func toggleCRT(_ sender: Any?) { renderer.crtEnabled.toggle() }
    /// Preview of how background rooms will look until multi-room lands.
    @objc func toggleCurl(_ sender: Any?) { renderer.scene.targetCurl = renderer.scene.targetCurl > 0.5 ? 0 : 1 }

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
        submenu("Phosphor", [item("Quit Phosphor", #selector(NSApplication.terminate(_:)), "q")])
        submenu("Edit", [item("Paste", #selector(PhosphorView.paste(_:)), "v")])
        submenu("View", [
            item("Reading Mode", #selector(toggleReading(_:)), "r", target: self),
            item("Next Theme", #selector(nextTheme(_:)), "t", target: self),
            item("CRT Effects", #selector(toggleCRT(_:)), "e", target: self),
            item("Roll Up Room (preview)", #selector(toggleCurl(_:)), "u", target: self),
        ])
        NSApp.mainMenu = main
    }
}
