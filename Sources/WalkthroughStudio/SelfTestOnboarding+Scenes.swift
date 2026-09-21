// SelfTestOnboarding+Scenes — Onboard to a Codebase, milestone M5.
//
//   syntaxTokenizerProbe — tokens land on the right characters, and a comment or a
//     string that runs across lines keeps its colour on the next one.
//   codeSceneProbe       — the window and type-size rules, the highlight band visible
//     in the rendered pixels, and a source file full of {{ user.name }} surviving the
//     template's own placeholder substitution.
//   sceneKindsProbe      — one still per scene kind, each with the signature that says
//     it actually rendered: a dark panel where there should be one, cream where there
//     should not, and never a black frame.
//   scriptValidatorProbe — the fixture script passes; a broken one is refused by name.
//
// The renders go through BrandedRenderer, which needs an offscreen NSWindow to paint
// (CLAUDE.md landmine 2) and is the same path the real export uses.

import Foundation
import AppKit
import CoreGraphics

extension SelfTest {

    // MARK: - syntaxTokenizerProbe

    static func syntaxTokenizerProbe(_ ctx: OnboardingProbeContext) async throws {
        // Python: a keyword, a string, a number, a comment, a capitalized name.
        let python = SyntaxTokenizer.highlight(
            "def total(items):\n    # sum them\n    n = 42\n    return Decimal(\"0.00\")\n",
            language: SyntaxTokenizer.python)
        guard python.count >= 4 else {
            throw StudioError("syntaxTokenizerProbe: four source lines produced \(python.count) output lines")
        }
        try SelfTest.expect(python[0], contains: "<span class=\"k\">def</span>", "the keyword `def`")
        try SelfTest.expect(python[1], contains: "<span class=\"c\">", "the comment")
        try SelfTest.expect(python[2], contains: "<span class=\"m\">42</span>", "the number")
        try SelfTest.expect(python[3], contains: "<span class=\"y\">Decimal</span>", "the capitalized name")
        try SelfTest.expect(python[3], contains: "<span class=\"s\">", "the string")

        // A block comment spanning lines keeps its colour on the second line: the
        // reason the scanner runs over the whole file instead of line by line.
        let swift = SyntaxTokenizer.highlight("/* one\n   two */\nlet x = 1\n",
                                              language: SyntaxTokenizer.swift)
        try SelfTest.expect(swift[0], contains: "<span class=\"c\">", "the comment's first line")
        try SelfTest.expect(swift[1], contains: "<span class=\"c\">", "the comment's second line")
        try SelfTest.expect(swift[2], contains: "<span class=\"k\">let</span>", "code after the comment")

        // SQL keywords are written upper case in the fixture and lower case everywhere else.
        let sql = SyntaxTokenizer.highlight("ALTER TABLE users DROP COLUMN address;\nselect 1;",
                                            language: SyntaxTokenizer.sql)
        try SelfTest.expect(sql[0], contains: "<span class=\"k\">ALTER</span>", "an upper-case SQL keyword")
        try SelfTest.expect(sql[1], contains: "<span class=\"k\">select</span>", "a lower-case SQL keyword")

        // Escaping happens inside the tokenizer, because its output goes straight into
        // a template: a file containing `<script>` must not become one.
        let shell = SyntaxTokenizer.highlight("echo \"<script>\" > out.html", language: SyntaxTokenizer.shell)
        guard !shell[0].contains("<script>") else {
            throw StudioError("syntaxTokenizerProbe: `<script>` reached the output unescaped")
        }
        try SelfTest.expect(shell[0], contains: "&lt;script&gt;", "the escaped tag")

        // Every file in the fixture tokenizes without losing a character.
        for path in FixtureRepoFacts.files {
            let text = try SelfTestSupport.runGit(["show", "HEAD:\(path)"], in: ctx.fixtureRepo)
            let language = SyntaxTokenizer.language(forPath: path)
            let lines = SyntaxTokenizer.highlight(text, language: language)
            let sourceLines = text.components(separatedBy: "\n").count
            guard lines.count == sourceLines else {
                throw StudioError("syntaxTokenizerProbe: \(path) tokenized to \(lines.count) lines "
                                  + "from \(sourceLines) — a line was lost or invented")
            }
            guard !lines.joined().contains("<script") else {
                throw StudioError("syntaxTokenizerProbe: \(path) emitted an unescaped tag")
            }
        }

        print("selftest: syntaxTokenizerProbe OK (keywords, strings, numbers, comments across lines, "
              + "SQL in both cases, escaping; all \(FixtureRepoFacts.files.count) fixture files tokenize)")
    }

    static func expect(_ haystack: String, contains needle: String, _ what: String) throws {
        guard haystack.contains(needle) else {
            throw StudioError("expected \(what) in:\n      \(haystack.prefix(200))")
        }
    }

    // MARK: - codeSceneProbe

    static func codeSceneProbe(_ ctx: OnboardingProbeContext) async throws {
        let size = CGSize(width: 1280, height: 720)

        // 1. The window rule. A file that fits is shown whole; one that does not is
        //    centred on the highlight and says how much it left out. Silent truncation
        //    is the failure this rule exists to prevent.
        let room = SceneRenderer.capacity(height: size.height)
        let short = SceneRenderer.window(totalLines: 7, want: 1...7, highlight: 7...7, height: size.height)
        guard short == SceneRenderer.Window(first: 1, last: 7, linesAbove: 0, linesBelow: 0) else {
            throw StudioError("codeSceneProbe: a seven-line file was windowed to \(short)")
        }
        let long = SceneRenderer.window(totalLines: 300, want: 1...300, highlight: 150...154,
                                        height: size.height)
        guard long.count == room, long.first <= 150, long.last >= 154 else {
            throw StudioError("codeSceneProbe: a 300-line file windowed to \(long.first)-\(long.last), "
                              + "which does not hold the highlight at 150-154 in \(room) lines")
        }
        guard long.linesAbove == long.first - 1, long.linesBelow == 300 - long.last,
              long.linesAbove + long.count + long.linesBelow == 300 else {
            throw StudioError("codeSceneProbe: the elision counts do not add up to the file: \(long)")
        }
        // Type size shrinks as the window grows, and never past legibility.
        let bigType = SceneRenderer.codeMetrics(height: size.height, lineCount: 6)
        let smallType = SceneRenderer.codeMetrics(height: size.height, lineCount: room)
        guard bigType.linePx > smallType.linePx, smallType.codePx >= 12 else {
            throw StudioError("codeSceneProbe: type sizes \(bigType) and \(smallType) do not scale sensibly")
        }

        // 2. A rendered code scene. The fixture's email template is the interesting
        //    source: it is full of `{{ user.name }}`, which the template engine must
        //    not mistake for one of its own slots.
        let source = try SelfTestSupport.runGit(["show", "HEAD:templates/email.tmpl"], in: ctx.fixtureRepo)
        let shot = VideoScript.Shot(
            id: "s01a", sceneType: "code",
            narration: "The email template interpolates the user's name.",
            anchors: ["code:templates/email.tmpl@\(FixtureRepoFacts.headSHA.prefix(7))#L1-L3"],
            highlight: CodeRefHighlight(
                anchor: "code:templates/email.tmpl@\(FixtureRepoFacts.headSHA.prefix(7))#L1-L1",
                callout: "the only templating in the repository"),
            caption: "A mail template")
        var input = SceneRenderer.Input(
            shot: shot, scene: VideoScript.Scene(id: "s01", title: "Templates", shots: [shot]),
            sha7: String(FixtureRepoFacts.headSHA.prefix(7)), theme: BrandTheme(), size: size)
        input.sourceLines = source.components(separatedBy: "\n")
        input.path = "templates/email.tmpl"
        let html = try SceneRenderer.html(for: input)

        try SelfTest.expect(html, contains: "{{ user.name }}", "the source's own braces, left alone")
        let leftover = SelfTest.unfilledSlots(html)
        guard leftover.isEmpty else {
            throw StudioError("codeSceneProbe: unfilled slot(s) reached the rendered HTML: "
                              + leftover.joined(separator: ", "))
        }
        try SelfTest.expect(html, contains: "templates/email.tmpl", "the file path in the title bar")
        try SelfTest.expect(html, contains: "line 1", "the highlighted line range")
        try SelfTest.expect(html, contains: "the only templating", "the callout")

        // 3. The pixels. A highlight nobody can see is the same as no highlight.
        let renderer = BrandedRenderer()
        let image = try await renderer.render(html: html, pixelWidth: Int(size.width),
                                              pixelHeight: Int(size.height))
        guard let cg = SelfTest.cgImage(image) else {
            throw StudioError("codeSceneProbe: the code scene did not rasterize")
        }
        try? Exporters.pngData(from: image, pixelWidth: Int(size.width), pixelHeight: Int(size.height))?
            .write(to: ctx.outDir.appendingPathComponent("scene-code.png"))

        let stats = SelfTest.imageStats(cg)
        guard stats.meanLuma > 0.2 else {
            throw StudioError(String(format: "codeSceneProbe: the frame rendered near-black "
                                     + "(mean luma %.3f) — the headless render failed", stats.meanLuma))
        }
        guard stats.darkFraction > 0.25 else {
            throw StudioError(String(format: "codeSceneProbe: only %.1f%% of the frame is the code panel; "
                                     + "it did not render", stats.darkFraction * 100))
        }
        let band = SelfTest.accentBandRows(cg)
        guard band.count >= 4 else {
            throw StudioError("codeSceneProbe: found \(band.count) row(s) of highlight band in the "
                              + "rendered frame; the coral wash over the highlighted line is missing")
        }
        guard band.last! - band.first! + 1 <= band.count + 2 else {
            throw StudioError("codeSceneProbe: the highlight band is not contiguous "
                              + "(rows \(band.first!)...\(band.last!) for \(band.count) matches)")
        }

        print("selftest: codeSceneProbe OK (window rules hold; \(band.count) rows of highlight band; "
              + "the source's own {{ }} survived; no unfilled slots)")
    }

    // MARK: - sceneKindsProbe

    /// One still per scene kind, each pixel-checked for the thing that says it rendered.
    static func sceneKindsProbe(_ ctx: OnboardingProbeContext) async throws {
        let size = CGSize(width: 1280, height: 720)
        let sha = String(FixtureRepoFacts.headSHA.prefix(7))
        let renderer = BrandedRenderer()

        func input(_ type: String, _ narration: String) -> SceneRenderer.Input {
            let shot = VideoScript.Shot(id: "s01a", sceneType: type, narration: narration,
                                        caption: "\(type.capitalized) scene")
            return SceneRenderer.Input(
                shot: shot, scene: VideoScript.Scene(id: "s01", title: "Kinds", shots: [shot]),
                sha7: sha, theme: BrandTheme(), size: size)
        }

        // Each kind, with the least content that should still produce a full frame.
        var cases: [(String, SceneRenderer.Input)] = []

        var title = input("title", "The order service.")
        title.subtitle = "Fifteen files, one database, no framework."
        cases.append(("title", title))

        var card = input("card", "Every request leaks a connection.")
        card.kicker = "Landmine"
        card.claim = "Every request constructs a new OrdersRepo, which opens a connection never closed."
        card.evidence = ["code:src/repo/orders_repo.py@\(sha)#L7-L9"]
        cases.append(("card", card))

        var code = input("code", "The repository opens a connection here.")
        code.sourceLines = try SelfTestSupport.runGit(["show", "HEAD:src/auth/authz.py"],
                                                      in: ctx.fixtureRepo).components(separatedBy: "\n")
        code.path = "src/auth/authz.py"
        cases.append(("code", code))

        var terminal = input("terminal", "The suite passes and proves nothing.")
        terminal.terminal = [
            .init(kind: .command, text: "bash tests/test_orders.sh"),
            .init(kind: .output, text: "1..1"),
            .init(kind: .output, text: "ok 1 - total adds up"),
            .init(kind: .output, text: ""),
            .init(kind: .problem, text: "the script never imports src/"),
        ]
        terminal.kicker = "PASSED"
        terminal.subtitle = "one assertion, zero lines of the service under test"
        cases.append(("terminal", terminal))

        var table = input("table", "Ten concerns, four answered.")
        table.subtitle = "What the traced path does and does not do"
        table.tableRows = [
            ["Concern", "Status", "Evidence"],
            ["idempotency", "absent", "orders_repo.py L11-18"],
            ["authorization", "partial", "authz.py L8-10"],
            ["input validation", "present", "authz.py L8-10"],
        ]
        cases.append(("table", table))

        var diagram = input("diagram", "Four directories and a database.")
        diagram.diagramSVG = SelfTest.probeSVG
        diagram.subtitle = "containers"
        cases.append(("diagram", diagram))

        // What each kind must look like. The shared rule is the important one: a frame
        // that renders black is the headless failure this whole app works around.
        let expectations: [String: (dark: ClosedRange<Double>, note: String)] = [
            "title": (0...0.10, "a title card is cream, with no panel"),
            "card": (0...0.10, "a claim card is cream, with no panel"),
            "code": (0.25...0.95, "a code scene is mostly its dark panel"),
            "terminal": (0.15...0.95, "a terminal scene shows a dark window"),
            "table": (0...0.10, "a table is cream"),
            "diagram": (0...0.20, "a diagram is line work on cream"),
        ]

        var rendered: [String] = []
        for (kind, sceneInput) in cases {
            let html = try SceneRenderer.html(for: sceneInput)
            let unfilled = SelfTest.unfilledSlots(html)
            guard unfilled.isEmpty else {
                throw StudioError("sceneKindsProbe: the \(kind) scene left \(unfilled.joined(separator: ", ")) unfilled")
            }
            let image = try await renderer.render(html: html, pixelWidth: Int(size.width),
                                                  pixelHeight: Int(size.height))
            guard let cg = SelfTest.cgImage(image) else {
                throw StudioError("sceneKindsProbe: the \(kind) scene did not rasterize")
            }
            try? Exporters.pngData(from: image, pixelWidth: Int(size.width), pixelHeight: Int(size.height))?
                .write(to: ctx.outDir.appendingPathComponent("scene-\(kind).png"))

            let stats = SelfTest.imageStats(cg)
            guard stats.meanLuma > 0.15 else {
                throw StudioError(String(format: "sceneKindsProbe: the %@ scene rendered near-black "
                                         + "(mean luma %.3f)", kind, stats.meanLuma))
            }
            guard let expected = expectations[kind] else { continue }
            guard expected.dark.contains(stats.darkFraction) else {
                throw StudioError(String(format: "sceneKindsProbe: the %@ scene is %.1f%% dark, expected "
                                         + "%.0f-%.0f%% — %@", kind, stats.darkFraction * 100,
                                         expected.dark.lowerBound * 100, expected.dark.upperBound * 100,
                                         expected.note))
            }
            rendered.append("\(kind) \(Int(stats.darkFraction * 100))%")
        }

        print("selftest: sceneKindsProbe OK (" + rendered.joined(separator: ", ") + " dark)")
    }

    /// A tiny SVG standing in for a Mermaid render, so the diagram scene can be checked
    /// without running Mermaid in the probe.
    static let probeSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 160" width="400" height="160">
      <rect x="10" y="20" width="150" height="60" rx="8" fill="#FFFBF5" stroke="#1A1612"/>
      <rect x="240" y="20" width="150" height="60" rx="8" fill="#FFFBF5" stroke="#1A1612"/>
      <line x1="160" y1="50" x2="240" y2="50" stroke="#1A1612"/>
      <text x="30" y="55" font-size="16" fill="#1A1612">src/api/</text>
      <text x="260" y="55" font-size="16" fill="#1A1612">src/repo/</text>
    </svg>
    """

    // MARK: - scriptValidatorProbe

    static func scriptValidatorProbe(_ ctx: OnboardingProbeContext) async throws {
        let store = try PackageStore(root: SelfTest.fixturePackageURL(ctx))
        let router = LinkRouter(store: store, headSHA: FixtureRepoFacts.headSHA)
        let sha = String(FixtureRepoFacts.headSHA.prefix(7))

        // The script the fixture package actually ships must pass, or every render of it
        // is already suspect.
        let good = FixturePackage.script(sha: sha)
        let report = ScriptValidator.validate(good, router: router)
        guard report.ok else {
            throw StudioError("scriptValidatorProbe: the fixture script does not validate: "
                              + ScriptValidator.message(for: report))
        }
        guard report.shotCount == good.shots.count, report.estimatedSeconds > 10 else {
            throw StudioError("scriptValidatorProbe: the report says \(report.shotCount) shots and "
                              + "\(report.estimatedSeconds)s, which does not describe the script")
        }

        // And each way a script goes wrong is caught, by name.
        var broken = good
        broken.scenes[1].shots[0].highlight = CodeRefHighlight(
            anchor: "code:src/api/orders_handler.py@\(sha)#L900-L901", callout: "gone")
        broken.scenes[2].shots[0].anchors = ["code:src/api/nope.py@\(sha)#L1-L2"]
        broken.scenes[4].shots[0].diagram = ""
        broken.scenes[3].shots[0].sceneType = "interpretive-dance"
        let bad = ScriptValidator.validate(broken, router: router)
        guard !bad.ok, bad.errors.count >= 4 else {
            throw StudioError("scriptValidatorProbe: four broken shots produced "
                              + "\(bad.errors.count) error(s)")
        }
        let places = Set(bad.errors.map { $0.at })
        for expected in ["s02a", "s03a", "s04a", "s05a"] where !places.contains(expected) {
            throw StudioError("scriptValidatorProbe: nothing was reported against \(expected); "
                              + "reported: \(places.sorted().joined(separator: ", "))")
        }
        guard ScriptValidator.message(for: bad).contains("error") else {
            throw StudioError("scriptValidatorProbe: the message does not say there are errors")
        }

        // A shot with no narration is a warning, not a failure: a title card held in
        // silence is a legitimate choice.
        var silent = good
        silent.scenes[0].shots[0].sceneType = "card"
        silent.scenes[0].shots[0].narration = ""
        let quiet = ScriptValidator.validate(silent, router: router)
        guard quiet.ok, quiet.warnings.contains(where: { $0.at == "s01a" }) else {
            throw StudioError("scriptValidatorProbe: an unnarrated card should warn, not fail "
                              + "(\(quiet.errors.count) errors, \(quiet.warnings.count) warnings)")
        }

        print("selftest: scriptValidatorProbe OK (\(report.summary); four broken shots each reported "
              + "by id; silence warns rather than fails)")
    }

    /// `{{SLOT}}` names left behind by the template fill. A source file's own braces
    /// (`{{ user.name }}` in the fixture's mail template) are not slots and must survive,
    /// so only upper-case names count.
    static func unfilledSlots(_ html: String) -> [String] {
        var out: [String] = []
        var rest = Substring(html)
        while let open = rest.range(of: "{{") {
            guard let close = rest[open.upperBound...].range(of: "}}") else { break }
            let name = String(rest[open.upperBound..<close.lowerBound])
            if !name.isEmpty, name.allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "_" }) {
                out.append("{{\(name)}}")
            }
            rest = rest[close.upperBound...]
        }
        return out
    }

    // MARK: - Pixel helpers

    static func cgImage(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    struct ImageStats {
        var meanLuma: Double
        /// Fraction of pixels darker than 25% luma — a code or terminal panel.
        var darkFraction: Double
    }

    /// Aggregate statistics rather than named pixels: a scene's layout is allowed to
    /// move, but "it rendered a dark panel" and "it did not render black" must not.
    ///
    /// `NSBitmapImageRep.colorAt` is top-left origin (CLAUDE.md landmine 6); nothing
    /// here depends on the direction, but the next person to add a row check will.
    static func imageStats(_ image: CGImage, step: Int = 4) -> ImageStats {
        let rep = NSBitmapImageRep(cgImage: image)
        var total = 0.0
        var dark = 0
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let luma = 0.2126 * colour.redComponent + 0.7152 * colour.greenComponent
                    + 0.0722 * colour.blueComponent
                total += luma
                if luma < 0.25 { dark += 1 }
                count += 1
            }
        }
        guard count > 0 else { return ImageStats(meanLuma: 0, darkFraction: 0) }
        return ImageStats(meanLuma: total / Double(count), darkFraction: Double(dark) / Double(count))
    }

    /// Rows where the dark panel carries a red wash — the highlight band. Finding it by
    /// scanning rather than by sampling a fixed pixel means the layout can change and
    /// the probe still checks the thing it is named after.
    static func accentBandRows(_ image: CGImage) -> [Int] {
        let rep = NSBitmapImageRep(cgImage: image)
        var rows: [Int] = []
        let sampleXs = Array(stride(from: rep.pixelsWide / 10, to: rep.pixelsWide * 8 / 10,
                                    by: max(1, rep.pixelsWide / 40)))
        for y in 0..<rep.pixelsHigh {
            var washed = 0
            var samples = 0
            for x in sampleXs {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                samples += 1
                let r = colour.redComponent, g = colour.greenComponent, b = colour.blueComponent
                // Dark (inside the panel) and distinctly redder than it is blue.
                if r < 0.55, r - b > 0.06, r - g > 0.04 { washed += 1 }
            }
            if samples > 0, Double(washed) / Double(samples) > 0.7 { rows.append(y) }
        }
        return rows
    }
}
