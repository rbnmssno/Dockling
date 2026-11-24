import AppKit
import ImageIO

/// One row of the sheet.
struct SkinAnimation: Codable {
    let name: String
    let title: String?
    let row: Int
    let frames: Int
    let fps: Double
    let loop: Bool

    var duration: TimeInterval { Double(frames) / max(fps, 0.1) }
}

/// sheet.json next to the picture: frame size, where the soles are, and one entry per animation row.
struct SkinManifest: Codable {
    let frameWidth: Int
    let frameHeight: Int
    let baselineY: Int?
    let animations: [SkinAnimation]
}

/// The character's sprite sheet. It ships inside the app (Resources/Skin, copied in by scripts/build.sh)
/// and cannot be replaced from the app.
final class Skin {
    let image: CGImage
    let manifest: SkinManifest
    private let byName: [String: SkinAnimation]

    var frameSize: CGSize { CGSize(width: manifest.frameWidth, height: manifest.frameHeight) }
    /// Rows of transparent pixels under the soles.
    var footPadding: Int { max(0, manifest.frameHeight - 1 - (manifest.baselineY ?? manifest.frameHeight - 1)) }

    /// Development: a folder to read the sheet from instead of the built-in one (`--skin`).
    static var overrideFolder: URL?
    static var folder: URL { overrideFolder ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Skin") }
    static var imageURL: URL { folder.appendingPathComponent("sheet.png") }
    static var manifestURL: URL { folder.appendingPathComponent("sheet.json") }

    init(image: CGImage, manifest: SkinManifest) {
        self.image = image
        self.manifest = manifest
        var map: [String: SkinAnimation] = [:]
        for a in manifest.animations { map[a.name] = a }
        byName = map
    }

    subscript(name: String) -> SkinAnimation? { byName[name] }
    func has(_ name: String) -> Bool { byName[name] != nil }

    /// Part of the sheet to show for a frame, in the unit coordinates of `CALayer.contentsRect`
    /// (origin at the bottom left on macOS).
    func contentsRect(row: Int, column: Int) -> CGRect {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let fw = CGFloat(manifest.frameWidth), fh = CGFloat(manifest.frameHeight)
        let x = CGFloat(column) * fw / w
        let yTop = CGFloat(row) * fh / h
        return CGRect(x: x, y: 1 - yTop - fh / h, width: fw / w, height: fh / h)
    }

    /// The first idle frame as its own picture, for the chat avatar and the settings preview.
    func frameImage(_ name: String = "idle", column: Int = 0) -> CGImage? {
        guard let a = byName[name] ?? manifest.animations.first else { return nil }
        let rect = CGRect(x: column * manifest.frameWidth, y: a.row * manifest.frameHeight,
                          width: manifest.frameWidth, height: manifest.frameHeight)
        return image.cropping(to: rect)
    }

    /// A close square crop of the face for the chat avatar, centred on it. The face is the bright part
    /// of the head (the mask); a sheet without one gets the top of the figure. The side has the same
    /// odd or even count as the face, so the margins on both sides are equal.
    func faceImage() -> CGImage? {
        guard let frame = frameImage() else { return nil }
        let w = frame.width, h = frame.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))
        // A bitmap context keeps its top row first in memory, so y counts from the top, as in the sheet
        // and as `cropping(to:)` expects.
        func pixel(_ x: Int, _ y: Int) -> (a: Int, luma: Double) {
            let i = (y * w + x) * 4
            let a = Int(px[i + 3])
            guard a > 0 else { return (0, 0) }
            let r = Double(px[i]) / Double(a), g = Double(px[i + 1]) / Double(a), b = Double(px[i + 2]) / Double(a)
            return (a, 0.299 * r + 0.587 * g + 0.114 * b)
        }
        var body = (x0: w, y0: h, x1: -1, y1: -1), face = (x0: w, y0: h, x1: -1, y1: -1)
        for y in 0..<h {
            for x in 0..<w {
                let p = pixel(x, y)
                guard p.a > 128 else { continue }
                body = (min(body.x0, x), min(body.y0, y), max(body.x1, x), max(body.y1, y))
                if y < h / 2 && p.luma > 0.75 { face = (min(face.x0, x), min(face.y0, y), max(face.x1, x), max(face.y1, y)) }
            }
        }
        guard body.x1 >= 0 else { return frame }
        let fw = face.x1 - face.x0 + 1, fh = face.y1 - face.y0 + 1
        let rect: CGRect
        if face.x1 >= 0, fw >= 4, fh >= 4 {
            var side = max(fw, fh) + 4
            if (side - fw) % 2 != 0 { side += 1 }
            side = min(side, w, h)
            let x = (face.x0 - (side - fw) / 2).clamped(0, w - side)
            let y = (face.y0 - (side - fh) / 2).clamped(0, h - side)
            rect = CGRect(x: x, y: y, width: side, height: side)
        } else {
            let side = min((body.x1 - body.x0 + 1) * 3 / 4, h)
            let x = ((body.x0 + body.x1 + 1) / 2 - side / 2).clamped(0, w - side)
            rect = CGRect(x: x, y: body.y0, width: side, height: side)
        }
        return frame.cropping(to: rect)
    }

    static func load() -> Skin? {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(SkinManifest.self, from: data),
              let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Log.error("built-in sprite sheet missing or unreadable")
            return nil
        }
        return Skin(image: image, manifest: manifest)
    }
}
