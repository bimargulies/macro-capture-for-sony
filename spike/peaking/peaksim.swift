import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// usage: peaksim <in.jpg> <out.png> [k=6]   Simulates focus peaking: flags pixels whose local contrast is
// well above the image's own noise level, and paints them red.
let args = CommandLine.arguments
guard args.count >= 3, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("cannot read"); exit(1) }
let k = args.count > 3 ? Double(args[3])! : 6.0
let w = img.width, h = img.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

var luma = [Float](repeating: 0, count: w * h)
for i in 0..<(w * h) { luma[i] = 0.2126 * Float(px[i*4]) + 0.7152 * Float(px[i*4+1]) + 0.0722 * Float(px[i*4+2]) }
// 3x3 box blur: suppresses single-pixel noise so only real edges survive
var blur = luma
for y in 1..<(h-1) { for x in 1..<(w-1) {
    var s: Float = 0
    for dy in -1...1 { for dx in -1...1 { s += luma[(y+dy)*w + x+dx] } }
    blur[y*w + x] = s / 9
} }
// Sobel gradient magnitude
var mag = [Float](repeating: 0, count: w * h)
for y in 2..<(h-2) { for x in 2..<(w-2) {
    func p(_ dx: Int, _ dy: Int) -> Float { blur[(y+dy)*w + x+dx] }
    let gx = (p(1,-1) + 2*p(1,0) + p(1,1)) - (p(-1,-1) + 2*p(-1,0) + p(-1,1))
    let gy = (p(-1,1) + 2*p(0,1) + p(1,1)) - (p(-1,-1) + 2*p(0,-1) + p(1,-1))
    mag[y*w + x] = (gx*gx + gy*gy).squareRoot() / 8
} }
// noise level: median gradient (most of the picture is flat or finely textured); threshold = k * median, at least 4 levels
let sorted = mag.sorted()
let median = sorted[sorted.count / 2], p99 = sorted[Int(Double(sorted.count) * 0.99)]
let threshold = max(4.0, Float(k) * median)
var flagged = 0
for i in 0..<(w * h) where mag[i] > threshold {
    flagged += 1
    px[i*4] = 255; px[i*4+1] = 30; px[i*4+2] = 30
}
let frac = Double(flagged) / Double(w * h) * 100
print(String(format: "%@  %dx%d  median grad %.2f  p99 %.1f  threshold %.1f  flagged %.2f%% of pixels", (args[1] as NSString).lastPathComponent, w, h, median, p99, threshold, frac))
let out = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, nil); CGImageDestinationFinalize(dest)
