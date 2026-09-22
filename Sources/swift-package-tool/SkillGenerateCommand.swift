import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// generate a hermes skill that packages a swift package's documented public
/// api surface into a `SKILL.md` tree an agent can load.
///
/// everything is derived from the package source at call time — public
/// declarations and their docc comments (via the same collector `api` uses),
/// plus the `.docc` catalog articles — so the output is deterministic and
/// stateless: no build, no cache, no timestamps, and identical inputs produce
/// byte-identical trees. this is the "embedded digest" mode; `--reference` is
/// reserved for a future thin live-query variant.
struct SkillGenerateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill-generate",
        abstract: "Generate a Hermes skill from a package's documented API."
    )

    @Argument(help: "Package paths to scan (directory or .swift file).")
    var paths: [String] = ["."]

    @Option(name: .customLong("output-dir"), help: "Directory for the generated skill tree (default: <root>/.build/skills/<name>).")
    var outputDirOverride: String?

    @Flag(name: .customLong("install"), help: "Install the skill into the hermes skills dir.")
    var install = false

    @Option(name: .customLong("category"), help: "Category for --install (default: swift).")
    var category: String = "swift"

    @Option(name: .customLong("hermes-skills"), help: "Hermes skills directory for --install (default: ~/.hermes/skills).")
    var hermesSkillsDirOverride: String?

    @Option(name: .customLong("name"), help: "Override the derived skill name.")
    var nameOverride: String?

    @Option(name: .customLong("version"), help: "Frontmatter version (default: 0.1.0).")
    var skillVersion: String = "0.1.0"

    @Option(name: .customLong("author"), help: "Frontmatter author (default: Hermes Agent).")
    var author: String = "Hermes Agent"

    @Flag(name: .customLong("include-internal"), inversion: .prefixedNo, help: "Include internal declarations (default: public only).")
    var includeInternal = false

    @Flag(name: .customLong("reference"), help: "Reserved: thin live-query skill mode, not yet implemented.")
    var referenceMode = false

    @Option(name: .long, help: "Output format: json, compact, csv, short, jsonl.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Option(name: .customLong("output"), help: "Write the summary to a file instead of stdout.")
    var outputPath: String = ""

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(SkillSummary.jsonSchema)
            return
        }
        if referenceMode {
            throw ValidationError("--reference is reserved (thin live-query skill mode is not yet implemented); the embedded digest is the only mode today.")
        }
        guard let rootRaw = paths.first, !rootRaw.isEmpty else {
            throw ValidationError("missing package path")
        }
        if isStdinPath(rootRaw) {
            throw ValidationError("skill-generate requires a directory path, not stdin")
        }
        try validateInputPathsExist(paths)

        let files = collectSwiftFiles(from: paths)
        let searchRoot = directoryRoot(of: rootRaw)
        let packageName = resolvePackageName(from: searchRoot)
            ?? URL(fileURLWithPath: searchRoot).lastPathComponent
        let skillName = try resolveSkillName(packageName, override: nameOverride)
        let description = skillDescription(packageName: packageName)

        // 1. flat public surface (reuses the `api` collector), with each
        //    symbol's enclosing-type path attached via a secondary walk.
        var symbols: [SkillSymbol] = []
        for file in files {
            guard let source = readSwiftSource(file) else { continue }
            let tree = Parser.parse(source: source)
            let api = ApiCollector(filePath: file, source: source, includeInternal: includeInternal)
            api.walk(tree)
            let contexts = EnclosingContextCollector(source: source)
            contexts.walk(tree)
            for item in api.items {
                let doc = normalizeDoc(item.docComment)
                symbols.append(SkillSymbol(
                    name: item.name,
                    kind: item.kind,
                    access: item.access,
                    file: relativePath(item.file, from: searchRoot),
                    line: item.line,
                    signature: item.signature,
                    conformsTo: item.conformsTo,
                    abstract: doc.abstract,
                    remainder: doc.remainder,
                    context: contexts.contexts[item.line] ?? []
                ))
            }
        }
        symbols.sort { ($0.kind, $0.name) < ($1.kind, $1.name) }

        // 2. fold the `.docc` catalog articles (directive-stripped).
        let articles = findDoccArticles(from: searchRoot).compactMap { path -> SkillArticle? in
            guard let text = readSwiftSource(path) else { return nil }
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return SkillArticle(name: name, markdown: normalizeArticle(text))
        }
        let pitfalls = extractCallouts(from: articles)

        // 3. render the tree.
        let digest = renderApiDigest(packageName: packageName, symbols: symbols)
        let skillMarkdown = renderSkillMarkdown(
            packageName: packageName,
            skillName: skillName,
            description: description,
            version: skillVersion,
            author: author,
            symbols: symbols,
            articles: articles,
            pitfalls: pitfalls
        )

        let skillDir: String
        if let explicit = outputDirOverride, !explicit.isEmpty {
            skillDir = explicit
        } else {
            skillDir = "\(searchRoot)/.build/skills/\(skillName)"
        }

        var writtenFiles: [String] = ["SKILL.md", "references/api.md"]
        try FileManager.default.createDirectory(atPath: "\(skillDir)/references", withIntermediateDirectories: true)
        if !articles.isEmpty {
            try FileManager.default.createDirectory(atPath: "\(skillDir)/references/articles", withIntermediateDirectories: true)
        }
        try skillMarkdown.write(toFile: "\(skillDir)/SKILL.md", atomically: true, encoding: .utf8)
        try digest.write(toFile: "\(skillDir)/references/api.md", atomically: true, encoding: .utf8)
        for article in articles {
            let rel = "references/articles/\(article.name).md"
            writtenFiles.append(rel)
            try article.markdown.write(toFile: "\(skillDir)/\(rel)", atomically: true, encoding: .utf8)
        }

        // 4. optional install into the hermes skills tree.
        var installedTo = ""
        if install {
            let skillsDir = hermesSkillsDirOverride
                ?? ProcessInfo.processInfo.environment["HERMES_SKILLS_DIR"]
                ?? "\(PathWirer.homeDir())/.hermes/skills"
            let dest = "\(skillsDir)/\(category)/\(skillName)"
            if (dest as NSString).standardizingPath != (skillDir as NSString).standardizingPath {
                if FileManager.default.fileExists(atPath: dest) {
                    try FileManager.default.removeItem(atPath: dest)
                }
                try FileManager.default.createDirectory(
                    atPath: URL(fileURLWithPath: dest).deletingLastPathComponent().path,
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(atPath: skillDir, toPath: dest)
            }
            installedTo = dest
        }

        // 5. emit the summary (compact JSON by default, per the agent contract).
        let documented = symbols.filter { !$0.abstract.isEmpty }.count
        let summary = SkillSummary(
            ok: true,
            skillName: skillName,
            skillDir: skillDir,
            installedTo: installedTo,
            summaryDescription: description,
            symbols: symbols.count,
            documented: documented,
            undocumented: symbols.count - documented,
            kinds: kindCounts(symbols),
            articles: articles.map(\.name),
            files: writtenFiles
        )
        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let out = try emitSummary(summary, format: fmt)
        try writeOutput(out, to: outputPath)
    }
}

// MARK: - models

/// one public (or internal, with --include-internal) declaration on the
/// package's surface, with its normalized doc abstract and enclosing path.
struct SkillSymbol {
    let name: String
    let kind: String
    let access: String
    let file: String
    let line: Int
    let signature: String
    let conformsTo: [String]
    let abstract: String
    let remainder: String
    let context: [String]
}

/// a folded `.docc` catalog article.
struct SkillArticle {
    let name: String
    let markdown: String
}

/// the agent-facing result payload.
struct SkillSummary: Codable, Sendable, CustomStringConvertible {
    let ok: Bool
    let skillName: String
    let skillDir: String
    let installedTo: String
    let summaryDescription: String
    let symbols: Int
    let documented: Int
    let undocumented: Int
    let kinds: [String: Int]
    let articles: [String]
    let files: [String]

    enum CodingKeys: String, CodingKey {
        case ok, skillName, skillDir, installedTo, symbols, documented, undocumented, kinds, articles, files
        case summaryDescription = "description"
    }

    var description: String {
        "\(skillName) — \(summaryDescription) (\(symbols) symbols)"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "SkillSummary",
      "type": "object",
      "properties": {
        "ok":           { "type": "boolean", "description": "Always true on success" },
        "skillName":    { "type": "string", "description": "Generated skill name" },
        "skillDir":     { "type": "string", "description": "Directory holding the generated skill tree" },
        "installedTo":  { "type": "string", "description": "Install destination when --install was given" },
        "description":  { "type": "string", "description": "Frontmatter description (<=60 chars, ends with a period)" },
        "symbols":      { "type": "integer", "description": "Total symbols captured" },
        "documented":   { "type": "integer", "description": "Symbols with a non-empty abstract" },
        "undocumented": { "type": "integer", "description": "Symbols without a doc comment" },
        "kinds":        { "type": "object", "description": "Symbol counts by declaration kind" },
        "articles":     { "type": "array", "items": { "type": "string" }, "description": "Folded .docc article names" },
        "files":        { "type": "array", "items": { "type": "string" }, "description": "Files written, relative to skillDir" }
      },
      "required": ["ok", "skillName", "skillDir", "installedTo", "description", "symbols", "documented", "undocumented", "kinds", "articles", "files"]
    }
    """
}

// MARK: - enclosing-type attribution

/// records, for every declaration the api collector captures, the path of
/// enclosing type names. joined to the flat pass on (file, line), which is
/// unique per declaration within a file.
final class EnclosingContextCollector: SyntaxVisitor {
    let source: String
    private var stack: [String] = []
    private(set) var contexts: [Int: [String]] = [:]

    init(source: String) {
        self.source = source
        super.init(viewMode: .sourceAccurate)
    }

    private func record(_ node: some DeclSyntaxProtocol) {
        let (line, _) = lineColumn(at: node.position.utf8Offset, in: source)
        contexts[line] = stack
    }

    private func enter(_ node: some DeclSyntaxProtocol, name: String) -> SyntaxVisitorContinueKind {
        record(node)
        stack.append(name)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, name: node.name.text)
    }
    override func visitPost(_ node: StructDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, name: node.name.text)
    }
    override func visitPost(_ node: ClassDeclSyntax) { stack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, name: node.name.text)
    }
    override func visitPost(_ node: EnumDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, name: node.name.text)
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { stack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        enter(node, name: node.extendedType.description.trimmingCharacters(in: .whitespaces))
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { stack.removeLast() }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { record(node); return .visitChildren }
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind { record(node); return .visitChildren }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { record(node); return .visitChildren }
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind { record(node); return .visitChildren }
    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind { record(node); return .visitChildren }
    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind { record(node); return .visitChildren }
}

// MARK: - digest renderer

let skillTypeKinds: Set<String> = ["struct", "class", "enum", "protocol"]
let skillMemberOrder = ["struct", "class", "enum", "protocol", "variable", "subscript", "initializer", "deinitializer", "function", "associatedtype", "typealias", "macro", "operator", "precedencegroup"]

func skillMemberRank(_ kind: String) -> Int {
    skillMemberOrder.firstIndex(of: kind) ?? 99
}

func isTypeKind(_ kind: String) -> Bool {
    skillTypeKinds.contains(kind)
}

func skillMemberSort(_ a: SkillSymbol, _ b: SkillSymbol) -> Bool {
    let ra = skillMemberRank(a.kind)
    let rb = skillMemberRank(b.kind)
    if ra != rb { return ra < rb }
    return a.name < b.name
}

/// the full public-api digest, nested by enclosing type. deterministic: every
/// symbol appears exactly once, ordering is fixed, and no timestamps appear.
func renderApiDigest(packageName: String, symbols: [SkillSymbol]) -> String {
    let documented = symbols.filter { !$0.abstract.isEmpty }.count
    var out = "# \(packageName) public API\n\n"
    out += "deterministic digest of the public surface, generated from source doc comments and the `.docc` catalog. \(documented) of \(symbols.count) symbols carry a doc comment; symbols without an abstract are listed but undocumented — confirm their behavior from the package source before relying on them.\n"

    // group non-top-level symbols by their enclosing path so type members can
    // be nested under their type. a control char joins the path (identifiers
    // cannot contain it, so the key is unambiguous).
    let sep = "\u{0}"
    var groups: [String: [SkillSymbol]] = [:]
    for s in symbols where !s.context.isEmpty {
        let key = s.context.joined(separator: sep)
        groups[key, default: []].append(s)
    }
    for key in groups.keys {
        groups[key]?.sort(by: skillMemberSort)
    }
    var consumed: Set<String> = []

    func contextKey(_ context: [String], _ name: String) -> String {
        context.isEmpty ? name : context.joined(separator: sep) + sep + name
    }

    func renderItem(_ item: SkillSymbol, depth: Int) -> String {
        var blocks = [symbolBlock(item, level: min(depth + 2, 6))]
        if isTypeKind(item.kind) {
            let childKey = contextKey(item.context, item.name)
            if let members = groups[childKey] {
                consumed.insert(childKey)
                for member in members {
                    blocks.append(renderItem(member, depth: depth + 1))
                }
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    // top-level types first (struct, class, enum, protocol order).
    let topTypes = symbols
        .filter { $0.context.isEmpty && isTypeKind($0.kind) }
        .sorted(by: skillMemberSort)
    var typeBlocks: [String] = []
    for t in topTypes {
        typeBlocks.append(renderItem(t, depth: 0))
    }
    if !typeBlocks.isEmpty {
        out += "\n" + typeBlocks.joined(separator: "\n\n")
    }

    // remaining top-level symbols, grouped into kind sections.
    let topOthers = symbols.filter { $0.context.isEmpty && !isTypeKind($0.kind) }
    var sections: [(String, [SkillSymbol])] = []
    var seenKinds = Set<String>()
    for kind in skillMemberOrder where topOthers.contains(where: { $0.kind == kind }) {
        sections.append((kind, topOthers.filter { $0.kind == kind }))
        seenKinds.insert(kind)
    }
    for kind in topOthers.map(\.kind).filter({ !seenKinds.contains($0) }) {
        sections.append((kind, topOthers.filter { $0.kind == kind }))
    }
    for (kind, items) in sections {
        out += "\n## \(pluralizeKind(kind))\n\n"
        out += items.map { symbolBlock($0, level: 3) }.joined(separator: "\n\n")
    }

    // leftover member groups whose parent type is not in the digest (e.g. an
    // extension on a stdlib type) — rendered under their own section.
    let leftover = groups.keys.filter { !consumed.contains($0) }.sorted()
    for key in leftover {
        out += "\n## Members of \(key.replacingOccurrences(of: sep, with: "."))\n\n"
        out += (groups[key] ?? []).map { symbolBlock($0, level: 3) }.joined(separator: "\n\n")
    }

    return out
}

/// one symbol's markdown block: heading, provenance, conformances, abstract,
/// and any remaining doc paragraphs as a blockquote. no leading or trailing
/// blank lines — callers join blocks with `\n\n`.
func symbolBlock(_ item: SkillSymbol, level: Int) -> String {
    let hash = String(repeating: "#", count: level)
    let access = (item.access == "public" || item.access == "open" || item.access == "package") ? "\(item.access) " : ""
    var parts: [String] = []
    parts.append("\(hash) `\(access)\(item.signature)`")
    parts.append("source: `\(item.file):\(item.line)`")
    if !item.conformsTo.isEmpty {
        parts.append("conforms: \(item.conformsTo.map { "`\($0)`" }.joined(separator: ", "))")
    }
    if !item.abstract.isEmpty {
        parts.append(item.abstract)
    }
    if !item.remainder.isEmpty {
        parts.append(item.remainder
            .components(separatedBy: "\n")
            .map { "> \($0)" }
            .joined(separator: "\n"))
    }
    return parts.joined(separator: "\n\n")
}

func pluralizeKind(_ kind: String) -> String {
    switch kind {
    case "function": return "Functions"
    case "variable": return "Variables"
    case "typealias": return "Type Aliases"
    case "associatedtype": return "Associated Types"
    case "subscript": return "Subscripts"
    case "initializer": return "Initializers"
    case "deinitializer": return "Deinitializers"
    case "operator": return "Operators"
    case "precedencegroup": return "Precedence Groups"
    case "macro": return "Macros"
    case "extension": return "Extensions"
    default: return "\(kind.capitalized)s"
    }
}

// MARK: - SKILL.md renderer

/// the hermes skill document. frontmatter honors the authoring contract:
/// `name` lowercase-hyphen ≤64, `description` ≤60 chars ending in a period,
/// semver `version`, `platforms` audited to what the content actually needs.
func renderSkillMarkdown(
    packageName: String,
    skillName: String,
    description: String,
    version: String,
    author: String,
    symbols: [SkillSymbol],
    articles: [SkillArticle],
    pitfalls: [String]
) -> String {
    let countable = kindSummaryLine(symbols)
    let articleLines = articles.isEmpty
        ? ["- none — the package ships no `.docc` catalog articles."]
        : articles.map { "- `\($0.name)` — references/articles/\($0.name).md" }
    let pitfallLines = pitfalls.isEmpty
        ? ["- this skill is a reference — it encodes no package-specific pitfalls."]
        : pitfalls.map(calloutToBullet)

    var out = ""
    out += "---\n"
    out += "name: \(skillName)\n"
    out += "description: \(description)\n"
    out += "version: \(version)\n"
    out += "author: \(author)\n"
    out += "license: MIT\n"
    out += "platforms: [macos, linux]\n"
    out += "metadata:\n"
    out += "  hermes:\n"
    out += "    tags: [swift, \(slugify(packageName)), api, reference]\n"
    out += "    related_skills: []\n"
    out += "---\n\n"
    out += "# \(packageName) API Skill\n\n"
    out += "a packaged, deterministic reference to the \(packageName) public API, generated from the package's own source doc comments and `.docc` catalog. consult this skill when writing code against \(packageName) or answering questions about its public surface — signatures, contracts, and conformances. it carries no implementation detail and no private API.\n\n"

    out += "## When to Use\n"
    out += "- answering questions about \(packageName)'s public API — signatures, parameters, conformances\n"
    out += "- writing code against \(packageName): choosing a type, checking a call shape\n"
    out += "- confirming whether a symbol is public and what its documentation says\n"
    out += "- Don't use for: implementation internals, build/test issues, private API\n\n"

    out += "## Prerequisites\n"
    out += "- none for reading — the full digest ships inside this skill\n\n"

    out += "## How to Consult\n"
    out += "- full digest: read_file `references/api.md`\n"
    out += "- symbol lookup: search_files pattern `<Symbol>` in `references/api.md`\n"
    out += "- catalog articles (below) carry the package's own prose\n\n"

    out += "## Procedure\n"
    out += "1. search `references/api.md` for the symbol you need\n"
    out += "2. read its signature, abstract, conformances, and source location\n"
    out += "3. if a symbol has no abstract, treat it as undocumented — confirm its behavior from the package source before relying on it\n\n"

    out += "## Pitfalls\n"
    out += pitfallLines.joined(separator: "\n") + "\n\n"

    out += "## Articles\n"
    out += articleLines.joined(separator: "\n") + "\n\n"

    out += "## Verification\n"
    out += "generated summary:\n"
    out += "- \(symbols.count) public symbols, \(symbols.filter { !$0.abstract.isEmpty }.count) documented, \(symbols.filter { $0.abstract.isEmpty }.count) undocumented\n"
    out += "- \(countable)\n"
    out += "- regenerate with `swift-package-tool skill-generate .` after API changes\n"
    return out
}

/// `> Important: widgets must be spun.` -> `- **Important:** widgets must be spun.`
func calloutToBullet(_ line: String) -> String {
    var s = line.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix(">") {
        s.removeFirst()
        if s.hasPrefix(" ") { s.removeFirst() }
    }
    if let colon = s.firstIndex(of: ":") {
        let label = s[..<colon]
        let rest = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return "- **\(label):** \(rest)"
    }
    return "- \(s)"
}

func kindSummaryLine(_ symbols: [SkillSymbol]) -> String {
    var counts: [String: Int] = [:]
    for s in symbols { counts[s.kind, default: 0] += 1 }
    let parts = counts.keys.sorted { skillMemberRank($0) < skillMemberRank($1) }
        .map { "\($0) \(counts[$0] ?? 0)" }
    return "kinds: \(parts.joined(separator: ", "))"
}

// MARK: - naming

/// package name -> skill name: lowercase, hyphens, capped at 64 with a
/// meaningful `-api` suffix.
func sanitizeSkillName(_ raw: String) -> String {
    var out = ""
    var pendingDash = false
    for ch in raw.lowercased() {
        if ch.isLetter || ch.isNumber {
            if pendingDash, !out.isEmpty { out.append("-") }
            pendingDash = false
            out.append(ch)
        } else {
            pendingDash = true
        }
    }
    if out.isEmpty { return "swift-package-api" }
    if out.count > 64 {
        out = String(out.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        out += "-api"
    }
    return out
}

func slugify(_ raw: String) -> String {
    let slug = sanitizeSkillName(raw)
    if slug.hasSuffix("-api") { return String(slug.dropLast(4)) }
    return slug
}

func resolveSkillName(_ packageName: String, override nameOverride: String?) throws -> String {
    if let override = nameOverride, !override.isEmpty {
        let valid = override.count <= 64
            && !override.hasPrefix("-")
            && !override.hasSuffix("-")
            && override.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
        guard valid else {
            throw ValidationError("invalid --name '\(override)' — use lowercase letters, digits, hyphens, ≤64 chars.")
        }
        return override
    }
    return sanitizeSkillName(packageName + "-api")
}

/// description must fit hermes' 60-char hard cap and end with a period.
/// deterministic: try the package-specific candidate, fall back to a fixed
/// always-safe line.
func skillDescription(packageName: String) -> String {
    let candidate = "\(packageName) public API — signatures, contracts and usage for agents."
    if candidate.count <= 60 { return candidate }
    return "Swift package public API reference for agent use."
}

// MARK: - doc normalization

/// strip doc-comment markers from a raw trivia line and return clean text.
private func stripDocMarker(_ line: String) -> String {
    var s = line
    if s.hasPrefix("///") {
        s.removeFirst(3)
    } else if s.hasPrefix("/**") {
        s.removeFirst(3)
    } else if s.hasPrefix("/*") {
        s.removeFirst(2)
    } else if s.hasPrefix("//") {
        s.removeFirst(2)
    }
    if s.hasPrefix(" ") { s.removeFirst() }
    var t = s.trimmingCharacters(in: .whitespaces)
    if t == "*/" || t == "*" { return "" }
    if t.hasPrefix("*") {
        t = String(t.dropFirst())
        if t.hasPrefix(" ") { t.removeFirst() }
    } else if t.hasSuffix("*/") {
        t = String(t.dropLast(2)).trimmingCharacters(in: .whitespaces)
    }
    return t
}

/// split a raw doc comment into (first-paragraph abstract, remainder), with
/// markers stripped, blank runs collapsed, and double backticks normalized.
func normalizeDoc(_ raw: String) -> (abstract: String, remainder: String) {
    var lines: [String] = []
    var blankRun = false
    for line in raw.components(separatedBy: "\n") {
        let stripped = stripDocMarker(line)
        if stripped.trimmingCharacters(in: .whitespaces).isEmpty {
            if !blankRun { lines.append("") }
            blankRun = true
        } else {
            lines.append(stripped)
            blankRun = false
        }
    }
    while let first = lines.first, first.isEmpty { lines.removeFirst() }
    while let last = lines.last, last.isEmpty { lines.removeLast() }
    let text = lines.joined(separator: "\n")
    guard !text.isEmpty else { return ("", "") }

    var paragraphs = text.components(separatedBy: "\n\n")
    let abstract = paragraphs.removeFirst()
    let remainder = paragraphs.joined(separator: "\n\n")
    return (normalizeBackticks(abstract), normalizeBackticks(remainder))
}

// MARK: - .docc catalog folding

/// find `*.md` files inside any `*.docc` directory under the scan root.
func findDoccArticles(from root: String) -> [String] {
    var results: [String] = []
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: root, isDirectory: true),
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else { return [] }
    for case let url as URL in enumerator {
        if url.lastPathComponent == ".build" || url.lastPathComponent == ".git" {
            enumerator.skipDescendants()
            continue
        }
        if url.pathExtension == "md",
           url.deletingLastPathComponent().lastPathComponent.hasSuffix(".docc") {
            results.append(url.path)
        }
    }
    return results.sorted()
}

/// normalize a catalog article for standalone consumption: strip docc
/// directives, flatten double backticks to code voice, resolve `<doc:>`
/// links to bare names, and retitle `# ``X`` ` page headers to plain text.
func normalizeArticle(_ text: String) -> String {
    var result = stripDoccDirectives(text)
    result = normalizePageTitle(normalizeDocLinks(normalizeBackticks(result)))
    return result
}

/// remove docc block directives (`@Metadata { ... }`) and standalone
/// directive tokens. `@Identifier` is only treated as a directive when it
/// starts a line or opens a `{` block, so mid-prose text like `@handle`
/// survives.
func stripDoccDirectives(_ text: String) -> String {
    let chars = Array(text)
    var out: [Character] = []
    var i = 0
    while i < chars.count {
        var isDirective = false
        var blockEnd = -1
        if chars[i] == "@", i + 1 < chars.count, chars[i + 1].isLetter {
            var j = i + 1
            while j < chars.count, chars[j].isLetter || chars[j].isNumber { j += 1 }
            var atLineStart = true
            var k = i - 1
            while k >= 0, chars[k] != "\n" {
                if !chars[k].isWhitespace { atLineStart = false; break }
                k -= 1
            }
            var t = j
            while t < chars.count, chars[t].isWhitespace { t += 1 }
            if atLineStart || (t < chars.count && chars[t] == "{") {
                if t < chars.count, chars[t] == "{" {
                    // consume the whole brace-balanced block
                    var depth = 0
                    var m = t
                    while m < chars.count {
                        if chars[m] == "{" { depth += 1 }
                        else if chars[m] == "}" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                        m += 1
                    }
                    blockEnd = m < chars.count ? m + 1 : chars.count
                } else {
                    // standalone token: drop the identifier, keep the rest
                    // of the line (directive args like `(purple)` are rare).
                    blockEnd = j
                }
                isDirective = true
            }
        }
        if isDirective, blockEnd >= 0 {
            i = blockEnd
            continue
        }
        out.append(chars[i])
        i += 1
    }
    return String(out)
}

/// ` ``X`` ` -> `` `X` ``; unclosed double backticks are left untouched.
func normalizeBackticks(_ text: String) -> String {
    let chars = Array(text)
    var out: [Character] = []
    var i = 0
    while i < chars.count {
        if i + 1 < chars.count, chars[i] == "`", chars[i + 1] == "`" {
            var j = i + 2
            var closed = false
            while j + 1 < chars.count {
                if chars[j] == "`", chars[j + 1] == "`" {
                    out.append("`")
                    out.append(contentsOf: chars[(i + 2)..<j])
                    out.append("`")
                    i = j + 2
                    closed = true
                    break
                }
                j += 1
            }
            if closed { continue }
        }
        out.append(chars[i])
        i += 1
    }
    return String(out)
}

/// `<doc:name>` -> `` `name` `` (doc links never resolve in a standalone skill).
func normalizeDocLinks(_ text: String) -> String {
    let chars = Array(text)
    var out: [Character] = []
    var i = 0
    while i < chars.count {
        if i + 4 < chars.count, chars[i] == "<", chars[i + 1] == "d", chars[i + 2] == "o", chars[i + 3] == "c", chars[i + 4] == ":" {
            var j = i + 5
            while j < chars.count, chars[j] != ">" { j += 1 }
            let target = String(chars[(i + 5)..<min(j, chars.count)])
            out.append("`")
            out.append(contentsOf: target)
            out.append("`")
            i = j < chars.count ? j + 1 : chars.count
            continue
        }
        out.append(chars[i])
        i += 1
    }
    return String(out)
}

/// headings like `# ``Widget`` ` (the docc merged-page title form) become
/// plain `# Widget` once backticks are flattened.
func normalizePageTitle(_ text: String) -> String {
    text.components(separatedBy: "\n").map { line in
        if line.hasPrefix("# "), line.contains("`") {
            return line.replacingOccurrences(of: "`", with: "")
        }
        return line
    }.joined(separator: "\n")
}

// MARK: - callouts

/// pull `> Important:` / `> Note:` / `> Warning:` / `> Caution:` / `> Tip:`
/// callouts out of the folded articles, verbatim, as the skill's pitfalls.
func extractCallouts(from articles: [SkillArticle]) -> [String] {
    let labels = ["> Important:", "> Note:", "> Warning:", "> Caution:", "> Tip:"]
    var found: [String] = []
    for article in articles {
        for line in article.markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if labels.contains(where: { trimmed.hasPrefix($0) }) {
                found.append(trimmed)
            }
        }
    }
    return found
}

// MARK: - path + package helpers

func directoryRoot(of path: String) -> String {
    var isDir: ObjCBool = false
    _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    if isDir.boolValue {
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
    return URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
}

func relativePath(_ path: String, from root: String) -> String {
    let rootPath = (root as NSString).standardizingPath
    let filePath = (path as NSString).standardizingPath
    if rootPath == "/" { return String(filePath.dropFirst(1)) }
    if filePath.hasPrefix(rootPath + "/") {
        return String(filePath.dropFirst(rootPath.count + 1))
    }
    if filePath == rootPath { return (filePath as NSString).lastPathComponent }
    return path
}

/// walk up (bounded) from the scan root for a Package.swift and read its
/// `name:`; nil when none is found, so the caller can fall back to the
/// directory name.
func resolvePackageName(from searchRoot: String) -> String? {
    var dir = searchRoot
    for _ in 0..<8 {
        let manifest = URL(fileURLWithPath: dir).appendingPathComponent("Package.swift").path
        if FileManager.default.fileExists(atPath: manifest),
           let text = try? String(contentsOfFile: manifest, encoding: .utf8),
           let name = parsePackageName(text) {
            return name
        }
        let parent = URL(fileURLWithPath: dir).deletingLastPathComponent().path
        if parent == dir { return nil }
        dir = parent
    }
    return nil
}

func parsePackageName(_ manifest: String) -> String? {
    let pattern = /name\s*:\s*"([^"]+)"/
    guard let match = manifest.firstMatch(of: pattern) else { return nil }
    return String(match.1)
}

func kindCounts(_ symbols: [SkillSymbol]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for s in symbols { counts[s.kind, default: 0] += 1 }
    return counts
}

func emitSummary(_ summary: SkillSummary, format: OutputFormat) throws -> String {
    func makeEncoder(pretty: Bool) -> JSONEncoder {
        let enc = JSONEncoder()
        var fmt: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { fmt.insert(.prettyPrinted) }
        enc.outputFormatting = fmt
        return enc
    }
    switch format {
    case .json, .compact:
        return String(data: try makeEncoder(pretty: format == .json).encode(summary), encoding: .utf8) ?? "{}"
    case .csv:
        return try formatOutput([summary], format: .csv)
    case .short:
        return summary.description
    case .jsonl:
        return String(data: try makeEncoder(pretty: false).encode(summary), encoding: .utf8) ?? "{}"
    }
}
