import Foundation

/// Returns true if `url` is safe to hand to NSWorkspace.open as a release page:
/// https only, host exactly github.com. Release `html_url` values from the GitHub
/// API always live on github.com itself, so subdomains are deliberately rejected.
public func isTrustedReleaseURL(_ url: URL) -> Bool {
    url.scheme == "https" && url.host == "github.com"
}
