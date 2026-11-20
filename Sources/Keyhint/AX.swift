import AppKit
import ApplicationServices

/// A clickable element found in the frontmost window.
/// `frame` is in global AX coordinates (origin at the top-left of the primary screen, y down),
/// already clipped to what is visible.
struct Target {
    let element: AXUIElement
    let role: String
    let frame: CGRect
    /// Found inside an AXWebArea (Chrome, Electron apps such as Slack).
    let isWeb: Bool
}

enum AX {
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Fetches several attributes in one IPC round trip. Missing attributes come back as nil.
    static func attributes(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef?] {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(), &values)
        guard error == .success, let array = values as? [CFTypeRef], array.count == names.count else {
            return Array(repeating: nil, count: names.count)
        }
        return array.map { value in
            // Per-attribute failures are reported as an AXValue of type .axError.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
    }

    static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        let values = attributes(element, [kAXPositionAttribute, kAXSizeAttribute])
        guard let origin = point(values[0]), let size = size(values[1]) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Chromium and Electron only build their accessibility tree when an assistive app asks for it.
    static func enableManualAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 1.0)
        if let window = element(appElement, kAXFocusedWindowAttribute) { return window }
        if let window = element(appElement, kAXMainWindowAttribute) { return window }
        if let windows = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] { return windows.first }
        return nil
    }
}

/// Walks a window's accessibility tree and collects elements worth a hint.
final class Collector {
    private static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXTextField", "AXTextArea", "AXComboBox", "AXSlider", "AXIncrementor", "AXDisclosureTriangle",
        "AXTab", "AXRow", "AXCell", "AXMenuBarItem", "AXColorWell", "AXDockItem",
    ]
    /// Containers whose children are still worth visiting even though the container itself gets a hint.
    private static let descendRoles: Set<String> = ["AXRow", "AXCell"]

    private static let webSearchKeys = [
        "AXButtonSearchKey", "AXCheckBoxSearchKey", "AXControlSearchKey", "AXLinkSearchKey",
        "AXRadioGroupSearchKey", "AXTextFieldSearchKey",
    ]

    private(set) var targets: [Target] = []
    private var seenFrames = Set<String>()
    private let deadline: Date
    private let limit = 1500

    init(budget: TimeInterval = 1.5) {
        deadline = Date().addingTimeInterval(budget)
    }

    func collect(window: AXUIElement) -> [Target] {
        guard let windowFrame = AX.frame(window) else { return [] }
        walk(window, clip: windowFrame, depth: 0)
        return targets.sorted { a, b in
            if abs(a.frame.minY - b.frame.minY) > 4 { return a.frame.minY < b.frame.minY }
            return a.frame.minX < b.frame.minX
        }
    }

    private var exhausted: Bool { targets.count >= limit || Date() > deadline }

    private func walk(_ element: AXUIElement, clip: CGRect, depth: Int) {
        if exhausted || depth > 60 { return }

        let values = AX.attributes(element, [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute])
        let role = values[0] as? String ?? ""
        var visible = clip
        if let origin = AX.point(values[1]), let size = AX.size(values[2]), size.width > 0, size.height > 0 {
            visible = clip.intersection(CGRect(origin: origin, size: size))
            if visible.isNull || visible.width < 2 || visible.height < 2 { return }
        }

        if role == "AXWebArea" {
            collectWeb(element, clip: visible)
            return
        }

        if Self.clickableRoles.contains(role) {
            add(element, role: role, frame: visible)
            if !Self.descendRoles.contains(role) { return }
        }

        guard let children = AX.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        let childClip = (role == "AXScrollArea" || role == "AXWindow") ? visible : clip
        for child in children {
            walk(child, clip: childClip, depth: depth + 1)
            if exhausted { return }
        }
    }

    /// Web content is too deep to walk node by node, so ask the browser to search it for us.
    /// Chromium used to reject multiple search keys in one query, hence the per-key fallback.
    private func collectWeb(_ webArea: AXUIElement, clip: CGRect) {
        var query: [String: Any] = [
            "AXDirection": "AXDirectionNext",
            "AXImmediateDescendantsOnly": false,
            "AXResultsLimit": -1,
            "AXVisibleOnly": true,
            "AXSearchKey": Self.webSearchKeys,
        ]
        var found = search(webArea, query)
        if found.isEmpty {
            for key in Self.webSearchKeys {
                query["AXSearchKey"] = key
                found.append(contentsOf: search(webArea, query))
            }
        }
        for element in found {
            if exhausted { return }
            let values = AX.attributes(element, [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute])
            guard let origin = AX.point(values[1]), let size = AX.size(values[2]) else { continue }
            let visible = clip.intersection(CGRect(origin: origin, size: size))
            if visible.isNull || visible.width < 2 || visible.height < 2 { continue }
            add(element, role: values[0] as? String ?? "", frame: visible, isWeb: true)
        }
    }

    private func search(_ element: AXUIElement, _ query: [String: Any]) -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, "AXUIElementsForSearchPredicate" as CFString, query as CFDictionary, &value)
        guard error == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func add(_ element: AXUIElement, role: String, frame: CGRect, isWeb: Bool = false) {
        // Links that wrap a button (or vice versa) report the same frame; one hint is enough.
        let key = "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
        guard seenFrames.insert(key).inserted else { return }
        targets.append(Target(element: element, role: role, frame: frame, isWeb: isWeb))
    }
}
