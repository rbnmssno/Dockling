import AppKit
import SwiftUI

/// A rounded piece of the system's Liquid Glass with content inside. On systems before macOS 26 it falls
/// back to the frosted material.
final class GlassBox: NSView {
    private let glass: NSView
    /// Frosted glass under the clear one; fading it in and out gives a gradual blur, which the system
    /// glass does not offer by itself (it has only a frosted and a clear style).
    private var frost: NSView?
    let content: NSView

    init(content: NSView, cornerRadius: CGFloat) {
        self.content = content
        if #available(macOS 26.0, *) {
            let f = NSGlassEffectView()
            f.style = .regular
            f.cornerRadius = cornerRadius
            frost = f
            let g = NSGlassEffectView()
            g.style = .clear
            g.cornerRadius = cornerRadius
            g.contentView = content
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = cornerRadius
            v.layer?.masksToBounds = true
            v.addSubview(content)
            glass = v
        }
        super.init(frame: .zero)
        wantsLayer = true
        // A half-faded frosted glass is drawn as its whole rectangle; the mask keeps the corners round.
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        if let frost { addSubview(frost) }
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        frost?.frame = bounds
        glass.frame = bounds
        if !(glass is NSGlassEffectViewCompat) { content.frame = bounds }
    }

    /// How the slider maps to the glass: the tint (how solid the panel is) and the frost (how blurred
    /// what lies behind it is) both change gradually over the whole range, with no step anywhere.
    /// `clarity` is how sharply what lies behind shows through (0 hidden or blurred, 1 sharp); the chat
    /// makes its bubbles denser with it so text stays readable.
    static func look(_ transparency: Double) -> (tint: Double, frost: Double, clarity: Double) {
        let t = (transparency / 100).clamped(0, 1)
        let tint = 0.05 + 0.9 * pow(1 - t, 1.6)
        // How much sharp detail from behind comes through. The eye picks up even a faint sharp image
        // over a blurred one, so it rises slowly at first (a square curve) and fully only at 100.
        let x = ((t - 0.15) / 0.85).clamped(0, 1)
        let sharp = 0.95 * x * x
        // The frosted layer is whatever the tint leaves to cover.
        let frost = (1 - sharp / (1 - tint)).clamped(0, 1)
        return (tint, frost, (sharp / 0.95).clamped(0, 1))
    }

    /// Light or dark glass, from solid (0) to clear like the Dock (100).
    func apply(dark: Bool, transparency: Double) {
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let look = Self.look(transparency)
        if #available(macOS 26.0, *), let g = glass as? NSGlassEffectView {
            let base: NSColor = dark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 1, alpha: 1)
            g.tintColor = base.withAlphaComponent(look.tint)
            frost?.alphaValue = look.frost
            frost?.isHidden = look.frost < 0.01
        }
    }
}

/// Marker so the layout above can tell the system glass, which places its content itself.
private protocol NSGlassEffectViewCompat {}
@available(macOS 26.0, *)
extension NSGlassEffectView: NSGlassEffectViewCompat {}

// MARK: - Pixel shapes shared by the chat and the cards

/// A rectangle whose corners are cut in pixel steps, like the bubbles in the prototype.
struct PixelRect: Shape {
    var step: CGFloat = 3

    func path(in r: CGRect) -> Path {
        let s = step
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - 2 * s))
        p.closeSubpath()
        return p
    }
}

/// 8×8 and 10×10 pixel icons, drawn as unions of squares.
enum PixelIcon: String {
    case code, lock, done, fail, calendar, clock, battery, limit, camera, mic, send, stop, close

    var grid: (Int, String) {
        switch self {
        case .code: return (8, "M1 1h1v1H1zM2 2h1v1H2zM3 3h1v1H3zM2 4h1v1H2zM1 5h1v1H1zM4 6h3v1H4z")
        case .lock: return (8, "M2 0h4v1H2zM1 1h1v2H1zM6 1h1v2H6zM0 3h8v1H0zM0 7h8v1H0zM0 4h1v3H0zM7 4h1v3H7zM3 4h2v2H3z")
        case .done: return (8, "M7 1h1v2H7zM6 2h1v2H6zM5 3h1v2H5zM4 4h1v2H4zM3 5h1v2H3zM2 4h1v2H2zM1 3h1v2H1z")
        case .fail: return (8, "M3 1h2v4H3zM3 6h2v1H3z")
        case .calendar: return (8, "M2 0h1v1H2zM5 0h1v1H5zM1 1h6v2H1zM1 3h1v4H1zM6 3h1v4H6zM1 7h6v1H1zM3 4h2v2H3z")
        case .clock: return (8, "M2 0h4v1H2zM1 1h1v1H1zM6 1h1v1H6zM0 2h1v4H0zM7 2h1v4H7zM1 6h1v1H1zM6 6h1v1H6zM2 7h4v1H2zM3 2h1v3H3zM4 4h2v1H4z")
        case .battery: return (8, "M0 2h7v1H0zM0 5h7v1H0zM0 3h1v2H0zM6 3h1v2H6zM7 3h1v2H7zM1 3h1v2H1z")
        case .limit: return (8, "M0 5h2v2H0zM3 3h2v4H3zM6 1h2v6H6z")
        case .camera: return (8, "M2 1h3v1H2zM0 2h8v1H0zM0 7h8v1H0zM0 3h1v4H0zM7 3h1v4H7zM3 3h2v1H3zM2 4h1v2H2zM5 4h1v2H5zM3 6h2v1H3z")
        case .mic: return (10, "M4 0h2v1H4zM3 1h4v4H3zM4 5h2v1H4zM1 3h1v2H1zM8 3h1v2H8zM2 5h1v1H2zM7 5h1v1H7zM3 6h4v1H3zM4 7h2v2H4zM3 9h4v1H3z")
        case .send: return (10, "M4 1h2v1H4zM3 2h4v1H3zM2 3h6v1H2zM1 4h8v1H1zM4 5h2v4H4z")
        case .stop: return (10, "M2 2h6v6H2z")
        case .close: return (7, "M0 0h1v1H0zM1 1h1v1H1zM2 2h1v1H2zM3 3h1v1H3zM4 4h1v1H4zM5 5h1v1H5zM6 6h1v1H6zM6 0h1v1H6zM5 1h1v1H5zM4 2h1v1H4zM2 4h1v1H2zM1 5h1v1H1zM0 6h1v1H0z")
        }
    }
}

struct PixelIconShape: Shape {
    let icon: PixelIcon

    func path(in r: CGRect) -> Path {
        let (n, d) = icon.grid
        let cell = min(r.width, r.height) / CGFloat(n)
        let ox = r.midX - cell * CGFloat(n) / 2, oy = r.midY - cell * CGFloat(n) / 2
        var p = Path()
        // The path strings are lists of "Mx yhWvH...z" squares.
        let scanner = Scanner(string: d)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: "z ")
        while !scanner.isAtEnd {
            guard scanner.scanString("M") != nil, let x = scanner.scanDouble(), let y = scanner.scanDouble(),
                  scanner.scanString("h") != nil, let w = scanner.scanDouble(),
                  scanner.scanString("v") != nil, let h = scanner.scanDouble() else { break }
            _ = scanner.scanString("H")
            _ = scanner.scanDouble()
            _ = scanner.scanString("z")
            p.addRect(CGRect(x: ox + CGFloat(x) * cell, y: oy + CGFloat(y) * cell, width: CGFloat(w) * cell, height: CGFloat(h) * cell))
        }
        return p
    }
}

extension Font {
    static func pixel(_ size: CGFloat) -> Font { .custom(PixelFont.name, size: size) }
}
