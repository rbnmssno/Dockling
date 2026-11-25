import AppKit
import CoreText
import os

/// Development output and error logging.
enum Log {
    private static let logger = Logger(subsystem: "app.dockling.Dockling", category: "app")
    static var echo = false

    static func debug(_ message: @autoclosure () -> String) {
        guard echo else { return }
        FileHandle.standardError.write(Data((message() + "\n").utf8))
    }

    /// What happened, kept in the system log so a feature can be checked after the fact
    /// (`log show --predicate 'subsystem == "app.dockling.Dockling"' --last 1h`). Short technical text only.
    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        debug(message)
    }

    /// Problems worth keeping in the system log. Callers pass technical text only.
    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        debug("error: " + message)
    }
}

/// A cancellable one-shot timer on the main queue.
final class OneShot {
    private var item: DispatchWorkItem?

    var isPending: Bool { item != nil }

    /// `wallClock`: count real time, sleep included (reminders, meetings). Otherwise the timer stops
    /// while the Mac sleeps, like the animations it keeps in step with.
    func schedule(after delay: TimeInterval, wallClock: Bool = false, _ block: @escaping () -> Void) {
        item?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.item = nil
            block()
        }
        item = work
        if wallClock {
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, delay), execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
        }
    }

    func cancel() {
        item?.cancel()
        item = nil
    }

    deinit { item?.cancel() }
}

extension Comparable {
    func clamped(_ low: Self, _ high: Self) -> Self { min(max(self, low), high) }
}

/// Where the app keeps its own files.
enum Paths {
    static let support: URL = {
        // An `--isolated` test run keeps its hook socket, reminders and chat folder in a temporary folder,
        // away from the Dockling the user is running.
        let url = DevTools.isolated
            ? FileManager.default.temporaryDirectory.appendingPathComponent("Dockling-isolated", isDirectory: true)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Dockling", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func folder(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// The pixel face: Pixelify Sans with C and 5 made unambiguous (SIL OFL 1.1), shipped in the bundle.
enum PixelFont {
    static let name = "Ghost Pixel"

    static func register() {
        guard let url = Bundle.main.url(forResource: "GhostPixel", withExtension: "ttf") else {
            Log.error("pixel font missing from the bundle")
            return
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            Log.error("pixel font not registered")
        }
    }

    static func ns(_ size: CGFloat) -> NSFont {
        NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .semibold)
    }
}
