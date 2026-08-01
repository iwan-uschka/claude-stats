import AppKit
import ClaudeStatsCore
import Combine
import SwiftUI

/// Owns the `NSStatusItem` and its popover.
///
/// The button shows the ``MenuBarGlyph`` template image (Claude mark + two thin
/// window bars) and is redrawn whenever ``AppModel`` publishes a new snapshot.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel
    /// Ticks only while the popover is on screen — see ``PopoverClock``.
    private let clock = PopoverClock()
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = MenuBarGlyph.image(for: model.snapshot)
            button.imagePosition = .imageOnly
            button.toolTip = "Claude Stats"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popover.behavior = .transient
        popover.delegate = self
        // No explicit contentSize: the hosting controller reports the SwiftUI
        // layout's fitting size, so the popover tracks the real content height.
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: model, clock: clock)
        )

        observeModel()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Redraw the glyph on every new quota reading.
    private func observeModel() {
        model.$snapshot
            .removeDuplicates()
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated {
                    self?.updateGlyph(for: snapshot)
                }
            }
            .store(in: &cancellables)
    }

    private func updateGlyph(for snapshot: QuotaSnapshot?) {
        statusItem.button?.image = MenuBarGlyph.image(for: snapshot)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        model.refresh()
        clock.resume()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Fires for every dismissal path — the button, Escape, and clicking away
    /// from a `.transient` popover.
    func popoverDidClose(_ notification: Notification) {
        clock.suspend()
    }
}
