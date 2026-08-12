import Foundation

/// Single source of truth for "is this a `swift build`/`swift run` dev binary,
/// not the packaged `.app` release" — consumed by ``LaunchAtLogin``,
/// ``MenuBarGlyph``, and ``StatusItemController``.
enum BuildEnvironment {
    /// `SMAppService.mainApp` (login items) and dev-build UI markers all need
    /// a real `.app` bundle; a bundle-less dev binary doesn't have one.
    static var isDevelopmentBuild: Bool {
        Bundle.main.bundleURL.pathExtension != "app"
    }

    /// Shared label suffix for dev-build UI markers (tooltip, accessibility
    /// description) so the wording doesn't drift between call sites.
    static let devBuildSuffix = " (dev)"
}
