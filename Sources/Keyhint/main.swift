import AppKit

/// Owns the global key event tap and routes keys to whichever mode is active.
final class Coordinator: NSObject, NSApplicationDelegate {
    private enum State {
        case idle
        case pending
        case hint(HintMode)
        case scroll(ScrollMode)
    }

    private var state = State.idle
    private let overlay = Overlay()
    private var tap: CFMachPort?
    private var swallowedKeyUps = Set<Int64>()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        waitForAccessibility()
    }

    // MARK: Setup

    private func waitForAccessibility() {
        if AX.isTrusted(prompt: true) {
            installTap()
            if let app = NSWorkspace.shared.frontmostApplication { AX.enableManualAccessibility(pid: app.processIdentifier) }
            return
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AX.isTrusted(prompt: false) else { return }
            timer.invalidate()
            self?.installTap()
        }
    }

    private func installTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: refcon)
        else {
            NSLog("keyhint: failed to create event tap")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        statusItem?.button?.appearsDisabled = false
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keyhint")
        item.button?.appearsDisabled = true
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Hints: ⌃F", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Scroll: ⌃J", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Keyhint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != getpid() else { return }
        AX.enableManualAccessibility(pid: app.processIdentifier)
    }

    // MARK: Event handling

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            return swallowedKeyUps.remove(keyCode) != nil ? nil : Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        switch state {
        case .idle:
            guard let trigger = Self.trigger(keyCode: keyCode, flags: flags) else { return Unmanaged.passUnretained(event) }
            swallowedKeyUps.insert(keyCode)
            start(trigger)
            return nil
        case .pending:
            swallowedKeyUps.insert(keyCode)
            return nil
        case .hint(let mode):
            swallowedKeyUps.insert(keyCode)
            if mode.handle(keyCode: keyCode, flags: flags) == .exit { finish() }
            return nil
        case .scroll(let mode):
            swallowedKeyUps.insert(keyCode)
            if mode.handle(keyCode: keyCode, flags: flags) == .exit { finish() }
            return nil
        }
    }

    private enum Trigger { case hint, scroll }

    private static func trigger(keyCode: Int64, flags: CGEventFlags) -> Trigger? {
        let modifiers = flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        guard modifiers == [.maskControl] else { return nil }
        switch keyCode {
        case 3: return .hint // F
        case 38: return .scroll // J
        default: return nil
        }
    }

    /// Querying the AX tree can take a while, so do it outside the tap callback
    /// (a slow callback gets the tap disabled by the system).
    private func start(_ trigger: Trigger) {
        state = .pending
        DispatchQueue.main.async { [self] in
            guard let app = NSWorkspace.shared.frontmostApplication else { return finish() }
            switch trigger {
            case .hint:
                guard let mode = HintMode(app: app, overlay: overlay) else { NSSound.beep(); return finish() }
                state = .hint(mode)
            case .scroll:
                guard let mode = ScrollMode(app: app, overlay: overlay) else { NSSound.beep(); return finish() }
                state = .scroll(mode)
            }
        }
    }

    private func finish() {
        state = .idle
        overlay.hide()
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let coordinator = Unmanaged<Coordinator>.fromOpaque(refcon).takeUnretainedValue()
    return coordinator.handle(type: type, event: event)
}

let app = NSApplication.shared
let coordinator = Coordinator()
app.delegate = coordinator
app.setActivationPolicy(.accessory)
app.run()
