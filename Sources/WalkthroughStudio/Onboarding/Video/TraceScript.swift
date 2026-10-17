import Foundation

/// Shortening narration one step at a time, so a script over its budget can be brought
/// under it without a line that ends mid-thought.
///
/// Every step keeps a whole unit of meaning: the first sentence, then the first clause,
/// and only as a last resort a word cap. `shorter` returns nil when a line is as short
/// as it gets, which is what tells the tighten loop to try something else.
enum NarrationFit {

    static func words(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Sentences, split at `.`, `!` or `?` followed by a space and a capital or a digit.
    /// `request.json` and `0.1s` stay whole, because no space follows their dot.
    static func sentences(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var current = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            current.append(char)
            if ".!?".contains(char), index + 2 < chars.count, chars[index + 1] == " ",
               chars[index + 2].isUppercase || chars[index + 2].isNumber {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                index += 1
            }
            index += 1
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    static func firstSentence(_ text: String) -> String {
        terminated(sentences(text).first ?? text)
    }

    /// The text up to the first clause break that leaves at least `minWords` words.
    /// The markers are the ones a summary sentence hinges on: a dash, a semicolon, a
    /// colon, and the commas that open "which", "so", "and" or "but".
    static let clauseMarkers = [" — ", " – ", "; ", ": ", ", which ", ", so ", ", and ", ", but ",
                                ", while ", ", with "]

    static func firstClause(_ text: String, minWords: Int = 4) -> String {
        var best: String.Index? = nil
        for marker in clauseMarkers {
            var search = text.startIndex..<text.endIndex
            while let range = text.range(of: marker, range: search) {
                if words(String(text[..<range.lowerBound])) >= minWords {
                    if best == nil || range.lowerBound < best! { best = range.lowerBound }
                    break
                }
                search = range.upperBound..<text.endIndex
            }
        }
        guard let best else { return terminated(text) }
        return terminated(String(text[..<best]))
    }

    /// The first `count` words, closed with a full stop.
    static func capped(_ text: String, words count: Int) -> String {
        let parts = text.split(whereSeparator: { $0.isWhitespace })
        guard parts.count > count else { return terminated(text) }
        return terminated(parts.prefix(count).joined(separator: " "))
    }

    /// One step shorter, or nil when the line is already as short as it gets.
    static func shorter(_ text: String, floorWords: Int = 6) -> String? {
        let count = words(text)
        guard count > floorWords else { return nil }
        let sentence = firstSentence(text)
        if words(sentence) < count { return sentence }
        let clause = firstClause(text)
        // A clause of four words is still a whole thought; a word cap of six is not.
        if words(clause) < count, words(clause) >= 4 { return clause }
        return capped(text, words: max(floorWords, count * 2 / 3))
    }

    /// Ends with one terminal mark: trailing commas and spaces go, a full stop is added
    /// when there is none.
    static func terminated(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = out.last, ",;:—–-".contains(last) {
            out.removeLast()
            out = out.trimmingCharacters(in: .whitespaces)
        }
        guard let last = out.last else { return out }
        if !".!?\"')".contains(last) { out += "." }
        return out
    }
}

/// A trace video, written from the packet's trace with no model: a tldr card, one code
/// scene per hop, and — at full length — the path as a diagram, the ten-concern table
/// and the "what scares me" card.
///
/// Deterministic on purpose. The trace is already the most carefully evidenced thing in
/// a packet (every hop an anchor, every concern a status with evidence), so a script
/// that walks it needs arrangement rather than authorship, and arrangement that is
/// reproducible is arrangement a probe can hold to ON-5.4: the hop scenes are the hop
/// list, in order, each naming its hop's anchor.
enum TraceScript {

    enum Cut: String, Codable {
        /// The tldr and the hops: what the smoke scope renders in a minute.
        case hops
        /// Hops plus the path diagram, the concern table and the confessional card.
        case full
    }

    static func videoID(pathId: String) -> String { "trace-\(pathId)" }

    /// Scene ids: `s01` the tldr, `h01`… the hops, then `map`, `concerns`, `scares`.
    static func hopSceneID(_ n: Int) -> String { String(format: "h%02d", n) }

    static func make(trace: PacketTrace, packet: ResearchPacket, source: PinnedSource,
                     cut: Cut, budgetSeconds: Double) async -> VideoScript {
        let sha7 = packet.sha7
        let usable = Set(packet.usableFacts.map { $0.id })
        let short = shortTitle(trace.title)
        let files = orderedFiles(trace)
        let entryFile = files.first.map { fileName($0) } ?? "the entry point"
        let across = "\(spelled(trace.hops.count)) \(trace.hops.count == 1 ? "stop" : "stops") across "
            + "\(spelled(files.count)) \(files.count == 1 ? "file" : "files")"

        var scenes: [VideoScript.Scene] = []

        // 1. The tldr.
        let absent = PacketTrace.concernKeys.filter { trace.concerns[$0]?.status == "absent" }
        var tldr = "\(short), followed hop by hop: \(across), starting in \(entryFile)."
        if let scare = trace.scaresMe.first {
            tldr += " The one to watch: " + lowerFirst(NarrationFit.firstClause(
                NarrationFit.firstSentence(scare), minWords: 8))
        }
        var bullets = ["Starts at \(entryFile)",
                       "\(trace.hops.count) hops through \(files.count) \(files.count == 1 ? "file" : "files")"]
        if !absent.isEmpty {
            bullets.append("\(absent.count) of 10 concerns absent: "
                           + absent.prefix(3).map { concernLabel($0).lowercased() }.joined(separator: ", "))
        }
        if let scare = trace.scaresMe.first {
            bullets.append(NarrationFit.capped(NarrationFit.firstClause(scare, minWords: 6), words: 18))
        }
        scenes.append(VideoScript.Scene(
            id: "s01", title: "TL;DR", variant: "tldr",
            shots: [VideoScript.Shot(id: "s01a", sceneType: "card", narration: tldr,
                                     anchors: [trace.entry], caption: short,
                                     bullets: bullets)]))

        // 2. One scene per hop.
        for hop in trace.hops {
            let sceneID = hopSceneID(hop.n)
            let hopAnchor = "trace:\(trace.pathId)#hop\(hop.n)"
            let path = ProjectionSupport.codePath(hop.anchor) ?? ""
            // Not a ternary: `await` cannot sit to the right of `?:`.
            var lines: [String]? = nil
            if !path.isEmpty { lines = await source.lines(of: path) }
            var callout = "the entry point"
            if let callSite = hop.callSite, let site = ProjectionSupport.codePath(callSite) {
                callout = "called from \(fileName(site))" + lineSuffix(callSite)
            }
            let shot = VideoScript.Shot(
                id: "\(sceneID)a", sceneType: "code",
                narration: NarrationFit.terminated(hop.summary),
                anchors: [hop.anchor, hopAnchor],
                highlight: CodeRefHighlight(anchor: hop.anchor, callout: callout),
                visibleLines: window(for: hop.anchor, totalLines: lines?.count),
                factIds: (hop.factIds ?? []).filter { usable.contains($0) },
                caption: hopCaption(hop, path: path))
            scenes.append(VideoScript.Scene(
                id: sceneID, title: "Hop \(hop.n): \(fileName(path.isEmpty ? hop.anchor : path))",
                docAnchor: hopAnchor, traceHop: hop.n, shots: [shot]))
        }

        if cut == .full {
            // 3. The path on one page.
            scenes.append(VideoScript.Scene(
                id: "map", title: "The whole path",
                shots: [VideoScript.Shot(
                    id: "mapa", sceneType: "diagram",
                    narration: "The whole path on one page: \(across), in the order a request meets them.",
                    anchors: [trace.entry], diagram: trace.pathId, caption: short)]))

            // 4. The ten concerns.
            var rows: [[String]] = [["Concern", "Status", "Evidence"]]
            for key in PacketTrace.concernKeys {
                guard let concern = trace.concerns[key] else { continue }
                rows.append([concernLabel(key), concern.status,
                             concern.evidence.first.map { MarkdownLite.anchorLabel($0) } ?? ""])
            }
            if rows.count > 1 {
                scenes.append(VideoScript.Scene(
                    id: "concerns", title: "The ten concerns",
                    shots: [VideoScript.Shot(
                        id: "concernsa", sceneType: "table",
                        narration: concernsNarration(trace),
                        anchors: PacketTrace.concernKeys.compactMap { trace.concerns[$0]?.evidence.first }
                            .uniqued().prefix(4).map { $0 },
                        caption: "The ten concerns", table: rows)]))
            }

            // 5. What scares me.
            let fears = trace.scaresMe.prefix(2).map { NarrationFit.firstSentence($0) }
            if !fears.isEmpty {
                scenes.append(VideoScript.Scene(
                    id: "scares", title: "What scares me", variant: "confessional",
                    shots: [VideoScript.Shot(
                        id: "scaresa", sceneType: "card", narration: fears.joined(separator: " "),
                        caption: "What scares me")]))
            }
        }

        return VideoScript(
            id: videoID(pathId: trace.pathId),
            title: "Critical path: \(short)",
            summary: "\(short), followed hop by hop: \(across), starting in \(entryFile)"
                + (cut == .full ? ", then the ten concerns and what should worry you." : "."),
            sha: sha7, kind: "trace", targetSeconds: budgetSeconds, scenes: scenes)
    }

    // MARK: - Pieces

    /// `Create an order (POST create-order → …)` → `Create an order`.
    static func shortTitle(_ title: String) -> String {
        let cut = title.firstIndex(of: "(").map { String(title[..<$0]) } ?? title
        let trimmed = cut.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    /// The files the hops visit, in first-visit order.
    static func orderedFiles(_ trace: PacketTrace) -> [String] {
        trace.hops.compactMap { ProjectionSupport.codePath($0.anchor) }.uniqued()
    }

    static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// `:9` or `:6-11` from a `code:` anchor's line range.
    static func lineSuffix(_ anchor: String) -> String {
        guard case .code(_, _, let lines?)? = Anchor(string: anchor) else { return "" }
        return lines.lowerBound == lines.upperBound ? ":\(lines.lowerBound)"
            : ":\(lines.lowerBound)-\(lines.upperBound)"
    }

    /// The identifier a hop's summary opens with (`handle_create_order`,
    /// `OrdersRepo.insert`), else the file name.
    static func hopCaption(_ hop: PacketTrace.Hop, path: String) -> String {
        let first = hop.summary.split(separator: " ").first.map(String.init) ?? ""
        let looksLikeCode = first.contains("_") || first.contains(".")
            || (first.first?.isLowercase == false && first.dropFirst().contains(where: { $0.isUppercase }))
        let cleaned = first.trimmingCharacters(in: CharacterSet(charactersIn: ",;:"))
        return looksLikeCode && !cleaned.isEmpty ? cleaned : fileName(path)
    }

    /// The highlight with up to eight lines of context each side, inside the 40-line
    /// panel. Nil (let the renderer centre it) when the file length is unknown or the
    /// highlight alone nearly fills a panel.
    static func window(for anchor: String, totalLines: Int?) -> [Int]? {
        guard let total = totalLines, total > 0,
              case .code(_, _, let lines?)? = Anchor(string: anchor) else { return nil }
        let span = lines.upperBound - lines.lowerBound + 1
        guard span <= ScriptValidator.maxWindowLines - 6 else { return nil }
        let context = min(8, (ScriptValidator.maxWindowLines - span) / 2)
        let first = max(1, lines.lowerBound - context)
        let last = min(max(total, lines.upperBound), lines.upperBound + context)
        return [first, last]
    }

    static func concernLabel(_ key: String) -> String {
        switch key {
        case "entry": return "Entry"
        case "authorization": return "Authorization"
        case "validation": return "Validation"
        case "businessLogic": return "Business logic"
        case "persistence": return "Persistence"
        case "sideEffects": return "Side effects"
        case "failureHandling": return "Failure handling"
        case "idempotency": return "Idempotency"
        case "timeoutsRetries": return "Timeouts and retries"
        case "logging": return "Logging"
        default: return key
        }
    }

    static func concernsNarration(_ trace: PacketTrace) -> String {
        func names(_ status: String) -> [String] {
            PacketTrace.concernKeys.filter { trace.concerns[$0]?.status == status }
                .map { concernLabel($0).lowercased() }
        }
        let absent = names("absent")
        let partial = names("partial")
        var out: String
        if absent.isEmpty {
            out = "Every one of the ten concerns is handled somewhere on this path."
        } else {
            out = "\(spelled(absent.count).capitalizedFirst) of the ten concerns "
                + "\(absent.count == 1 ? "is" : "are") missing on this path: \(listed(absent))."
        }
        if !partial.isEmpty {
            out += " \(spelled(partial.count).capitalizedFirst) \(partial.count == 1 ? "is" : "are") "
                + "only partly there: \(listed(partial))."
        }
        return out
    }

    static func listed(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// Small numbers as words, because a narrator reading "9 stops" says "nine" anyway
    /// and a caption that matches the voice reads better.
    static func spelled(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
                     "nine", "ten", "eleven", "twelve"]
        return words.indices.contains(n) ? words[n] : String(n)
    }

    static func lowerFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // An identifier or an acronym keeps its case.
        if text.dropFirst().first?.isUppercase == true { return text }
        return first.lowercased() + text.dropFirst()
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

extension Sequence where Element: Hashable {
    /// The elements in order, each once.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
