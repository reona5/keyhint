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

    /// The window to work on for every screen: the focused window of the frontmost app first,
    /// then, for each other screen, the frontmost normal window whose centre lies on it.
    static func visibleWindows() -> [AXUIElement] {
        var result: [AXUIElement] = []
        var claimedScreens = Set<Int>()
        let screens = NSScreen.screens.map { axRect(fromCocoa: $0.frame) }

        func claim(_ frame: CGRect) -> Bool {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            guard let index = screens.firstIndex(where: { $0.contains(center) }) else { return false }
            return claimedScreens.insert(index).inserted
        }

        if let app = NSWorkspace.shared.frontmostApplication, let window = focusedWindow(of: app) {
            result.append(window)
            if let frame = frame(window) { _ = claim(frame) }
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return result }
        let ownPid = getpid()
        // The list is ordered front to back.
        for info in infos where claimedScreens.count < screens.count {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPid,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = info[kCGWindowBounds as String],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary),
                  bounds.width > 50, bounds.height > 50,
                  let window = window(pid: pid, matching: bounds),
                  !result.contains(where: { CFEqual($0, window) }),
                  claim(bounds)
            else { continue }
            result.append(window)
        }
        return result
    }

    private static func window(pid: pid_t, matching bounds: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        return windows.first { window in
            guard let frame = frame(window) else { return false }
            return abs(frame.minX - bounds.minX) < 3 && abs(frame.minY - bounds.minY) < 3
                && abs(frame.width - bounds.width) < 3 && abs(frame.height - bounds.height) < 3
        }
    }

    /// Runs `body` for each window on its own thread and concatenates the results in window order.
    static func concurrentMap<T>(_ windows: [AXUIElement], _ body: (AXUIElement) -> [T]) -> [T] {
        var results = Array(repeating: [T](), count: windows.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: windows.count) { index in
            let value = body(windows[index])
            lock.lock()
            results[index] = value
            lock.unlock()
        }
        return results.flatMap { $0 }
    }
}

/// Finds regions that can be scrolled. Native apps expose AXScrollArea; web content (Chrome,
/// Slack and other Electron apps) usually does not, so lists and elements whose DOM class
/// mentions "scroll" stand in for them.
final class ScrollRegionCollector {
    private static let regionRoles: Set<String> = [
        "AXScrollArea", "AXWebArea", "AXOutline", "AXList", "AXTable", "AXGrid", "AXBrowser",
    ]
    private static let leafRoles: Set<String> = [
        "AXStaticText", "AXLink", "AXButton", "AXImage", "AXTextField", "AXTextArea", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXHeading", "AXRow", "AXCell",
    ]
    private static let minSize = CGSize(width: 120, height: 100)

    private var regions: [CGRect] = []
    private var visited = 0
    private let deadline = Date().addingTimeInterval(0.8)

    func collect(window: AXUIElement) -> [CGRect] {
        guard let windowFrame = AX.frame(window) else { return [] }
        walk(window, clip: windowFrame, depth: 0)
        if regions.isEmpty { regions.append(windowFrame) }
        return regions
    }

    private func walk(_ element: AXUIElement, clip: CGRect, depth: Int) {
        visited += 1
        if depth > 80 || visited > 4000 || Date() > deadline { return }

        let values = AX.attributes(element, [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, "AXDOMClassList"])
        let role = values[0] as? String ?? ""
        var visible = clip
        if let origin = AX.point(values[1]), let size = AX.size(values[2]), size.width > 0, size.height > 0 {
            visible = clip.intersection(CGRect(origin: origin, size: size))
            // Children of a small element are smaller still, so the whole subtree can go.
            if visible.isNull || visible.width < Self.minSize.width || visible.height < Self.minSize.height { return }
        }
        if Self.leafRoles.contains(role) { return }

        let classes = values[3] as? [String] ?? []
        if Self.regionRoles.contains(role) || classes.contains(where: { $0.lowercased().contains("scroll") }) {
            add(visible)
        }

        guard let children = AX.attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return }
        let childClip = role == "AXScrollArea" ? visible : clip
        for child in children {
            walk(child, clip: childClip, depth: depth + 1)
        }
    }

    /// Nested wrappers often share one frame (e.g. a scroll container inside a scrollbar hider).
    private func add(_ rect: CGRect) {
        let duplicate = regions.contains { existing in
            let overlap = existing.intersection(rect)
            guard !overlap.isNull else { return false }
            let union = existing.union(rect)
            return overlap.width * overlap.height / (union.width * union.height) > 0.85
        }
        if !duplicate { regions.append(rect) }
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
