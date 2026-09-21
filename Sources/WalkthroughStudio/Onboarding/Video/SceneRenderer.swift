import Foundation
import CoreGraphics

/// Builds the HTML for one shot of a code walk, from the `scene-*.html` templates.
///
/// Every scene kind is a template with `{{PLACEHOLDER}}` slots, loaded through
/// `TemplateStore` so a user's edited copy wins over the bundled one — the same
/// contract the slide and video frames already use. Nothing here draws: the renderer
/// rasterizes the HTML offscreen (`BrandedRenderer`), which is why a template change
/// takes effect on the next export with no rebuild.
///
/// The two rules worth reading are `codeMetrics` and `window`. A nine-line migration
/// and a forty-line repository both have to read on the same 1080p frame, and the
/// failure that matters is the silent one: clipping a file with `overflow: hidden`
/// shows something that looks complete and is not.
enum SceneRenderer {

    /// Everything one shot needs to become a frame.
    struct Input {
        var shot: VideoScript.Shot
        var scene: VideoScript.Scene
        var sha7: String
        var theme: BrandTheme
        var size: CGSize
        /// The whole file, one string per line, for a `code` shot.
        var sourceLines: [String] = []
        /// The path shown in the panel's title bar.
        var path: String = ""
        /// Pre-rendered SVG for a `diagram` shot.
        var diagramSVG: String = ""
        /// Command and output lines for a `terminal` shot.
        var terminal: [TerminalLine] = []
        /// Header row plus body rows for a `table` shot.
        var tableRows: [[String]] = []
        /// The claim and its evidence, for a `card` shot.
        var claim: String = ""
        var kicker: String = ""
        var evidence: [String] = []
        /// Subtitle for a title or table shot.
        var subtitle: String = ""
        var hedge: String = ""
    }

    struct TerminalLine {
        enum Kind { case command, output, problem }
        var kind: Kind
        var text: String
    }

    // MARK: - Sizing

    /// The share of the frame a code or terminal panel gets, after the heading and the
    /// callout have taken theirs.
    static let panelHeightFraction: CGFloat = 0.62

    /// Type size that fills the space a panel has, within bounds. A fixed size makes a
    /// short file tiny in a sea of charcoal and a long one overflow.
    static func codeMetrics(height: CGFloat, lineCount: Int) -> (codePx: Int, linePx: Int) {
        let available = height * panelHeightFraction
        let raw = available / CGFloat(max(1, lineCount))
        let line = max(height * 0.026, min(height * 0.060, raw))
        return (Int((line * 0.68).rounded()), Int(line.rounded()))
    }

    /// The most lines a panel can hold at the smallest legible size.
    static func capacity(height: CGFloat) -> Int {
        max(6, Int((height * panelHeightFraction) / (height * 0.026)))
    }

    struct Window: Equatable {
        var first: Int
        var last: Int
        var linesAbove: Int
        var linesBelow: Int

        var count: Int { max(0, last - first + 1) }
        var isComplete: Bool { linesAbove == 0 && linesBelow == 0 }
    }

    /// Which source lines the panel shows, and how many it had to leave out.
    ///
    /// The window is centred on the highlight, because the highlight is what the
    /// narrator is talking about; the counts above and below become the `⋮` markers, so
    /// a viewer is told the file continues rather than left to assume it does not.
    static func window(totalLines: Int, want: ClosedRange<Int>,
                       highlight: ClosedRange<Int>?, height: CGFloat) -> Window {
        guard totalLines > 0 else { return Window(first: 1, last: 0, linesAbove: 0, linesBelow: 0) }
        let wantFirst = max(1, want.lowerBound)
        let wantLast = min(totalLines, max(wantFirst, want.upperBound))
        let room = capacity(height: height)
        if wantLast - wantFirst + 1 <= room {
            return Window(first: wantFirst, last: wantLast,
                          linesAbove: wantFirst - 1, linesBelow: totalLines - wantLast)
        }
        var first = wantFirst
        if let highlight {
            let centre = (highlight.lowerBound + highlight.upperBound) / 2
            first = centre - room / 2
        }
        first = max(wantFirst, min(first, wantLast - room + 1))
        let last = first + room - 1
        return Window(first: first, last: last,
                      linesAbove: first - 1, linesBelow: totalLines - last)
    }

    // MARK: - Rendering

    static func html(for input: Input) throws -> String {
        switch input.shot.sceneType {
        case "code": return try codeHTML(input)
        case "diagram": return try diagramHTML(input)
        case "terminal": return try terminalHTML(input)
        case "table": return try tableHTML(input)
        case "title": return try titleHTML(input)
        default: return try cardHTML(input)
        }
    }

    static func template(_ name: String) throws -> String {
        guard let text = TemplateStore.load(name) else {
            throw StudioError("SceneRenderer: the \(name).html template is missing from the app bundle.")
        }
        return text
    }

    /// Fill the slots, then clear any the caller did not supply — an unfilled
    /// `{{PLACEHOLDER}}` rendered into a frame is the kind of thing that ships.
    static func fill(_ template: String, _ values: [String: String], input: Input) -> String {
        var html = template
        var all = values
        all["WIDTH"] = String(Int(input.size.width.rounded()))
        all["HEIGHT"] = String(Int(input.size.height.rounded()))
        all["THEME_CSS"] = input.theme.css()
        all["WORDMARK"] = input.theme.wordmarkHTML
        for (key, value) in all {
            html = html.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return SceneRenderer.clearUnfilled(html)
    }

    static func clearUnfilled(_ html: String) -> String {
        var out = ""
        var rest = Substring(html)
        while let open = rest.range(of: "{{") {
            out += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                out += rest[open.lowerBound...]
                return out
            }
            let name = rest[open.upperBound..<close.lowerBound]
            // Only clear slot-shaped names; anything else is the template's own text.
            let isSlot = !name.isEmpty && name.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
            if !isSlot { out += rest[open.lowerBound..<close.upperBound] }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    // MARK: Code

    static func codeHTML(_ input: Input) throws -> String {
        let highlight = SceneRenderer.highlightRange(input)
        let wanted = SceneRenderer.wantedRange(input, highlight: highlight,
                                               totalLines: input.sourceLines.count)
        let window = SceneRenderer.window(totalLines: input.sourceLines.count, want: wanted,
                                          highlight: highlight, height: input.size.height)
        let language = SyntaxTokenizer.language(forPath: input.path)
        let highlighted = SyntaxTokenizer.highlight(input.sourceLines.joined(separator: "\n"),
                                                    language: language)

        var rows: [String] = []
        let markerCount = (window.linesAbove > 0 ? 1 : 0) + (window.linesBelow > 0 ? 1 : 0)
        let metrics = codeMetrics(height: input.size.height, lineCount: window.count + markerCount)
        if window.linesAbove > 0 { rows.append(gapRow(window.linesAbove, "above")) }
        for number in window.first...max(window.first, window.last) {
            guard number - 1 < highlighted.count else { break }
            var classes = ["row"]
            if let highlight, highlight.contains(number) {
                classes.append("hi")
                if number == highlight.lowerBound { classes.append("hi-first") }
                if number == highlight.upperBound { classes.append("hi-last") }
            }
            let body = highlighted[number - 1].isEmpty ? "&nbsp;" : highlighted[number - 1]
            rows.append("<div class=\"\(classes.joined(separator: " "))\">"
                        + "<span class=\"n\">\(number)</span><span class=\"t\">\(body)</span></div>")
        }
        if window.linesBelow > 0 { rows.append(gapRow(window.linesBelow, "below")) }

        return fill(try template("scene-code"), [
            "TITLE": MarkdownLite.esc(input.shot.caption.isEmpty ? input.scene.title : input.shot.caption),
            "WHERE": MarkdownLite.esc(lineRangeLabel(highlight)),
            "PATH": MarkdownLite.esc(input.path),
            "SHA": MarkdownLite.esc(input.sha7),
            "ROWS": rows.joined(separator: "\n"),
            "CODE_PX": String(metrics.codePx),
            "LINE_PX": String(metrics.linePx),
            "CALLOUT": MarkdownLite.esc(input.shot.highlight?.callout ?? ""),
            "CALLOUT_CLASS": (input.shot.highlight?.callout ?? "").isEmpty ? "empty" : "",
        ], input: input)
    }

    static func gapRow(_ count: Int, _ where_: String) -> String {
        "<div class=\"gap\">\(count) line\(count == 1 ? "" : "s") \(where_)</div>"
    }

    /// `lines 6-11`, `line 7`, or nothing.
    static func lineRangeLabel(_ range: ClosedRange<Int>?) -> String {
        guard let range else { return "" }
        return range.lowerBound == range.upperBound
            ? "line \(range.lowerBound)"
            : "lines \(range.lowerBound)-\(range.upperBound)"
    }

    static func highlightRange(_ input: Input) -> ClosedRange<Int>? {
        guard let anchor = input.shot.highlight?.anchor,
              let parsed = try? Anchor.parse(anchor),
              case .code(_, _, let lines) = parsed else { return nil }
        return lines
    }

    /// `visibleLines` when the script gave one, else a window around the highlight, else
    /// the whole file.
    static func wantedRange(_ input: Input, highlight: ClosedRange<Int>?,
                            totalLines: Int) -> ClosedRange<Int> {
        if let visible = input.shot.visibleLines, visible.count >= 2, visible[0] <= visible[1] {
            return max(1, visible[0])...max(1, visible[1])
        }
        if let highlight {
            return max(1, highlight.lowerBound - 6)...(highlight.upperBound + 6)
        }
        return 1...max(1, totalLines)
    }

    // MARK: Other kinds

    static func titleHTML(_ input: Input) throws -> String {
        fill(try template("scene-title"), [
            "TITLE": MarkdownLite.esc(input.shot.caption.isEmpty ? input.scene.title : input.shot.caption),
            "SUB": MarkdownLite.esc(input.subtitle),
            "WHERE": MarkdownLite.esc(input.path.isEmpty ? input.sha7 : "\(input.path) @ \(input.sha7)"),
        ], input: input)
    }

    static func cardHTML(_ input: Input) throws -> String {
        let chips = input.evidence
            .map { "<span class=\"chip\">\(MarkdownLite.esc(MarkdownLite.anchorLabel($0)))</span>" }
            .joined()
        return fill(try template("scene-card"), [
            "KICKER": MarkdownLite.esc(input.kicker.isEmpty ? input.scene.title : input.kicker),
            "CLAIM": MarkdownLite.esc(input.claim.isEmpty ? input.shot.narration : input.claim),
            "CHIPS": chips,
            "HEDGE": MarkdownLite.esc(input.hedge),
            "HEDGE_CLASS": input.hedge.isEmpty ? "empty" : "",
        ], input: input)
    }

    static func terminalHTML(_ input: Input) throws -> String {
        let metrics = codeMetrics(height: input.size.height, lineCount: max(1, input.terminal.count))
        let lines = input.terminal.map { line -> String in
            let cssClass: String
            switch line.kind {
            case .command: cssClass = "cmd"
            case .output: cssClass = "out"
            case .problem: cssClass = "bad"
            }
            // A blank line collapses to nothing without a space, and the pause it marks
            // between a command's output and the comment on it is the point.
            let text = line.text.isEmpty ? "&nbsp;" : MarkdownLite.esc(line.text)
            return "<div class=\"\(cssClass)\">\(text)</div>"
        }.joined()
        let problem = input.terminal.contains { $0.kind == .problem }
        return fill(try template("scene-terminal"), [
            "TITLE": MarkdownLite.esc(input.shot.caption.isEmpty ? input.scene.title : input.shot.caption),
            "WHERE": MarkdownLite.esc(input.sha7.isEmpty ? "" : "ran at \(input.sha7)"),
            "LINES": lines,
            "CODE_PX": String(metrics.codePx),
            "LINE_PX": String(metrics.linePx),
            "STATUS": MarkdownLite.esc(input.kicker),
            "STATUS_KIND": problem ? "" : "ok",
            "NOTE": MarkdownLite.esc(input.subtitle),
            "STATUS_CLASS": input.kicker.isEmpty ? "empty" : "",
        ], input: input)
    }

    static func tableHTML(_ input: Input) throws -> String {
        guard let header = input.tableRows.first else {
            throw StudioError("SceneRenderer: a table scene needs at least a header row.")
        }
        let cellPx = Int((input.size.height * 0.030).rounded())
        var html = "<tr>" + header.map { "<th>\(MarkdownLite.esc($0))</th>" }.joined() + "</tr>"
        for row in input.tableRows.dropFirst() {
            var cells = ""
            for (index, cell) in row.enumerated() {
                let text = MarkdownLite.esc(cell)
                // The second column is a verdict, and colour carries it: painting a
                // clean row coral would make it look like a finding.
                if index == 1, let flag = SceneRenderer.flagClass(cell) {
                    cells += "<td><span class=\"flag \(flag)\">\(text)</span></td>"
                } else if index >= 2 {
                    cells += "<td class=\"mono\">\(text)</td>"
                } else {
                    cells += "<td>\(text)</td>"
                }
            }
            html += "<tr>" + cells + "</tr>"
        }
        return fill(try template("scene-table"), [
            "TITLE": MarkdownLite.esc(input.shot.caption.isEmpty ? input.scene.title : input.shot.caption),
            "SUB": MarkdownLite.esc(input.subtitle),
            "ROWS": html,
            "CELL_PX": String(cellPx),
        ], input: input)
    }

    /// `absent` is the finding, `partial` a caveat, `present` fine.
    static func flagClass(_ status: String) -> String? {
        switch status.lowercased() {
        case "absent", "missing", "no", "fail", "failed": return ""
        case "partial", "unknown", "unclear": return "warn"
        case "present", "yes", "ok", "pass", "passed": return "ok"
        default: return nil
        }
    }

    static func diagramHTML(_ input: Input) throws -> String {
        let chips = (input.shot.focusNodes ?? [])
            .map { "<span class=\"chip\">\(MarkdownLite.esc($0))</span>" }
            .joined()
        return fill(try template("scene-diagram"), [
            "TITLE": MarkdownLite.esc(input.shot.caption.isEmpty ? input.scene.title : input.shot.caption),
            "WHERE": MarkdownLite.esc(input.subtitle),
            "SVG": input.diagramSVG,
            "FOCUS_COLOR": input.theme.accentColor,
            "CHIPS": chips,
            "LEGEND_CLASS": chips.isEmpty ? "empty" : "",
        ], input: input)
    }
}
