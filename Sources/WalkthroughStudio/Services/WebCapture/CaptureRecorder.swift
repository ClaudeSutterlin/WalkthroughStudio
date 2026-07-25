import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo

/// Composes the synthetic "screen recording" of a web capture: page snapshots
/// become held frames, cursor travel and click pulses are animated between
/// them, and (for iPhone captures) the Apple-marketing status bar is painted
/// into a reserved top band. Output is an H.264 .mov the rest of the pipeline
/// treats exactly like an imported recording.
///
/// Time is explicit: a hold appends ONE frame whose duration runs until the
/// next append, so long dwells cost almost nothing; animations append at
/// `animationFPS`.
///
/// An actor so frame rasterization stays off the main actor (the capture UI
/// keeps animating while frames encode).
actor CaptureRecorder {

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int
    private let height: Int
    private let bandHeight: Int
    /// Status-bar glyph overlays (built by the caller on the main actor —
    /// AppKit symbol drawing doesn't belong inside this actor).
    private let barOverlayLight: CGImage?  // black glyphs, for light pages
    private let barOverlayDark: CGImage?   // white glyphs, for dark pages
    private let animationFPS: Double = 24

    /// Where the write head is, in seconds of output video.
    private(set) var currentTime: Double = 0
    private var finished = false

    init(
        outputURL: URL,
        viewport: CaptureViewport,
        barOverlayLight: CGImage?,
        barOverlayDark: CGImage?
    ) throws {
        width = Int(viewport.pixelSize.width)
        height = Int(viewport.pixelSize.height)
        bandHeight = viewport.statusBarBandHeight
        self.barOverlayLight = barOverlayLight
        self.barOverlayDark = barOverlayDark

        try? FileManager.default.removeItem(at: outputURL)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 3,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw StudioError("Could not configure the capture video writer.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? StudioError("The capture video writer refused to start.")
        }
        writer.startSession(atSourceTime: .zero)
    }

    // MARK: Appending

    /// Show `page` for `seconds` (one cheap frame; duration runs to the next append).
    func appendHold(_ page: CGImage, seconds: Double, cursor: CGPoint?) throws {
        try append(render(page: page, cursor: cursor, pulse: nil), at: currentTime)
        currentTime += max(0.05, seconds)
    }

    /// Glide the cursor from `from` to `to` over `duration` (ease-in-out).
    func appendCursorMove(_ page: CGImage, from: CGPoint, to: CGPoint, duration: Double) throws {
        let frames = max(3, Int(duration * animationFPS))
        for i in 0..<frames {
            let linear = Double(i) / Double(frames - 1)
            let eased = linear * linear * (3 - 2 * linear) // smoothstep
            let position = CGPoint(
                x: from.x + (to.x - from.x) * eased,
                y: from.y + (to.y - from.y) * eased
            )
            try append(render(page: page, cursor: position, pulse: nil), at: currentTime + Double(i) * duration / Double(frames))
        }
        currentTime += duration
    }

    /// Expanding click ring at `point` (the moment the agent "presses").
    func appendClickPulse(_ page: CGImage, at point: CGPoint, duration: Double = 0.4) throws {
        let frames = max(4, Int(duration * animationFPS))
        for i in 0..<frames {
            let progress = Double(i) / Double(frames - 1)
            try append(render(page: page, cursor: point, pulse: progress), at: currentTime + Double(i) * duration / Double(frames))
        }
        currentTime += duration
    }

    /// A run of quick states (scroll positions, typing progress), evenly spaced.
    func appendSequence(_ pages: [CGImage], secondsPerFrame: Double, cursor: CGPoint?) throws {
        for page in pages {
            try append(render(page: page, cursor: cursor, pulse: nil), at: currentTime)
            currentTime += secondsPerFrame
        }
    }

    /// Close the movie. `endSession` extends the final frame's duration to the
    /// write head — without it the last hold would be dropped on the floor.
    func finish() async throws {
        guard !finished else { return }
        finished = true
        writer.endSession(atSourceTime: CMTime(seconds: currentTime, preferredTimescale: 600))
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? StudioError("The capture recording could not be written.")
        }
    }

    // MARK: Frame rendering

    private var lastAppendTime = -1.0

    private func append(_ buffer: CVPixelBuffer, at seconds: Double) throws {
        while !input.isReadyForMoreMediaData {
            usleep(5_000)
        }
        guard writer.status == .writing else {
            throw writer.error ?? StudioError("The capture video writer failed mid-recording.")
        }
        // Presentation times must be strictly increasing; rounding in the
        // animation math must never walk backwards.
        let safeSeconds = max(seconds, lastAppendTime + 1.0 / 600.0)
        lastAppendTime = safeSeconds
        let time = CMTime(seconds: safeSeconds, preferredTimescale: 600)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw writer.error ?? StudioError("A capture frame could not be appended.")
        }
    }

    /// Compose one output frame: status-bar band (iPhone) + page + cursor.
    /// `cursor` is in CONTENT pixels, top-left origin (the band offset and the
    /// CGContext bottom-left flip are handled here — see CLAUDE.md landmine 6).
    private func render(page: CGImage, cursor: CGPoint?, pulse: Double?) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            let attributes = [kCVPixelBufferCGImageCompatibilityKey as String: true] as CFDictionary
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &pixelBuffer)
        }
        guard let buffer = pixelBuffer else { throw StudioError("Could not allocate a capture frame buffer.") }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw StudioError("Could not draw into a capture frame buffer.") }

        ctx.interpolationQuality = .high
        let contentHeight = CGFloat(height - bandHeight)
        // Page content sits below the band: CG is bottom-left, so it fills
        // y ∈ [0, contentHeight] and the band is the top strip above it.
        ctx.draw(page, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: contentHeight))

        if bandHeight > 0 {
            let stats = Self.topRowStats(of: page)
            ctx.setFillColor(CGColor(red: stats.r, green: stats.g, blue: stats.b, alpha: 1))
            ctx.fill(CGRect(x: 0, y: contentHeight, width: CGFloat(width), height: CGFloat(bandHeight)))
            if let overlay = stats.isDark ? barOverlayDark : barOverlayLight {
                ctx.draw(overlay, in: CGRect(x: 0, y: contentHeight, width: CGFloat(width), height: CGFloat(bandHeight)))
            }
        }

        if let cursor {
            // Content top-left → CG bottom-left within the full frame.
            let cx = cursor.x
            let cy = contentHeight - cursor.y
            let radius = max(9, CGFloat(width) * 0.008)

            if let pulse {
                // Expanding, fading ring around the press point.
                let ringRadius = radius * (1.2 + 3.2 * pulse)
                ctx.setStrokeColor(CGColor(red: 0.855, green: 0.310, blue: 0.271, alpha: 0.85 * (1 - pulse))) // brand coral
                ctx.setLineWidth(max(2, radius * 0.35))
                ctx.strokeEllipse(in: CGRect(x: cx - ringRadius, y: cy - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
            }

            // Screencast-style pointer: soft halo, white ring, charcoal dot.
            ctx.setFillColor(CGColor(red: 0.855, green: 0.310, blue: 0.271, alpha: 0.22))
            ctx.fillEllipse(in: CGRect(x: cx - radius * 2.1, y: cy - radius * 2.1, width: radius * 4.2, height: radius * 4.2))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
            ctx.fillEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
            ctx.setFillColor(CGColor(red: 0.102, green: 0.086, blue: 0.071, alpha: 1)) // brand charcoal
            let inner = radius * 0.62
            ctx.fillEllipse(in: CGRect(x: cx - inner, y: cy - inner, width: inner * 2, height: inner * 2))
        }

        return buffer
    }

    /// Mean color + luminance of the page's top edge — the band continues the
    /// page background so the fake bar reads as part of the site.
    private static func topRowStats(of image: CGImage) -> (r: CGFloat, g: CGFloat, b: CGFloat, isDark: Bool) {
        let sampleW = 64
        var pixels = [UInt8](repeating: 0, count: sampleW * 4)
        guard let strip = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: 1)),
              let ctx = CGContext(
                data: &pixels, width: sampleW, height: 1, bitsPerComponent: 8,
                bytesPerRow: sampleW * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return (1, 1, 1, false) }
        ctx.interpolationQuality = .medium
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: sampleW, height: 1))
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<sampleW {
            r += Double(pixels[i * 4])
            g += Double(pixels[i * 4 + 1])
            b += Double(pixels[i * 4 + 2])
        }
        let n = Double(sampleW) * 255.0
        let luminance = (0.299 * r + 0.587 * g + 0.114 * b) / n
        return (CGFloat(r / n), CGFloat(g / n), CGFloat(b / n), luminance < 0.5)
    }
}
