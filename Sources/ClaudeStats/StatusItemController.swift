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
    /// Diameter of the dev-build indicator dot — see ``addDevBuildIndicator``.
    private static let devDotDiameter: CGFloat = 6

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
            button.toolTip = "Claude Stats" + (BuildEnvironment.isDevelopmentBuild ? BuildEnvironment.devBuildSuffix : "")
            button.target = self
            button.action = #selector(togglePopover(_:))

            if BuildEnvironment.isDevelopmentBuild {
                addDevBuildIndicator(to: button)
            }
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

    /// Overlays a small colored dot on the status item's top-left corner.
    ///
    /// The glyph itself is a template `NSImage` — macOS strips any color it
    /// contains and renders it monochrome, so a colored dev-build marker has
    /// to live outside the image, as a real subview on the button.
    private func addDevBuildIndicator(to button: NSStatusBarButton) {
        // The button's bounds are the menu bar's own thickness, not the drawn
        // glyph's size — the (smaller) image is centered inside it. Anchor the
        // dot to the image's actual corner, not the button's, so it lands on
        // the glyph rather than in the surrounding padding.
        let bounds = button.bounds
        let imageOrigin = CGPoint(
            x: (bounds.width - MenuBarGlyph.width) / 2,
            y: (bounds.height - MenuBarGlyph.height) / 2
        )
        let dot = DevBuildDotView(frame: CGRect(
            x: imageOrigin.x,
            y: imageOrigin.y + MenuBarGlyph.height - Self.devDotDiameter,
            width: Self.devDotDiameter,
            height: Self.devDotDiameter
        ))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.devDotDiameter / 2
        dot.updateBackgroundColor()
        dot.autoresizingMask = [.maxXMargin, .minYMargin]
        button.addSubview(dot)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard statusItem.button != nil else { return }
        // An `.accessory`-policy app never otherwise activates; without this,
        // NSPopover's anchor math for a status-item button is unreliable and
        // the popover can render overlapping the menu bar instead of below it.
        // Activation is asynchronous — showing the popover on the same
        // run-loop turn still sees pre-activation window-server state, so the
        // actual `show` is deferred to the next tick.
        NSApp.activate(ignoringOtherApps: true)
        model.refresh()
        clock.resume()
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            // NSHostingController's fitting size isn't reliably ready the
            // instant the popover is asked to show — `show()` can anchor
            // using a stale/undersized layout and never re-anchor once
            // SwiftUI's real size lands, leaving the window's top edge
            // wherever the wrong size put it (observed: overlapping the menu
            // bar). Forcing layout and handing NSPopover the real size first
            // makes the anchor math correct from the first frame.
            if let hostingView = self.popover.contentViewController?.view {
                hostingView.layoutSubtreeIfNeeded()
                self.popover.contentSize = hostingView.fittingSize
            }
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Fires for every dismissal path — the button, Escape, and clicking away
    /// from a `.transient` popover.
    func popoverDidClose(_ notification: Notification) {
        clock.suspend()
    }
}

/// The dev-build indicator dot. `NSColor.systemOrange.cgColor` resolves once,
/// against whatever appearance is current at the call site — a plain
/// `NSView`'s layer would keep that light/dark snapshot forever. This
/// re-resolves on every effective-appearance change instead.
private final class DevBuildDotView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    func updateBackgroundColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.systemOrange.cgColor
        }
    }
}
