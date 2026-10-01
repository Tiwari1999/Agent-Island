// mov -> animated GIF with nothing installed: AVFoundation decodes, ImageIO encodes.
// usage: swift tools/mov2gif.swift <in.mov> <out.gif> [fps] [width]
import AVFoundation
import ImageIO
import CoreServices
import AppKit

let a = CommandLine.arguments
guard a.count >= 3 else { fputs("usage: mov2gif in.mov out.gif [fps] [width]\n", stderr); exit(2) }
let fps = a.count > 3 ? Double(a[3]) ?? 20 : 20
let outW = a.count > 4 ? Int(a[4]) ?? 760 : 760

let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero

let sem = DispatchSemaphore(value: 0)
var dur = CMTime.zero
Task { dur = (try? await asset.load(.duration)) ?? .zero; sem.signal() }
sem.wait()
let seconds = CMTimeGetSeconds(dur)
guard seconds > 0 else { fputs("mov2gif: empty or unreadable movie\n", stderr); exit(1) }

let step = 1.0 / fps
let times = stride(from: 0.0, to: seconds, by: step).map {
    NSValue(time: CMTime(seconds: $0, preferredTimescale: 600))
}
guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: a[2]) as CFURL, "com.compuserve.gif" as CFString,
        times.count, nil) else { fputs("mov2gif: cannot create gif\n", stderr); exit(1) }
CGImageDestinationSetProperties(dest, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

/// Downscale on the way out: a retina-width GIF is several times the byte budget for no
/// visible gain once it is embedded in a README at 760px.
func scaled(_ img: CGImage) -> CGImage {
    guard img.width > outW else { return img }
    let h = Int(Double(img.height) * Double(outW) / Double(img.width))
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: outW, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return img }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: outW, height: h))
    return ctx.makeImage() ?? img
}

var n = 0
let frameProps = [kCGImagePropertyGIFDictionary:
                  [kCGImagePropertyGIFDelayTime: step]] as CFDictionary
let group = DispatchGroup()
group.enter()
gen.generateCGImagesAsynchronously(forTimes: times) { _, img, _, result, _ in
    if result == .succeeded, let img {
        CGImageDestinationAddImage(dest, scaled(img), frameProps)
        n += 1
    }
    if n + 1 >= times.count || result == .failed { }
}
// generateCGImagesAsynchronously has no completion; poll until every time is accounted for.
DispatchQueue.global().async {
    while n < times.count { usleep(20_000) }
    group.leave()
}
_ = group.wait(timeout: .now() + 180)
guard CGImageDestinationFinalize(dest) else { fputs("mov2gif: finalize failed\n", stderr); exit(1) }
let bytes = (try? FileManager.default.attributesOfItem(atPath: a[2])[.size] as? Int) ?? 0
print("\(n) frames at \(Int(fps))fps, \(outW)px wide, \((bytes ?? 0)/1024) KB")
