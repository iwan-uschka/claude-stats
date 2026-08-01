import Foundation
import Security

/// Supplies the OAuth bearer token for ``OAuthUsageClient``.
///
/// Synchronous and throwing: every implementation is a local read (file or
/// Keychain), and failure means "no credentials", not "try again later".
///
/// Implementations must never include the token value in a thrown error's
/// message, and callers must never log the returned string.
public protocol OAuthTokenProviding: Sendable {
    /// - Throws: ``ClaudeStatsError/missingCredentials`` when no token can be read.
    func accessToken() throws -> String
}

// MARK: - Shared JSON extraction

/// Pulls an access token out of a Claude Code credentials JSON blob.
///
/// The same blob shape is used whether it lives in a file or in the Keychain, so
/// both stores share this. Key paths are probed in order because the layout is
/// undocumented and has moved before; the documented/most-cited path is
/// `claudeAiOauth.accessToken`.
enum OAuthCredentialsJSON {
    /// Ordered candidate key paths, most-likely first.
    static let candidateKeyPaths: [[String]] = [
        ["claudeAiOauth", "accessToken"],
        ["claudeAiOauth", "access_token"],
        ["claudeAiOAuth", "accessToken"],
        ["oauth", "accessToken"],
        ["oauth", "access_token"],
        ["oauthAccount", "accessToken"],
        ["credentials", "accessToken"],
        ["accessToken"],
        ["access_token"],
    ]

    /// Leaf key names accepted by the recursive fallback search.
    static let leafKeyNames: Set<String> = ["accessToken", "access_token"]

    static func accessToken(from data: Data) -> String? {
        guard let root = QuotaJSON.object(try? JSONSerialization.jsonObject(with: data)) else {
            return nil
        }
        for path in candidateKeyPaths {
            if let token = string(at: path, in: root) { return token }
        }
        // Last resort: the token moved somewhere we didn't predict. Depth-limited
        // so a pathological blob can't spin.
        return firstLeafToken(in: root, depth: 0)
    }

    private static func string(at path: [String], in root: [String: Any]) -> String? {
        var current: Any? = root
        for key in path {
            guard let dict = QuotaJSON.object(current) else { return nil }
            current = dict[key]
        }
        guard let value = current as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func firstLeafToken(in dict: [String: Any], depth: Int) -> String? {
        guard depth < 4 else { return nil }
        for name in leafKeyNames {
            if let value = dict[name] as? String, !value.isEmpty { return value }
        }
        for value in dict.values {
            if let nested = QuotaJSON.object(value),
               let token = firstLeafToken(in: nested, depth: depth + 1) {
                return token
            }
        }
        return nil
    }
}

// MARK: - File-backed store

/// Reads the token from Claude Code's credentials **file**.
///
/// Default path `~/.claude/.credentials.json` (honouring `$CLAUDE_CONFIG_DIR`).
/// Note that this file does not exist on every machine: on macOS, Claude Code
/// generally keeps credentials in the login Keychain instead and only writes a
/// plaintext file on Linux or when Keychain access is unavailable. Chain this
/// with ``KeychainOAuthTokenStore`` rather than relying on it alone — see
/// ``ClaudeOAuthTokenStore``.
public struct FileOAuthTokenStore: OAuthTokenProviding {
    /// Candidate credentials files, in probe order.
    public static var defaultURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls: [URL] = []
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
            urls.append(URL(fileURLWithPath: configDir, isDirectory: true)
                .appendingPathComponent(".credentials.json"))
        }
        urls.append(home.appendingPathComponent(".claude/.credentials.json"))
        urls.append(home.appendingPathComponent(".config/claude/.credentials.json"))
        return urls
    }

    public let urls: [URL]
    private let fileManager: FileManager

    public init(urls: [URL] = FileOAuthTokenStore.defaultURLs, fileManager: FileManager = .default) {
        self.urls = urls
        self.fileManager = fileManager
    }

    /// Convenience for a single explicit path (used by tests).
    public init(url: URL, fileManager: FileManager = .default) {
        self.init(urls: [url], fileManager: fileManager)
    }

    public func accessToken() throws -> String {
        for url in urls {
            guard let data = fileManager.contents(atPath: url.path) else { continue }
            if let token = OAuthCredentialsJSON.accessToken(from: data) { return token }
        }
        throw ClaudeStatsError.missingCredentials
    }
}

// MARK: - Keychain-backed store

/// Reads the token from the macOS login Keychain.
///
/// Claude Code stores the same JSON blob as the credentials file in a
/// generic-password item under the service name `Claude Code-credentials`
/// (verified present on this machine, where no `.credentials.json` exists). The
/// account name is not constrained, so the first matching item wins.
///
/// The first read prompts the user for Keychain access, since this app is a
/// different binary from the one that created the item.
public struct KeychainOAuthTokenStore: OAuthTokenProviding {
    public static let defaultService = "Claude Code-credentials"

    public let service: String

    public init(service: String = KeychainOAuthTokenStore.defaultService) {
        self.service = service
    }

    public func accessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = OAuthCredentialsJSON.accessToken(from: data) else {
            throw ClaudeStatsError.missingCredentials
        }
        return token
    }
}

// MARK: - Chain

/// Tries each store in order and returns the first token found.
public struct ChainedOAuthTokenStore: OAuthTokenProviding {
    public let stores: [OAuthTokenProviding]

    public init(_ stores: [OAuthTokenProviding]) {
        self.stores = stores
    }

    public func accessToken() throws -> String {
        for store in stores {
            if let token = try? store.accessToken() { return token }
        }
        throw ClaudeStatsError.missingCredentials
    }
}

/// The production token source: credentials file first (cheap, no prompt), then
/// the login Keychain.
public enum ClaudeOAuthTokenStore {
    public static func makeDefault() -> OAuthTokenProviding {
        ChainedOAuthTokenStore([FileOAuthTokenStore(), KeychainOAuthTokenStore()])
    }
}
