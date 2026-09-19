// SelfTestSupport — Onboard to a Codebase, milestone M1.
//
// Internal helpers shared by the onboarding selftest probes (SelfTestOnboarding.swift
// and the probes other milestones add in `extension SelfTest`): pixel sampling,
// a synthetic WAV for narration stand-ins, and a small Process wrapper for git.
//
// TODO(M2+): the five NSHostingView offscreen-snapshot harnesses in SelfTest.swift
// (uiProbe, newProjectSheetProbe, setupSheetProbe, exportSheetProbe,
// processingViewProbe) should be consolidated into one helper here once the
// onboarding sheet probes need the same pattern. Left untouched in M1 on purpose.
import Foundation
import AppKit
import CoreGraphics

enum SelfTestSupport {

    // MARK: Pixels

    /// Sample one pixel of `image` at TOP-LEFT coordinates (x, y), returning
    /// 0...255 RGB.
    ///
    /// Convention (CLAUDE.md landmine 6): the image is drawn into an RGBA
    /// CGBitmapContext covering the whole image. CG *draws* with a bottom-left
    /// origin, but the context's backing memory is TOP-ROW-FIRST — row 0 in
    /// memory is the top row of the image as displayed. So the byte offset for
    /// a top-left (x, y) sample is `y * bytesPerRow + x * 4`, with no flip.
    /// This matches `NSBitmapImageRep.colorAt(x:y:)`, which is also top-left.
    static func pixel(in image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return (0, 0, 0) }
        let cx = min(max(0, x), width - 1)
        let cy = min(max(0, y), height - 1)

        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue // R,G,B,A bytes
                  ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return (0, 0, 0) }
        let offset = cy * bytesPerRow + cx * 4
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }

    /// Channel spread (max - min) of an RGB sample: > ~50 means "saturated".
    static func spread(_ rgb: (r: Int, g: Int, b: Int)) -> Int {
        max(rgb.r, rgb.g, rgb.b) - min(rgb.r, rgb.g, rgb.b)
    }

    // MARK: Audio

    /// A 440 Hz mono 16-bit WAV of `seconds` length — the narration stand-in
    /// every probe uses instead of ElevenLabs. Delegates to the walkthrough
    /// selftest's generator so the two selftests share one implementation.
    static func sineWAV(seconds: Double) -> Data {
        SelfTest.sineWAV(duration: seconds)
    }

    // MARK: Processes

    struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Lock-protected byte buffer filled from a background drain (a class so
    /// the @Sendable dispatch block does not mutate a captured var).
    private final class StreamBuffer {
        private let lock = NSLock()
        private var data = Data()
        func set(_ newData: Data) {
            lock.lock()
            data = newData
            lock.unlock()
        }
        var value: Data {
            lock.lock()
            let copy = data
            lock.unlock()
            return copy
        }
    }

    /// Run `executable` with `args` in `dir`, capturing both streams. Does not
    /// throw on a non-zero exit; callers decide what a failure means. Both
    /// pipes are drained on background queues while the caller waits, so a
    /// child that writes more than the pipe buffer to stderr before closing
    /// stdout cannot deadlock the selftest (mirrors `GitRunner.Child`). A child
    /// still running after `timeout` seconds is killed and a `StudioError`
    /// is thrown.
    static func runProcess(
        _ executable: String, _ args: [String], in dir: URL?, timeout: TimeInterval = 120
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let dir { process.currentDirectoryURL = dir }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"   // never block on a credential prompt
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            throw StudioError("could not launch \(executable): \(error.localizedDescription)")
        }

        let outBuffer = StreamBuffer()
        let errBuffer = StreamBuffer()
        let drained = DispatchGroup()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            outBuffer.set(outHandle.readDataToEndOfFile())
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            errBuffer.set(errHandle.readDataToEndOfFile())
            drained.leave()
        }

        let completed = finished.wait(timeout: .now() + timeout) == .success
        if !completed, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 5)
        }
        // Bounded: a grandchild that inherited the pipes may outlive a killed
        // child for a moment; never hang on it.
        _ = drained.wait(timeout: .now() + 30)
        guard completed else {
            throw StudioError("\(executable) \(args.joined(separator: " ")) timed out after \(Int(timeout))s")
        }

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outBuffer.value, as: UTF8.self),
            stderr: String(decoding: errBuffer.value, as: UTF8.self)
        )
    }

    /// Run `/usr/bin/git <args>` in `dir` and return trimmed stdout. Throws a
    /// `StudioError` carrying stderr when git exits non-zero.
    static func runGit(_ args: [String], in dir: URL) throws -> String {
        let result = try runProcess("/usr/bin/git", args, in: dir)
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw StudioError("git \(args.joined(separator: " ")) exited \(result.status): \(detail.isEmpty ? result.stdout : detail)")
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
