import CoreText
import Metal
import simd

/// Signed-distance-field glyphs baked on demand from CoreText into one r8 texture.
///
/// Layout goes through CTLine, so font fallback (CJK, symbols, emoji) comes for free.
/// Color emoji bake as their silhouette and get tinted like everything else.
final class GlyphAtlas {
    struct Entry {
        var uvRect: SIMD4<Float>     // normalized x, y, w, h
        var offset: SIMD2<Float>     // quad bottom-left relative to the pen, in bake points
        var size: SIMD2<Float>       // quad size in bake points
        var isEmpty: Bool { size.x == 0 }
    }

    struct PlacedGlyph {
        var x: Float                 // pen position along the baseline, bake points
        var entry: Entry
    }

    struct TextLine {
        var glyphs: [PlacedGlyph]
        var width: Float             // typographic width, bake points
    }

    let texture: MTLTexture
    let bakeSize: CGFloat = 48
    private let spread = 8           // SDF range in pixels either side of the edge
    private let dimension = 2048
    private let font: CTFont

    private struct Key: Hashable {
        let font: String
        let glyph: CGGlyph
    }

    private var entries: [Key: Entry] = [:]
    private var lines: [String: TextLine] = [:]
    private var shelfX = 0, shelfY = 0, shelfHeight = 0

    init(device: MTLDevice) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: dimension, height: dimension, mipmapped: false)
        descriptor.usage = .shaderRead
        texture = device.makeTexture(descriptor: descriptor)!
        let zeros = [UInt8](repeating: 0, count: dimension * dimension)
        texture.replace(region: MTLRegionMake2D(0, 0, dimension, dimension), mipmapLevel: 0,
                        withBytes: zeros, bytesPerRow: dimension)

        let mono = CTFontCreateUIFontForLanguage(.userFixedPitch, bakeSize, nil)
        font = mono ?? CTFontCreateWithName("Menlo" as CFString, bakeSize, nil)
    }

    func layout(_ string: String) -> TextLine {
        if let cached = lines[string] { return cached }

        let attributed = CFAttributedStringCreate(
            nil, string as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        var placed: [PlacedGlyph] = []

        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = attrs[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                let entry = self.entry(font: runFont, glyph: glyph)
                if !entry.isEmpty {
                    placed.append(PlacedGlyph(x: Float(position.x), entry: entry))
                }
            }
        }

        let width = Float(CTLineGetTypographicBounds(line, nil, nil, nil))
        let result = TextLine(glyphs: placed, width: width)
        lines[string] = result
        return result
    }

    private func entry(font: CTFont, glyph: CGGlyph) -> Entry {
        let key = Key(font: CTFontCopyPostScriptName(font) as String, glyph: glyph)
        if let cached = entries[key] { return cached }
        let baked = bake(font: font, glyph: glyph)
        entries[key] = baked
        return baked
    }

    private func bake(font: CTFont, glyph: CGGlyph) -> Entry {
        let empty = Entry(uvRect: .zero, offset: .zero, size: .zero)
        var g = glyph
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .default, &g, nil, 1)
        if bounds.isEmpty || bounds.isNull { return empty }

        let w = Int(ceil(bounds.width)) + 2 * spread
        let h = Int(ceil(bounds.height)) + 2 * spread
        guard let (x, y) = allocate(w, h) else {
            print("GlyphAtlas: full, dropping glyph \(glyph)")
            return empty
        }

        // Render coverage into RGBA and keep alpha, so color emoji become silhouettes.
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return empty }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        var origin = CGPoint(x: CGFloat(spread) - bounds.minX, y: CGFloat(spread) - bounds.minY)
        CTFontDrawGlyphs(font, &g, &origin, 1, ctx)

        let rgba = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var inside = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { inside[i] = rgba[i * 4 + 3] > 127 }
        let sdf = signedDistanceField(inside: inside, width: w, height: h)

        texture.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0, withBytes: sdf, bytesPerRow: w)

        let d = Float(dimension)
        return Entry(
            uvRect: SIMD4(Float(x) / d, Float(y) / d, Float(w) / d, Float(h) / d),
            offset: SIMD2(Float(bounds.minX) - Float(spread), Float(bounds.minY) - Float(spread)),
            size: SIMD2(Float(w), Float(h))
        )
    }

    /// Shelf packing: fill rows left to right, start a new row when one is full.
    private func allocate(_ w: Int, _ h: Int) -> (Int, Int)? {
        if shelfX + w > dimension {
            shelfX = 0
            shelfY += shelfHeight + 1
            shelfHeight = 0
        }
        guard shelfY + h <= dimension else { return nil }
        defer {
            shelfX += w + 1
            shelfHeight = max(shelfHeight, h)
        }
        return (shelfX, shelfY)
    }

    /// 0.5 at the edge, rising to 1 inside and falling to 0 outside over `spread` pixels.
    private func signedDistanceField(inside: [Bool], width w: Int, height h: Int) -> [UInt8] {
        let far: Float = 1e20
        let toInside = edt(inside.map { $0 ? 0 : far }, w, h)    // for outside pixels
        let toOutside = edt(inside.map { $0 ? far : 0 }, w, h)   // for inside pixels
        var out = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            var d = toInside[i].squareRoot() - toOutside[i].squareRoot()
            d += d > 0 ? -0.5 : 0.5   // the edge lies between pixel centers
            let v = 0.5 - d / Float(2 * spread)
            out[i] = UInt8(max(0, min(1, v)) * 255)
        }
        return out
    }

    /// Squared Euclidean distance transform (Felzenszwalb & Huttenlocher), columns then rows.
    private func edt(_ grid: [Float], _ w: Int, _ h: Int) -> [Float] {
        var g = grid
        var column = [Float](repeating: 0, count: h)
        for x in 0..<w {
            for y in 0..<h { column[y] = g[y * w + x] }
            let d = edt1d(column)
            for y in 0..<h { g[y * w + x] = d[y] }
        }
        var row = [Float](repeating: 0, count: w)
        for y in 0..<h {
            for x in 0..<w { row[x] = g[y * w + x] }
            let d = edt1d(row)
            for x in 0..<w { g[y * w + x] = d[x] }
        }
        return g
    }

    private func edt1d(_ f: [Float]) -> [Float] {
        let n = f.count
        var d = [Float](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n)
        var z = [Float](repeating: 0, count: n + 1)
        var k = 0
        z[0] = -.infinity
        z[1] = .infinity
        for q in 1..<n {
            var s: Float
            while true {
                let r = v[k]
                s = ((f[q] + Float(q * q)) - (f[r] + Float(r * r))) / Float(2 * q - 2 * r)
                if s <= z[k] { k -= 1 } else { break }
            }
            k += 1
            v[k] = q
            z[k] = s
            z[k + 1] = .infinity
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let dq = Float(q - v[k])
            d[q] = dq * dq + f[v[k]]
        }
        return d
    }
}
