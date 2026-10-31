// Draws the FileTree app icon and saves it as an .icns file.
// Usage: swift Scripts/make_icon.swift Resources/AppIcon.icns [preview.png]
import AppKit

let arguments = CommandLine.arguments
let output = arguments.count > 1 ? arguments[1] : "AppIcon.icns"
let preview = arguments.count > 2 ? arguments[2] : nil

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A folder silhouette: a body with a tab on its upper left.
func folder(in rect: NSRect) -> NSBezierPath {
    let radius = rect.height * 0.13
    let body = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.8)
    let tab = NSRect(x: rect.minX, y: rect.minY + rect.height * 0.55, width: rect.width * 0.46, height: rect.height * 0.45)
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    path.append(NSBezierPath(roundedRect: tab, xRadius: radius, yRadius: radius))
    return path
}

func capsule(_ rect: NSRect) -> NSBezierPath {
    let radius = min(rect.width, rect.height) / 2
    return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

/// Draws on a 1024-point canvas scaled to `pixels`.
func drawIcon(pixels: CGFloat) {
    let transform = NSAffineTransform()
    transform.scale(by: pixels / 1024)
    transform.concat()

    // The rounded square of the macOS icon grid, with its shadow.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0x1D3B8F).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x4F8DF7), ending: color(0x1C2F80))?.draw(in: tile, angle: -90)

    // The tree: a trunk from the top folder, a branch to every subfolder, and a bar for its size.
    let line = NSColor.white.withAlphaComponent(0.85)
    line.setFill()
    capsule(NSRect(x: 296, y: 274, width: 24, height: 420)).fill()
    let rows: [(y: CGFloat, length: CGFloat, hue: UInt32)] = [
        (566, 300, 0xFF6B5B),
        (426, 196, 0xFFC93C),
        (286, 104, 0x4ADE80),
    ]
    for row in rows {
        line.setFill()
        capsule(NSRect(x: 296, y: row.y - 12, width: 110, height: 24)).fill()
        color(row.hue).setFill()
        folder(in: NSRect(x: 392, y: row.y - 50, width: 128, height: 100)).fill()
        capsule(NSRect(x: 546, y: row.y - 25, width: row.length, height: 50)).fill()
    }
    NSColor.white.setFill()
    folder(in: NSRect(x: 228, y: 650, width: 160, height: 126)).fill()
}

func render(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon(pixels: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FileTree-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if let preview {
    try render(pixels: 1024).write(to: URL(fileURLWithPath: preview))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    print("iconutil failed")
    exit(1)
}
print("Wrote \(output)")
