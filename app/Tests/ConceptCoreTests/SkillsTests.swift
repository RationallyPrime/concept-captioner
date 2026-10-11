// Skill loading, frontmatter, name rules, references, profiles. See docs/CORE-SPEC.md, module `skills`.
// Python counterpart: tests/test_skills_and_prompt.py (the skill half). Reference messages and texts
// were produced by running skills.py on the same inputs.

@testable import ConceptCore
import Foundation
import Testing

private func configurationMessage(_ body: () throws -> some Any) -> String? {
    do {
        _ = try body()
        return nil
    } catch let error as ConfigurationError {
        return error.message
    } catch {
        return "unexpected error type: \(error)"
    }
}

/// A fresh temp root with a skill directory `name` whose SKILL.md is `skillMD`.
private func makeSkill(_ name: String, skillMD: String, root: URL? = nil) throws -> URL {
    let root = try root ?? Fixtures.tempDirectory()
    let directory = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(skillMD.utf8).write(to: directory.appendingPathComponent("SKILL.md"))
    return directory
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url)
}

/// The Python package's copy of the bundled skill, relative to this package.
private let pythonSkillURL = Fixtures.exampleJobURL
    .deletingLastPathComponent() // examples
    .deletingLastPathComponent() // repo
    .appendingPathComponent("src/concept_captioner/skills/diffusion-training-captioner", isDirectory: true)

@Suite("skills")
struct SkillsTests {
    // MARK: - The bundled default

    @Test("default skill loads with profiles")
    func defaultSkillLoadsWithProfiles() throws {
        let skill = try Skills.load()
        #expect(skill.name == "diffusion-training-captioner")
        #expect(!skill.description.isEmpty)
        #expect(skill.references.isEmpty)
        #expect(skill.metadata["references"] == .array([]))
        let instructions = try skill.instructions()
        #expect(instructions.contains("# Core Caption Policy"))
        #expect(instructions.hasPrefix("# Diffusion Training Captioner\n"))
        #expect(instructions.hasSuffix("\n") && !instructions.hasSuffix("\n\n"))
        #expect(instructions == skill.body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        #expect(skill.profiles() == ["flux-image", "h3-still", "h3-video", "ltx-image", "ltx-video", "plain"])
        #expect(try skill.profile("h3-still").contains("[Shot 1]"))
        #expect(
            configurationMessage { try skill.profile("nope") }
                == "unknown profile 'nope'; skill 'diffusion-training-captioner' has "
                + "['flux-image', 'h3-still', 'h3-video', 'ltx-image', 'ltx-video', 'plain'], "
                + "or pass a path to a .md file"
        )
    }

    @Test("default skill is served from the built resource bundle")
    func defaultSkillURLIsBundled() throws {
        let url = Skills.defaultSkillURL()
        #expect(url.lastPathComponent == Skills.defaultSkillName)
        #expect(url.isFileURL)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path))
        #expect(ConceptCore.defaultSkillURL == url)
        #expect(try Skills.load(path: nil).name == Skills.defaultSkillName)
        #expect(try Skills.load(url).directory == url)
    }

    @Test("bundled skill is a verbatim copy of the Python package's")
    func bundledSkillMatchesPython() throws {
        // The resource directory is never edited here; it is re-copied when the Python side changes.
        guard FileManager.default.fileExists(atPath: pythonSkillURL.appendingPathComponent("SKILL.md").path) else {
            return // running outside the repository checkout
        }
        let bundled = Skills.defaultSkillURL()
        let files = try relativeFiles(under: pythonSkillURL)
        #expect(files.contains("SKILL.md"))
        #expect(files.contains("references/profiles/h3-still.md"))
        #expect(try relativeFiles(under: bundled) == files)
        for file in files {
            let expected = try Data(contentsOf: pythonSkillURL.appendingPathComponent(file))
            let actual = try Data(contentsOf: bundled.appendingPathComponent(file))
            #expect(actual == expected, "\(file) differs from src/concept_captioner/skills")
        }
    }

    private func relativeFiles(under root: URL) throws -> [String] {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        var files: [String] = []
        guard let walker = FileManager.default.enumerator(atPath: base) else {
            throw ConfigurationError("cannot enumerate \(base)")
        }
        while let relative = walker.nextObject() as? String {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: base + "/" + relative, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                files.append(relative)
            }
        }
        return files.sorted()
    }

    // MARK: - A user skill

    @Test("user skill with a named reference and a profile by path")
    func userSkillWithNamedReferenceAndProfilePath() throws {
        let tmp = try Fixtures.tempDirectory()
        let root = try makeSkill(
            "my-skill",
            skillMD: "---\ndescription: Mine.\nmetadata:\n  references: [extra.md]\n---\nBODY TEXT\n",
            root: tmp
        )
        try write("EXTRA TEXT", to: root.appendingPathComponent("references/extra.md"))
        try write("NEVER", to: root.appendingPathComponent("references/unused.md"))
        try write("SHAPE TEXT", to: tmp.appendingPathComponent("shape.md"))

        let skill = try Skills.load(root)
        #expect(skill.name == "my-skill")
        #expect(skill.description == "Mine.")
        #expect(skill.body == "BODY TEXT\n")
        #expect(skill.references == ["extra.md"])
        #expect(skill.metadata == ["references": .array([.string("extra.md")])])
        #expect(skill.directory == root)
        let text = try skill.instructions()
        #expect(text.contains("BODY TEXT") && text.contains("EXTRA TEXT") && !text.contains("NEVER"))
        #expect(text == "BODY TEXT\n\nEXTRA TEXT\n")
        #expect(try skill.profile(tmp.appendingPathComponent("shape.md").path) == "SHAPE TEXT")
        #expect(skill.profiles() == [])
        #expect(try skill.reference("unused.md") == "NEVER")
        #expect(
            configurationMessage { try skill.reference("gone.md") }
                == "skill 'my-skill' has no reference 'gone.md'"
        )
        #expect(try Skills.load(path: root.path).name == "my-skill")
        #expect(try Skills.load(path: root.path + "/").name == "my-skill")
    }

    @Test("profiles are the sorted stems of references/profiles/*.md")
    func profilesAreSortedStems() throws {
        let root = try makeSkill("prof-skill", skillMD: "---\ndescription: x\n---\nbody\n")
        for name in ["zeta.md", "alpha.md", "mid.md", "notes.txt", "two.part.md"] {
            try write("profile \(name)", to: root.appendingPathComponent("references/profiles/\(name)"))
        }
        let skill = try Skills.load(root)
        #expect(skill.profiles() == ["alpha", "mid", "two.part", "zeta"])
        #expect(try skill.profile("two.part") == "profile two.part.md")
        #expect(
            configurationMessage { try skill.profile("notes") }
                == "unknown profile 'notes'; skill 'prof-skill' has ['alpha', 'mid', 'two.part', 'zeta'], "
                + "or pass a path to a .md file"
        )
        // A ".md" name that is not an existing file falls through to the bundled lookup.
        #expect(
            configurationMessage { try skill.profile("alpha.md") }?
                .hasPrefix("unknown profile 'alpha.md'") == true
        )
    }

    @Test("instructions trim the body and each reference and join with blank lines")
    func instructionsTrimAndJoin() throws {
        let root = try makeSkill(
            "trim-skill",
            skillMD: "---\ndescription: x\nmetadata:\n  references: [a.md, sub/b.md]\n---\n\n  BODY  \n\n\n"
        )
        try write("\n\nA TEXT\n", to: root.appendingPathComponent("references/a.md"))
        try write("B TEXT", to: root.appendingPathComponent("references/sub/b.md"))
        let skill = try Skills.load(root)
        #expect(skill.references == ["a.md", "sub/b.md"])
        #expect(try skill.instructions() == "BODY\n\nA TEXT\n\nB TEXT\n")
    }

    @Test("CRLF files read like Python's text mode")
    func crlfFilesNormalize() throws {
        let root = try makeSkill("crlf-skill", skillMD: "---\r\ndescription: x\r\n---\r\nline1\r\nline2\r\n")
        try write("P1\r\nP2", to: root.appendingPathComponent("references/profiles/win.md"))
        let skill = try Skills.load(root)
        #expect(skill.body == "line1\nline2\n")
        #expect(try skill.instructions() == "line1\nline2\n")
        #expect(try skill.profile("win") == "P1\nP2")
    }

    // MARK: - Validation

    @Test("skill validation messages match skills.py")
    func skillValidation() throws {
        let tmp = try Fixtures.tempDirectory()
        let bad = try makeSkill("Bad_Name", skillMD: "---\ndescription: x\n---\nbody", root: tmp)
        #expect(
            configurationMessage { try Skills.load(bad) }
                == "skill name 'Bad_Name' must be lowercase letters/digits separated by single hyphens"
        )
        let noDescription = try makeSkill("no-desc", skillMD: "---\nname: no-desc\n---\nbody", root: tmp)
        #expect(
            configurationMessage { try Skills.load(noDescription) }
                == "skill 'no-desc': frontmatter needs a non-blank description"
        )
        let blank = try makeSkill("blank-desc", skillMD: "---\ndescription: '   '\n---\nbody", root: tmp)
        #expect(
            configurationMessage { try Skills.load(blank) }
                == "skill 'blank-desc': frontmatter needs a non-blank description"
        )
        // `tmp` is a directory URL (trailing slash); the message prints the path as Python does, without it.
        #expect(
            configurationMessage { try Skills.load(tmp) }
                == "not a skill directory (no SKILL.md): \(tmp.path)"
        )
        #expect(!tmp.path.hasSuffix("/") && tmp.path(percentEncoded: false).hasSuffix("/"))
        let missing = tmp.appendingPathComponent("missing-skill", isDirectory: true)
        #expect(configurationMessage { try Skills.load(missing) }?.hasPrefix("not a skill directory") == true)
        #expect(configurationMessage { try Skills.load(path: missing.path) }?
            .hasPrefix("not a skill directory") == true)

        let long = String(repeating: "a", count: 65)
        let tooLong = try makeSkill(long, skillMD: "---\ndescription: x\n---\n", root: tmp)
        #expect(
            configurationMessage { try Skills.load(tooLong) }
                == "skill name '\(long)' must be lowercase letters/digits separated by single hyphens"
        )
        let limit = String(repeating: "b", count: 64)
        #expect(try Skills.load(makeSkill(limit, skillMD: "---\ndescription: x\n---\n", root: tmp)).name == limit)

        let mismatch = try makeSkill("mismatch", skillMD: "---\nname: other-name\ndescription: x\n---\n", root: tmp)
        #expect(
            configurationMessage { try Skills.load(mismatch) }
                == "skill name 'other-name' does not match directory 'mismatch'"
        )
        let metaBad = try makeSkill("meta-bad", skillMD: "---\ndescription: x\nmetadata: 3\n---\nbody", root: tmp)
        #expect(configurationMessage { try Skills.load(metaBad) } == "skill 'meta-bad': metadata must be a mapping")
        let refMissing = try makeSkill(
            "ref-missing",
            skillMD: "---\ndescription: x\nmetadata:\n  references: [gone.md]\n---\nbody",
            root: tmp
        )
        #expect(
            configurationMessage { try Skills.load(refMissing) }
                == "skill 'ref-missing' has no reference 'gone.md'"
        )
        let refsNotList = try makeSkill(
            "refs-string",
            skillMD: "---\ndescription: x\nmetadata:\n  references: extra.md\n---\nbody",
            root: tmp
        )
        #expect(configurationMessage { try Skills.load(refsNotList) } != nil)
        let notMapping = try makeSkill("not-mapping", skillMD: "---\n- a\n---\nbody", root: tmp)
        #expect(configurationMessage { try Skills.load(notMapping) } == "SKILL.md frontmatter must be a mapping")
    }

    @Test("name rules: lowercase letters and digits in single-hyphen groups, at most 64")
    func nameRules() {
        for good in ["a", "abc", "a1-b2", "diffusion-training-captioner", "x-y-z", String(repeating: "a", count: 64)] {
            #expect(Skills.isValidName(good), "\(good)")
        }
        for bad in [
            "",
            "-a",
            "a-",
            "a--b",
            "A",
            "Bad_Name",
            "a b",
            "a.b",
            "ä",
            "ｍy",
            String(repeating: "a", count: 65),
        ] {
            #expect(!Skills.isValidName(bad), "\(bad)")
        }
    }

    @Test("names and directory names are NFKC-normalized before the rules apply")
    func nfkcNormalization() throws {
        // Separate roots: APFS is case-insensitive, so "ｍy-skill" and "Ｍy-skill" would be one directory.
        // Fullwidth lowercase "ｍ" normalizes to "m": the skill loads under its ASCII name.
        let fullwidthLower = try makeSkill("ｍy-skill", skillMD: "---\ndescription: x\n---\nbody")
        #expect(try Skills.load(fullwidthLower).name == "my-skill")
        // Fullwidth uppercase "Ｍ" normalizes to "M" and then fails the regex; the message shows the normalized name.
        let fullwidthUpper = try makeSkill("Ｍy-skill", skillMD: "---\ndescription: x\n---\nbody")
        #expect(
            configurationMessage { try Skills.load(fullwidthUpper) }
                == "skill name 'My-skill' must be lowercase letters/digits separated by single hyphens"
        )
        // The frontmatter name is normalized the same way before it is compared with the directory.
        let named = try makeSkill("nfkc-skill", skillMD: "---\nname: ｎfkc-skill\ndescription: x\n---\nbody")
        #expect(try Skills.load(named).name == "nfkc-skill")
        // The directory name is resolved like Python's `Path.resolve()`: symlinks followed, case kept as typed.
        let typed = try makeSkill("typed-skill", skillMD: "---\ndescription: x\n---\nbody")
        let viaDot = typed.appendingPathComponent(".", isDirectory: true)
        #expect(try Skills.load(viaDot).name == "typed-skill")
        let uppercaseTyped = typed.deletingLastPathComponent().appendingPathComponent("TYPED-SKILL", isDirectory: true)
        if FileManager.default.fileExists(atPath: uppercaseTyped.appendingPathComponent("SKILL.md").path) {
            // Case-insensitive volume: the typed name is still what the rules see, as with Python's resolve().
            #expect(
                configurationMessage { try Skills.load(uppercaseTyped) }
                    == "skill name 'TYPED-SKILL' must be lowercase letters/digits separated by single hyphens"
            )
        }
    }

    @Test("a symlinked skill directory is named after its target, like Path.resolve()")
    func symlinkedDirectoryResolvesToTarget() throws {
        let tmp = try Fixtures.tempDirectory()
        let real = try makeSkill("my-skill", skillMD: "---\nname: my-skill\ndescription: x\n---\nbody", root: tmp)
        let link = tmp.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // Named: the frontmatter name matches the resolved directory, not the link.
        let viaLink = try Skills.load(link)
        #expect(viaLink.name == "my-skill")
        #expect(viaLink.directory == link) // kept as given; files are read through the link
        #expect(viaLink.body == "body")
        #expect(try Skills.load(path: link.path).name == "my-skill")
        #expect(try Skills.load(path: link.path + "/").name == "my-skill")

        // Unnamed: the name is the resolved directory's.
        try Data("---\ndescription: x\n---\nbody".utf8).write(to: real.appendingPathComponent("SKILL.md"))
        #expect(try Skills.load(link).name == "my-skill")

        // Naming the link instead is a mismatch, reported against the resolved directory.
        try Data("---\nname: current\ndescription: x\n---\nbody".utf8)
            .write(to: real.appendingPathComponent("SKILL.md"))
        #expect(
            configurationMessage { try Skills.load(link) }
                == "skill name 'current' does not match directory 'my-skill'"
        )

        // `..` is applied after the symlink before it is resolved, as realpath does (not lexically).
        try Data("---\ndescription: x\n---\nbody".utf8).write(to: real.appendingPathComponent("SKILL.md"))
        try write("R", to: real.appendingPathComponent("references/extra.md"))
        let intoReferences = tmp.appendingPathComponent("refs-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: intoReferences,
            withDestinationURL: real.appendingPathComponent("references", isDirectory: true)
        )
        let viaDotDot = intoReferences.appendingPathComponent("..", isDirectory: true)
        #expect(try Skills.load(viaDotDot).name == "my-skill")
        #expect(try Skills.load(path: intoReferences.path + "/..").name == "my-skill")

        // A link whose target name breaks the rules fails on the resolved name.
        let upper = try makeSkill("UPPER-TARGET", skillMD: "---\ndescription: x\n---\nbody", root: tmp)
        let lowerLink = tmp.appendingPathComponent("lower-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: lowerLink, withDestinationURL: upper)
        #expect(
            configurationMessage { try Skills.load(lowerLink) }
                == "skill name 'UPPER-TARGET' must be lowercase letters/digits separated by single hyphens"
        )
    }

    @Test("pythonRealpath follows symlinks, keeps case and missing components, survives loops")
    func pythonRealpathMatchesPosixRealpath() throws {
        let tmp = try Fixtures.tempDirectory()
        // The temp root sits under /var, a symlink to /private/var on macOS; `base` is its realpath.
        #expect(Skills.pythonRealpath("/var") == "/private/var")
        #expect(Skills.pythonRealpath("/tmp/") == "/private/tmp")
        let base = Skills.pythonRealpath(tmp.path(percentEncoded: false))
        #expect(base.hasPrefix("/") && base.hasSuffix("/" + tmp.lastPathComponent) && !base.hasSuffix("/"))
        let real = tmp.appendingPathComponent("real-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: base + "/abs-link", withDestinationPath: base + "/real-dir"
        )
        try FileManager.default.createSymbolicLink(atPath: base + "/rel-link", withDestinationPath: "real-dir/sub")
        try FileManager.default.createSymbolicLink(atPath: base + "/loop", withDestinationPath: "loop")
        try FileManager.default.createSymbolicLink(atPath: base + "/chain", withDestinationPath: "abs-link")

        #expect(Skills.pythonRealpath(base + "/abs-link/") == base + "/real-dir")
        #expect(Skills.pythonRealpath(base + "/rel-link") == base + "/real-dir/sub")
        #expect(Skills.pythonRealpath(base + "/rel-link/..") == base + "/real-dir")
        #expect(Skills.pythonRealpath(base + "/rel-link/../..") == base)
        #expect(Skills.pythonRealpath(base + "/chain/sub/./") == base + "/real-dir/sub")
        #expect(Skills.pythonRealpath(base + "//real-dir///sub") == base + "/real-dir/sub")
        // Missing components stay as written; nothing is invented.
        #expect(Skills.pythonRealpath(base + "/abs-link/missing/deeper") == base + "/real-dir/missing/deeper")
        // Case is kept as typed even on a case-insensitive volume (Python's resolve() does the same).
        #expect(Skills.pythonRealpath(base + "/REAL-DIR") == base + "/REAL-DIR")
        // lstat finds "ABS-LINK" only on a case-insensitive volume; then the link is followed, as in Python.
        let caseInsensitive = FileManager.default.fileExists(atPath: base + "/ABS-LINK")
        #expect(Skills
            .pythonRealpath(base + "/ABS-LINK") == (caseInsensitive ? base + "/real-dir" : base + "/ABS-LINK"))
        // A loop leaves the rest unresolved rather than hanging or throwing.
        #expect(Skills.pythonRealpath(base + "/loop") == base + "/loop")
        #expect(Skills.pythonRealpath(base + "/loop/x") == base + "/loop/x")
        #expect(Skills.pythonRealpath(base + "/loop/../real-dir/") == base + "/real-dir") // normpath after the loop
        #expect(Skills.pythonRealpath("/") == "/")
        #expect(Skills.pythonRealpath("/..") == "/")
    }

    @Test("other frontmatter fields are accepted and kept in metadata only when nested there")
    func extraFrontmatterFields() throws {
        let root = try makeSkill(
            "extra-fields",
            skillMD: "---\nname: extra-fields\ndescription: x\nlicense: MIT\nallowed-tools: [Read]\n"
                + "metadata:\n  version: 2026-10-10\n  author: someone\n---\nbody"
        )
        let skill = try Skills.load(root)
        #expect(skill.metadata["version"] == .string("2026-10-10"))
        #expect(skill.metadata["author"] == .string("someone"))
        #expect(skill.metadata["license"] == nil)
        #expect(skill.references.isEmpty)
    }

    @Test("load(path:) expands a leading tilde")
    func loadPathExpandsTilde() {
        let name = "concept-core-missing-\(UUID().uuidString.lowercased())"
        let message = configurationMessage { try Skills.load(path: "~/\(name)") }
        #expect(message == "not a skill directory (no SKILL.md): \(NSHomeDirectory())/\(name)")
        let trailing = configurationMessage { try Skills.load(path: "~/\(name)/") }
        #expect(trailing == "not a skill directory (no SKILL.md): \(NSHomeDirectory())/\(name)")
    }

    // MARK: - Frontmatter

    @Test("frontmatter: none, closed, trailing whitespace, end of text")
    func frontmatterSplitting() throws {
        let plain = try Skills.frontmatter("no front\n")
        #expect(plain.0 == [:] && plain.1 == "no front\n")
        let empty = try Skills.frontmatter("")
        #expect(empty.0 == [:] && empty.1 == "")

        let closed = try Skills.frontmatter("---\ndescription: x\nmetadata:\n  references: []\n---\nbody\n")
        #expect(closed.0 == ["description": .string("x"), "metadata": .object(["references": .array([])])])
        #expect(closed.1 == "body\n")

        let atEnd = try Skills.frontmatter("---\ndescription: x\n---")
        #expect(atEnd.0 == ["description": .string("x")] && atEnd.1 == "")

        let spaced = try Skills.frontmatter("---  \ndescription: x\n---\t\n\nbody")
        #expect(spaced.0 == ["description": .string("x")] && spaced.1 == "\nbody")

        let blankYAML = try Skills.frontmatter("---\n# only a comment\n---\nbody")
        #expect(blankYAML.0 == [:] && blankYAML.1 == "body")

        // A line that merely contains "---" is YAML, not the closing fence; the YAML excludes the
        // line break before the fence, so a block scalar on the last line has no trailing newline
        // (PyYAML gives the same two values).
        let dashes = try Skills.frontmatter("---\ndescription: x\nnote: |\n  ---- not a fence\nafter: 1\n---\nbody")
        #expect(dashes.0["note"] == .string("---- not a fence\n") && dashes.0["after"] == .int(1))
        #expect(dashes.1 == "body")
        let lastLine = try Skills.frontmatter("---\nnote: |\n  ---- not a fence\n---\nbody")
        #expect(lastLine.0["note"] == .string("---- not a fence") && lastLine.1 == "body")
    }

    @Test("frontmatter: CRLF line endings parse")
    func frontmatterCRLF() throws {
        let (meta, body) = try Skills.frontmatter(
            "---\r\ndescription: x\r\nmetadata:\r\n  references: []\r\n---\r\nbody\r\n"
        )
        #expect(meta == ["description": .string("x"), "metadata": .object(["references": .array([])])])
        #expect(body == "body\r\n")
        let (meta2, body2) = try Skills.frontmatter("---\r\ndescription: y\r\n---")
        #expect(meta2 == ["description": .string("y")] && body2 == "")
    }

    @Test("frontmatter errors match skills.py")
    func frontmatterErrors() {
        for unclosed in ["---\ndescription: x\n", "----\nx\n---\n", "---", "---\n", "--- x\ndescription: x\n---\n"] {
            #expect(
                configurationMessage { try Skills.frontmatter(unclosed) } == "SKILL.md frontmatter is not closed",
                "input \(unclosed.debugDescription)"
            )
        }
        #expect(
            configurationMessage { try Skills.frontmatter("---\n- a\n---\n") }
                == "SKILL.md frontmatter must be a mapping"
        )
        #expect(
            configurationMessage { try Skills.frontmatter("---\njust text\n---\n") }
                == "SKILL.md frontmatter must be a mapping"
        )
        #expect(
            configurationMessage { try Skills.frontmatter("---\na: [\n---\n") }?
                .hasPrefix("SKILL.md frontmatter is not valid YAML: ") == true
        )
    }
}
