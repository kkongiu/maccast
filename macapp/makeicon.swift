// Genera le PNG dell'icona Maccast in stile macOS (squircle + gradiente + simbolo).
// Uso: makeicon <cartella-output>
import AppKit

func render(_ size: Int) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0),
        let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    let inset = s * 0.095
    let side = s - inset * 2
    let rect = NSRect(x: inset, y: inset, width: side, height: side)
    let radius = side * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Sfondo con gradiente blu -> viola.
    NSGradient(colors: [
        NSColor(srgbRed: 0.30, green: 0.56, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.46, green: 0.30, blue: 0.95, alpha: 1),
    ])?.draw(in: path, angle: -90)

    // Leggera luce in alto.
    NSGradient(colors: [
        NSColor(white: 1, alpha: 0.28),
        NSColor(white: 1, alpha: 0.0),
    ])?.draw(in: path, angle: -90)

    // Bordo interno sottile.
    NSColor(white: 1, alpha: 0.18).setStroke()
    path.lineWidth = max(1, s * 0.006)
    path.stroke()

    // Simbolo "cast" bianco centrato.
    let cfg = NSImage.SymbolConfiguration(pointSize: side * 0.44, weight: .semibold)
    if let base = NSImage(systemSymbolName: "airplayvideo",
                          accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let sz = base.size
        let tinted = NSImage(size: sz)
        tinted.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: sz))
        NSColor.white.set()
        NSRect(origin: .zero, size: sz).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let target = NSRect(x: rect.midX - sz.width / 2,
                            y: rect.midY - sz.height / 2,
                            width: sz.width, height: sz.height)
        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }

    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, sz) in specs {
    if let data = render(sz) {
        try? data.write(to: URL(fileURLWithPath: outDir)
            .appendingPathComponent(name))
    }
}
