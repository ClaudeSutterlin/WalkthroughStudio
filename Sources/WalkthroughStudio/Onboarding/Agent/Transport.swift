// Transport.swift — "Onboard to a Codebase", milestone M6 (LLM runtime).
//
// The one seam between the tool loop and the network (D9). Everything above it —
// request building, SSE accumulation, retries, the loop itself — runs byte for byte
// the same in the headless selftest as against the real API, because the selftest
// swaps in `FixtureTransport` and changes nothing else.
//
// The protocol deliberately carries HTTP, not meaning: a status, headers and bytes.
// A 429 is not an error here, it is a reply with a status; deciding what a status
// means belongs to RateLimiter, and deciding what the bytes mean belongs to
// MessagesAPI. That split is what makes the backoff probe possible without a
// server: a recorded 429 is just another recording.

import Foundation

/// One HTTP call, already built.
struct TransportRequest: Sendable {
    var endpoint: URL
    /// Includes `x-api-key`. Never logged, never written to a file: `BuildLog`
    /// redacts, and the transcript writes `headersRedacted` instead.
    var headers: [String: String]
    var body: Data
    var stream: Bool
    var timeout: TimeInterval
    /// Fixture key (D9): the prompt's name and which turn of it this is. Not sent.
    var promptName: String
    var turn: Int
    /// SHA-256 of `body`, so a fixture can warn when the prompt has moved on.
    var bodyHash: String

    init(
        endpoint: URL,
        headers: [String: String],
        body: Data,
        stream: Bool,
        timeout: TimeInterval,
        promptName: String,
        turn: Int,
        bodyHash: String
    ) {
        self.endpoint = endpoint
        self.headers = headers
        self.body = body
        self.stream = stream
        self.timeout = timeout
        self.promptName = promptName
        self.turn = turn
        self.bodyHash = bodyHash
    }
}

struct TransportReply: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// A streaming reply: the status and headers arrive first, then the bytes.
///
/// The status comes before the bytes on purpose. A failed streaming request
/// answers with an ordinary JSON error body, so the caller checks the status,
/// drains the chunks into one `Data` and parses an error — the same path as a
/// non-streaming failure, with no duplicate error handling.
struct TransportStream: Sendable {
    var status: Int
    var headers: [String: String]
    var chunks: AsyncThrowingStream<Data, Error>
}

protocol MessagesTransport: Sendable {
    func send(_ request: TransportRequest) async throws -> TransportReply
    func stream(_ request: TransportRequest) async throws -> TransportStream
}

// MARK: - The real one

/// `URLSession` over raw HTTP.
///
/// Stateless, and it holds no session of its own: `URLSession.shared` already pools
/// connections across the fleet's parallel units, and a stored session would make
/// this struct's `Sendable` conformance depend on Foundation's. Injection happens
/// one level up — the protocol is the seam, so a test swaps the whole transport
/// rather than a session inside it.
struct URLSessionTransport: MessagesTransport {
    private var session: URLSession { .shared }

    init() {}

    func send(_ request: TransportRequest) async throws -> TransportReply {
        let urlRequest = URLSessionTransport.urlRequest(from: request)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw MessagesAPIError(status: 0, type: "no_response",
                                       message: "No HTTP response.", isTransport: true)
            }
            return TransportReply(status: http.statusCode,
                                  headers: URLSessionTransport.headers(http),
                                  body: data)
        } catch let error as MessagesAPIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw URLSessionTransport.transportError(error)
        }
    }

    func stream(_ request: TransportRequest) async throws -> TransportStream {
        let urlRequest = URLSessionTransport.urlRequest(from: request)
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw URLSessionTransport.transportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MessagesAPIError(status: 0, type: "no_response",
                                   message: "No HTTP response.", isTransport: true)
        }

        // `AsyncBytes` yields one byte at a time, so the bytes are re-batched here:
        // a chunk per SSE record boundary, or every 16 KB if a record is enormous.
        // Cancelling the consumer cancels this task, which cancels the underlying
        // URLSession task — that is how Pause stops an in-flight turn at once.
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var buffer = Data()
                var recentNewlines = 0
                do {
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == 0x0A {
                            recentNewlines += 1
                            if recentNewlines >= 2 {
                                continuation.yield(buffer)
                                buffer.removeAll(keepingCapacity: true)
                                recentNewlines = 0
                            }
                        } else if byte != 0x0D {
                            recentNewlines = 0
                        }
                        if buffer.count >= 16_384 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                            recentNewlines = 0
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: URLSessionTransport.transportError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return TransportStream(status: http.statusCode,
                               headers: URLSessionTransport.headers(http),
                               chunks: chunks)
    }

    /// `timeoutInterval` is an *idle* timeout, not a deadline: URLSession restarts
    /// it whenever more data arrives. That is exactly what a stream needs
    /// (ARCHITECTURE 4.2: 120 s between events, 300 s for a non-streaming reply),
    /// so there is no watchdog here. A long streaming turn is fine; a stalled one
    /// fails as a transport error and the retry ladder picks it up.
    static func urlRequest(from request: TransportRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        return urlRequest
    }

    static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String {
                out[key] = String(describing: value)
            }
        }
        return out
    }

    /// Every URLError is a transport failure: worth retrying, and never the
    /// server's considered answer.
    static func transportError(_ error: Error) -> MessagesAPIError {
        let urlError = error as? URLError
        return MessagesAPIError(
            status: 0,
            type: urlError.map { "urlerror_\($0.code.rawValue)" } ?? "transport_error",
            message: error.localizedDescription,
            isTransport: true)
    }
}

// MARK: - The fixture one

/// Replays recorded replies, keyed by prompt name and turn (D9).
///
/// Two jobs in one type. In the selftest it replays recordings written by hand or
/// by a recording run, which is what lets every probe above this seam run with no
/// network and no key. In a probe it is also the scripted server: a recording can
/// carry any status and any headers, so "429 with retry-after: 2, then 200" is a
/// two-line fixture rather than a mock framework.
actor FixtureTransport: MessagesTransport {

    /// One recorded reply.
    struct Recording: Codable, Equatable, Sendable {
        var promptName: String
        var turn: Int
        /// SHA-256 of the request body this was recorded against. A mismatch warns
        /// rather than fails: editing a prompt should not break the selftest until
        /// someone re-records, and a stale fixture that still exercises the code
        /// path is worth more than a red probe nobody can fix offline.
        var requestHash: String = ""
        var status: Int = 200
        var headers: [String: String] = [:]
        /// A non-streaming reply body.
        var body: JSONValue? = nil
        /// A streaming reply, as the raw SSE text the server would have sent.
        var sse: String? = nil
        /// Chunk size for replaying `sse`. 0 means "one chunk", which is the
        /// easiest case and therefore the one that hides framing bugs; the probe
        /// sweeps this value.
        var chunkBytes: Int = 0

        init(promptName: String, turn: Int, status: Int = 200) {
            self.promptName = promptName
            self.turn = turn
            self.status = status
        }

        private enum CodingKeys: String, CodingKey {
            case promptName, turn, requestHash, status, headers, body, sse, chunkBytes
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            promptName = try c.decodeIfPresent(String.self, forKey: .promptName) ?? ""
            turn = try c.decodeIfPresent(Int.self, forKey: .turn) ?? 0
            requestHash = try c.decodeIfPresent(String.self, forKey: .requestHash) ?? ""
            status = try c.decodeIfPresent(Int.self, forKey: .status) ?? 200
            headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
            body = try c.decodeIfPresent(JSONValue.self, forKey: .body)
            sse = try c.decodeIfPresent(String.self, forKey: .sse)
            chunkBytes = try c.decodeIfPresent(Int.self, forKey: .chunkBytes) ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(promptName, forKey: .promptName)
            try c.encode(turn, forKey: .turn)
            try c.encode(requestHash, forKey: .requestHash)
            try c.encode(status, forKey: .status)
            try c.encode(headers, forKey: .headers)
            try c.encodeIfPresent(body, forKey: .body)
            try c.encodeIfPresent(sse, forKey: .sse)
            try c.encode(chunkBytes, forKey: .chunkBytes)
        }

        var bodyData: Data {
            guard let body, let data = try? MessagesRequest.canonicalJSON(body) else { return Data() }
            return data
        }
    }

    /// Recordings per (prompt, turn), in the order they should be served.
    ///
    /// A list rather than a single value, because a *retry* is the same turn. The
    /// cursor advances per call and sticks on the last entry once exhausted, so
    /// `[429 with retry-after, 200]` is a two-line fixture for the backoff path
    /// while an ordinary one-entry fixture replays identically however many times
    /// the ladder repeats it.
    private var recordings: [String: [Recording]] = [:]
    private var cursor: [String: Int] = [:]
    /// Requests seen, in order, so a probe can assert what the loop actually sent.
    private(set) var sent: [TransportRequest] = []
    private(set) var warnings: [String] = []

    init(recordings: [Recording] = []) {
        for recording in recordings {
            self.recordings[FixtureTransport.key(recording.promptName, recording.turn), default: []]
                .append(recording)
        }
    }

    /// Load `<directory>/<promptName>/<turn>.json`.
    init(directory: URL) throws {
        let fileManager = FileManager.default
        let decoder = OnboardingJSON.decoder()
        let prompts = (try? fileManager.contentsOfDirectory(at: directory,
                                                            includingPropertiesForKeys: nil)) ?? []
        for promptDirectory in prompts.sorted(by: { $0.path < $1.path }) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: promptDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let files = (try? fileManager.contentsOfDirectory(at: promptDirectory,
                                                              includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "json" {
                let data = try Data(contentsOf: file)
                // A file holds one recording, or an array of them for a turn whose
                // first reply should fail (a recorded 429, a recorded 500).
                var loaded: [Recording]
                if let one = try? decoder.decode(Recording.self, from: data) {
                    loaded = [one]
                } else {
                    loaded = try decoder.decode([Recording].self, from: data)
                }
                let turn = Int(file.deletingPathExtension().lastPathComponent)
                for index in loaded.indices {
                    if loaded[index].promptName.isEmpty {
                        loaded[index].promptName = promptDirectory.lastPathComponent
                    }
                    if let turn { loaded[index].turn = turn }
                    recordings[FixtureTransport.key(loaded[index].promptName, loaded[index].turn),
                               default: []].append(loaded[index])
                }
            }
        }
    }

    static func key(_ promptName: String, _ turn: Int) -> String { "\(promptName)#\(turn)" }

    func add(_ recording: Recording) {
        recordings[FixtureTransport.key(recording.promptName, recording.turn), default: []]
            .append(recording)
    }

    func send(_ request: TransportRequest) async throws -> TransportReply {
        let recording = try record(for: request)
        return TransportReply(status: recording.status,
                              headers: recording.headers,
                              body: recording.bodyData)
    }

    func stream(_ request: TransportRequest) async throws -> TransportStream {
        let recording = try record(for: request)
        let payload = recording.sse.map { Data($0.utf8) } ?? recording.bodyData
        let size = recording.chunkBytes
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            if size <= 0 {
                if !payload.isEmpty { continuation.yield(payload) }
            } else {
                var start = payload.startIndex
                while start < payload.endIndex {
                    let end = payload.index(start, offsetBy: size, limitedBy: payload.endIndex)
                        ?? payload.endIndex
                    continuation.yield(payload[start..<end])
                    start = end
                }
            }
            continuation.finish()
        }
        return TransportStream(status: recording.status, headers: recording.headers, chunks: chunks)
    }

    private func record(for request: TransportRequest) throws -> Recording {
        sent.append(request)
        let key = FixtureTransport.key(request.promptName, request.turn)
        guard let list = recordings[key], !list.isEmpty else {
            throw StudioError("No fixture for prompt \"\(request.promptName)\" turn \(request.turn). "
                              + "Record one, or run with a real key.")
        }
        let index = min(cursor[key] ?? 0, list.count - 1)
        cursor[key] = index + 1
        let recording = list[index]
        if !recording.requestHash.isEmpty, recording.requestHash != request.bodyHash {
            let warning = "fixture \(request.promptName)#\(request.turn) was recorded against a "
                + "different request (prompt edited since); replaying it anyway"
            warnings.append(warning)
            BuildLog.warn(warning)
        }
        return recording
    }
}

// MARK: - The recording one

/// Wraps a transport and writes what came back, so a builder with a real key can
/// refresh the selftest's fixtures in one run (`SettingsKeys.onboardingRecordFixtures`).
///
/// It records the reply, never the request headers: the key is in those headers,
/// and a fixture directory is the kind of thing that ends up in a repository.
struct RecordingTransport: MessagesTransport {
    var inner: MessagesTransport
    var directory: URL

    init(inner: MessagesTransport, directory: URL) {
        self.inner = inner
        self.directory = directory
    }

    func send(_ request: TransportRequest) async throws -> TransportReply {
        let reply = try await inner.send(request)
        var recording = FixtureTransport.Recording(promptName: request.promptName,
                                                   turn: request.turn,
                                                   status: reply.status)
        recording.requestHash = request.bodyHash
        recording.headers = RecordingTransport.keptHeaders(reply.headers)
        recording.body = try? JSONDecoder().decode(JSONValue.self, from: reply.body)
        write(recording)
        return reply
    }

    func stream(_ request: TransportRequest) async throws -> TransportStream {
        let upstream = try await inner.stream(request)
        let directory = self.directory
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var collected = Data()
                do {
                    for try await chunk in upstream.chunks {
                        collected.append(chunk)
                        continuation.yield(chunk)
                    }
                    var recording = FixtureTransport.Recording(promptName: request.promptName,
                                                               turn: request.turn,
                                                               status: upstream.status)
                    recording.requestHash = request.bodyHash
                    recording.headers = RecordingTransport.keptHeaders(upstream.headers)
                    recording.sse = String(data: collected, encoding: .utf8)
                    RecordingTransport.write(recording, to: directory)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return TransportStream(status: upstream.status, headers: upstream.headers, chunks: chunks)
    }

    /// Only the headers a replay needs. Nothing that identifies the account.
    static func keptHeaders(_ headers: [String: String]) -> [String: String] {
        let wanted = ["retry-after", "content-type", "anthropic-ratelimit-requests-remaining"]
        var out: [String: String] = [:]
        for (key, value) in headers where wanted.contains(key.lowercased()) {
            out[key.lowercased()] = value
        }
        return out
    }

    private func write(_ recording: FixtureTransport.Recording) {
        RecordingTransport.write(recording, to: directory)
    }

    static func write(_ recording: FixtureTransport.Recording, to directory: URL) {
        let promptDirectory = directory.appendingPathComponent(recording.promptName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: promptDirectory, withIntermediateDirectories: true)
            let data = try OnboardingJSON.encoder().encode(recording)
            try data.write(to: promptDirectory.appendingPathComponent("\(recording.turn).json"),
                           options: .atomic)
        } catch {
            BuildLog.warn("could not record fixture \(recording.promptName)#\(recording.turn): "
                          + error.localizedDescription)
        }
    }
}
