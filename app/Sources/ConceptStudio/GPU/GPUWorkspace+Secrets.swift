// Credentials for a new pod travel as RunPod account secrets (POD-SPEC §1): the pod's
// environment holds `{{ RUNPOD_SECRET_<name> }}` placeholders and never a token, so a pod
// listing cannot leak one.

import ConceptCore
import Foundation
import Security

extension GPUWorkspace {
    /// 256 random bits from the system CSPRNG, hex encoded: the pod agent's bearer and vLLM key.
    nonisolated static func newAgentToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw StudioError.message("Your Mac could not generate a key for the computer. Try again.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    struct PodCredentials {
        let env: [String: String]
        /// The per-pod secret holding the agent bearer; deleted when the pod is removed.
        let agentSecret: String
    }

    /// Writes the Hub token (when there is one) and the new agent bearer to the account's secret
    /// store. The Hub secret has one fixed name and is rewritten every time, so a rotated token
    /// takes effect at the next rental.
    func storeCredentials(_ provider: any GPUProvider) async throws -> PodCredentials {
        var env: [String: String] = [:]
        if !hubToken.isEmpty {
            try await provider.storeSecret(name: PodSecrets.hubTokenName, value: hubToken)
            env["HF_TOKEN"] = PodSecrets.reference(PodSecrets.hubTokenName)
        }
        let agentSecret = try PodSecrets.newAgentSecretName()
        try await provider.storeSecret(name: agentSecret, value: agentToken)
        env["PODAGENT_TOKEN"] = PodSecrets.reference(agentSecret)
        return PodCredentials(env: env, agentSecret: agentSecret)
    }

    /// Creates the pod. A creation that fails leaves no agent secret behind.
    func createPod(
        _ provider: any GPUProvider, offer: GPUOffer, volume: GPUVolume, credentials: PodCredentials
    ) async throws -> RentedPod {
        do {
            return try await provider.create(PodCreation(
                name: PodNaming.name(project: projectFolder?.lastPathComponent ?? ""),
                offer: offer, count: gpuCount,
                image: imageName.replacingOccurrences(of: "{trainer}", with: trainer),
                minCudaVersion: Self.minimumCUDA(trainer), volume: volume, env: credentials.env
            ))
        } catch {
            try? await provider.deleteSecret(name: credentials.agentSecret)
            throw error
        }
    }
}
