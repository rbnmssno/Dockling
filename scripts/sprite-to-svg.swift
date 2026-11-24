// Turns part of a frame of the sprite sheet into an SVG of square pixels for the app icon, so the
// character on the icon is the same pixels as on the Dock, only bigger.
//
// swift scripts/sprite-to-svg.swift <sheet dir> <out.svg> <row> <col> <x0> <y0> <x1> <y1> <unit> <centreCol> <bottomY> [rim <#RRGGBB>]
//   x0…x1, y0…y1  pixel range inside the frame (inclusive)
//   unit          icon points per sprite pixel (the canvas is 1024)
//   centreCol     frame column (may be fractional) placed at the icon's horizontal centre
//   bottomY       icon y where the bottom edge of row y1 lands
//   rim           instead of the pixels, a one-pixel outline around them in that colour (a sticker edge)
import AppKit

let a = CommandLine.arguments
let dir = URL(fileURLWithPath: a[1])
let out = URL(fileURLWithPath: a[2])
let (row, col) = (Int(a[3])!, Int(a[4])!)
let (x0, y0, x1, y1) = (Int(a[5])!, Int(a[6])!, Int(a[7])!, Int(a[8])!)
let unit = Double(a[9])!, centreCol = Double(a[10])!, bottomY = Double(a[11])!

let manifest = try! JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("sheet.json"))) as! [String: Any]
let fw = manifest["frameWidth"] as! Int, fh = manifest["frameHeight"] as! Int
let rep = NSBitmapImageRep(data: try! Data(contentsOf: dir.appendingPathComponent("sheet.png")))!

func hex(_ x: Int, _ y: Int) -> String? {
    guard let c = rep.colorAt(x: col * fw + x, y: row * fh + y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5 else { return nil }
    return String(format: "#%02X%02X%02X", Int(c.redComponent * 255 + 0.5), Int(c.greenComponent * 255 + 0.5), Int(c.blueComponent * 255 + 0.5))
}

let rimColour = a.count > 13 && a[12] == "rim" ? a[13] : nil

/// Rim mode: empty pixels touching the figure (sides and corners) get the rim colour.
func colourAt(_ x: Int, _ y: Int) -> String? {
    guard let rim = rimColour else { return hex(x, y) }
    if hex(x, y) != nil { return nil }
    for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
        let nx = x + dx, ny = y + dy
        guard nx >= 0, ny >= 0, nx < fw, ny < fh, ny <= y1 else { continue }
        if hex(nx, ny) != nil { return rim }
    } }
    return nil
}

let left = 512 - (centreCol - Double(x0)) * unit
let top = bottomY - Double(y1 - y0 + 1) * unit
var rects: [String] = []
for y in y0...y1 {
    var x = x0
    while x <= x1 {
        guard let colour = colourAt(x, y) else { x += 1; continue }
        var end = x
        while end + 1 <= x1, colourAt(end + 1, y) == colour { end += 1 }
        let rx = left + Double(x - x0) * unit, ry = top + Double(y - y0) * unit
        // Each square reaches a little into the next one (which is drawn over it), so no seam of
        // background shows between them at any size.
        let overlap = unit * 0.06
        rects.append(String(format: "<rect x=\"%.2f\" y=\"%.2f\" width=\"%.2f\" height=\"%.2f\" fill=\"%@\"/>",
                            rx, ry, Double(end - x + 1) * unit + overlap, unit + overlap, colour))
        x = end + 1
    }
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" shape-rendering="crispEdges">
\(rects.joined(separator: "\n"))
</svg>

"""
try! svg.write(to: out, atomically: true, encoding: .utf8)
print("\(rects.count) runs -> \(out.path)")
