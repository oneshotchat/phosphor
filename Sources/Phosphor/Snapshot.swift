import OSCCore
import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Dev tool: render one frame to a PNG and quit, without needing screen-recording access.
///
///     PHOSPHOR_SNAPSHOT=/tmp/shot.png PHOSPHOR_SNAPSHOT_AT=6 PHOSPHOR_READING=1 PHOSPHOR_THEME=1 swift run Phosphor
final class Snapshot {
    let path: String
    let at: Float
    let readingMode: Bool
    let theme: Int
    private var taken = false

    private init(path: String, at: Float, readingMode: Bool, theme: Int) {
        self.path = path
        self.at = at
        self.readingMode = readingMode
        self.theme = theme
    }

    static func fromEnvironment() -> Snapshot? {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PHOSPHOR_SNAPSHOT"] else { return nil }
        return Snapshot(
            path: path,
            at: env["PHOSPHOR_SNAPSHOT_AT"].flatMap(Float.init) ?? 6,
            readingMode: env["PHOSPHOR_READING"] == "1",
            theme: env["PHOSPHOR_THEME"].flatMap(Int.init) ?? 0
        )
    }

    func isDue(time: Float) -> Bool { !taken && time >= at }

    func makeTarget(device: MTLDevice, size: CGSize, format: MTLPixelFormat) -> MTLTexture? {
        taken = true
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: Int(size.width), height: Int(size.height), mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    /// Called from the command buffer's completion handler.
    func write(_ texture: MTLTexture) {
        let w = texture.width, h = texture.height
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bgra, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)

        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                         UTType.png.identifier as CFString, 1, nil)
        else {
            print("Snapshot: failed to encode \(path)")
            exit(1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("Snapshot: wrote \(path)")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

/// Dev tool: feed lines into the input as if typed, from a FIFO or file, so the app's
/// own send path can be driven by a script.
///
///     PHOSPHOR_INPUT=/tmp/phosphor.in swift run Phosphor conformance
@MainActor
enum DevInput {
    static func startIfRequested(controller: ChatController) {
        guard let path = ProcessInfo.processInfo.environment["PHOSPHOR_INPUT"] else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        // Echo the room as text so a script can follow along.
        let previous = controller.onEvent
        controller.onEvent = { event in
            previous?(event)
            switch event.payload {
            case .messageCreated(let m), .messageEdited(let m):
                let label = controller.state?.labels[m.author.identity] ?? m.author.name
                let text = MentionText.display(m.text) { controller.state?.labels[$0] ?? String($0.prefix(8)) }
                print("[\(m.id)] \(SafeText.clean(label)): \(SafeText.clean(text))")
            case .reactionAdded(let r):
                print("· reaction \(SafeText.clean(r.reaction)) on [\(r.messageId)]")
            default:
                break
            }
        }
        Task.detached {
            guard let handle = FileHandle(forReadingAtPath: path) else { return }
            for try await line in handle.bytes.lines {
                await MainActor.run {
                    var labels: [String: String] = [:]
                    for (fp, label) in controller.state?.labels ?? [:] { labels[label] = fp }
                    controller.submit(line, labels: labels)
                }
            }
        }
    }
}
