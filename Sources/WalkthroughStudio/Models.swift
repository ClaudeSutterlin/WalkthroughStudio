import Foundation
import SwiftUI

// MARK: - Core model (the "spine": one ordered list of steps)

struct WalkthroughStep: Identifiable, Codable, Hashable {
    var id: UUID = UUID()

    // Timing (seconds into the recording)
    var startTime: Double
    var endTime: Double
    /// Timestamp of the chosen "settled" frame for this step.
    var frameTime: Double

    // Web-app tutorialSteps contract (Section 7 of the spec)
    var slug: String = ""        // stable slug, e.g. 'profile'
    var area: String = ""        // tab/area label, e.g. 'Content → Me'
    var title: String = ""       // short, warm
    var body: String = ""        // 1–2 sentences, plain language
    var alt: String = ""         // accessibility description of the screenshot

    // Narration
    var transcript: String = ""  // raw transcript for this step's time range
    var script: String = ""      // polished narration (what gets synthesized)

    // Branded App Store slide
    var headline: String = ""    // may contain <br> and <span class="accent">
    var subheadline: String = ""

    var includeInTutorial: Bool = true
    var includeInBranded: Bool = true

    var duration: Double { max(0, endTime - startTime) }

    var displayName: String {
        if !title.isEmpty { return title }
        if !slug.isEmpty { return slug }
        return "Step"
    }

    var resolvedSlug: String {
        if !slug.isEmpty { return slug }
        let base = title.isEmpty ? "step" : title
        let allowed = base.lowercased().map { c -> Character in
            (c.isLetter || c.isNumber) ? c : "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "step" : collapsed
    }
}

struct TranscriptSegment: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var text: String
}

/// Serialized project document (.walkstudio.json)
struct WalkthroughProject: Codable {
    var version: Int = 1
    var videoPath: String
    var steps: [WalkthroughStep]
    var transcript: [TranscriptSegment]
    /// PDF briefing whose text guides all generated copy (optional so older
    /// project files keep decoding).
    var briefingPath: String?
    /// Custom frame design tokens (nil = LiveAgain defaults).
    var theme: BrandTheme?
    /// What the recording was captured on (nil = re-detect on open).
    var deviceKind: DeviceKind?
}

// MARK: - Errors

struct StudioError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Brand system (Section 5 — canonical tokens)

enum Brand {
    static let coral = Color(hex: 0xDA4F45)
    static let coralHover = Color(hex: 0xC4443B)
    static let coralGlow = Color(hex: 0xFF6B5E)
    static let peach = Color(hex: 0xFFB088)
    static let golden = Color(hex: 0xF5A623)
    static let cream = Color(hex: 0xFFFBF5)
    static let warm = Color(hex: 0xFFF7EE)
    static let soft = Color(hex: 0xFFF3E6)
    static let charcoal = Color(hex: 0x1A1612)
    static let muted = Color(hex: 0x5C5549)
    static let faded = Color(hex: 0x9B9286)

    /// Voice/tone reference passed to the LLM (from the shipped tutorialSteps copy).
    static let voiceReference = """
    Reference copy (the register to match — warm, second person, plain, encouraging, no jargon):
    "Make it yours" (Content → Me): "Open the Content tab and tell LiveAgain a little about you — \
    your name, how you talk, and what matters to you. This is what makes every suggestion sound \
    like you, not a generic voice."
    """
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

// MARK: - Device kind (what the recording was captured on)

enum DeviceKind: String, Codable, CaseIterable, Identifiable {
    case iphone
    case ipad
    case computer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iphone: return "iPhone"
        case .ipad: return "iPad"
        case .computer: return "Computer"
        }
    }

    var symbolName: String {
        switch self {
        case .iphone: return "iphone"
        case .ipad: return "ipad"
        case .computer: return "desktopcomputer"
        }
    }

    /// App Store Connect only takes iPhone/iPad screenshots.
    var supportsAppStoreExport: Bool { self != .computer }

    /// Height of the status bar as a fraction of the frame height.
    /// iPhone ≈ 59pt/852pt; iPad ≈ 24pt/1032pt (short edge); Macs have a menu
    /// bar we leave alone.
    var statusBarFraction: Double {
        switch self {
        case .iphone: return 0.0693
        case .ipad: return 0.024
        case .computer: return 0
        }
    }

    /// Classify a recording by its oriented pixel dimensions.
    /// Portrait & very tall → iPhone; ~4:3 either way → iPad; wide → computer.
    static func detect(width: Int, height: Int) -> DeviceKind {
        guard width > 0, height > 0 else { return .iphone }
        let ratio = Double(max(width, height)) / Double(min(width, height))
        if height >= width {
            return ratio >= 1.6 ? .iphone : .ipad
        }
        return ratio >= 1.5 ? .computer : .ipad
    }
}

// MARK: - App Store export sizes (Section 4C / generate.mjs)

struct ExportSize: Identifiable, Hashable {
    var id: String { dir }
    let width: Int
    let height: Int
    let dir: String

    /// Kept for compatibility: the iPhone sizes.
    static let appStore: [ExportSize] = appStore(for: .iphone)

    static func appStore(for device: DeviceKind) -> [ExportSize] {
        switch device {
        case .iphone:
            return [
                ExportSize(width: 1290, height: 2796, dir: "6.9-inch"), // iPhone 6.9" (15/16 Pro Max)
                ExportSize(width: 1284, height: 2778, dir: "6.5-inch"), // iPhone 6.5"
            ]
        case .ipad:
            return [
                ExportSize(width: 2064, height: 2752, dir: "13-inch"),   // iPad Pro 13"
                ExportSize(width: 2048, height: 2732, dir: "12.9-inch"), // iPad Pro 12.9"
            ]
        case .computer:
            return []
        }
    }
}

// MARK: - Settings keys

enum SettingsKeys {
    static let anthropicModel = "anthropicModel"           // default claude-sonnet-5
    static let elevenVoiceID = "elevenVoiceID"             // default: Rachel (stock narrator)
    static let elevenModelID = "elevenModelID"             // empty = auto-select recommended
    static let transcribeLocale = "transcribeLocale"       // default en-US
    static let keepOriginalAudio = "keepOriginalAudio"     // default false
    static let lastVideoExportDir = "lastVideoExportDir"   // remembered export folder
}

enum Defaults {
    static let anthropicModel = "claude-sonnet-5"
    static let anthropicModels = ["claude-sonnet-5", "claude-opus-4-8"]
    /// "Rachel" — a prebuilt, neutral/warm narrator voice from the ElevenLabs Voice Library.
    static let elevenVoiceID = "21m00Tcm4TlvDq8ikWAM"
    static let transcribeLocale = "en-US"

    static func string(_ key: String, _ fallback: String) -> String {
        let v = UserDefaults.standard.string(forKey: key) ?? ""
        return v.isEmpty ? fallback : v
    }
    static func bool(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }
}
