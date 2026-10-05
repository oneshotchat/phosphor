import AppKit
import MetalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var renderer: Renderer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this machine")
        }
        let view = PhosphorView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), device: device)
        do {
            renderer = try Renderer(view: view)
        } catch {
            fatalError("Renderer setup failed: \(error)")
        }
        view.renderer = renderer
        view.delegate = renderer

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Phosphor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}

/// Owns input; the renderer owns everything else.
final class PhosphorView: MTKView {
    weak var renderer: Renderer?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDragged(with event: NSEvent) {
        renderer?.camera.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        renderer?.camera.zoom(by: Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
    }

    override func keyDown(with event: NSEvent) {
        guard let renderer else { return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": renderer.crtEnabled.toggle()
        case "t": renderer.nextTheme()
        case "r": renderer.readingMode.toggle()
        default: super.keyDown(with: event)
        }
    }
}
