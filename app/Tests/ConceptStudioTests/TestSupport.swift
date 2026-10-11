@testable import ConceptStudio
import Foundation
import Synchronization

/// Secrets kept in memory so tests never read or write the login keychain.
final class MemorySecretStore: SecretStore {
    private let values = Mutex<[String: String]>([:])
    private let reads = Mutex<[String]>([])

    init(_ initial: [String: String] = [:]) {
        values.withLock { $0 = initial }
    }

    var readAccounts: [String] {
        reads.withLock { $0 }
    }

    func read(_ account: String) throws -> String? {
        reads.withLock { $0.append(account) }
        return values.withLock { $0[account] }
    }

    func save(_ value: String, account: String) throws {
        values.withLock { $0[account] = value.isEmpty ? nil : value }
    }
}

/// A fresh directory under the test process's temporary directory.
func temporaryTestDirectory(_ name: String = "ConceptStudioTests") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
}

/// The demo project in its own directory, so parallel tests never share one.
func makeDemoProject() async throws -> StudioProject {
    try await DemoProject.create(at: temporaryTestDirectory("ConceptStudio-demo"))
}

/// Preferences in their own suite; call `remove()` (usually in a `defer`) when the test ends.
struct IsolatedDefaults {
    let name = "ConceptStudioTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
    }

    func remove() {
        defaults.removePersistentDomain(forName: name)
    }
}

/// A session with in-memory secrets and its own demo directory. Tests that inspect or seed
/// preferences pass an `IsolatedDefaults`; the rest never write preferences (demo mode).
@MainActor
func makeTestSession(
    preferences: UserDefaults = .standard,
    secrets: MemorySecretStore = MemorySecretStore(),
    chatGPT: ChatGPTAccounts? = nil
) -> StudioSession {
    StudioSession(
        preferences: preferences,
        chatGPT: chatGPT,
        secrets: secrets,
        demoDirectory: temporaryTestDirectory("ConceptStudio-demo")
    )
}

/// A minimal valid Agent Skill directory named `name`, with one profile.
func makeSkill(named name: String, in parent: URL, profile: String = "flux-image") throws -> URL {
    let skill = parent.appendingPathComponent(name, isDirectory: true)
    let profiles = skill.appendingPathComponent("references/profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    try """
    ---
    name: \(name)
    description: Test captioning instructions.
    ---
    Describe what can change.
    """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try "Write one plain sentence.".write(
        to: profiles.appendingPathComponent("\(profile).md"), atomically: true, encoding: .utf8
    )
    return skill
}
