import AppKit

/// Where the Dock is. macOS does not tell apps the Dock's size, so the walking range is worked out
/// from the Dock's own settings (icon size, pinned items) and the apps that are running.
struct DockInfo: Equatable {
    /// The screen the Dock is on, in global coordinates.
    var screen: CGRect
    /// Height of the line the character stands on, in global coordinates.
    var floorY: CGFloat
    /// Horizontal range of the Dock, in global coordinates.
    var minX: CGFloat
    var maxX: CGFloat
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

enum DockGeometry {
    static func current() -> DockInfo {
        // The README showcase plays on a Dock of its own.
        if let stage = Showcase.stage { return stage }
        let screens = NSScreen.screens
        let dock = UserDefaults(suiteName: "com.apple.dock")
        // The Dock's screen is the one whose usable area is cut at the bottom. When no screen shows that
        // (yet), the display holding the Dock's own screen-sized window decides.
        let bottomInset = { (s: NSScreen) in s.visibleFrame.minY - s.frame.minY }
        let byInset = screens.filter { bottomInset($0) > 20 }.max(by: { bottomInset($0) < bottomInset($1) })
        let byWindow = byInset == nil ? dockDisplay().flatMap { id in screens.first { $0.displayID == id } } : nil
        let dockScreen = byInset ?? byWindow ?? NSScreen.main ?? screens[0]
        let frame = dockScreen.frame
        var inset = bottomInset(dockScreen)
        let orientation = dock?.string(forKey: "orientation") ?? "bottom"
        let autohide = dock?.bool(forKey: "autohide") ?? false
        if inset <= 20 && byWindow != nil && orientation == "bottom" && !autohide {
            // The screen's usable area has not caught up with the move yet: the Dock is its icons plus a margin.
            let tile = CGFloat(dock?.double(forKey: "tilesize") ?? 0)
            inset = (tile > 0 ? tile : 64) + 26
        }

        // Standing line: the top edge of the Dock, or the bottom of the screen when the Dock hides or sits at a side.
        let floorY: CGFloat
        if orientation == "bottom" && !autohide && inset > 20 {
            floorY = frame.minY + inset - 6
        } else {
            floorY = frame.minY + 2
        }

        let width = estimatedWidth(dock: dock, orientation: orientation)
        var minX = frame.midX - width / 2
        var maxX = frame.midX + width / 2
        if orientation != "bottom" || autohide || inset <= 20 {
            // No Dock to stand on: he walks along the middle part of the screen's bottom edge.
            minX = frame.minX + frame.width * 0.2
            maxX = frame.maxX - frame.width * 0.2
        }
        return DockInfo(screen: frame, floorY: floorY, minX: max(frame.minX, minX), maxX: min(frame.maxX, maxX))
    }

    // MARK: - Which display the Dock is on

    private static var dockWindowID: CGWindowID?

    /// The display that holds the Dock's own screen-sized window (layer 20). Looking up one known window
    /// is cheap, so this can run every couple of seconds.
    static func dockDisplay() -> CGDirectDisplayID? {
        if let id = dockWindowID, let bounds = bounds(of: id) { return display(containing: bounds) }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "Dock" && (w[kCGWindowLayer as String] as? Int) == 20 {
            guard let number = w[kCGWindowNumber as String] as? Int,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
            dockWindowID = CGWindowID(number)
            return display(containing: bounds)
        }
        dockWindowID = nil
        return nil
    }

    private static func bounds(of id: CGWindowID) -> CGRect? {
        let ids = [UnsafeRawPointer(bitPattern: UInt(id))] as CFArray
        guard let info = (CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let dict = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict)
    }

    private static func display(containing bounds: CGRect) -> CGDirectDisplayID? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(center, 1, &id, &count) == .success, count > 0 else { return nil }
        return id
    }

    private static func estimatedWidth(dock: UserDefaults?, orientation: String) -> CGFloat {
        let tile = CGFloat(dock?.double(forKey: "tilesize") ?? 0) > 0 ? CGFloat(dock!.double(forKey: "tilesize")) : 64
        let pinned = dock?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        let pinnedIDs = Set(pinned.compactMap { (($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String) })
        let others = (dock?.array(forKey: "persistent-others") as? [Any])?.count ?? 0
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != "com.apple.finder" && !pinnedIDs.contains($0.bundleIdentifier ?? "")
        }.count
        let showRecents = dock?.object(forKey: "show-recents") as? Bool ?? true
        let recents = showRecents ? min(3, (dock?.array(forKey: "recent-apps") as? [Any])?.count ?? 0) : 0
        // Finder, pinned apps, running apps, recents, then a separator, folders and the Trash.
        let icons = 1 + pinned.count + running + recents + others + 1
        let separators = 1 + (recents > 0 ? 1 : 0)
        Log.debug("dock estimate: tile \(tile) pinned \(pinned.count) running \(running) recents \(recents) others \(others) -> \(icons) icons")
        return CGFloat(icons) * tile * 1.04 + CGFloat(separators) * tile * 0.32 + 24
    }
}
