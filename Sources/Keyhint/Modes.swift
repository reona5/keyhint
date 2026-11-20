import AppKit

/// Result of feeding a key to a mode.
enum ModeResult {
    case stay
    case exit
}

final class HintMode {
    static let alphabet: [Character] = Array("sadfjklewcmpgh")

    private let hints: [(target: Target, label: String)]
    private let overlay: Overlay
    private var typed = ""

    init?(app: NSRunningApplication, overlay: Overlay) {
        guard let window = AX.focusedWindow(of: app) else { return nil }
        let targets = Collector().collect(window: window)
        guard !targets.isEmpty else { return nil }
        let labels = Self.labels(count: targets.count)
        hints = Array(zip(targets, labels)).map { (target: $0.0, label: $0.1) }
        self.overlay = overlay
        render()
    }

    func handle(keyCode: Int64, flags: CGEventFlags) -> ModeResult {
        switch keyCode {
        case Key.escape:
            return .exit
        case Key.delete:
            if typed.isEmpty { return .exit }
            typed.removeLast()
            render()
            return .stay
        default:
            break
        }
        guard let char = Key.letters[keyCode], Self.alphabet.contains(char) else { return .stay }

        let candidate = typed + String(char)
        let matches = hints.filter { $0.label.hasPrefix(candidate) }
        if matches.isEmpty { return .stay }
        if matches.count == 1, matches[0].label == candidate {
            overlay.hide()
            let target = matches[0].target
            // Let the key-up and overlay teardown settle before acting on the app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                Self.activate(target, flags: flags)
            }
            return .exit
        }
        typed = candidate
        render()
        return .stay
    }

    private func render() {
        overlay.showHints(hints.map { HintLabel(label: $0.label, frame: cocoaRect(fromAX: $0.target.frame)) }, typed: typed)
    }

    /// Shift on the last key: ⌘-click (open link in a new tab). Option: right-click.
    private static func activate(_ target: Target, flags: CGEventFlags) {
        let center = CGPoint(x: target.frame.midX, y: target.frame.midY)
        if flags.contains(.maskAlternate) {
            Mouse.click(at: center, right: true)
            return
        }
        if flags.contains(.maskShift) {
            Mouse.click(at: center, flags: .maskCommand)
            return
        }
        // Electron (Slack etc.) reports AXPress as succeeded on web elements without firing the
        // DOM click, so web content always gets a real mouse click.
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
        if target.isWeb || textRoles.contains(target.role) {
            Mouse.click(at: center)
            return
        }
        if AXUIElementPerformAction(target.element, kAXPressAction as CFString) != .success {
            Mouse.click(at: center)
        }
    }

    /// Fixed-length labels so that no label is a prefix of another.
    static func labels(count: Int) -> [String] {
        let base = alphabet.count
        var length = 1
        var capacity = base
        while capacity < count {
            length += 1
            capacity *= base
        }
        return (0..<count).map { index in
            var n = index
            var chars: [Character] = []
            for _ in 0..<length {
                chars.append(alphabet[n % base])
                n /= base
            }
            return String(chars)
        }
    }
}

final class ScrollMode {
    private let point: CGPoint
    private let overlay: Overlay

    init?(app: NSRunningApplication, overlay: Overlay) {
        guard let window = AX.focusedWindow(of: app), let frame = AX.frame(window) else { return nil }
        point = CGPoint(x: frame.midX, y: frame.midY)
        self.overlay = overlay
        overlay.showBorder(cocoaRect(fromAX: frame))
    }

    func handle(keyCode: Int64, flags: CGEventFlags) -> ModeResult {
        if keyCode == Key.escape { return .exit }
        guard let char = Key.letters[keyCode] else { return .stay }
        let shift = flags.contains(.maskShift)
        switch char {
        case "j": smooth(dy: -120)
        case "k": smooth(dy: 120)
        case "h": smooth(dx: 120)
        case "l": smooth(dx: -120)
        case "d": smooth(dy: -500)
        case "u": smooth(dy: 500)
        case "g": smooth(dy: shift ? -100_000 : 100_000, steps: 1)
        case "q", "i": return .exit
        default: break
        }
        return .stay
    }

    /// Spread one keystroke over a few frames so the page glides instead of jumping.
    private func smooth(dx: Int32 = 0, dy: Int32 = 0, steps: Int32 = 6) {
        for step in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.012) { [point] in
                Mouse.scroll(at: point, dx: dx / steps, dy: dy / steps)
            }
        }
    }
}
