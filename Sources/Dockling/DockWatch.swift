import AppKit

/// Notices the Dock going to another display, so the pet can follow at once.
///
/// macOS tells apps nothing about it, but the Dock moves in one way only: the cursor is pushed against
/// the bottom edge of a display the Dock is not on. So a transparent strip lies along that edge on
/// every other display. The cursor entering one starts a short run of looks at where the Dock's window
/// is, a few hundredths of a second apart, which ends when the Dock has moved or two seconds have
/// passed. Nothing runs while the cursor is anywhere else; a slow look every few seconds is the safety
/// net. With one display there is nothing at all.
final class DockWatch {
    /// The Dock is on another display than `dockScreen`.
    var onMove: (() -> Void)?
    /// The display the pet stands on. Setting it lays the strips out on the others.
    var dockScreen: CGRect = .zero {
        didSet { if dockScreen != oldValue { layOut() } }
    }

    private var strips: [NSPanel] = []
    private var run: DispatchSourceTimer?
    private var net: DispatchSourceTimer?
    private var looksLeft = 0
    private var activity: NSObjectProtocol?

    /// Screens were added, removed or rearranged.
    func screensChanged() { layOut() }

    private func layOut() {
        strips.forEach { $0.orderOut(nil) }
        strips.removeAll()
        let screens = NSScreen.screens.map(\.frame)
        guard screens.count > 1, dockScreen != .zero else {
            net?.cancel()
            net = nil
            return
        }
        for screen in screens where screen != dockScreen {
            for part in Self.freeBottomEdge(of: screen, among: screens) {
                strips.append(makeStrip(CGRect(x: part.lowerBound, y: screen.minY, width: part.upperBound - part.lowerBound, height: 4)))
            }
        }
        Log.debug("dock watch: \(strips.count) edge strips, Dock on \(dockScreen)")
        if net == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 4, repeating: 4, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in self?.look() }
            timer.resume()
            net = timer
        }
    }

    /// The parts of a display's bottom edge with no other display right below: only there can the
    /// cursor be pushed against the edge.
    static func freeBottomEdge(of screen: CGRect, among screens: [CGRect]) -> [ClosedRange<CGFloat>] {
        var parts = [screen.minX...screen.maxX]
        for other in screens where other != screen && abs(other.maxY - screen.minY) < 1 {
            parts = parts.flatMap { part -> [ClosedRange<CGFloat>] in
                let lo = max(part.lowerBound, other.minX), hi = min(part.upperBound, other.maxX)
                guard lo < hi else { return [part] }
                return [part.lowerBound...lo, hi...part.upperBound]
            }
        }
        return parts.filter { $0.upperBound - $0.lowerBound > 8 }
    }

    private func makeStrip(_ frame: CGRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        // On every Space, full-screen ones too: the Dock can be called from any of them.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let edge = EdgeView(frame: CGRect(origin: .zero, size: frame.size))
        edge.entered = { [weak self] in self?.startRun() }
        panel.contentView = edge
        panel.orderFrontRegardless()
        return panel
    }

    /// The Dock moves about a fifth of a second after the cursor reaches the edge.
    private func startRun() {
        Log.debug("dock watch: cursor at an edge")
        looksLeft = 66
        guard run == nil else { return }
        // Not slowed down by App Nap while he is out of sight.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Following the Dock")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.03, repeating: 0.03, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.looksLeft -= 1
            if self.look() || self.looksLeft <= 0 { self.stopRun() }
        }
        timer.resume()
        run = timer
    }

    private func stopRun() {
        run?.cancel()
        run = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// True when the Dock is on another display, after telling so.
    @discardableResult
    private func look() -> Bool {
        guard let now = DockGeometry.dockScreen(), now != dockScreen else { return false }
        Log.debug("dock watch: the Dock is on \(now)")
        onMove?()
        return true
    }
}

/// A transparent strip that says when the cursor comes onto it. Being fully transparent, it lets
/// clicks through to whatever is underneath.
private final class EdgeView: NSView {
    var entered: (() -> Void)?

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { entered?() }
}
