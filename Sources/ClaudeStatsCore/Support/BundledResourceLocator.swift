import Foundation

/// Resolves a file inside a SwiftPM-generated resource bundle without relying
/// on `Bundle.module`, which only checks `Bundle.main.bundleURL` (the `.app`
/// bundle's own root, not `Contents/Resources`) and a `.build/...` path baked
/// in at compile time on whichever machine built the release — never present
/// on a machine that only downloaded the zip. Worse, merely referencing
/// `Bundle.module` crashes the process outright if both candidates miss,
/// rather than returning `nil`.
///
/// Pure and injectable (`fileExists`) so it's testable without touching the
/// filesystem or `AppKit`.
public enum BundledResourceLocator {
    public static func resolve(
        bundleName: String,
        fileName: String,
        candidateDirectories: [URL?],
        fileExists: (String) -> Bool
    ) -> URL? {
        for directory in candidateDirectories {
            guard let fileURL = directory?
                .appendingPathComponent(bundleName)
                .appendingPathComponent(fileName)
            else { continue }
            if fileExists(fileURL.path) {
                return fileURL
            }
        }
        return nil
    }
}
