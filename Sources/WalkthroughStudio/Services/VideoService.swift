import Foundation
import AVFoundation
import AppKit

/// AVFoundation glue: frame extraction, audio-swap assembly, SRT.
enum VideoService {

    // MARK: Frame extraction

    /// Extract a full-resolution frame at `time` (zero tolerance so the user
    /// gets exactly the frame they scrubbed to).
    static func extractFrame(videoURL: URL, at time: Double, maxDimension: CGFloat? = nil) async throws -> CGImage {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let maxDimension {
            generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        let (image, _) = try await generator.image(at: cmTime)
        return image
    }

    // MARK: Narrated video assembly (Output A)

    /// One slice of the output timeline: a range of the source recording plus
    /// the narration clip (if any) that plays from the slice's start. Trimming
    /// quiet stretches = making a slice shorter than its step.
    struct ExportSegment {
        var sourceStart: Double     // where in the ORIGINAL recording this slice begins
        var duration: Double        // how much of the recording to keep
        var narrationURL: URL?      // WAV narration to play from the slice's start
    }

    /// Stitch the export timeline from `segments` (in order), overlaying each
    /// segment's narration, then export H.264 MP4. When `framing` is set, the
    /// portrait recording is composited inside the branded 16:9 wrapper.
    static func assembleNarratedVideo(
        videoURL: URL,
        segments: [ExportSegment],
        keepOriginalAudio: Bool,
        framing: VideoFraming? = nil,
        outputURL: URL
    ) async throws {
        let asset = AVURLAsset(url: videoURL)
        let assetDuration = try await asset.load(.duration)
        let composition = AVMutableComposition()

        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw StudioError("The recording has no video track.")
        }
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw StudioError("Could not create the composition video track.") }
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        let sourceAudio = keepOriginalAudio
            ? try await asset.loadTracks(withMediaType: .audio).first
            : nil
        let originalTrack = sourceAudio == nil ? nil : composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )

        guard let narrationTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw StudioError("Could not create the narration audio track.") }

        // Build the output timeline segment by segment. The narration track's
        // segments must be CONTIGUOUS — every silent stretch needs an explicit
        // empty range, or playback goes quiet after the first discontinuity.
        let timescale: CMTimeScale = 600
        var cursor = CMTime.zero          // write position in the output
        var narrationCursor = CMTime.zero // end of the last narration insert
        for segment in segments {
            let start = max(0, segment.sourceStart)
            guard start < assetDuration.seconds - 0.05 else { continue }
            let length = min(segment.duration, assetDuration.seconds - start)
            guard length > 0.05 else { continue }

            let sourceRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: timescale),
                duration: CMTime(seconds: length, preferredTimescale: timescale)
            )
            try videoTrack.insertTimeRange(sourceRange, of: sourceVideo, at: cursor)
            if let sourceAudio, let originalTrack {
                try originalTrack.insertTimeRange(sourceRange, of: sourceAudio, at: cursor)
            }

            if let narrationURL = segment.narrationURL {
                let clipAsset = AVURLAsset(url: narrationURL)
                if let clipAudio = try await clipAsset.loadTracks(withMediaType: .audio).first {
                    let clipDuration = try await clipAsset.load(.duration)
                    let useSeconds = min(clipDuration.seconds, length)
                    if useSeconds > 0.05 {
                        if cursor > narrationCursor {
                            narrationTrack.insertEmptyTimeRange(
                                CMTimeRange(start: narrationCursor, end: cursor)
                            )
                        }
                        let useDuration = CMTime(seconds: useSeconds, preferredTimescale: timescale)
                        try narrationTrack.insertTimeRange(
                            CMTimeRange(start: .zero, duration: useDuration),
                            of: clipAudio,
                            at: cursor
                        )
                        narrationCursor = cursor + useDuration
                    }
                }
            }
            cursor = cursor + sourceRange.duration
        }
        let totalDuration = cursor
        guard totalDuration.seconds > 0.1 else {
            throw StudioError("Nothing to export — every segment was empty.")
        }
        if narrationCursor < totalDuration {
            narrationTrack.insertEmptyTimeRange(CMTimeRange(start: narrationCursor, end: totalDuration))
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw StudioError("Could not create the export session.")
        }
        if let framing {
            export.videoComposition = try await framedVideoComposition(
                sourceVideo: sourceVideo,
                compositionVideoTrack: videoTrack,
                duration: totalDuration,
                framing: framing
            )
        }
        try? FileManager.default.removeItem(at: outputURL)
        export.outputURL = outputURL
        export.outputFileType = .mp4

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously {
                continuation.resume()
            }
        }
        if export.status != .completed {
            throw export.error ?? StudioError("Video export failed.")
        }
    }

    // MARK: 16:9 branded frame compositing

    /// Build the AVVideoComposition that places the portrait recording inside the
    /// branded canvas using the custom Core Image `FrameCompositor` (reliable
    /// headless, unlike the CoreAnimation animation tool).
    private static func framedVideoComposition(
        sourceVideo: AVAssetTrack,
        compositionVideoTrack: AVMutableCompositionTrack,
        duration: CMTime,
        framing: VideoFraming
    ) async throws -> AVMutableVideoComposition {
        let preferred = try await sourceVideo.load(.preferredTransform)
        guard let maskCG = framing.roundedScreenMask() else {
            throw StudioError("Could not build the device screen mask.")
        }
        let mask = CIImage(cgImage: maskCG)

        // One instruction per background segment. Instructions must tile the
        // timeline contiguously: segment i ends exactly where i+1 begins (built
        // from the same CMTime value), and the last one ends at the video's end.
        let timescale: CMTimeScale = 600
        let segments = framing.segments.filter { $0.start < duration.seconds }
        var instructions: [FrameCompositionInstruction] = []
        for (index, segment) in segments.enumerated() {
            let start = index == 0 ? CMTime.zero : CMTime(seconds: segment.start, preferredTimescale: timescale)
            let end = index + 1 < segments.count
                ? CMTime(seconds: segments[index + 1].start, preferredTimescale: timescale)
                : duration
            guard end > start else { continue }
            var cropFraction = 0.0
            var maskFraction = 0.0
            var overlay: CIImage?
            switch framing.statusBar {
            case .off:
                break
            case .crop(let fraction):
                cropFraction = fraction
            case .clean(let fraction, let overlayImage):
                maskFraction = fraction
                overlay = CIImage(cgImage: overlayImage)
            }
            instructions.append(FrameCompositionInstruction(
                sourceTrackID: compositionVideoTrack.trackID,
                timeRange: CMTimeRange(start: start, end: end),
                background: CIImage(cgImage: segment.background),
                mask: mask,
                screenRectCI: framing.screenRectCI,
                canvas: framing.canvas,
                preferred: preferred,
                cropTopFraction: cropFraction,
                maskBandFraction: maskFraction,
                barOverlay: overlay
            ))
        }
        guard !instructions.isEmpty else {
            throw StudioError("The branded frame has no background segments.")
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = FrameCompositor.self
        videoComposition.renderSize = framing.canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        return videoComposition
    }

    // MARK: SRT sidecar

    /// One or more cues per step: the script is split into sentences and
    /// distributed proportionally across the step's narration window.
    static func srt(steps: [WalkthroughStep], narrationDurations: [UUID: Double]) -> String {
        var cues: [(start: Double, end: Double, text: String)] = []

        for step in steps where !step.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let script = step.script.trimmingCharacters(in: .whitespacesAndNewlines)
            let windowEnd: Double
            if let audio = narrationDurations[step.id] {
                windowEnd = min(step.startTime + audio, step.endTime)
            } else {
                windowEnd = step.endTime
            }
            let window = max(1.0, windowEnd - step.startTime)

            let sentences = splitSentences(script)
            let totalChars = sentences.reduce(0) { $0 + $1.count }
            var cursor = step.startTime
            for sentence in sentences {
                let share = totalChars > 0 ? Double(sentence.count) / Double(totalChars) : 1.0
                let cueDuration = max(0.8, window * share)
                cues.append((cursor, min(cursor + cueDuration, windowEnd), sentence))
                cursor += cueDuration
                if cursor >= windowEnd { break }
            }
        }

        var out = ""
        for (index, cue) in cues.enumerated() {
            out += "\(index + 1)\n"
            out += "\(timestamp(cue.start)) --> \(timestamp(cue.end))\n"
            out += wrap(cue.text, width: 42) + "\n\n"
        }
        return out
    }

    /// Sentence split on `. ! ?`, shared with `TranscriptBuilder` (M4) so captions and
    /// transcript segments are cut the same way. Internal, not private, for that reason.
    static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if char == "." || char == "!" || char == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sentences.append(trimmed) }
        return sentences
    }

    private static func timestamp(_ seconds: Double) -> String {
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d,%03d", total / 3600, (total % 3600) / 60, total % 60, ms)
    }

    private static func wrap(_ text: String, width: Int) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if line.isEmpty {
                line = String(word)
            } else if line.count + word.count + 1 <= width {
                line += " " + word
            } else {
                lines.append(line)
                line = String(word)
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}
