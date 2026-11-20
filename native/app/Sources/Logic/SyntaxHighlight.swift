// Syntax highlighting for the native editor (Foundation only, so the unit tests cover it).
//
// A hand-written scanner over UTF-16 code units, driven by a small per-language spec. It is built for a text
// view that shows a WINDOW of a big file: `scan` colours any range given the state at its first line, and
// `Checkpoints` keeps that state every `stride` lines so a window deep in a 50 MB file starts at the nearest
// checkpoint instead of at line 1. Tokens carry only a kind; the colours (Monaco's vs / vs-dark palettes, as
// classic uses) live in the view layer.

import Foundation

public enum TokenKind: UInt8 {
    case plain, comment, string, number, keyword, type, key, tag, attribute, heading, constant, punctuation, variable, bracket1, bracket2, bracket3
}

public enum SyntaxLanguage: String, CaseIterable {
    case plain, json, javascript, typescript, python, rust, go, swift, c, java, shell, css, html, yaml, toml, sql, markdown, ruby

    /// How the language is named in the UI (classic shows Monaco's names).
    public var displayName: String {
        switch self {
        case .plain: return "Plain Text"
        case .json: return "JSON"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .python: return "Python"
        case .rust: return "Rust"
        case .go: return "Go"
        case .swift: return "Swift"
        case .c: return "C / C++"
        case .java: return "Java"
        case .shell: return "Shell"
        case .css: return "CSS"
        case .html: return "HTML"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .sql: return "SQL"
        case .markdown: return "Markdown"
        case .ruby: return "Ruby"
        }
    }

    /// From the file name: extension first, then well-known extension-less names.
    public static func detect(path: String) -> SyntaxLanguage {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "makefile", "dockerfile", ".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", ".envrc": return name == "makefile" || name == "dockerfile" ? .shell : .shell
        case "cargo.lock", "pipfile": return .toml
        default: break
        }
        switch (name as NSString).pathExtension {
        case "json", "jsonc", "json5", "webmanifest", "geojson": return .json
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "py", "pyi", "pyw": return .python
        case "rs": return .rust
        case "go": return .go
        case "swift": return .swift
        case "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm", "cs": return .c
        case "java", "kt", "kts", "scala", "groovy", "gradle": return .java
        case "sh", "bash", "zsh", "fish", "env", "mk", "conf": return .shell
        case "css", "scss", "less": return .css
        case "html", "htm", "xml", "svg", "xhtml", "plist", "vue", "svelte": return .html
        case "yaml", "yml": return .yaml
        case "toml", "ini", "cfg": return .toml
        case "sql": return .sql
        case "md", "markdown", "mdx": return .markdown
        case "rb", "rake", "gemspec": return .ruby
        default: return .plain
        }
    }
}

/// One language's rules. Private to the scanner; built once per language.
struct LangSpec {
    var lineComments: [[UInt16]] = []
    var blockOpen: [UInt16] = [], blockClose: [UInt16] = []
    var quotes: [UInt16] = [0x22, 0x27]            // " '
    var tripleQuotes = false                          // python """ and '''
    var backtickMultiline = false                     // JS template literals
    var rustChars = false                             // 'a' is a char, 'a is a lifetime
    var keywords: Set<String> = []
    var types: Set<String> = []
    var constants: Set<String> = []
    var capitalizedAreTypes = false
    var jsonKeys = false                              // "key": …
    var yamlKeys = false                              // key: …
    var shellVars = false                             // $VAR ${VAR}
    var cssProps = false                              // prop: …;  #hex  .class
    var atWords = false                               // @decorator / @media
    var caseInsensitiveKeywords = false
}

private func u(_ s: String) -> [UInt16] { Array(s.utf16) }
private func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

enum Specs {
    static let table: [SyntaxLanguage: LangSpec] = {
        var t: [SyntaxLanguage: LangSpec] = [:]
        let jsKw = "break case catch class const continue debugger default delete do else enum export extends finally for function if import in instanceof new of return super switch this throw try typeof var let void while with yield async await static get set from as implements interface package private protected public readonly abstract declare namespace module type keyof infer is satisfies override"
        var js = LangSpec(lineComments: [u("//")], blockOpen: u("/*"), blockClose: u("*/"), quotes: [0x22, 0x27, 0x60], backtickMultiline: true,
                          keywords: words(jsKw), types: words("string number boolean any unknown never object symbol bigint void Array Promise Record Map Set Date Error"),
                          constants: words("true false null undefined NaN Infinity"), capitalizedAreTypes: true, atWords: true)
        t[.javascript] = js
        js.keywords.formUnion(words("")); t[.typescript] = js
        t[.json] = LangSpec(lineComments: [u("//")], blockOpen: u("/*"), blockClose: u("*/"), quotes: [0x22], constants: words("true false null"), jsonKeys: true)
        t[.python] = LangSpec(lineComments: [u("#")], tripleQuotes: true,
                              keywords: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case"),
                              types: words("int str float bool list dict tuple set bytes object type"), constants: words("True False None self cls"), capitalizedAreTypes: true, atWords: true)
        t[.rust] = LangSpec(lineComments: [u("//")], blockOpen: u("/*"), blockClose: u("*/"), quotes: [0x22, 0x27], rustChars: true,
                            keywords: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while union"),
                            types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box Rc Arc"),
                            constants: words("true false None Some Ok Err"), capitalizedAreTypes: true)
        t[.go] = LangSpec(lineComments: [u("//")], blockOpen: u("/*"), blockClose: u("*/"), quotes: [0x22, 0x27, 0x60], backtickMultiline: true,
                          keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
                          types: words("int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float32 float64 string bool byte rune error any"), constants: words("true false nil iota"), capitalizedAreTypes: true)
        t[.swift] = LangSpec(lineComments: [u("//")], blockOpen: u("/*"), blockClose: u("*/"), quotes: [0x22],
                             keywords: words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private protocol public static struct subscript typealias var break case continue default defer do else fallthrough for guard if in repeat return switch where while as catch is rethrows throw throws try await async actor some any final lazy override mutating weak unowned"),
                             types: words("Int Double Float Bool String Character Array Dictionary Set Optional Any AnyObject Void"), constants: words("true false nil self Self super"), capitalizedAreTypes: true, atWords: true)
        t[.c] = LangSpec(lineComments: [u("//")], blockOpen: u("/*"), blockClose: u("*/"),
                         keywords: words("auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while class namespace template typename public private protected virtual override new delete using this try catch throw operator final constexpr nullptr"),
                         types: words("int long short char float double void unsigned signed bool size_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t string vector"), constants: words("true false NULL nullptr"), capitalizedAreTypes: true)
        t[.java] = LangSpec(lineComments: [u("//")], blockOpen: u("/*"), blockClose: u("*/"),
                            keywords: words("abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try volatile while fun val var when object override data sealed lateinit companion"),
                            types: words("int long short byte char float double boolean void String Object List Map Set Int Long Unit"), constants: words("true false null"), capitalizedAreTypes: true, atWords: true)
        t[.shell] = LangSpec(lineComments: [u("#")], quotes: [0x22, 0x27, 0x60],
                             keywords: words("if then else elif fi for while until do done case esac in function select return exit break continue local export readonly declare unset source alias set trap shift eval exec"),
                             constants: words("true false"), shellVars: true)
        t[.css] = LangSpec(blockOpen: u("/*"), blockClose: u("*/"), keywords: words("important"), cssProps: true, atWords: true)
        t[.yaml] = LangSpec(lineComments: [u("#")], constants: words("true false null yes no on off True False Null ~"), yamlKeys: true)
        t[.toml] = LangSpec(lineComments: [u("#"), u(";")], tripleQuotes: true, constants: words("true false"), yamlKeys: true)
        t[.sql] = LangSpec(lineComments: [u("--")], blockOpen: u("/*"), blockClose: u("*/"), quotes: [0x22, 0x27],
                           keywords: words("select from where and or not insert into values update set delete create table alter drop index view join inner left right outer full cross on as group by order having limit offset union all distinct case when then else end null is in like between exists primary key foreign references default unique check constraint begin commit rollback with returning asc desc"),
                           types: words("int integer bigint smallint text varchar char boolean bool date timestamp timestamptz numeric decimal float double json jsonb uuid serial"),
                           constants: words("true false"), caseInsensitiveKeywords: true)
        t[.ruby] = LangSpec(lineComments: [u("#")], quotes: [0x22, 0x27, 0x60],
                            keywords: words("alias and begin break case class def defined do else elsif end ensure for if in module next nil not or redo rescue retry return self super then undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer"),
                            constants: words("true false nil"), capitalizedAreTypes: true)
        t[.html] = LangSpec(quotes: [0x22, 0x27]) // markup: handled by its own branch
        t[.markdown] = LangSpec(quotes: [])        // markdown: its own branch
        t[.plain] = LangSpec(quotes: [])
        return t
    }()
}

/// Scanner state at a line start. 0 = normal; the others are "inside a multi-line construct".
public enum ScanState {
    public static let normal = 0, blockComment = 1, tripleDouble = 2, tripleSingle = 3, backtick = 4, htmlComment = 5, mdFence = 6, htmlTag = 7
}

public enum SyntaxScanner {
    public typealias Emit = (_ location: Int, _ length: Int, _ kind: TokenKind) -> Void

    @inline(__always) private static func isIdentStart(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c > 0x7F }
    @inline(__always) private static func isIdentPart(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 0x30 && c <= 0x39) }
    @inline(__always) private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    /// Scans `buf[start..<end]` (UTF-16 units; `start` must be at a line start) from `state`; returns the state at `end`.
    /// `emit == nil` tracks state only (no identifier work): that is what the whole-file checkpoint pass uses.
    @discardableResult
    public static func scan(_ buf: UnsafeBufferPointer<UInt16>, from start: Int, to end: Int, language: SyntaxLanguage, state initial: Int, emit: Emit?) -> Int {
        guard language != .plain else { return 0 }
        if language == .html { return scanMarkup(buf, start, end, initial, emit) }
        if language == .markdown { return scanMarkdown(buf, start, end, initial, emit) }
        let spec = Specs.table[language]!
        var state = initial & 0xFF          // low byte: multi-line construct; the rest: bracket nesting depth
        var depth = initial >> 8
        var i = start
        var lineStart = true
        let lc = spec.lineComments
        let hasBlock = !spec.blockOpen.isEmpty

        @inline(__always) func starts(_ pat: [UInt16], at p: Int) -> Bool {
            if p + pat.count > end { return false }
            for k in 0 ..< pat.count where buf[p + k] != pat[k] { return false }
            return true
        }
        /// End of the multi-line construct body starting at `p` (index after the closer, or `end`); true if closed.
        func skipBlock(_ p: Int, closer: [UInt16]) -> (Int, Bool) {
            var q = p
            let c0 = closer[0]
            while q < end {
                if buf[q] == c0, starts(closer, at: q) { return (q + closer.count, true) }
                q += 1
            }
            return (end, false)
        }
        func skipTemplate(_ p: Int) -> (Int, Bool) {
            var q = p
            while q < end {
                let c = buf[q]
                if c == 0x5C { q += 2; continue }
                if c == 0x60 { return (q + 1, true) }
                q += 1
            }
            return (min(q, end), false)
        }

        // Resume a multi-line construct.
        switch state {
        case ScanState.blockComment:
            let (q, closed) = skipBlock(i, closer: spec.blockClose)
            emit?(i, q - i, .comment); i = q; if closed { state = 0 }
        case ScanState.tripleDouble, ScanState.tripleSingle:
            let q3: UInt16 = state == ScanState.tripleDouble ? 0x22 : 0x27
            let (q, closed) = skipBlock(i, closer: [q3, q3, q3])
            emit?(i, q - i, .string); i = q; if closed { state = 0 }
        case ScanState.backtick:
            let (q, closed) = skipTemplate(i)
            emit?(i, q - i, .string); i = q; if closed { state = 0 }
        default: break
        }

        while i < end {
            let c = buf[i]
            if c == 0x0A { lineStart = true; i += 1; continue }
            if c == 0x20 || c == 0x09 || c == 0x0D { i += 1; continue }
            let atLineStart = lineStart; lineStart = false

            // Comments.
            if hasBlock, c == spec.blockOpen[0], starts(spec.blockOpen, at: i) {
                let (q, closed) = skipBlock(i + spec.blockOpen.count, closer: spec.blockClose)
                emit?(i, q - i, .comment); i = q; if !closed { state = ScanState.blockComment }
                continue
            }
            var isLC = false
            for p in lc where c == p[0] && starts(p, at: i) { isLC = true; break }
            if isLC {
                var q = i; while q < end, buf[q] != 0x0A { q += 1 }
                emit?(i, q - i, .comment); i = q; continue
            }
            // Strings.
            if spec.quotes.contains(c) {
                if spec.tripleQuotes, i + 2 < end, buf[i + 1] == c, buf[i + 2] == c {
                    let (q, closed) = skipBlock(i + 3, closer: [c, c, c])
                    emit?(i, q - i, .string); i = q; if !closed { state = c == 0x22 ? ScanState.tripleDouble : ScanState.tripleSingle }
                    continue
                }
                if c == 0x60, spec.backtickMultiline {
                    let (q, closed) = skipTemplate(i + 1)
                    emit?(i, q - i, .string); i = q; if !closed { state = ScanState.backtick }
                    continue
                }
                if c == 0x27, spec.rustChars {
                    // 'x' / '\n' / '\u{..}' is a char literal; 'a (no closing quote right after) is a lifetime.
                    var q = i + 1
                    if q < end, buf[q] == 0x5C { q += 2; while q < end, buf[q] != 0x27, buf[q] != 0x0A, q - i < 12 { q += 1 } }
                    else if q < end { q += 1 }
                    if q < end, buf[q] == 0x27 { emit?(i, q + 1 - i, .string); i = q + 1; continue }
                    var r = i + 1; while r < end, isIdentPart(buf[r]) { r += 1 }
                    emit?(i, r - i, .type); i = max(r, i + 1); continue
                }
                var q = i + 1
                while q < end {
                    let d = buf[q]
                    if d == 0x5C { q += 2; continue }
                    if d == c { q += 1; break }
                    if d == 0x0A { break }
                    q += 1
                }
                q = min(q, end)
                var kind = TokenKind.string
                if spec.jsonKeys {
                    var r = q; while r < end, buf[r] == 0x20 || buf[r] == 0x09 { r += 1 }
                    if r < end, buf[r] == 0x3A { kind = .key }
                } else if spec.yamlKeys {
                    var r = q; while r < end, buf[r] == 0x20 { r += 1 }
                    if r < end, buf[r] == 0x3A, atLineStart || true { kind = .key }
                }
                emit?(i, q - i, kind); i = q; continue
            }
            // Numbers.
            if isDigit(c) || (c == 0x2E && i + 1 < end && isDigit(buf[i + 1]) && !spec.cssProps) {
                var q = i + 1
                while q < end {
                    let d = buf[q]
                    if isIdentPart(d) || d == 0x2E { q += 1; if (d == 0x65 || d == 0x45), q < end, buf[q] == 0x2D || buf[q] == 0x2B { q += 1 } }
                    else { break }
                }
                emit?(i, q - i, .number); i = q; continue
            }
            // Variables, decorators, css.
            if spec.shellVars, c == 0x24 {
                var q = i + 1
                if q < end, buf[q] == 0x7B { while q < end, buf[q] != 0x7D, buf[q] != 0x0A { q += 1 }; q = min(q + 1, end) }
                else { while q < end, isIdentPart(buf[q]) || buf[q] == 0x40 || buf[q] == 0x3F || buf[q] == 0x2A { q += 1 } }
                if q > i + 1 { emit?(i, q - i, .variable); i = q; continue }
            }
            if spec.atWords, c == 0x40 {
                var q = i + 1; while q < end, isIdentPart(buf[q]) || buf[q] == 0x2D { q += 1 }
                if q > i + 1 { emit?(i, q - i, spec.cssProps ? .keyword : .attribute); i = q; continue }
            }
            if spec.cssProps {
                if c == 0x23 { var q = i + 1; while q < end, isIdentPart(buf[q]) || buf[q] == 0x2D { q += 1 }; emit?(i, q - i, .constant); i = q; continue }
                if c == 0x2E, i + 1 < end, isIdentStart(buf[i + 1]) { var q = i + 1; while q < end, isIdentPart(buf[q]) || buf[q] == 0x2D { q += 1 }; emit?(i, q - i, .type); i = q; continue }
            }
            // Identifiers.
            if isIdentStart(c) {
                var q = i + 1
                while q < end, isIdentPart(buf[q]) || (spec.cssProps && buf[q] == 0x2D) || (spec.yamlKeys && (buf[q] == 0x2D || buf[q] == 0x2E)) { q += 1 }
                if let emit {
                    let kind = classify(buf, i, q, end, spec)
                    if kind != .plain { emit(i, q - i, kind) }
                }
                i = q; continue
            }
            if c == 0x2D, spec.cssProps || spec.yamlKeys { // --custom-prop / - list item
                var q = i + 1; while q < end, isIdentPart(buf[q]) || buf[q] == 0x2D { q += 1 }
                if spec.cssProps, q > i + 1 { emit?(i, q - i, .key); i = q; continue }
            }
            // Bracket pairs, coloured by nesting depth (Monaco's bracketPairColorization).
            if c == 0x28 || c == 0x5B || c == 0x7B { emit?(i, 1, TokenKind(rawValue: TokenKind.bracket1.rawValue + UInt8(depth % 3))!); depth += 1 }
            else if c == 0x29 || c == 0x5D || c == 0x7D { depth = max(0, depth - 1); emit?(i, 1, TokenKind(rawValue: TokenKind.bracket1.rawValue + UInt8(depth % 3))!) }
            i += 1
        }
        return state | (depth << 8)
    }

    private static func classify(_ buf: UnsafeBufferPointer<UInt16>, _ s: Int, _ e: Int, _ end: Int, _ spec: LangSpec) -> TokenKind {
        let len = e - s
        if len > 24 { return .plain }
        var word = String(utf16CodeUnits: buf.baseAddress! + s, count: len)
        if spec.caseInsensitiveKeywords { word = word.lowercased() }
        if spec.keywords.contains(word) { return .keyword }
        if spec.constants.contains(word) { return .constant }
        if spec.types.contains(word) { return .type }
        if spec.cssProps {
            var r = e; while r < end, buf[r] == 0x20 { r += 1 }
            if r < end, buf[r] == 0x3A { return .key }
            return .plain
        }
        if spec.yamlKeys {
            var r = e; while r < end, buf[r] == 0x20 { r += 1 }
            if r < end, buf[r] == 0x3A { return .key }
            if r < end, buf[r] == 0x3D { return .key }
            return .plain
        }
        if spec.capitalizedAreTypes, let f = buf[s] as UInt16?, f >= 0x41, f <= 0x5A, len > 1 { return .type }
        return .plain
    }

    // MARK: Markup (HTML / XML / SVG)

    private static func scanMarkup(_ buf: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, _ initial: Int, _ emit: Emit?) -> Int {
        var state = initial
        var i = start
        func starts(_ s: StaticString, _ p: Int) -> Bool {
            let n = s.utf8CodeUnitCount
            if p + n > end { return false }
            return s.withUTF8Buffer { b in (0 ..< n).allSatisfy { buf[p + $0] == UInt16(b[$0]) } }
        }
        if state == ScanState.htmlComment {
            var q = i; var closed = false
            while q < end { if buf[q] == 0x2D, starts("-->", q) { q += 3; closed = true; break }; q += 1 }
            emit?(i, q - i, .comment); i = q; if closed { state = 0 }
        }
        while i < end {
            let c = buf[i]
            if state == ScanState.htmlTag || c == 0x3C {
                if state != ScanState.htmlTag {
                    if starts("<!--", i) {
                        var q = i + 4; var closed = false
                        while q < end { if buf[q] == 0x2D, starts("-->", q) { q += 3; closed = true; break }; q += 1 }
                        emit?(i, q - i, .comment); i = q; if !closed { state = ScanState.htmlComment }
                        continue
                    }
                    var q = i + 1; if q < end, buf[q] == 0x2F || buf[q] == 0x21 || buf[q] == 0x3F { q += 1 }
                    while q < end, isIdentPart(buf[q]) || buf[q] == 0x2D || buf[q] == 0x3A || buf[q] == 0x2E { q += 1 }
                    emit?(i, q - i, .tag); i = q; state = ScanState.htmlTag
                    continue
                }
                // inside a tag: attributes, strings, end
                if c == 0x3E { emit?(i, 1, .tag); i += 1; state = 0; continue }
                if c == 0x2F, i + 1 < end, buf[i + 1] == 0x3E { emit?(i, 2, .tag); i += 2; state = 0; continue }
                if c == 0x22 || c == 0x27 {
                    var q = i + 1; while q < end, buf[q] != c { q += 1 }; q = min(q + 1, end)
                    emit?(i, q - i, .string); i = q; continue
                }
                if isIdentStart(c) {
                    var q = i + 1; while q < end, isIdentPart(buf[q]) || buf[q] == 0x2D || buf[q] == 0x3A || buf[q] == 0x2E || buf[q] == 0x40 { q += 1 }
                    emit?(i, q - i, .attribute); i = q; continue
                }
                i += 1; continue
            }
            if c == 0x26 { // &entity;
                var q = i + 1; while q < end, q - i < 10, buf[q] != 0x3B, buf[q] != 0x20, buf[q] != 0x0A { q += 1 }
                if q < end, buf[q] == 0x3B { emit?(i, q + 1 - i, .constant); i = q + 1; continue }
            }
            i += 1
        }
        return state
    }

    // MARK: Markdown

    private static func scanMarkdown(_ buf: UnsafeBufferPointer<UInt16>, _ start: Int, _ end: Int, _ initial: Int, _ emit: Emit?) -> Int {
        var state = initial
        var i = start
        while i < end {
            var le = i; while le < end, buf[le] != 0x0A { le += 1 }
            // [i, le) is one line
            var p = i; while p < le, buf[p] == 0x20 { p += 1 }
            let isFence = p + 2 < le + 0 && ((buf[p] == 0x60 && buf[p + 1] == 0x60 && buf[p + 2] == 0x60) || (buf[p] == 0x7E && buf[p + 1] == 0x7E && buf[p + 2] == 0x7E))
            if isFence {
                emit?(i, le - i, .comment); state = state == ScanState.mdFence ? 0 : ScanState.mdFence
            } else if state == ScanState.mdFence {
                emit?(i, le - i, .string)
            } else if p < le {
                let c = buf[p]
                if c == 0x23 { var h = p; while h < le, buf[h] == 0x23 { h += 1 }; if h < le, buf[h] == 0x20 { emit?(p, le - p, .heading) } }
                else if c == 0x3E { emit?(p, le - p, .comment) }
                else if (c == 0x2D || c == 0x2A || c == 0x2B), p + 1 < le, buf[p + 1] == 0x20 { emit?(p, 1, .keyword) }
                else if isDigit(c) {
                    var d = p; while d < le, isDigit(buf[d]) { d += 1 }
                    if d < le, buf[d] == 0x2E, d + 1 < le, buf[d + 1] == 0x20 { emit?(p, d + 1 - p, .keyword) }
                }
                if let emit {
                    // inline `code`
                    var q = p
                    while q < le {
                        if buf[q] == 0x60 { var r = q + 1; while r < le, buf[r] != 0x60 { r += 1 }; if r < le { emit(q, r + 1 - q, .string); q = r + 1; continue } }
                        q += 1
                    }
                }
            }
            i = le + 1
        }
        return state
    }
}

/// Scanner state at every `stride`-th line start, so a window anywhere in a big file can start close to itself.
/// `build` is one pass over the text (state tracking only, ~hundreds of MB/s); an edit invalidates everything after it.
public struct Checkpoints {
    public static let stride = 256
    /// (UTF-16 offset of a line start, scanner state there, 1-based line number) for every `stride`-th line; entry 0 is always (0, 0, 1).
    /// The line number is stored, not derived: an edit shifts the entries after it instead of dropping them (see `shift`).
    public private(set) var entries: [(offset: Int, state: Int, line: Int)] = [(0, 0, 1)]
    /// Everything up to and including this entry index is valid.
    public private(set) var validThrough = 0
    /// The pass reached the end of the text (nothing after the last entry is unknown).
    public private(set) var isComplete = false
    /// Lines in the text (exact right after a finished pass, kept in step by `shift`).
    public private(set) var totalLines = 1

    public init() {}

    public static func build(_ buf: UnsafeBufferPointer<UInt16>, language: SyntaxLanguage, isCancelled: () -> Bool = { false }) -> Checkpoints {
        var cp = Checkpoints()
        cp.extend(buf, language: language, isCancelled: isCancelled)
        return cp
    }

    /// Continues the pass from the last valid entry to the end of the text.
    public mutating func extend(_ buf: UnsafeBufferPointer<UInt16>, language: SyntaxLanguage, isCancelled: () -> Bool = { false }) {
        entries.removeSubrange((validThrough + 1)...)
        var offset = entries[validThrough].offset, state = entries[validThrough].state, line = entries[validThrough].line
        let n = buf.count
        while offset < n {
            if isCancelled() { isComplete = false; return }
            var lines = 0, q = offset
            while q < n, lines < Checkpoints.stride { if buf[q] == 0x0A { lines += 1 }; q += 1 }
            state = SyntaxScanner.scan(buf, from: offset, to: q, language: language, state: state, emit: nil)
            offset = q; line += lines
            if lines == Checkpoints.stride, offset < n { entries.append((offset, state, line)); validThrough = entries.count - 1 }
            else { break }
        }
        validThrough = entries.count - 1
        totalLines = line
        isComplete = true
    }

    /// The nearest valid checkpoint at or before `location`.
    public func nearest(before location: Int) -> (offset: Int, state: Int) { let e = entries[nearestIndex(before: location)]; return (e.offset, e.state) }

    public func nearestIndex(before location: Int) -> Int {
        var lo = 0, hi = validThrough
        while lo < hi { let mid = (lo + hi + 1) / 2; if entries[mid].offset <= location { lo = mid } else { hi = mid - 1 } }
        return lo
    }

    /// Index of the last checkpoint that starts at or before 1-based `line`.
    public func nearestIndex(beforeLine line: Int) -> Int {
        var lo = 0, hi = validThrough
        while lo < hi { let mid = (lo + hi + 1) / 2; if entries[mid].line <= line { lo = mid } else { hi = mid - 1 } }
        return lo
    }

    /// An edit at `location` invalidates every checkpoint that starts after it.
    public mutating func invalidate(from location: Int) {
        var keep = 0
        while keep + 1 <= validThrough, entries[keep + 1].offset <= location { keep += 1 }
        validThrough = keep
        isComplete = false
        entries.removeSubrange((keep + 1)...)
    }

    /// An edit at `location` changed the text length by `delta` UTF-16 units and the line count by `lineDelta`: the checkpoints after
    /// it move with the text, so line numbers and window highlighting stay O(one window) while a background pass recomputes the
    /// states. (A state after the edit can be wrong until that pass ends, e.g. when the edit opened a comment.)
    public mutating func shift(after location: Int, by delta: Int, lines lineDelta: Int) {
        for i in entries.indices where entries[i].offset > location {
            entries[i].offset = max(location, entries[i].offset + delta)
            entries[i].line = max(1, entries[i].line + lineDelta)
        }
        totalLines = max(1, totalLines + lineDelta)
    }
}
