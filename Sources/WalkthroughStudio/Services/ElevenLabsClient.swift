import Foundation
import AVFoundation

/// ElevenLabs Text-to-Speech client.
///
/// Per the spec, the TTS model is NOT hard-coded: the current recommended
/// high-quality model is discovered from /v1/models at runtime (with a settings
/// override), and the voice id lives in settings so it can be swapped without a
/// code change. Audio is requested as raw PCM and wrapped in a WAV container so
/// AVFoundation can composite it without a re-encode step.
struct ElevenLabsClient {
    var apiKey: String

    private static let base = URL(string: "https://api.elevenlabs.io")!

    struct Voice: Identifiable, Hashable {
        var id: String
        var name: String
        var category: String
    }

    private func request(path: String, query: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw StudioError("No response from ElevenLabs.") }
        guard http.statusCode == 200 else {
            var message = "HTTP \(http.statusCode)"
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let detail = json["detail"] {
                if let detailDict = detail as? [String: Any], let text = detailDict["message"] as? String {
                    message = text
                } else if let text = detail as? String {
                    message = text
                }
            }
            throw StudioError("ElevenLabs API error: \(message)")
        }
    }

    /// Pick the current recommended high-quality TTS model from /v1/models.
    /// Preference order favors the newest high-quality tiers; falls back to the
    /// first TTS-capable model the account can use.
    func recommendedModelID() async throws -> String {
        guard !apiKey.isEmpty else {
            throw StudioError("No ElevenLabs API key. Add one in Settings (it's stored in the Keychain).")
        }
        let (data, response) = try await URLSession.shared.data(for: request(path: "/v1/models"))
        try check(data, response)
        guard let models = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw StudioError("Unexpected ElevenLabs models response.")
        }
        let ttsModels = models.filter { ($0["can_do_text_to_speech"] as? Bool) == true }
        let ids = ttsModels.compactMap { $0["model_id"] as? String }

        let preferred = ["eleven_v3", "eleven_multilingual_v2", "eleven_turbo_v2_5", "eleven_flash_v2_5"]
        for candidate in preferred where ids.contains(candidate) {
            return candidate
        }
        guard let first = ids.first else { throw StudioError("No TTS-capable ElevenLabs model available on this account.") }
        return first
    }

    func voices() async throws -> [Voice] {
        let (data, response) = try await URLSession.shared.data(for: request(path: "/v1/voices"))
        try check(data, response)
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let voices = json["voices"] as? [[String: Any]] else {
            throw StudioError("Unexpected ElevenLabs voices response.")
        }
        return voices.compactMap { voice in
            guard let id = voice["voice_id"] as? String, let name = voice["name"] as? String else { return nil }
            return Voice(id: id, name: name, category: voice["category"] as? String ?? "")
        }
    }

    /// Output formats to try, best quality first. High-rate PCM is gated to
    /// higher ElevenLabs tiers; MP3 is available everywhere and gets decoded to
    /// WAV locally so the rest of the pipeline always sees PCM.
    private static let formatCandidates = [
        "pcm_44100", "pcm_24000", "pcm_22050", "pcm_16000", "mp3_44100_128",
    ]
    /// The format that worked for this account (cached for the app's lifetime).
    private static var workingFormat: String?

    /// Synthesize `text` and return WAV data.
    func synthesizeWAV(text: String, voiceID: String, modelID: String) async throws -> Data {
        var candidates = Self.formatCandidates
        if let known = Self.workingFormat {
            candidates = [known] + candidates.filter { $0 != known }
        }

        var lastError: Error?
        for format in candidates {
            do {
                let data = try await synthesize(text: text, voiceID: voiceID, modelID: modelID, outputFormat: format)
                Self.workingFormat = format
                return try Self.toWAV(data, format: format)
            } catch let error as StudioError where Self.isTierError(error) {
                lastError = error
                continue
            }
        }
        throw lastError ?? StudioError("ElevenLabs synthesis failed for every output format.")
    }

    /// The same synthesis, asking for the character alignment the timing files want.
    ///
    /// `/with-timestamps` returns the audio base64-encoded beside
    /// `alignment.characters` and per-character start and end seconds. When the
    /// endpoint or the format is not available on the account's tier, this returns nil
    /// rather than throwing: a video with estimated caption times is worth far more
    /// than no video, and `timingSource` records which one the package got.
    func synthesizeWithAlignment(text: String, voiceID: String,
                                 modelID: String) async throws -> Alignment? {
        var candidates = Self.formatCandidates
        if let known = Self.workingFormat {
            candidates = [known] + candidates.filter { $0 != known }
        }
        var lastError: Error?
        for format in candidates {
            do {
                var req = request(path: "/v1/text-to-speech/\(voiceID)/with-timestamps",
                                  query: ["output_format": format])
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = try JSONSerialization.data(withJSONObject: [
                    "text": text, "model_id": modelID,
                ])
                let (data, response) = try await URLSession.shared.data(for: req)
                try check(data, response)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let base64 = object["audio_base64"] as? String,
                      let audio = Data(base64Encoded: base64) else {
                    return nil
                }
                Self.workingFormat = format
                let wav = try Self.toWAV(audio, format: format)
                guard let alignment = object["alignment"] as? [String: Any],
                      let characters = alignment["characters"] as? [String],
                      let starts = alignment["character_start_times_seconds"] as? [Double],
                      let ends = alignment["character_end_times_seconds"] as? [Double] else {
                    return Alignment(wav: wav, characters: [], starts: [], ends: [])
                }
                return Alignment(wav: wav, characters: characters, starts: starts, ends: ends)
            } catch let error as StudioError where Self.isTierError(error) {
                lastError = error
                continue
            } catch let error as StudioError where error.message.contains("404") {
                return nil          // the account's plan has no timestamps endpoint
            }
        }
        _ = lastError
        return nil
    }

    struct Alignment {
        var wav: Data
        var characters: [String]
        var starts: [Double]
        var ends: [Double]

        var hasTimings: Bool { !characters.isEmpty && characters.count == starts.count }
    }

    private static func isTierError(_ error: StudioError) -> Bool {
        let message = error.message.lowercased()
        return message.contains("only available on") ||
               message.contains("tier") ||
               message.contains("output format") ||
               message.contains("output_format")
    }

    private func synthesize(text: String, voiceID: String, modelID: String, outputFormat: String) async throws -> Data {
        var req = request(
            path: "/v1/text-to-speech/\(voiceID)",
            query: ["output_format": outputFormat]
        )
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "text": text,
            "model_id": modelID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        try check(data, response)
        return data
    }

    private static func toWAV(_ data: Data, format: String) throws -> Data {
        if format.hasPrefix("pcm_"), let rate = Int(format.dropFirst(4)) {
            return wavData(fromPCM: data, sampleRate: rate, channels: 1, bitsPerSample: 16)
        }
        return try decodeToWAV(data, fileExtension: format.hasPrefix("mp3") ? "mp3" : "dat")
    }

    /// Decode a compressed audio payload (MP3) to a WAV file via AVAudioFile.
    private static func decodeToWAV(_ data: Data, fileExtension: String) throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("el-\(UUID().uuidString).\(fileExtension)")
        let outputURL = tempDir.appendingPathComponent("el-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        try data.write(to: inputURL)

        let input = try AVAudioFile(forReading: inputURL)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: input.processingFormat,
            frameCapacity: AVAudioFrameCount(input.length)
        ) else { throw StudioError("Could not allocate an audio buffer for decoding.") }
        try input.read(into: buffer)

        // Inner scope so the writer deallocates (and flushes) before we read the file back.
        try autoreleasepool {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: input.processingFormat.sampleRate,
                AVNumberOfChannelsKey: input.processingFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let output = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: input.processingFormat.commonFormat,
                interleaved: input.processingFormat.isInterleaved
            )
            try output.write(from: buffer)
        }
        return try Data(contentsOf: outputURL)
    }

    /// Wrap raw little-endian PCM in a minimal WAV container.
    static func wavData(fromPCM pcm: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var header = Data()
        func append(_ string: String) { header.append(Data(string.utf8)) }
        func appendUInt32(_ value: Int) {
            var v = UInt32(value).littleEndian
            header.append(Data(bytes: &v, count: 4))
        }
        func appendUInt16(_ value: Int) {
            var v = UInt16(value).littleEndian
            header.append(Data(bytes: &v, count: 2))
        }

        append("RIFF")
        appendUInt32(36 + pcm.count)
        append("WAVE")
        append("fmt ")
        appendUInt32(16)
        appendUInt16(1) // PCM
        appendUInt16(channels)
        appendUInt32(sampleRate)
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(bitsPerSample)
        append("data")
        appendUInt32(pcm.count)

        return header + pcm
    }
}
