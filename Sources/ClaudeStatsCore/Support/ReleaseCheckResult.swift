import Foundation

/// Outcome of comparing a GitHub "latest release" API response against the
/// running app's local version.
public enum ReleaseCheckResult: Equatable {
    case updateAvailable(version: String, url: String)
    case upToDate(version: String)
    case malformedResponse
    case httpError(Int)
}

/// Decodes a GitHub `/releases/latest` response body and decides the outcome
/// against `localVersion`. Pure — no networking — so the malformed-JSON and
/// HTTP-error branches are unit-testable without a live request.
public func decodeReleaseCheck(data: Data, httpStatus: Int, localVersion: String) -> ReleaseCheckResult {
    // URLSession only throws on transport errors; HTTP errors (403 rate limit,
    // 404, 500) still return a body, just without tag_name.
    guard (200...299).contains(httpStatus) else {
        return .httpError(httpStatus)
    }
    let json: [String: Any]
    do {
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformedResponse
        }
        json = parsed
    } catch {
        return .malformedResponse
    }
    guard
        let tag = json["tag_name"] as? String,
        let releaseURL = json["html_url"] as? String
    else {
        return .malformedResponse
    }

    let remote = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    if isVersionNewer(remote, than: localVersion) {
        return .updateAvailable(version: remote, url: releaseURL)
    }
    return .upToDate(version: localVersion)
}
