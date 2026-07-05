import Foundation
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Project briefing: a document whose text guides every content-generating
/// prompt (step copy, slide headlines, narration scripts).
///
/// Supported: PDF (PDFKit), plain text/Markdown (direct read), and the formats
/// NSAttributedString imports natively — RTF, RTFD, HTML, and Word (.docx/.doc).
enum Briefing {
    /// Generous cap so a long briefing can't blow up the prompt.
    static let maxCharacters = 20_000

    static let plainTextExtensions = ["txt", "md", "markdown", "text"]
    static let richTextExtensions = ["rtf", "rtfd", "html", "htm", "docx", "doc"]
    static var allExtensions: [String] { ["pdf"] + plainTextExtensions + richTextExtensions }

    /// For NSOpenPanel / drop-zone filtering.
    static var contentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .text, .rtf, .rtfd, .html]
        for ext in ["md", "markdown", "docx", "doc"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    static func extractText(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        let raw: String
        switch ext {
        case "pdf":
            guard let document = PDFDocument(url: url) else {
                throw StudioError("Couldn't open \(url.lastPathComponent) as a PDF.")
            }
            raw = document.string ?? ""
        case let e where plainTextExtensions.contains(e):
            raw = try readPlainText(url)
        case let e where richTextExtensions.contains(e):
            raw = try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        default:
            // Unknown extension: try rich import first (it sniffs the format),
            // then plain text.
            if let rich = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
                raw = rich.string
            } else {
                raw = try readPlainText(url)
            }
        }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw StudioError("No text found in \(url.lastPathComponent)\(ext == "pdf" ? " — if it's a scanned PDF, export it with text first." : ".")")
        }
        if text.count > maxCharacters {
            return String(text.prefix(maxCharacters)) + "\n[…briefing truncated at \(maxCharacters) characters]"
        }
        return text
    }

    private static func readPlainText(_ url: URL) throws -> String {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            return utf8
        }
        var encoding = String.Encoding.utf8
        do {
            return try String(contentsOf: url, usedEncoding: &encoding)
        } catch {
            throw StudioError("Couldn't read \(url.lastPathComponent) as text.")
        }
    }
}
