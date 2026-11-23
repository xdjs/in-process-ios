import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers
let args = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let w = image.width, h = image.height
// Read source pixels as grey over white.
var grey = [UInt8](repeating: 255, count: w * h)
let gctx = CGContext(data: &grey, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
gctx.setFillColor(gray: 1, alpha: 1); gctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
gctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
// Ink coverage: drop paper specks (light greys), keep the stroke.
var minX = w, minY = h, maxX = 0, maxY = 0
var cover = [Float](repeating: 0, count: w * h)
for y in 0..<h { for x in 0..<w {
    let v = Float(grey[y * w + x]) / 255
    let c = max(0, min(1, (0.62 - v) / 0.42))
    cover[y * w + x] = c
    if c > 0.5 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
} }
// Remove isolated specks: require dark neighbours within a small window.
var clean = cover
for y in 2..<(h - 2) { for x in 2..<(w - 2) where cover[y * w + x] > 0 {
    var n = 0
    for dy in -2...2 { for dx in -2...2 where cover[(y + dy) * w + x + dx] > 0.5 { n += 1 } }
    if n < 6 { clean[y * w + x] = 0 }
} }
// Thicken the stroke so it stays legible at home-screen size.
let radius = 4
var bold = clean
for y in radius..<(h - radius) { for x in radius..<(w - radius) {
    var m: Float = 0
    for dy in -radius...radius { for dx in -radius...radius where dx * dx + dy * dy <= radius * radius { m = max(m, clean[(y + dy) * w + x + dx]) } }
    bold[y * w + x] = m
} }
clean = bold
let mark = args.count > 3 && args[3] == "mark"
let size = mark ? 600 : 1024
let paper: (Float, Float, Float) = (0xF3, 0xF1, 0xEC), ink: (Float, Float, Float) = (0x1B, 0x15, 0x04)
let bw = maxX - minX + 1, bh = maxY - minY + 1
let scale = Float(size) * (mark ? 0.96 : 0.78) / Float(max(bw, bh))
let ox = (Float(size) - Float(bw) * scale) / 2, oy = (Float(size) - Float(bh) * scale) / 2
var out = [UInt8](repeating: 255, count: size * size * 4)
for y in 0..<size { for x in 0..<size {
    let sx = (Float(x) - ox) / scale + Float(minX), sy = (Float(y) - oy) / scale + Float(minY)
    var c: Float = 0
    if sx >= 0, sy >= 0, sx < Float(w - 1), sy < Float(h - 1) {
        let x0 = Int(sx), y0 = Int(sy); let fx = sx - Float(x0), fy = sy - Float(y0)
        // Source rows are stored bottom-up relative to this loop's top-down y; flip.
        func at(_ xx: Int, _ yy: Int) -> Float { clean[yy * w + xx] }
        c = at(x0, y0) * (1 - fx) * (1 - fy) + at(x0 + 1, y0) * fx * (1 - fy) + at(x0, y0 + 1) * (1 - fx) * fy + at(x0 + 1, y0 + 1) * fx * fy
    }
    let i = (y * size + x) * 4
    if mark {
        // Template image: black ink, premultiplied alpha, tinted by the app at draw time.
        out[i] = 0; out[i + 1] = 0; out[i + 2] = 0; out[i + 3] = UInt8(255 * c)
    } else {
        out[i] = UInt8(paper.0 + (ink.0 - paper.0) * c); out[i + 1] = UInt8(paper.1 + (ink.1 - paper.1) * c); out[i + 2] = UInt8(paper.2 + (ink.2 - paper.2) * c); out[i + 3] = 255
    }
} }
let octx = CGContext(data: &out, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: (mark ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
let result = octx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, result, nil); print(CGImageDestinationFinalize(dest), bw, bh)
