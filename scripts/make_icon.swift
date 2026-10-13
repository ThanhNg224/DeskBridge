#!/usr/bin/env swift
// Generates the app icon: mac/Resources/AppIcon.icns and docs/logo.png.
// Usage: swift scripts/make_icon.swift   (run from the repo root; needs `iconutil`)
import AppKit

func render(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Background: macOS-style rounded square with a teal-to-blue gradient.
    let bg = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 212, yRadius: 212)
    ctx.saveGState()
    bg.addClip()
    NSGradient(colors: [NSColor(red: 0.13, green: 0.83, blue: 0.75, alpha: 1),
                        NSColor(red: 0.15, green: 0.39, blue: 0.92, alpha: 1)])!
        .draw(in: NSRect(x: 40, y: 40, width: 944, height: 944), angle: -60)
    ctx.restoreGState()

    // Soft shadow under the glyphs.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()

    // Mac display (left) with a stand, phone (right), and the cursor bridging the gap.
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 150, y: 400, width: 470, height: 320), xRadius: 40, yRadius: 40).fill()
    NSBezierPath(roundedRect: NSRect(x: 300, y: 330, width: 170, height: 36), xRadius: 18, yRadius: 18).fill()
    NSBezierPath(roundedRect: NSRect(x: 375, y: 360, width: 20, height: 60), xRadius: 6, yRadius: 6).fill()
    NSBezierPath(roundedRect: NSRect(x: 690, y: 330, width: 190, height: 380), xRadius: 46, yRadius: 46).fill()

    // Screens (inner dark panels) to give the white shapes some depth.
    NSColor(red: 0.08, green: 0.18, blue: 0.42, alpha: 0.9).setFill()
    NSBezierPath(roundedRect: NSRect(x: 180, y: 430, width: 410, height: 260), xRadius: 22, yRadius: 22).fill()
    NSBezierPath(roundedRect: NSRect(x: 712, y: 372, width: 146, height: 296), xRadius: 30, yRadius: 30).fill()

    // Cursor arrow crossing from the display to the phone.
    NSShadow().set()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 520, y: 620))
    arrow.line(to: NSPoint(x: 520, y: 470))
    arrow.line(to: NSPoint(x: 560, y: 508))
    arrow.line(to: NSPoint(x: 592, y: 440))
    arrow.line(to: NSPoint(x: 624, y: 454))
    arrow.line(to: NSPoint(x: 592, y: 522))
    arrow.line(to: NSPoint(x: 646, y: 522))
    arrow.close()
    NSColor.white.setFill()
    arrow.fill()
    NSColor(red: 0.04, green: 0.1, blue: 0.3, alpha: 1).setStroke()
    arrow.lineWidth = 10
    arrow.lineJoinStyle = .round
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(size: base), to: "\(iconset)/icon_\(base)x\(base).png")
    writePNG(render(size: base * 2), to: "\(iconset)/icon_\(base)x\(base)@2x.png")
}
try! fm.createDirectory(atPath: "mac/Resources", withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "mac/Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
writePNG(render(size: 512), to: "docs/logo.png")
print("wrote mac/Resources/AppIcon.icns and docs/logo.png")
