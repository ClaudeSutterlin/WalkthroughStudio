import Foundation
import AVFoundation
import CoreImage

/// Per-frame Core Image compositor for the 16:9 branded wrapper. Deterministic
/// (no CoreAnimation render server), so it works headless and off the main
/// thread — unlike `AVVideoCompositionCoreAnimationTool`, which renders black
/// in offscreen contexts.
///
/// Each output frame = the branded background with the recording scaled into
/// the device screen rect and clipped to rounded corners.
final class FrameCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange
    var enablePostProcessing = false
    var containsTweening = true
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID = kCMPersistentTrackID_Invalid

    let sourceTrackID: CMPersistentTrackID
    let background: CIImage
    let mask: CIImage
    let screenRectCI: CGRect      // Core Image (bottom-left) coordinates
    let canvas: CGSize
    let preferred: CGAffineTransform
    let cropTopFraction: Double   // crop mode: cut the band, cover-fit the rest
    let maskBandFraction: Double  // clean mode: bg-extend the band + overlay
    let barOverlay: CIImage?      // clean mode: synthetic status bar glyphs

    init(
        sourceTrackID: CMPersistentTrackID,
        timeRange: CMTimeRange,
        background: CIImage,
        mask: CIImage,
        screenRectCI: CGRect,
        canvas: CGSize,
        preferred: CGAffineTransform,
        cropTopFraction: Double = 0,
        maskBandFraction: Double = 0,
        barOverlay: CIImage? = nil
    ) {
        self.sourceTrackID = sourceTrackID
        self.timeRange = timeRange
        self.background = background
        self.mask = mask
        self.screenRectCI = screenRectCI
        self.canvas = canvas
        self.preferred = preferred
        self.cropTopFraction = cropTopFraction
        self.maskBandFraction = maskBandFraction
        self.barOverlay = barOverlay
        super.init()
        self.requiredSourceTrackIDs = [NSNumber(value: sourceTrackID)]
    }
}

final class FrameCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? FrameCompositionInstruction else {
                request.finish(with: StudioError("Frame compositor: wrong instruction type."))
                return
            }
            guard let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: StudioError("Frame compositor: could not allocate an output buffer."))
                return
            }
            guard let source = request.sourceFrame(byTrackID: instruction.sourceTrackID) else {
                // No source frame (shouldn't happen) — emit the background alone.
                context.render(instruction.background, to: output, bounds: CGRect(origin: .zero, size: instruction.canvas), colorSpace: colorSpace)
                request.finish(withComposedVideoFrame: output)
                return
            }

            var video = CIImage(cvPixelBuffer: source)
            video = video.transformed(by: instruction.preferred)

            let extent = video.extent
            let screen = instruction.screenRectCI
            let crop = CGFloat(instruction.cropTopFraction)
            var transform: CGAffineTransform
            if crop > 0.001 {
                // Status-bar crop: scale so the frame MINUS its top band fills
                // the screen rect. The cropped band ends up above screen.maxY
                // and the rounded mask clips it (cover semantics on the rest).
                let visibleH = extent.height * (1 - crop)
                let scale = max(screen.width / extent.width, screen.height / visibleH)
                let drawW = extent.width * scale
                let tx = screen.minX + (screen.width - drawW) / 2 - extent.minX * scale
                // Center the VISIBLE region (bottom `visibleH` of the frame,
                // in CI's bottom-left space) on the screen rect vertically.
                let ty = screen.midY - (visibleH * scale) / 2 - extent.minY * scale
                transform = CGAffineTransform(scaleX: scale, y: scale)
                    .concatenating(CGAffineTransform(translationX: tx, y: ty))
            } else {
                // Aspect-fit the oriented recording into the screen rect.
                let scale = min(screen.width / extent.width, screen.height / extent.height)
                let drawW = extent.width * scale
                let drawH = extent.height * scale
                let tx = screen.minX + (screen.width - drawW) / 2 - extent.minX * scale
                let ty = screen.minY + (screen.height - drawH) / 2 - extent.minY * scale
                transform = CGAffineTransform(scaleX: scale, y: scale)
                    .concatenating(CGAffineTransform(translationX: tx, y: ty))
            }
            var positioned = video.transformed(by: transform)

            // Clean status bar: stretch the row just below the band over the
            // band (background continues seamlessly), then stamp the synthetic
            // bar glyphs on top. Layout is untouched — no aspect change.
            if instruction.maskBandFraction > 0.001 {
                let bandH = screen.height * CGFloat(instruction.maskBandFraction)
                let bandRect = CGRect(x: screen.minX, y: screen.maxY - bandH, width: screen.width, height: bandH)
                let stripH: CGFloat = 2
                let stripY = screen.maxY - bandH - stripH - 1
                let strip = positioned
                    .cropped(to: CGRect(x: screen.minX, y: stripY, width: screen.width, height: stripH))
                    .transformed(by: CGAffineTransform(translationX: 0, y: -stripY))
                    .transformed(by: CGAffineTransform(scaleX: 1, y: bandH / stripH))
                    .transformed(by: CGAffineTransform(translationX: 0, y: bandRect.minY))
                    .cropped(to: bandRect)
                positioned = strip.composited(over: positioned)
                if let overlay = instruction.barOverlay {
                    let scaleX = bandRect.width / overlay.extent.width
                    let scaleY = bandRect.height / overlay.extent.height
                    let placedOverlay = overlay
                        .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                        .transformed(by: CGAffineTransform(translationX: bandRect.minX, y: bandRect.minY))
                    positioned = placedOverlay.composited(over: positioned)
                }
            }

            // Video where the rounded mask is opaque, branded background elsewhere.
            let composited = positioned
                .applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: instruction.background,
                    kCIInputMaskImageKey: instruction.mask,
                ])
                .cropped(to: CGRect(origin: .zero, size: instruction.canvas))

            context.render(
                composited,
                to: output,
                bounds: CGRect(origin: .zero, size: instruction.canvas),
                colorSpace: colorSpace
            )
            request.finish(withComposedVideoFrame: output)
        }
    }
}
