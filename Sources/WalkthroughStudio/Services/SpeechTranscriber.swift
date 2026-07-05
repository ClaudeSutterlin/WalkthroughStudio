import Foundation
import AVFoundation
import Speech

/// On-device transcription via Apple's Speech framework.
///
/// File-based recognition is only reliable for ~1 minute at a time, so the
/// recording's audio is exported in ~55s chunks and each chunk is recognized
/// separately, with timestamps offset back into recording time.
///
/// This sits behind a tiny interface so WhisperKit can be swapped in later
/// (the spec's preferred engine) without touching the rest of the app.
protocol Transcribing {
    func transcribe(
        videoURL: URL,
        localeID: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [TranscriptSegment]
}

struct SpeechTranscriber: Transcribing {

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func transcribe(
        videoURL: URL,
        localeID: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> [TranscriptSegment] {
        guard await Self.requestAuthorization() else {
            throw StudioError("Speech recognition permission was denied. Enable it in System Settings → Privacy & Security → Speech Recognition, or type narration per step instead.")
        }

        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw StudioError("The recording has no audio track. Type a script per step in the Narration tab instead.")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("walkthrough-transcribe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chunkLength = 55.0
        var segments: [TranscriptSegment] = []
        var chunkStart = 0.0
        var chunkIndex = 0

        while chunkStart < duration - 0.2 {
            let chunkEnd = min(chunkStart + chunkLength, duration)
            let chunkURL = tempDir.appendingPathComponent("chunk-\(chunkIndex).m4a")
            try await exportAudioChunk(asset: asset, start: chunkStart, end: chunkEnd, to: chunkURL)

            let chunkSegments = try await recognizeFile(url: chunkURL, localeID: localeID)
            let offset = chunkStart
            segments += chunkSegments.map {
                TranscriptSegment(start: $0.start + offset, end: $0.end + offset, text: $0.text)
            }

            progress(chunkEnd / duration, "Transcribed \(Int(chunkEnd))s of \(Int(duration))s")
            chunkStart = chunkEnd
            chunkIndex += 1
        }
        return segments
    }

    private func exportAudioChunk(asset: AVAsset, start: Double, end: Double, to url: URL) async throws {
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw StudioError("Could not create an audio export session.")
        }
        export.outputURL = url
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        if export.status != .completed {
            throw export.error ?? StudioError("Audio chunk export failed.")
        }
    }

    private func recognizeFile(url: URL, localeID: String) async throws -> [TranscriptSegment] {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              recognizer.isAvailable else {
            throw StudioError("Speech recognition is unavailable for locale \(localeID).")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                if finished { return }
                if let error {
                    finished = true
                    // "No speech detected" in a silent chunk is not an error for us.
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain" || ns.code == 1110 || ns.code == 203 {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                finished = true
                continuation.resume(returning: Self.group(result.bestTranscription.segments))
            }
        }
    }

    /// Group word-level segments into phrase-level cues (split on pauses).
    private static func group(_ words: [SFTranscriptionSegment]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var currentText: [String] = []
        var currentStart = 0.0
        var currentEnd = 0.0

        func flush() {
            let text = currentText.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                out.append(TranscriptSegment(start: currentStart, end: currentEnd, text: text))
            }
            currentText = []
        }

        for word in words {
            let start = word.timestamp
            let end = word.timestamp + word.duration
            if currentText.isEmpty {
                currentStart = start
            } else if start - currentEnd > 0.8 || currentText.count >= 16 {
                flush()
                currentStart = start
            }
            currentText.append(word.substring)
            currentEnd = end
        }
        flush()
        return out
    }
}
