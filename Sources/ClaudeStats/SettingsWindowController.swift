import AppKit
import SwiftUI

/// Owns the single Settings window's lifecycle.
///
/// The app is `.accessory` policy (no Dock icon, no `WindowGroup`), so this is
/// the only real `NSWindow` it ever shows. Created lazily on the first
/// "Settings" click and kept alive after that (`isReleasedWhenClosed = false`)
/// so closing and reopening it doesn't rebuild SwiftUI state each time.
@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        let target = window ?? makeWindow(model: model)
        window = target
        // `makeKeyAndOrderFront` alone doesn't reliably restore a miniaturized
        // window across macOS versions — since this window is kept alive and
        // reused (not recreated), a user who minimized it in a prior session
        // can reopen "Settings" and get a window that looks ordered front but
        // stays non-interactive. Deminiaturize explicitly first.
        if target.isMiniaturized {
            target.deminiaturize(nil)
        }
        // Same reasoning as the popover's `NSApp.activate` call: an
        // `.accessory`-policy app has no Dock icon to click, so nothing else
        // brings this window to the front or gives it key status.
        NSApp.activate(ignoringOtherApps: true)
        target.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow(model: AppModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Stats Settings"
        window.isReleasedWhenClosed = false
        window.center()
        // `contentViewController` (not `contentView`) so the window adopts the
        // hosting controller's fitting size instead of squeezing dynamic
        // SwiftUI content into the fixed `contentRect` height above.
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        return window
    }
}
