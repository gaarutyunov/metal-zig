// Records the first on-screen window owned by a process to a looping GIF.
//
// usage: windowgif <pid> <seconds> <fps> <width> <out.gif>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 6, let pid = Int32(args[1]), let seconds = Double(args[2]),
      let fps = Double(args[3]), let width = Int(args[4]) else {
    FileHandle.standardError.write("usage: windowgif <pid> <seconds> <fps> <width> <out.gif>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[5])

func windowID() -> CGWindowID? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    for w in windows where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
        return w[kCGWindowNumber as String] as? CGWindowID
    }
    return nil
}

guard let id = windowID() else {
    FileHandle.standardError.write("no window for pid \(pid)\n".data(using: .utf8)!)
    exit(1)
}

/// Scales an image to `width`, keeping its aspect ratio.
func scaled(_ image: CGImage) -> CGImage {
    let height = image.height * width / image.width
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

// Capture the frames first, then encode, so encoding does not slow capture.
let count = Int(seconds * fps)
var frames: [CGImage] = []
let start = Date()
for i in 0..<count {
    let due = start.addingTimeInterval(Double(i) / fps)
    let wait = due.timeIntervalSinceNow
    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) {
        frames.append(scaled(image))
    }
}

guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
    exit(1)
}
CGImageDestinationSetProperties(dest, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
] as CFDictionary)
let frameProperties = [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps],
] as CFDictionary
for frame in frames {
    CGImageDestinationAddImage(dest, frame, frameProperties)
}
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
