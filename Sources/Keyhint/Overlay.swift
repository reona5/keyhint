import AppKit

struct HintLabel {
    let label: String
    /// Element frame in Cocoa global coordinates.
    let frame: CGRect
    /// Region labels sit in the top-left corner instead of on the left edge.
    var topLeft = false
}

/// Transparent, click-through panels (one per screen) that draw hint labels or a scroll-mode border.
final class Overlay {
    private var panels: [NSPanel] = []

    func show(hints: [HintLabel], typed: String = "", border: CGRect? = nil) {
        render { view in
            view.hints = hints
            view.typed = typed
            view.border = border
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
    }

    private func render(_ configure: (OverlayView) -> Void) {
        syncPanels()
        for panel in panels {
            guard let view = panel.contentView as? OverlayView else { continue }
            view.screenOrigin = panel.frame.origin
            configure(view)
            view.needsDisplay = true
            panel.orderFrontRegardless()
        }
    }

    private func syncPanels() {
        let screens = NSScreen.screens
        if panels.count != screens.count {
            panels.forEach { $0.close() }
            panels = screens.map { _ in Self.makePanel() }
        }
        for (panel, screen) in zip(panels, screens) where panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: false)
        }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = OverlayView()
        return panel
    }
}

final class OverlayView: NSView {
    var hints: [HintLabel] = []
    var typed = ""
    var border: CGRect?
    var screenOrigin: CGPoint = .zero

    private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    private let fill = NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.25, alpha: 0.95)
    private let stroke = NSColor(calibratedRed: 0.55, green: 0.42, blue: 0.0, alpha: 1.0)

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.set()
        dirtyRect.fill()

        if let border {
            let rect = local(border).insetBy(dx: 2, dy: 2)
            NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            path.lineWidth = 4
            path.stroke()
        }

        for hint in hints where hint.label.hasPrefix(typed) {
            draw(hint)
        }
    }

    private func draw(_ hint: HintLabel) {
        let text = NSMutableAttributedString(string: hint.label.uppercased(), attributes: [
            .font: font, .foregroundColor: NSColor.black,
        ])
        text.addAttribute(.foregroundColor, value: NSColor.black.withAlphaComponent(0.35),
                          range: NSRange(location: 0, length: typed.count))
        let textSize = text.size()
        let padding = CGSize(width: 4, height: 1)
        let frame = local(hint.frame)
        // Every screen's panel receives the hints of all screens. Without this check, the clamping
        // below would pull another screen's hints onto this screen's edge.
        guard bounds.intersects(frame) else { return }
        // Sit on the element's left edge, vertically centred, nudged inside the screen.
        var origin = hint.topLeft
            ? CGPoint(x: frame.minX + 6, y: frame.maxY - textSize.height - padding.height * 2 - 6)
            : CGPoint(x: frame.minX - 2, y: frame.midY - textSize.height / 2 - padding.height)
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - textSize.width - padding.width * 2))
        origin.y = max(bounds.minY, min(origin.y, bounds.maxY - textSize.height - padding.height * 2))
        let box = CGRect(origin: origin, size: CGSize(width: textSize.width + padding.width * 2,
                                                      height: textSize.height + padding.height * 2))
        guard bounds.intersects(box) else { return }

        let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
        text.draw(at: CGPoint(x: box.minX + padding.width, y: box.minY + padding.height))
    }

    private func local(_ global: CGRect) -> CGRect {
        global.offsetBy(dx: -screenOrigin.x, dy: -screenOrigin.y)
    }
}
