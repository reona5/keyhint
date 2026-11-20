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

    /// Collects from the frontmost window on every screen, so hints also appear on the
    /// display that does not have focus.
    init?(overlay: Overlay) {
        let windows = AX.visibleWindows()
        let targets = AX.concurrentMap(windows) { Collector().collect(window: $0) }
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
        overlay.show(hints: hints.map { HintLabel(label: $0.label, frame: cocoaRect(fromAX: $0.target.frame)) }, typed: typed)
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

/// Scrolls one region at a time. Regions get number labels; the one under the focused
/// window's centre starts selected, so j/k work right away. 1…9/0 or Tab switch regions.
final class ScrollMode {
    private let regions: [CGRect]
    private var selected: Int
    private let overlay: Overlay

    init?(overlay: Overlay) {
        let windows = AX.visibleWindows()
        guard let focused = windows.first, let focusedFrame = AX.frame(focused) else { return nil }
        var found = AX.concurrentMap(windows) { ScrollRegionCollector().collect(window: $0) }

        // Keep the ten largest, then order them for reading so the numbers feel predictable.
        if found.count > Key.digits.count {
            found = Array(found.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(Key.digits.count))
        }
        found.sort { a, b in
            if abs(a.minX - b.minX) > 20 { return a.minX < b.minX }
            return a.minY < b.minY
        }
        regions = found

        // The smallest region containing the focused window's centre is the main content pane.
        let center = CGPoint(x: focusedFrame.midX, y: focusedFrame.midY)
        let containing = found.indices.filter { found[$0].contains(center) }
        selected = containing.min { found[$0].width * found[$0].height < found[$1].width * found[$1].height } ?? 0
        self.overlay = overlay
        render()
    }

    func handle(keyCode: Int64, flags: CGEventFlags) -> ModeResult {
        if keyCode == Key.escape { return .exit }
        if keyCode == Key.tab {
            let step = flags.contains(.maskShift) ? regions.count - 1 : 1
            selected = (selected + step) % regions.count
            render()
            return .stay
        }
        if let index = Key.digits.firstIndex(of: keyCode), index < regions.count {
            selected = index
            render()
            return .stay
        }
        guard let char = Key.letters[keyCode] else { return .stay }
        let shift = flags.contains(.maskShift)
        switch char {
        case "j": smooth(dy: -120)
        case "k": smooth(dy: 120)
        case "h": smooth(dx: 120)
        case "l": smooth(dx: -120)
        case "d": smooth(dy: -Int32(regions[selected].height / 2))
        case "u": smooth(dy: Int32(regions[selected].height / 2))
        case "g": smooth(dy: shift ? -100_000 : 100_000, steps: 1)
        case "q", "i": return .exit
        default: break
        }
        return .stay
    }

    private func render() {
        let labels = regions.count > 1
            ? regions.enumerated().map { index, frame in
                HintLabel(label: index == 9 ? "0" : String(index + 1), frame: cocoaRect(fromAX: frame), topLeft: true)
            }
            : []
        overlay.show(hints: labels, border: cocoaRect(fromAX: regions[selected]))
    }

    /// Spread one keystroke over a few frames so the page glides instead of jumping.
    private func smooth(dx: Int32 = 0, dy: Int32 = 0, steps: Int32 = 6) {
        let region = regions[selected]
        let point = CGPoint(x: region.midX, y: region.midY)
        for step in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.012) {
                Mouse.scroll(at: point, dx: dx / steps, dy: dy / steps)
            }
        }
    }
}
