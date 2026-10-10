// Agent Skills loader. Python counterpart: skills.py.
//
// A skill is a directory per the Agent Skills specification: SKILL.md with YAML frontmatter
// (`name` optional but must match the directory, `description` required) and a Markdown body,
// plus an optional references/ directory. Two conventions of our own:
// - metadata.references: [file.md, ...] names files under references/ to inline after the body.
// - references/profiles/<name>.md is a caption profile.
//
// The skill is loaded eagerly; its text goes straight into the agent's instructions. Error
// messages are copied from skills.py so both implementations report the same problem.

import Foundation
import Yams

public struct Skill: Sendable, Equatable {
    public let name: String
    public let description: String
    public let body: String
    public let directory: URL
    public let references: [String]
    public let metadata: JSONObject

    public init(
        name: String,
        description: String,
        body: String,
        directory: URL,
        references: [String] = [],
        metadata: JSONObject = [:]
    ) {
        self.name = name
        self.description = description
        self.body = body
        self.directory = directory
        self.references = references
        self.metadata = metadata
    }

    /// The text of references/<relative>; ConfigurationError when missing.
    public func reference(_ relative: String) throws -> String {
        let url = directory
            .appendingPathComponent("references", isDirectory: true)
            .appendingPathComponent(relative)
        guard Skills.isFile(url) else {
            throw ConfigurationError("skill '\(name)' has no reference '\(relative)'")
        }
        return try Skills.readText(url)
    }

    /// Body plus the named references, each trimmed, joined by blank lines, trailing newline.
    public func instructions() throws -> String {
        var parts = [body.trimmingCharacters(in: .whitespacesAndNewlines)]
        for relative in references {
            try parts.append(reference(relative).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Sorted stems of references/profiles/*.md; [] when the directory is missing.
    public func profiles() -> [String] {
        let root = profilesDirectory
        guard Skills.isDirectory(root),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            // Python's `sorted` orders by code point; Swift's String order is close but not identical.
            .sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    /// "h3-still" -> references/profiles/h3-still.md; or any existing .md path.
    public func profile(_ nameOrPath: String) throws -> String {
        if nameOrPath.hasSuffix(".md") {
            let candidate = URL(fileURLWithPath: nameOrPath)
            if Skills.isFile(candidate) {
                return try Skills.readText(candidate)
            }
        }
        let bundled = profilesDirectory.appendingPathComponent("\(nameOrPath).md")
        if Skills.isFile(bundled) {
            return try Skills.readText(bundled)
        }
        let known = profiles().map { "'\($0)'" }.joined(separator: ", ")
        throw ConfigurationError(
            "unknown profile '\(nameOrPath)'; skill '\(name)' has [\(known)], or pass a path to a .md file"
        )
    }

    private var profilesDirectory: URL {
        directory
            .appendingPathComponent("references", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
    }
}

public enum Skills {
    public static let defaultSkillName = "diffusion-training-captioner"

    /// The bundled default skill directory from the package resources.
    public static func defaultSkillURL() -> URL {
        let bundle = Bundle.module
        if let url = bundle.url(forResource: defaultSkillName, withExtension: nil, subdirectory: "Skills") {
            return url
        }
        // Not found: hand back where it should be so `load` reports "not a skill directory".
        return (bundle.resourceURL ?? bundle.bundleURL)
            .appendingPathComponent("Skills", isDirectory: true)
            .appendingPathComponent(defaultSkillName, isDirectory: true)
    }

    /// Load a skill directory; nil loads the bundled default.
    public static func load(_ directory: URL? = nil) throws -> Skill {
        let directory = directory ?? defaultSkillURL()
        let skillMD = directory.appendingPathComponent("SKILL.md")
        guard isFile(skillMD) else {
            throw ConfigurationError("not a skill directory (no SKILL.md): \(pathString(directory))")
        }
        let (meta, body) = try frontmatter(readText(skillMD))
        // `directory.resolve().name`: symlinks followed (a `current -> my-skill` link loads as
        // my-skill), case kept as typed. Foundation's `resolvingSymlinksInPath()` would also
        // canonicalize case on case-insensitive volumes, which Python's `resolve()` does not.
        let dirName = nfkc(pythonRealpath(directory.path(percentEncoded: false)).split(separator: "/").last
            .map(String.init) ?? "")
        let name = nfkc(truthyString(meta["name"]) ?? dirName)
        guard isValidName(name) else {
            throw ConfigurationError(
                "skill name '\(name)' must be lowercase letters/digits separated by single hyphens"
            )
        }
        guard name == dirName else {
            throw ConfigurationError("skill name '\(name)' does not match directory '\(dirName)'")
        }
        let description = (truthyString(meta["description"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            throw ConfigurationError("skill '\(name)': frontmatter needs a non-blank description")
        }
        let metadata: JSONObject = switch meta["metadata"] {
        case nil, .null?: [:]
        case let .object(object)?: object
        default: throw ConfigurationError("skill '\(name)': metadata must be a mapping")
        }
        let references: [String] = switch metadata["references"] {
        case nil, .null?: []
        case let .array(items)?: items.map(pythonString)
        default: throw ConfigurationError("skill '\(name)': metadata.references must be a list of file names")
        }
        let skill = Skill(
            name: name,
            description: description,
            body: body,
            directory: directory,
            references: references,
            metadata: metadata
        )
        for reference in references {
            _ = try skill.reference(reference) // fail at load time, not mid-run
        }
        return skill
    }

    /// Load from a path string (expands "~"); nil loads the bundled default.
    public static func load(path: String?) throws -> Skill {
        guard let path else { return try load() }
        let expanded = (path as NSString).expandingTildeInPath
        return try load(URL(fileURLWithPath: expanded, isDirectory: true))
    }

    // MARK: - Frontmatter

    /// Split "---\n<yaml>\n---\n" frontmatter from the body; ([:], text) when there is none.
    ///
    /// The Python regex is `^---[ \t]*\r?\n(.*?)\r?\n---[ \t]*\r?\n?` (DOTALL): the opening fence is
    /// `---` plus optional spaces/tabs and a line break; the closing fence is the first following
    /// line that is `---` plus optional spaces/tabs, ended by a line break or the end of the text.
    /// The YAML excludes the line break before the closing fence; the body is everything after it.
    static func frontmatter(_ text: String) throws -> (JSONObject, String) {
        let scalars = text.unicodeScalars
        guard scalars.starts(with: "---".unicodeScalars) else { return ([:], text) }
        let notClosed = ConfigurationError("SKILL.md frontmatter is not closed")
        guard let yamlStart = lineBreakEnd(scalars, from: scalars.index(scalars.startIndex, offsetBy: 3)) else {
            throw notClosed
        }
        var lineStart = yamlStart
        var yamlEnd = yamlStart
        while lineStart < scalars.endIndex {
            let newline = scalars[lineStart...].firstIndex(of: "\n") ?? scalars.endIndex
            var contentEnd = newline
            if contentEnd > lineStart, scalars[scalars.index(before: contentEnd)] == "\r" {
                contentEnd = scalars.index(before: contentEnd)
            }
            if isFence(scalars[lineStart ..< contentEnd]) {
                let yaml = String(scalars[yamlStart ..< yamlEnd])
                let body = newline == scalars.endIndex ? "" : String(scalars[scalars.index(after: newline)...])
                return try (parseFrontmatter(yaml), body)
            }
            yamlEnd = contentEnd
            guard newline < scalars.endIndex else { break }
            lineStart = scalars.index(after: newline)
        }
        throw notClosed
    }

    /// `[ \t]*\r?\n` at `start`: the index after the line break, or nil when the line is not blank.
    private static func lineBreakEnd(_ scalars: String.UnicodeScalarView, from start: String.Index) -> String.Index? {
        var cursor = start
        while cursor < scalars.endIndex, scalars[cursor] == " " || scalars[cursor] == "\t" {
            cursor = scalars.index(after: cursor)
        }
        if cursor < scalars.endIndex, scalars[cursor] == "\r" {
            cursor = scalars.index(after: cursor)
        }
        guard cursor < scalars.endIndex, scalars[cursor] == "\n" else { return nil }
        return scalars.index(after: cursor)
    }

    /// `---[ \t]*` as a whole line (the trailing `\r`, if any, already removed).
    private static func isFence(_ line: Substring.UnicodeScalarView) -> Bool {
        guard line.starts(with: "---".unicodeScalars) else { return false }
        return line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func parseFrontmatter(_ yaml: String) throws -> JSONObject {
        let node: Node?
        do {
            node = try Yams.compose(yaml: yaml)
        } catch {
            throw ConfigurationError("SKILL.md frontmatter is not valid YAML: \(error)")
        }
        guard let node else { return [:] }
        guard case .mapping = node else {
            throw ConfigurationError("SKILL.md frontmatter must be a mapping")
        }
        return try JSONValue(yamlNode: node).objectValue ?? [:]
    }

    // MARK: - Name rules

    /// `^[a-z0-9]+(?:-[a-z0-9]+)*$` and at most 64 characters.
    static func isValidName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        guard scalars.count <= 64 else { return false }
        return scalars.split(separator: "-", omittingEmptySubsequences: false).allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy { scalar in
                ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar)
            }
        }
    }

    private static func nfkc(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    // MARK: - Python scalar semantics

    /// `str(value)` for the value of a frontmatter field; `value or default` falls through on nil.
    /// None, "", 0, False, [] and {} are falsy in Python and yield nil here.
    private static func truthyString(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        let falsy = switch value {
        case .null: true
        case let .bool(flag): !flag
        case let .int(number): number == 0
        case let .double(number): number == 0
        case let .string(text): text.isEmpty
        case let .array(items): items.isEmpty
        case let .object(object): object.isEmpty
        }
        return falsy ? nil : pythonString(value)
    }

    /// Python `str()` of a YAML scalar; collections render as JSON (they are never valid here anyway).
    private static func pythonString(_ value: JSONValue) -> String {
        switch value {
        case .null: "None"
        case let .bool(flag): flag ? "True" : "False"
        case let .int(number): String(number)
        case let .double(number): JSONValue.pythonFloatRepr(number)
        case let .string(text): text
        case .array, .object: value.pythonDumps()
        }
    }

    // MARK: - Files

    /// `os.path.realpath(path)` for an absolute POSIX path, as `Path.resolve()` (non-strict) calls it:
    /// components are walked left to right, each symlink is replaced by its target, `..` pops the
    /// path resolved so far, missing components and a symlink loop are kept as written, and case is
    /// never touched. Empty and `.` components are dropped, so there is no trailing slash.
    static func pythonRealpath(_ path: String) -> String {
        var seen: [String: String?] = [:]
        // realpath ends with abspath(): for an absolute input that is normpath(), which matters
        // after a loop, where the unresolved remainder may still hold `..`, `.` or a trailing slash.
        return posixNormpath(joinRealpath("", path, &seen).path)
    }

    /// `posixpath.normpath(p)` for an absolute `p` (a leading `//` is not special-cased here).
    private static func posixNormpath(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/") where component != "." {
            if component == ".." {
                _ = parts.popLast() // `/..` is `/`
            } else {
                parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `posixpath._joinrealpath(path, rest, strict=False, seen)`; `ok` is false after a symlink loop.
    private static func joinRealpath(
        _ start: String,
        _ rest: String,
        _ seen: inout [String: String?]
    ) -> (path: String, ok: Bool) {
        var path = start
        var rest = Substring(rest)
        if rest.hasPrefix("/") {
            rest = rest.dropFirst()
            path = "/"
        }
        while !rest.isEmpty {
            let name: Substring
            if let slash = rest.firstIndex(of: "/") {
                name = rest[..<slash]
                rest = rest[rest.index(after: slash)...]
            } else {
                name = rest
                rest = ""
            }
            if name.isEmpty || name == "." {
                continue
            }
            if name == ".." {
                if path.isEmpty {
                    path = ".."
                } else {
                    let (head, tail) = posixSplit(path)
                    path = tail == ".." ? posixJoin(posixJoin(head, ".."), "..") : head
                }
                continue
            }
            let newpath = posixJoin(path, String(name))
            let attributes = try? FileManager.default.attributesOfItem(atPath: newpath) // lstat
            guard attributes?[.type] as? FileAttributeType == .typeSymbolicLink,
                  let target = try? FileManager.default.destinationOfSymbolicLink(atPath: newpath)
            else {
                path = newpath
                continue
            }
            if let entry = seen[newpath] {
                if let resolved = entry {
                    path = resolved
                    continue
                }
                return (posixJoin(newpath, String(rest)), false) // loop: leave the rest unresolved
            }
            seen[newpath] = .some(nil)
            let (resolved, ok) = joinRealpath(path, target, &seen)
            guard ok else { return (posixJoin(resolved, String(rest)), false) }
            path = resolved
            seen[newpath] = resolved
        }
        return (path, true)
    }

    /// `posixpath.join(a, b)` for a single `b`.
    private static func posixJoin(_ a: String, _ b: String) -> String {
        if b.hasPrefix("/") { return b }
        if a.isEmpty || a.hasSuffix("/") { return a + b }
        return a + "/" + b
    }

    /// `posixpath.split(p)`: the head keeps its trailing slash only when it is all slashes.
    private static func posixSplit(_ path: String) -> (head: String, tail: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        let tail = String(path[path.index(after: slash)...])
        var head = Substring(path[...slash])
        if head.contains(where: { $0 != "/" }) {
            while head.hasSuffix("/") {
                head = head.dropLast()
            }
        }
        return (String(head), tail)
    }

    /// The path as Python prints it: decoded, without a directory URL's trailing slash.
    private static func pathString(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// `Path.read_text(encoding="utf-8")`: UTF-8, with universal newlines ("\r\n" and "\r" become "\n").
    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConfigurationError("not UTF-8 text: \(pathString(url))")
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
