import AppKit

/// Whether an app fills a screen: a full-screen video, game or app. The Dock steps aside then, and so
/// does the pet.
enum FullScreen {
    /// True when the Dock has taken its window off the screen and another app's window covers it, full
    /// width down to the bottom edge. On a screen with a notch a full-screen app starts below the camera
    /// housing, so the top may stay uncovered by that much. Window bounds and owners are readable
    /// without any permission; names and contents are not read.
    static func covers(_ screen: CGRect) -> Bool {
        guard let main = NSScreen.screens.first?.frame else { return false }
        // Window bounds count from the top left of the main display.
        let target = CGRect(x: screen.minX, y: main.maxY - screen.maxY, width: screen.width, height: screen.height)
        let notch = NSScreen.screens.first { $0.frame == screen }?.safeAreaInsets.top ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { w -> (pid: Int32, layer: Int, alpha: Double, bounds: CGRect)? in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            return (pid, w[kCGWindowLayer as String] as? Int ?? 0, w[kCGWindowAlpha as String] as? Double ?? 1, bounds)
        }
        // The Dock keeps a screen-sized window on its screen, and removes it while a full-screen app shows there.
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        if windows.contains(where: { $0.pid == dock && $0.layer == dockLevel && $0.bounds.intersects(target) }) { return false }
        return windows.contains { w in
            w.layer == 0 && w.pid != me && w.pid != dock && w.alpha > 0.01 &&
                w.bounds.minX <= target.minX + 1 && w.bounds.maxX >= target.maxX - 1 &&
                w.bounds.maxY >= target.maxY - 1 && w.bounds.minY <= target.minY + notch + 2
        }
    }
}
