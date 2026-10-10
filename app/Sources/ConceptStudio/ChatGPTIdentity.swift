import ConceptCore
import CryptoKit
import Foundation
import Security

enum ChatGPTAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let discoveryURL = URL(string: issuer + "/.well-known/openid-configuration")!
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let directScope = "chatgpt.tokens.use.direct"
    static let dynamicClient = "dynamic_agent_client"

    static func randomValue(bytes: Int = 32) throws -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ChatGPTAuthError("Your Mac could not prepare sign-in. Try again.") }
        return encode(data)
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String) throws -> Data {
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
        else { throw ChatGPTAuthError("The sign-in response could not be verified. Try signing in again.") }
        return data
    }

    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map { key, value in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "="
                + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}

struct ChatGPTAuthError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

struct ChatGPTAuthorization {
    let state: String
    let nonce: String
    let verifier: String
    let redirectURI: URL
    let clientID: String

    init(redirectURI: URL, clientID: String) throws {
        state = try ChatGPTAuth.randomValue()
        nonce = try ChatGPTAuth.randomValue()
        verifier = try ChatGPTAuth.randomValue(bytes: 64)
        self.redirectURI = redirectURI
        self.clientID = clientID
    }

    func url(endpoint: URL, hostID: String, email: String?, idToken: String?, enablePlan: Bool) -> URL {
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var values = [
            "client_id": clientID, "ext_agent_host_id": hostID, "response_type": "code",
            "redirect_uri": redirectURI.absoluteString, "scope": ChatGPTAuth.scopes,
            "resource": ChatGPTAuth.resource, "state": state, "nonce": nonce,
            "code_challenge_method": "S256",
            "code_challenge": ChatGPTAuth.encode(Data(SHA256.hash(data: Data(verifier.utf8)))),
        ]
        if clientID == ChatGPTAuth.dynamicClient { values["agent_name_hint"] = "ConceptStudio" }
        if let email { values["login_hint"] = email }
        if let idToken { values["id_token_hint"] = idToken }
        if enablePlan { values["prompt"] = "consent" }
        parts.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }

    func accept(_ url: URL) throws -> (code: String, clientID: String) {
        guard url.scheme == redirectURI.scheme, url.host() == "127.0.0.1", url.port == redirectURI.port,
              url.path() == "/auth/callback",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { throw ChatGPTAuthError("The sign-in callback did not match this attempt. Try again.") }
        var values: [String: String] = [:]
        for item in items {
            guard values[item.name] == nil, let value = item.value else {
                throw ChatGPTAuthError("The sign-in response was ambiguous. Try signing in again.")
            }
            values[item.name] = value
        }
        guard values["state"] == state else { throw ChatGPTAuthError("The sign-in state did not match. Try again.") }
        if let error = values["error"] {
            throw ChatGPTAuthError(error == "access_denied"
                ? "ChatGPT sign-in was declined. No account was changed."
                : "ChatGPT could not complete sign-in. Try again.")
        }
        guard let code = values["code"], !code.isEmpty else {
            throw ChatGPTAuthError("ChatGPT did not return a sign-in code. Try again.")
        }
        let issued = values["client_id"] ?? clientID
        guard issued != ChatGPTAuth.dynamicClient, !issued.isEmpty,
              clientID == ChatGPTAuth.dynamicClient || issued == clientID else {
            throw ChatGPTAuthError("ChatGPT returned a different or incomplete registration. No account was changed.")
        }
        return (code, issued)
    }
}

struct ChatGPTIdentity {
    let subject: String
    let email: String?

    static func validate(
        _ token: String, jwks: Data, clientID: String, nonce: String?, now: Date
    ) throws -> ChatGPTIdentity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let header = try JSONValue(parsing: ChatGPTAuth.decode(String(parts[0]))).objectValue,
              header["alg"]?.stringValue == "RS256", let kid = header["kid"]?.stringValue,
              let keys = try JSONValue(parsing: jwks).objectValue?["keys"]?.arrayValue,
              let key = keys.compactMap(\.objectValue).first(where: { $0["kid"]?.stringValue == kid }),
              key["kty"]?.stringValue == "RSA", key["alg"] == nil || key["alg"]?.stringValue == "RS256",
              key["use"] == nil || key["use"]?.stringValue == "sig",
              let n = key["n"]?.stringValue, let e = key["e"]?.stringValue
        else { throw ChatGPTAuthError("ChatGPT's identity signature could not be verified. Sign in again.") }
        let modulus = try ChatGPTAuth.decode(n)
        let exponent = try ChatGPTAuth.decode(e)
        guard !modulus.isEmpty,
              !exponent.isEmpty else { throw ChatGPTAuthError("ChatGPT returned an invalid signing key.") }
        let der = sequence(integer(modulus) + integer(exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.count * 8,
        ]
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
              try SecKeyVerifySignature(
                  publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                  Data("\(parts[0]).\(parts[1])".utf8) as CFData,
                  ChatGPTAuth.decode(String(parts[2])) as CFData, nil
              ),
              let claims = try JSONValue(parsing: ChatGPTAuth.decode(String(parts[1]))).objectValue,
              claims["iss"]?.stringValue == ChatGPTAuth.issuer,
              claims["aud"]?.stringValue == clientID || claims["aud"]?.arrayValue?.contains(.string(clientID)) == true,
              let subject = claims["sub"]?.stringValue, !subject.isEmpty,
              let expiry = claims["exp"]?.doubleValue, expiry > now.timeIntervalSince1970,
              let issued = claims["iat"]?.doubleValue, issued <= now.timeIntervalSince1970 + 5,
              (claims["nbf"]?.doubleValue ?? 0) <= now.timeIntervalSince1970 + 5,
              nonce == nil || claims["nonce"]?.stringValue == nonce
        else { throw ChatGPTAuthError("ChatGPT's identity did not match this sign-in. No account was changed.") }
        return ChatGPTIdentity(subject: subject, email: claims["email"]?.stringValue)
    }

    private static func integer(_ data: Data) -> Data {
        let unsigned = data.first! >= 128 ? Data([0]) + data : data
        return Data([0x02]) + length(unsigned.count) + unsigned
    }

    private static func sequence(_ data: Data) -> Data {
        Data([0x30]) + length(data.count) + data
    }

    private static func length(_ value: Int) -> Data {
        if value < 128 { return Data([UInt8(value)]) }
        var value = value
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}
