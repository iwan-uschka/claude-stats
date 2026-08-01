import Foundation

/// One-second clock driving the popover's reset countdowns and freshness tag.
///
/// Gated deliberately: a menu bar app lives for weeks, so it must not wake up
/// once a second to re-render a popover nobody can see. ``StatusItemController``
/// resumes it as the popover opens and suspends it in `popoverDidClose`, which is
/// exact — unlike inferring visibility from SwiftUI's `onAppear`/`onDisappear`
/// inside an `NSPopover`.
@MainActor
final class PopoverClock: ObservableObject {
    @Published private(set) var now: Date

    private var timer: Timer?

    /// - Parameter now: starting value; injectable so previews stay deterministic
    ///   (a clock that is never resumed simply never ticks).
    init(now: Date = Date()) {
        self.now = now
    }

    var isRunning: Bool { timer != nil }

    /// Start ticking, publishing an immediate value so a reopened popover never
    /// shows the countdown from when it was last closed.
    func resume() {
        now = Date()
        guard timer == nil else { return }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.now = Date()
            }
        }
        // `.common` so the clock keeps ticking during popover event tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func suspend() {
        timer?.invalidate()
        timer = nil
    }
}
