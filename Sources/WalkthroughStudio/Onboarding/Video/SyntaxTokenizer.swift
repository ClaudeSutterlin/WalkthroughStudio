import Foundation

/// A small, dependency-free syntax highlighter for the code scenes (D14).
///
/// Not an IDE's highlighter and not trying to be: a code shot holds twenty or thirty
/// lines for eight seconds, and what a viewer needs is comments receding, strings and
/// numbers separating from names, and keywords carrying the structure. Getting a
/// generic type parameter subtly wrong costs nothing here; pulling in a parser for
/// every language in the world would cost the no-dependencies rule.
///
/// Output is one HTML string per source line, already escaped, with single-letter
/// classes the scene templates style: `k` keyword, `s` string, `m` number, `c` comment,
/// `y` type, `p` punctuation. Plain names are left unwrapped.
enum SyntaxTokenizer {

    struct Language: Equatable {
        var name: String
        var keywords: Set<String>
        /// Token that starts a comment running to end of line.
        var lineComments: [String]
        /// Open/close pair for a block comment, when the language has one.
        var blockComment: (open: String, close: String)?
        /// Quote characters that open a string.
        var quotes: Set<Character>
        /// Triple-quoted strings (Python, Swift multi-line).
        var tripleQuotes: [String]
        /// `\` escapes inside strings.
        var backslashEscapes: Bool

        static func == (lhs: Language, rhs: Language) -> Bool { lhs.name == rhs.name }
    }

    // MARK: - Languages

    static func language(forPath path: String) -> Language {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let ext = name.split(separator: ".").count > 1
            ? String(name.split(separator: ".").last!).lowercased()
            : ""
        switch ext {
        case "py", "pyi": return python
        case "swift": return swift
        case "js", "mjs", "cjs", "jsx", "ts", "tsx": return javascript
        case "go": return go
        case "rs": return rust
        case "java", "kt", "kts", "scala", "cs": return cLike(named: ext, extra: javaKeywords)
        case "c", "h", "cc", "cpp", "hpp", "m", "mm": return cLike(named: ext, extra: cKeywords)
        case "rb": return ruby
        case "php": return cLike(named: "php", extra: phpKeywords)
        case "sql": return sql
        case "sh", "bash", "zsh", "bashrc": return shell
        case "yml", "yaml": return yaml
        case "json": return json
        case "toml", "ini", "cfg", "conf", "example", "env": return ini
        case "html", "htm", "xml", "svg": return markup
        case "css", "scss": return css
        default:
            // A file with no extension is usually a script; `Makefile` and `Dockerfile`
            // both take `#` comments, which is the only thing that really matters.
            return shell
        }
    }

    static let python = Language(
        name: "python",
        keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not",
                   "and", "or", "import", "from", "as", "with", "try", "except", "finally",
                   "raise", "yield", "lambda", "pass", "break", "continue", "global", "nonlocal",
                   "assert", "del", "is", "None", "True", "False", "await", "async", "self"],
        lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"],
        tripleQuotes: ["\"\"\"", "'''"], backslashEscapes: true)

    static let swift = Language(
        name: "swift",
        keywords: ["func", "let", "var", "class", "struct", "enum", "protocol", "extension",
                   "if", "else", "guard", "for", "in", "while", "repeat", "return", "throw",
                   "throws", "rethrows", "try", "catch", "do", "switch", "case", "default",
                   "break", "continue", "import", "init", "deinit", "self", "Self", "super",
                   "nil", "true", "false", "static", "public", "private", "internal", "fileprivate",
                   "open", "final", "lazy", "weak", "unowned", "async", "await", "actor", "some",
                   "any", "where", "as", "is", "inout", "defer", "typealias", "associatedtype"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""],
        tripleQuotes: ["\"\"\""], backslashEscapes: true)

    static let javascript = Language(
        name: "javascript",
        keywords: ["function", "const", "let", "var", "class", "extends", "return", "if", "else",
                   "for", "of", "in", "while", "do", "switch", "case", "default", "break",
                   "continue", "new", "this", "super", "import", "export", "from", "as",
                   "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof",
                   "null", "undefined", "true", "false", "interface", "type", "enum", "implements",
                   "public", "private", "readonly", "static"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"],
        tripleQuotes: [], backslashEscapes: true)

    static let go = Language(
        name: "go",
        keywords: ["func", "package", "import", "var", "const", "type", "struct", "interface",
                   "map", "chan", "go", "defer", "return", "if", "else", "for", "range",
                   "switch", "case", "default", "break", "continue", "select", "nil", "true",
                   "false", "make", "new", "len", "cap", "append", "error"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "`"],
        tripleQuotes: [], backslashEscapes: true)

    static let rust = Language(
        name: "rust",
        keywords: ["fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl",
                   "for", "in", "while", "loop", "if", "else", "match", "return", "pub", "use",
                   "mod", "crate", "self", "Self", "super", "where", "async", "await", "move",
                   "ref", "dyn", "unsafe", "true", "false", "Some", "None", "Ok", "Err"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""],
        tripleQuotes: [], backslashEscapes: true)

    static let javaKeywords: Set<String> = [
        "class", "interface", "enum", "extends", "implements", "public", "private", "protected",
        "static", "final", "abstract", "void", "return", "new", "this", "super", "if", "else",
        "for", "while", "do", "switch", "case", "default", "break", "continue", "try", "catch",
        "finally", "throw", "throws", "import", "package", "null", "true", "false", "var", "val",
        "fun", "object", "data", "suspend", "override", "using", "namespace", "async", "await",
    ]

    static let cKeywords: Set<String> = [
        "int", "char", "float", "double", "long", "short", "unsigned", "signed", "void", "const",
        "static", "struct", "union", "enum", "typedef", "sizeof", "return", "if", "else", "for",
        "while", "do", "switch", "case", "default", "break", "continue", "goto", "extern",
        "inline", "class", "public", "private", "protected", "virtual", "template", "namespace",
        "using", "new", "delete", "nullptr", "true", "false", "auto",
    ]

    static let phpKeywords: Set<String> = [
        "function", "class", "interface", "trait", "extends", "implements", "public", "private",
        "protected", "static", "return", "new", "this", "if", "else", "elseif", "foreach", "for",
        "while", "switch", "case", "default", "break", "continue", "try", "catch", "finally",
        "throw", "use", "namespace", "echo", "null", "true", "false", "array", "const",
    ]

    static func cLike(named name: String, extra: Set<String>) -> Language {
        Language(name: name, keywords: extra, lineComments: ["//", "#"],
                 blockComment: ("/*", "*/"), quotes: ["\"", "'"], tripleQuotes: [],
                 backslashEscapes: true)
    }

    static let ruby = Language(
        name: "ruby",
        keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "case",
                   "when", "while", "until", "for", "in", "do", "return", "yield", "begin",
                   "rescue", "ensure", "raise", "require", "attr_accessor", "self", "nil",
                   "true", "false", "puts", "lambda", "proc"],
        lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"], tripleQuotes: [],
        backslashEscapes: true)

    static let sql = Language(
        name: "sql",
        keywords: ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
                   "DELETE", "CREATE", "TABLE", "ALTER", "DROP", "COLUMN", "ADD", "INDEX",
                   "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "NOT", "NULL", "DEFAULT",
                   "UNIQUE", "CONSTRAINT", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON",
                   "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "AS", "AND", "OR",
                   "BEGIN", "COMMIT", "ROLLBACK", "TRANSACTION", "SERIAL", "INTEGER", "TEXT",
                   "VARCHAR", "TIMESTAMP", "BOOLEAN", "NUMERIC", "EXISTS", "IF", "CASCADE"],
        lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'", "\""],
        tripleQuotes: [], backslashEscapes: false)

    static let shell = Language(
        name: "shell",
        keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while",
                   "until", "case", "esac", "function", "return", "export", "local", "readonly",
                   "set", "echo", "cd", "exit", "source", "trap", "shift", "test"],
        lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"], tripleQuotes: [],
        backslashEscapes: true)

    static let yaml = Language(
        name: "yaml",
        keywords: ["true", "false", "null", "on", "off", "yes", "no"],
        lineComments: ["#"], blockComment: nil, quotes: ["\"", "'"], tripleQuotes: [],
        backslashEscapes: true)

    static let json = Language(
        name: "json", keywords: ["true", "false", "null"],
        lineComments: [], blockComment: nil, quotes: ["\""], tripleQuotes: [],
        backslashEscapes: true)

    static let ini = Language(
        name: "ini", keywords: ["true", "false"],
        lineComments: ["#", ";"], blockComment: nil, quotes: ["\"", "'"], tripleQuotes: [],
        backslashEscapes: false)

    static let markup = Language(
        name: "markup", keywords: [],
        lineComments: [], blockComment: ("<!--", "-->"), quotes: ["\"", "'"],
        tripleQuotes: [], backslashEscapes: false)

    static let css = Language(
        name: "css", keywords: ["important", "media", "import", "keyframes", "supports", "root"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"],
        tripleQuotes: [], backslashEscapes: false)

    // MARK: - Tokenizing

    enum Kind: String {
        case plain = ""
        case keyword = "k"
        case string = "s"
        case number = "m"
        case comment = "c"
        case type = "y"
        case punctuation = "p"
    }

    /// One HTML string per line of `source`, escaped and wrapped in token spans.
    ///
    /// Comments and strings run across lines, so the whole file is scanned once and the
    /// spans are cut at newlines — a template literal opened on line 4 keeps its colour
    /// on line 5 instead of restarting as code.
    static func highlight(_ source: String, language: Language) -> [String] {
        var lines: [String] = [""]
        for (kind, text) in tokens(source, language: language) {
            let pieces = text.components(separatedBy: "\n")
            for (index, piece) in pieces.enumerated() {
                if index > 0 { lines.append("") }
                guard !piece.isEmpty else { continue }
                lines[lines.count - 1] += span(kind, piece)
            }
        }
        return lines
    }

    static func span(_ kind: Kind, _ text: String) -> String {
        let escaped = MarkdownLite.esc(text)
        return kind == .plain ? escaped : "<span class=\"\(kind.rawValue)\">\(escaped)</span>"
    }

    /// The scanner. Deliberately one pass with no lookbehind: every construct it knows
    /// is recognizable from its opening characters.
    static func tokens(_ source: String, language: Language) -> [(Kind, String)] {
        let chars = Array(source)
        var out: [(Kind, String)] = []
        var plain = ""

        func flush() {
            guard !plain.isEmpty else { return }
            out.append((.plain, plain))
            plain = ""
        }
        func emit(_ kind: Kind, _ text: String) {
            flush()
            out.append((kind, text))
        }

        var i = 0
        while i < chars.count {
            // Block comment
            if let block = language.blockComment, matches(chars, i, block.open) {
                let end = find(chars, from: i + block.open.count, needle: block.close)
                let stop = end.map { $0 + block.close.count } ?? chars.count
                emit(.comment, String(chars[i..<stop]))
                i = stop
                continue
            }
            // Line comment. `#` inside a shell string is handled by the string branch
            // above it; a `#` that starts a line or follows whitespace is a comment.
            if language.lineComments.contains(where: { matches(chars, i, $0) }) {
                var stop = i
                while stop < chars.count, chars[stop] != "\n" { stop += 1 }
                emit(.comment, String(chars[i..<stop]))
                i = stop
                continue
            }
            // Triple-quoted string
            if let triple = language.tripleQuotes.first(where: { matches(chars, i, $0) }) {
                let end = find(chars, from: i + triple.count, needle: triple)
                let stop = end.map { $0 + triple.count } ?? chars.count
                emit(.string, String(chars[i..<stop]))
                i = stop
                continue
            }
            // String
            if language.quotes.contains(chars[i]) {
                let quote = chars[i]
                var j = i + 1
                while j < chars.count {
                    if language.backslashEscapes, chars[j] == "\\" {
                        j += 2
                        continue
                    }
                    if chars[j] == quote {
                        j += 1
                        break
                    }
                    // An unterminated string does not swallow the rest of the file.
                    if chars[j] == "\n" { break }
                    j += 1
                }
                emit(.string, String(chars[i..<min(j, chars.count)]))
                i = min(j, chars.count)
                continue
            }
            // Number
            if chars[i].isNumber, i == 0 || !isWordCharacter(chars[i - 1]) {
                var j = i
                while j < chars.count, chars[j].isHexDigit || chars[j] == "." || chars[j] == "x"
                        || chars[j] == "_" {
                    j += 1
                }
                emit(.number, String(chars[i..<j]))
                i = j
                continue
            }
            // Word
            if isWordStart(chars[i]) {
                var j = i
                while j < chars.count, isWordCharacter(chars[j]) { j += 1 }
                let word = String(chars[i..<j])
                if language.keywords.contains(word) {
                    emit(.keyword, word)
                } else if language.keywords.contains(word.uppercased()), language.name == "sql" {
                    emit(.keyword, word)
                } else if let first = word.first, first.isUppercase, word.count > 1 {
                    emit(.type, word)       // a capitalized name reads as a type everywhere
                } else {
                    plain += word
                }
                i = j
                continue
            }
            // Punctuation
            if "{}()[];:,.<>=+-*/%&|!?".contains(chars[i]) {
                emit(.punctuation, String(chars[i]))
                i += 1
                continue
            }
            plain.append(chars[i])
            i += 1
        }
        flush()
        return out
    }

    // MARK: - Scanning helpers

    static func matches(_ chars: [Character], _ index: Int, _ needle: String) -> Bool {
        let n = Array(needle)
        guard !n.isEmpty, index + n.count <= chars.count else { return false }
        for (offset, ch) in n.enumerated() where chars[index + offset] != ch { return false }
        return true
    }

    static func find(_ chars: [Character], from: Int, needle: String) -> Int? {
        guard from <= chars.count else { return nil }
        var i = from
        while i < chars.count {
            if matches(chars, i, needle) { return i }
            i += 1
        }
        return nil
    }

    static func isWordStart(_ c: Character) -> Bool { c.isLetter || c == "_" || c == "$" }
    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }
}
