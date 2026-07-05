import Foundation
import AVFoundation
import CoreGraphics

/// Frame sampling + perceptual hash (dHash) scene detection.
///
/// Samples frames at a fixed rate, computes a 64-bit difference hash per frame,
/// and marks a step boundary on a rising edge of hamming distance. Within each
/// segment it also picks the most "settled" sample (lowest local motion) as the
/// suggested frame for screenshots.
struct SceneDetector {

    struct DetectedStep {
        var start: Double
        var end: Double
        var settledFrameTime: Double
    }

    var samplesPerSecond: Double = 2.0
    /// Hamming distance (out of 64) above which two consecutive samples count as a scene change.
    var changeThreshold: Int = 11
    /// Mean-luminance delta (0–255) that also counts as a scene change. dHash only
    /// sees gradients (layout); this catches screens that change tone but not structure.
    var luminanceThreshold: Int = 10
    /// Minimum step length in seconds; boundaries closer than this are dropped.
    var minStepDuration: Double = 1.2

    func detect(videoURL: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [DetectedStep] {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        guard duration > 0.5 else { throw StudioError("The recording is too short to segment.") }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)

        let interval = 1.0 / samplesPerSecond
        var sampleTimes: [Double] = []
        var t = 0.05
        while t < duration - 0.05 {
            sampleTimes.append(t)
            t += interval
        }
        guard sampleTimes.count >= 2 else { throw StudioError("Not enough frames to segment.") }

        let cmTimes = sampleTimes.map { CMTime(seconds: $0, preferredTimescale: 600) }

        // (time, hash, meanGray) for every sample we managed to decode
        var samples: [Sample] = []
        samples.reserveCapacity(cmTimes.count)

        var processed = 0
        for await result in generator.images(for: cmTimes) {
            processed += 1
            progress(Double(processed) / Double(cmTimes.count))
            switch result {
            case .success(requestedTime: _, image: let image, actualTime: let actual):
                let features = Self.features(image)
                samples.append(Sample(time: actual.seconds, hash: features.hash, meanRGB: features.meanRGB))
            case .failure:
                continue
            @unknown default:
                continue
            }
        }
        samples.sort { $0.time < $1.time }
        guard samples.count >= 2 else { throw StudioError("Could not decode frames from the recording.") }

        // Rising-edge boundaries
        var boundaries: [Double] = [0]
        var previousWasChange = false
        for i in 1..<samples.count {
            let isChange = Self.differ(
                samples[i - 1], samples[i],
                hashThreshold: changeThreshold, luminanceThreshold: luminanceThreshold
            )
            if isChange, !previousWasChange, let last = boundaries.last,
               samples[i].time - last >= minStepDuration {
                boundaries.append(samples[i].time)
            }
            previousWasChange = isChange
        }

        // Intro/outro seeding. Welcome and closing cards are often static title
        // screens whose cut into (or out of) the app is too subtle to cross the
        // primary threshold, so they get merged into the neighbouring step. Scan
        // for the first frame that diverges from the opening frame (end of the
        // intro) and the point where the closing frame first appears (start of
        // the outro) using a lower threshold, and force a boundary at each.
        let seedHash = max(6, changeThreshold - 5)
        let seedLum = max(6, luminanceThreshold - 4)

        func seed(_ time: Double) {
            guard time > minStepDuration, duration - time > minStepDuration else { return }
            if boundaries.contains(where: { abs($0 - time) < minStepDuration }) { return }
            boundaries.append(time)
        }

        if let first = samples.first {
            for i in 1..<samples.count where Self.differ(first, samples[i], hashThreshold: seedHash, luminanceThreshold: seedLum) {
                seed(samples[i].time)
                break
            }
        }
        if let last = samples.last {
            var i = samples.count - 2
            while i >= 1 {
                if Self.differ(last, samples[i], hashThreshold: seedHash, luminanceThreshold: seedLum) {
                    seed(samples[i + 1].time)
                    break
                }
                i -= 1
            }
        }
        boundaries.sort()

        // Build steps and pick settled frames
        var steps: [DetectedStep] = []
        for (index, start) in boundaries.enumerated() {
            let end = index + 1 < boundaries.count ? boundaries[index + 1] : duration
            let settled = Self.settledTime(in: samples, start: start, end: end)
            steps.append(DetectedStep(start: start, end: end, settledFrameTime: settled))
        }
        return steps
    }

    struct Sample {
        var time: Double
        var hash: UInt64
        var meanRGB: (Int, Int, Int)
    }

    static func colorDelta(_ a: Sample, _ b: Sample) -> Int {
        max(
            abs(a.meanRGB.0 - b.meanRGB.0),
            abs(a.meanRGB.1 - b.meanRGB.1),
            abs(a.meanRGB.2 - b.meanRGB.2)
        )
    }

    static func differ(_ a: Sample, _ b: Sample, hashThreshold: Int, luminanceThreshold: Int) -> Bool {
        hamming(a.hash, b.hash) >= hashThreshold || colorDelta(a, b) >= luminanceThreshold
    }

    /// Within [start, end), pick the sample with the lowest local motion
    /// (sum of differences to its neighbors) — i.e. no mid-transition blur.
    private static func settledTime(in samples: [Sample], start: Double, end: Double) -> Double {
        let lower = start + min(0.4, (end - start) * 0.2) // skip the transition itself
        let indices = samples.indices.filter { samples[$0].time >= lower && samples[$0].time < end }
        guard !indices.isEmpty else { return min(start + 0.5, end) }

        var bestIndex = indices[0]
        var bestScore = Int.max
        for i in indices {
            var score = 0
            if i > 0 {
                score += hamming(samples[i - 1].hash, samples[i].hash)
                score += colorDelta(samples[i - 1], samples[i]) / 4
            }
            if i + 1 < samples.count {
                score += hamming(samples[i].hash, samples[i + 1].hash)
                score += colorDelta(samples[i], samples[i + 1]) / 4
            }
            if score < bestScore {
                bestScore = score
                bestIndex = i
            }
        }
        return samples[bestIndex].time
    }

    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// 9x8 difference hash (on luminance) + per-channel mean color.
    /// The dHash captures layout; the channel means catch hue-only changes
    /// (e.g. two screens with the same structure but different tint).
    static func features(_ image: CGImage) -> (hash: UInt64, meanRGB: (Int, Int, Int)) {
        let width = 9, height = 8
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return (0, (0, 0, 0)) }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func gray(_ row: Int, _ col: Int) -> Int {
            let p = (row * width + col) * bytesPerPixel
            return (Int(pixels[p]) + Int(pixels[p + 1]) + Int(pixels[p + 2])) / 3
        }

        var hash: UInt64 = 0
        var bit = 0
        var sumR = 0, sumG = 0, sumB = 0
        for row in 0..<height {
            for col in 0..<width {
                let p = (row * width + col) * bytesPerPixel
                sumR += Int(pixels[p])
                sumG += Int(pixels[p + 1])
                sumB += Int(pixels[p + 2])
                if col < width - 1, gray(row, col) > gray(row, col + 1) {
                    hash |= (1 << UInt64(bit))
                }
                if col < width - 1 { bit += 1 }
            }
        }
        let count = width * height
        return (hash, (sumR / count, sumG / count, sumB / count))
    }
}
