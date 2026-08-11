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

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[ClaudeStats] LaunchAtLogin.setEnabled(\(enabled)) failed: \(error)")
        }
    }
}
