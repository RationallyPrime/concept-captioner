// The project folder contract: a job file's relative `skill` and `.md` profile paths resolve
// against the folder that holds the job file, not the process's working directory.
// See docs/CORE-SPEC.md, "Project folder".

import ConceptCore
import Foundation
import Testing

@Suite("project folder")
struct ProjectFolderTests {
    /// `<project>/job.yaml` naming `./skill/my-skill` and `./shape.md`, with both present.
    private func project() throws -> URL {
        let root = try Fixtures.tempDirectory().appendingPathComponent("project", isDirectory: true)
        let skill = root.appendingPathComponent("skill/my-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("---\ndescription: Mine.\n---\nPROJECT SKILL\n".utf8)
            .write(to: skill.appendingPathComponent("SKILL.md"))
        try Data("PROJECT SHAPE".utf8).write(to: root.appendingPathComponent("shape.md"))
        var job = try Fixtures.job()
        job.skill = "./skill/my-skill"
        job.profile = "./shape.md"
        try job.save(to: root.appendingPathComponent("job.yaml"))
        return root
    }

    @Test func relativePathsResolveAgainstTheJobFilesFolder() throws {
        let root = try project()
        #expect(FileManager.default.currentDirectoryPath != root.path)
        let job = try Job.load(contentsOf: root.appendingPathComponent("job.yaml"))
        #expect(job.directory?.standardizedFileURL.path == root.standardizedFileURL.path)
        #expect(job.resolvedURL(for: "./skill/my-skill").path == root.appendingPathComponent("skill/my-skill").path)
        #expect(job.resolvedURL(for: "/abs/skill").path == "/abs/skill")

        let runner = try Runner(job: job, captioner: Fixtures.endpoint(Fixtures.captionerOK()))
        #expect(runner.skill.name == "my-skill")
        #expect(runner.skill.body == "PROJECT SKILL\n")
        #expect(runner.profileText == "PROJECT SHAPE")
    }

    @Test func aJobParsedFromTextHasNoFolderAndDoesNotFindTheProjectSkill() throws {
        let root = try project()
        let text = try String(contentsOf: root.appendingPathComponent("job.yaml"), encoding: .utf8)
        let job = try Job.load(yaml: text)
        #expect(job.directory == nil)
        #expect(throws: ConfigurationError.self) {
            try Runner(job: job, captioner: Fixtures.endpoint(Fixtures.captionerOK()))
        }
    }

    @Test func equalityIgnoresWhereTheJobWasLoadedFrom() throws {
        let root = try project()
        let loaded = try Job.load(contentsOf: root.appendingPathComponent("job.yaml"))
        let parsed = try Job.load(yaml: loaded.dump())
        #expect(loaded.directory != nil)
        #expect(parsed == loaded)
    }
}
