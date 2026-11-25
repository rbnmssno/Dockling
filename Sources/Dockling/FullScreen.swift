import AppKit

/// Whether a display is showing a full-screen Space: a video, a game or an app in macOS's full screen.
///
/// macOS has no public call for this, so the window server is asked directly, the way window managers
/// do (`CGSCopyManagedDisplaySpaces`): each display reports the Space it shows and its kind. The
/// symbols are looked up at run time; if a future macOS drops them, a window that covers the whole
/// screen counts as full screen instead.
enum FullScreen {
    /// True when the answer comes from the window server itself and is right the moment a Space changes.
    static let exact = mainConnection != nil && copySpaces != nil

    static func isShowing(on screen: CGRect) -> Bool {
        spaceIsFullScreen(on: screen) ?? windowCovers(screen)
    }

    // MARK: - The window server's own answer

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let mainConnection: MainConnection? = symbol("CGSMainConnectionID")
    private static let copySpaces: CopySpaces? = symbol("CGSCopyManagedDisplaySpaces")
    /// The kind macOS gives a full-screen (or Split View) Space; a desktop is 0.
    private static let fullScreenKind = 4

    private static func symbol<T>(_ name: String) -> T? {
        // RTLD_DEFAULT: every library the app has loaded.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }
    }

    private static func spaceIsFullScreen(on screen: CGRect) -> Bool? {
        guard let mainConnection, let copySpaces,
              let displays = copySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let uuid = NSScreen.screens.first { $0.frame == screen }?.displayID
            .flatMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
            .map { CFUUIDCreateString(nil, $0) as String }
        // With "Displays have separate Spaces" off there is one entry for all displays.
        let entry = displays.first { ($0["Display Identifier"] as? String) == uuid } ?? (displays.count == 1 ? displays[0] : nil)
        guard let kind = (entry?["Current Space"] as? [String: Any])?["type"] as? Int else { return nil }
        return kind == fullScreenKind
    }

    // MARK: - Without it

    /// Another app's normal window covers the screen, full width down to the bottom edge. On a screen
    /// with a notch a full-screen app starts below the camera housing.
    private static func windowCovers(_ screen: CGRect) -> Bool {
        guard let main = NSScreen.screens.first?.frame else { return false }
        // Window bounds count from the top left of the main display.
        let target = CGRect(x: screen.minX, y: main.maxY - screen.maxY, width: screen.width, height: screen.height)
        let notch = NSScreen.screens.first { $0.frame == screen }?.safeAreaInsets.top ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: dict) else { return false }
            return b.minX <= target.minX + 1 && b.maxX >= target.maxX - 1 && b.maxY >= target.maxY - 1 && b.minY <= target.minY + notch + 2
        }
    }
}
