// Generates a synthetic portrait "screen recording" with 3 visually distinct
// scenes for the Walkthrough Studio selftest.
//   swift make-test-video.swift <output.mov>
import AVFoundation
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: out)

let width = 600, height = 1300
let fps = 10, seconds = 9
let writer = try! AVAssetWriter(outputURL: out, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]
)
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

func frame(_ scene: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    let pb = buffer!
    CVPixelBufferLockBaseAddress(pb, [])
    let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    )!
    let w = CGFloat(width), h = CGFloat(height)

    // Cream app background + fake status bar band at the top.
    ctx.setFillColor(CGColor(red: 1.0, green: 0.98, blue: 0.95, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
    ctx.fill(CGRect(x: 30, y: h - 60, width: 80, height: 24))   // fake clock
    ctx.fill(CGRect(x: w - 110, y: h - 60, width: 80, height: 24)) // fake battery

    // Colorful app header right below the status bar (top-left rows ~100-400)
    // so the framed-video probe finds saturated recording content near the
    // top of the composited screen.
    let headerColors: [CGColor] = [
        CGColor(red: 0.9, green: 0.2, blue: 0.3, alpha: 1),
        CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1),
        CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1),
        CGColor(red: 0.95, green: 0.7, blue: 0.1, alpha: 1),
    ]
    let tileW = w / 4
    for (i, color) in headerColors.enumerated() {
        ctx.setFillColor(color)
        let shift = CGFloat((i + scene) % 4)
        ctx.fill(CGRect(x: shift * tileW, y: h - 400, width: tileW, height: 335))
    }

    switch scene {
    case 0: // blue "welcome" card
        ctx.setFillColor(CGColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 60, y: h - 500, width: w - 120, height: 340))
        ctx.setFillColor(CGColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 60, y: 200, width: w - 120, height: 120))
    case 1: // green list rows
        ctx.setFillColor(CGColor(red: 0.15, green: 0.65, blue: 0.35, alpha: 1))
        for row in 0..<5 {
            ctx.fill(CGRect(x: 50, y: h - 340 - CGFloat(row) * 160, width: w - 100, height: 110))
        }
    default: // coral detail screen
        ctx.setFillColor(CGColor(red: 0.85, green: 0.30, blue: 0.27, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - 700, width: w, height: 560))
        ctx.setFillColor(CGColor(red: 0.10, green: 0.09, blue: 0.07, alpha: 1))
        ctx.fill(CGRect(x: 80, y: 150, width: w - 160, height: 300))
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}

let sceneAt: (Double) -> Int = { t in t < 3.5 ? 0 : (t < 6.0 ? 1 : 2) }
for i in 0..<(fps * seconds) {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
    let t = Double(i) / Double(fps)
    adaptor.append(frame(sceneAt(t)), withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
let sema = DispatchSemaphore(value: 0)
writer.finishWriting { sema.signal() }
sema.wait()
print("wrote \(out.path)")
