import AppKit
import CoreGraphics

/// Virtual key codes. Letter positions are identical on ANSI and JIS keyboards, so we read key codes
/// instead of characters and stay independent of the input source (e.g. Japanese IME on).
enum Key {
    static let space: Int64 = 49
    static let escape: Int64 = 53
    static let delete: Int64 = 51
    static let returnKey: Int64 = 36
    static let tab: Int64 = 48

    /// 1…9, 0 in label order.
    static let digits: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]

    static let letters: [Int64: Character] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j",
        40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t",
        32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
    ]
}

enum Mouse {
    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Clicks at a global (top-left origin) point, then puts the cursor back where it was.
    static func click(at point: CGPoint, flags: CGEventFlags = [], right: Bool = false) {
        let original = location
        let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for type in [downType, upType] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            CGWarpMouseCursorPosition(original)
        }
    }

    static func scroll(at point: CGPoint, dx: Int32, dy: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        event.location = point
        // A still-held ⌃ would turn the scroll into a zoom in Chromium-based apps.
        event.flags = []
        event.post(tap: .cghidEventTap)
    }
}

func axRect(fromCocoa rect: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}

/// Converts global AX coordinates (top-left origin) to Cocoa screen coordinates (bottom-left origin).
func cocoaRect(fromAX rect: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}
