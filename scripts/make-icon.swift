// Draws Vigil's app icon (a sun over a closed MacBook, on a night sky) into an .iconset.
// Usage: swift scripts/make-icon.swift OUT.iconset   then   iconutil -c icns OUT.iconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Vigil.iconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// macOS icon body: the 824-point grid square of a 1024 canvas with continuous ("squircle")
/// corners, built from the well-known cubic approximation of Apple's corner curve.
func squircle(_ rect: NSRect = NSRect(x: 100, y: 100, width: 824, height: 824), radius r: CGFloat = 185.4) -> NSBezierPath {
    // One corner in units of r: x runs back along the edge we arrive on, y along the edge we leave on.
    typealias P = (x: CGFloat, y: CGFloat)
    let segments: [(c1: P?, c2: P?, to: P)] = [
        ((1.08849323, 0), (0.86840689, 0), (0.66993427, 0.06549600)),
        (nil, nil, (0.63149399, 0.07491100)),
        ((0.37282392, 0.16905899), (0.16905899, 0.37282392), (0.07491100, 0.63149399)),
        (nil, nil, (0.06549600, 0.66993427)),
        ((0, 0.86840689), (0, 1.08849323), (0, 1.52866483)),
    ]
    let corners: [(P) -> NSPoint] = [
        { NSPoint(x: rect.maxX - $0.x * r, y: rect.minY + $0.y * r) }, // bottom right
        { NSPoint(x: rect.maxX - $0.y * r, y: rect.maxY - $0.x * r) }, // top right
        { NSPoint(x: rect.minX + $0.x * r, y: rect.maxY - $0.y * r) }, // top left
        { NSPoint(x: rect.minX + $0.y * r, y: rect.minY + $0.x * r) }, // bottom left
    ]
    let path = NSBezierPath()
    path.move(to: corners[3]((0, 1.52866483)))
    for map in corners {
        path.line(to: map((1.52866483, 0)))
        for s in segments {
            if let c1 = s.c1, let c2 = s.c2 {
                path.curve(to: map(s.to), controlPoint1: map(c1), controlPoint2: map(c2))
            } else {
                path.line(to: map(s.to))
            }
        }
    }
    path.close()
    return path
}

func capsule(_ rect: NSRect) -> NSBezierPath {
    let r = min(rect.width, rect.height) / 2
    return NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
}

func drawIcon() {
    let body = squircle()

    // Soft drop shadow under the body, as in Apple's icon template.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0x0E1030).setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    body.addClip()

    // Night sky, with a warm dawn glow rising from behind the laptop.
    NSGradient(colors: [color(0x0B0D2A), color(0x1B1F55), color(0x343B8F)], atLocations: [0, 0.55, 1],
               colorSpace: .sRGB)!.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: 90)
    NSGradient(colors: [color(0xFF9F43, 0.55), color(0xFF7A3D, 0.18), color(0xFF7A3D, 0)], atLocations: [0, 0.5, 1],
               colorSpace: .sRGB)!.draw(fromCenter: NSPoint(x: 512, y: 330), radius: 0,
                                         toCenter: NSPoint(x: 512, y: 330), radius: 470, options: [])

    // A few stars.
    for (x, y, r, a) in [(292.0, 812.0, 7.0, 0.85), (236.0, 690.0, 4.5, 0.6), (372.0, 884.0, 4.0, 0.55),
                         (760.0, 858.0, 6.0, 0.8), (836.0, 716.0, 4.5, 0.6), (668.0, 900.0, 3.5, 0.5)] {
        color(0xFFFFFF, a).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
    }

    // The sun: a glow, eight rays, and a disk.
    let sun = NSPoint(x: 512, y: 594)
    NSGradient(colors: [color(0xFFD15C, 0.55), color(0xFFB238, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(fromCenter: sun, radius: 120, toCenter: sun, radius: 300, options: [])
    for i in 0..<8 {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: sun.x, yBy: sun.y)
        t.rotate(byDegrees: CGFloat(i) * 45)
        t.concat()
        let ray = capsule(NSRect(x: -21, y: 168, width: 42, height: 76))
        NSGradient(colors: [color(0xFFE07A), color(0xFFB627)], atLocations: [0, 1], colorSpace: .sRGB)!
            .draw(in: ray, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
    }
    let disk = NSBezierPath(ovalIn: NSRect(x: sun.x - 128, y: sun.y - 128, width: 256, height: 256))
    NSGradient(colors: [color(0xFFF8D2), color(0xFFD14D), color(0xFFA41C)], atLocations: [0, 0.45, 1],
               colorSpace: .sRGB)!.draw(in: disk, relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))

    // The closed MacBook: lid over base, a thumb notch, and a shadow on the "ground".
    color(0x000000, 0.35).setFill()
    NSBezierPath(ovalIn: NSRect(x: 196, y: 236, width: 632, height: 44)).fill()
    let base = NSBezierPath(roundedRect: NSRect(x: 206, y: 262, width: 612, height: 40), xRadius: 18, yRadius: 18)
    NSGradient(colors: [color(0x8A93A6), color(0xC3CAD6)], atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: base, angle: 90)
    let lid = NSBezierPath(roundedRect: NSRect(x: 226, y: 296, width: 572, height: 34), xRadius: 16, yRadius: 16)
    NSGradient(colors: [color(0xC9CFDB), color(0xF5F7FB)], atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: lid, angle: 90)
    color(0x5B6477, 0.9).setFill()
    NSBezierPath(roundedRect: NSRect(x: 466, y: 293, width: 92, height: 9), xRadius: 4.5, yRadius: 4.5).fill()

    // Glass: a soft light from the top and a thin bright rim.
    NSGradient(colors: [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, 0.16).setStroke()
    body.lineWidth = 3
    body.stroke()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    let t = NSAffineTransform()
    t.scale(by: scale)
    t.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: out.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: out.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
print("wrote \(out.path)")
