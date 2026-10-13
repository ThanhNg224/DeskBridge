import AppKit

enum BrandIcon {
    /// Menu bar glyph (template image): a display and a phone. Filled shapes show activity:
    /// outline/outline = searching or paused, phone filled = connected, both filled = controlling Android.
    static func menuBar(_ phase: AppModel.Phase) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            let dim: CGFloat = phase == .paused ? 0.4 : 1
            let color = NSColor.black.withAlphaComponent(dim)
            color.setStroke()
            color.setFill()

            let monitor = NSBezierPath(
                roundedRect: NSRect(x: 1.5, y: 5, width: 13, height: 9),
                xRadius: 1.8,
                yRadius: 1.8
            )
            monitor.lineWidth = 1.4
            let phone = NSBezierPath(
                roundedRect: NSRect(x: 16.5, y: 3, width: 5, height: 9),
                xRadius: 1.4,
                yRadius: 1.4
            )
            phone.lineWidth = 1.4

            monitor.stroke()
            if phase == .controlling {
                monitor.fill()
            }
            phone.stroke()
            if phase == .connected || phase == .controlling {
                phone.fill()
            }
            NSBezierPath(roundedRect: NSRect(x: 4.5, y: 2.2, width: 7, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
