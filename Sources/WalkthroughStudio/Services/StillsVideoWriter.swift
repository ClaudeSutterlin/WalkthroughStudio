// StillsVideoWriter — Onboard to a Codebase, milestone M1.
//
// Manufactures an H.264 MP4 from still frames with per-frame holds. There is
// no screen recording in the onboarding mode: scene stills become a sparse
// video track that `VideoService.assembleNarratedVideo` then muxes with the
// narration exactly like a real recording (ARCHITECTURE.md section 5, step 5).
// Ported from scripts/make-test-video.swift (AVAssetWriter + pixel-buffer
// adaptor, 600 timescale).
import Foundation
import AVFoundation
import CoreGraphics

enum StillsVideoWriter {

    /// Interval at which a held frame is re-appended so the track never has a
    /// multi-second gap between samples (keeps seeking/thumbnailing cheap).
    static let repeatInterval: Double = 0.5

    /// Extra hold appended after the last frame so the asset is never shorter
    /// than the sum of the holds (the source-duration clamp in
    /// `assembleNarratedVideo` must never trigger for a stills video).
    static let trailingHold: Double = 1.0

    /// Write `frames` to an H.264 `.mp4` at `url`.
    ///
    /// Each frame is appended at its shot start and then every 0.5 s of its
    /// hold; the last frame is appended once more at the end of the final hold
    /// and the session ends 1.0 s later, so the asset duration is
    /// `sum(holds) + 1.0`. Presentation times use the 600 timescale.
    static func write(
        frames: [(image: CGImage, hold: Double)],
        size: CGSize,
        fps: Int = 30,
        to url: URL
    ) async throws {
        guard !frames.isEmpty else {
            throw StudioError("StillsVideoWriter: no frames to write.")
        }
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else {
            throw StudioError("StillsVideoWriter: invalid size \(width)x\(height).")
        }
        for (index, frame) in frames.enumerated() where frame.hold <= 0.001 {
            throw StudioError("StillsVideoWriter: frame \(index) has a non-positive hold (\(frame.hold)).")
        }

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: max(1, fps),
                AVVideoMaxKeyFrameIntervalKey: max(1, fps),
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw StudioError("StillsVideoWriter: the writer rejected the video input.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? StudioError("StillsVideoWriter: startWriting failed.")
        }
        writer.startSession(atSourceTime: .zero)

        // Build the presentation schedule first: (frame index, seconds).
        let timescale: CMTimeScale = 600
        var schedule: [(frameIndex: Int, seconds: Double)] = []
        var cursor = 0.0
        for (index, frame) in frames.enumerated() {
            var t = cursor
            let end = cursor + frame.hold
            while t < end - 0.001 {
                schedule.append((index, t))
                t += repeatInterval
            }
            cursor = end
        }
        let total = cursor
        // The last frame once more at the end of the final hold; the session
        // then ends `trailingHold` later so this sample is held that long.
        schedule.append((frames.count - 1, total))

        var lastTime = CMTime.invalid
        for entry in schedule {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            if writer.status == .failed {
                throw writer.error ?? StudioError("StillsVideoWriter: writer failed mid-run.")
            }
            let time = CMTime(seconds: entry.seconds, preferredTimescale: timescale)
            // Presentation times must strictly increase; skip exact duplicates
            // (can happen when a hold is a sub-600ths multiple).
            if lastTime.isValid, time <= lastTime { continue }
            let buffer = try pixelBuffer(
                from: frames[entry.frameIndex].image,
                width: width, height: height,
                pool: adaptor.pixelBufferPool
            )
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? StudioError(
                    String(format: "StillsVideoWriter: append failed at %.2fs.", entry.seconds)
                )
            }
            lastTime = time
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: total + trailingHold, preferredTimescale: timescale))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status != .completed {
            throw writer.error ?? StudioError("StillsVideoWriter: finishWriting did not complete (status \(writer.status.rawValue)).")
        }
    }

    /// A solid-colour RGBA frame for probes (components 0...1).
    static func solidFrame(color: (r: CGFloat, g: CGFloat, b: CGFloat), size: CGSize) -> CGImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("StillsVideoWriter.solidFrame: could not create a \(width)x\(height) bitmap context")
        }
        ctx.setFillColor(CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else {
            fatalError("StillsVideoWriter.solidFrame: makeImage failed")
        }
        return image
    }

    // MARK: - Pixel buffers

    /// Draw `image` (scaled to fill) into a fresh 32BGRA pixel buffer. Uses the
    /// adaptor's pool when available so buffers match the input's attributes.
    private static func pixelBuffer(
        from image: CGImage,
        width: Int,
        height: Int,
        pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status: CVReturn
        if let pool {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        } else {
            let attributes: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                attributes as CFDictionary, &buffer
            )
        }
        guard status == kCVReturnSuccess, let pb = buffer else {
            throw StudioError("StillsVideoWriter: could not create a pixel buffer (CVReturn \(status)).")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        // 32BGRA in memory == little-endian ARGB word: premultipliedFirst + byteOrder32Little.
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw StudioError("StillsVideoWriter: could not wrap the pixel buffer in a CGContext.")
        }
        ctx.interpolationQuality = .high
        // Drawing the whole image into the whole rect keeps orientation intact
        // regardless of CG's bottom-left origin (the buffer ends up top-row-first,
        // which is what the encoder expects).
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pb
    }
}
