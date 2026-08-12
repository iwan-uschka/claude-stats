import ServiceManagement

/// Registers/unregisters this app bundle itself as a login item.
///
/// `SMAppService.mainApp` (macOS 13+) relaunches the main app bundle directly —
/// no separate helper target or LaunchAgent plist needed, unlike the older
/// `SMLoginItemSetEnabled` API.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// macOS registered the login item but is holding it for the user to
    /// approve in System Settings → General → Login Items. `isEnabled` reads
    /// `false` in this state even though registration succeeded.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// `SMAppService.mainApp` needs a real `.app` bundle to register as a
    /// login item; a bundle-less `swift build` dev binary can't.
    static var isSupported: Bool {
        !BuildEnvironment.isDevelopmentBuild
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            print("[ClaudeStats] LaunchAtLogin.setEnabled(\(enabled)) failed: \(error)")
            return false
        }
    }
}
