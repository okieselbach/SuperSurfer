import ApplicationServices
import Cocoa

// Dock Click: a click on the Dock icon of the app that is already in front
// hides that app or minimizes its windows, and the next click on the icon
// brings it back. macOS itself does nothing for such a click.
//
// None of this has to do with routing links. It lives here because the app is
// loaded anyway, and it is off until chosen in the menu: until then there is
// no event monitor, no observer and no need for the Accessibility permission.
//
// A click is handled in two places:
//
//   main thread   A global event monitor sees the button go down and come up.
//                 It only listens; the Dock gets every click as before. Each
//                 event costs a few microseconds here.
//   worker queue  Asks the Dock, through Accessibility, which icon is under
//                 the pointer, and minimizes or restores windows. Another app
//                 may take its time over such a request, so none of it runs
//                 on the main thread or on the queue that routes links.

/// What a click on the Dock icon of the app in front does.
enum DockClick: String, CaseIterable {
    case hide
    case minimize
    case off

    private static let defaultsKey = "dockClick"

    /// `SUPERSURFER_DOCK_CLICK=hide` (or `minimize`) chooses for one run
    /// without storing anything. For the test script and for trying it out
    /// from a shell; an app started by macOS never sees the variable.
    private static var forced: DockClick? = ProcessInfo.processInfo
        .environment["SUPERSURFER_DOCK_CLICK"]
        .flatMap { DockClick(rawValue: $0) }

    static var current: DockClick {
        get {
            if let forced = forced {
                return forced
            }
            let stored = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            return DockClick(rawValue: stored) ?? .off
        }
        set {
            forced = nil
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var title: String {
        switch self {
        case .hide: return tr("Hide App", "App ausblenden")
        case .minimize: return tr("Minimize Windows", "Fenster minimieren")
        case .off: return tr("Off", "Aus")
        }
    }
}

/// The decisions that need neither the Dock nor another app, so that
/// `--self-test` can check them.
enum DockClickRules {
    /// A press held this long opens the Dock's menu for the icon instead.
    static let longestClick: TimeInterval = 0.4
    /// Pointer travel, in points, up to which a press is still a click and
    /// not the start of dragging the icon.
    static let slop: CGFloat = 4
    /// An event that is handled this long after it happened says nothing
    /// reliable about the moment it happened, and is left alone.
    static let staleAfter: TimeInterval = 0.25

    /// Both times are seconds since startup: `NSEvent.timestamp` and
    /// `ProcessInfo.systemUptime`.
    static func isFresh(eventTime: TimeInterval, now: TimeInterval) -> Bool {
        let late = now - eventTime
        return late > -staleAfter && late < staleAfter
    }

    static func isClick(
        from start: CGPoint,
        at began: TimeInterval,
        to end: CGPoint,
        at ended: TimeInterval
    ) -> Bool {
        let held = ended - began
        return held >= 0 && held < longestClick
            && abs(end.x - start.x) <= slop && abs(end.y - start.y) <= slop
    }

    /// With a modifier key the Dock does something else: ⌘ shows the app in
    /// the Finder, ⌥ hides, ⌃ opens the menu.
    static func isPlain(_ flags: NSEvent.ModifierFlags) -> Bool {
        return flags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    /// Whether an app can be said to have been in front before a click.
    /// `frontSince` is when this process learned that the app came to the
    /// front, which is never earlier than when it did. A click activates the
    /// app whose icon it hits, so an app that was brought to the front by the
    /// click itself can only have been noticed after the click began, however
    /// late either piece of news arrives here.
    static func wasInFront(since frontSince: TimeInterval, before click: TimeInterval) -> Bool {
        return frontSince < click
    }

    static func samePlace(_ one: URL, _ other: URL) -> Bool {
        return one.resolvingSymlinksInPath().standardizedFileURL.path
            == other.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// One press of the mouse button, from going down to what is done about it.
private final class Press {
    let time: TimeInterval
    /// Where the button went down, in the coordinates Accessibility uses:
    /// points from the top left corner of the main display.
    let point: CGPoint
    let mode: DockClick
    /// The app that was in front before the press began, if any.
    let front: NSRunningApplication?
    /// Set and read on the worker queue only.
    var plan = Plan.nothing
    /// Main thread only: a second click followed before anything was done.
    var cancelled = false
    /// What the click cost on the main thread and, before anything was done
    /// about it, on the worker queue. Only read for the `--resident` trace.
    var mainTime: TimeInterval = 0
    var workerTime: TimeInterval = 0

    init(time: TimeInterval, point: CGPoint, mode: DockClick, front: NSRunningApplication?) {
        self.time = time
        self.point = point
        self.mode = mode
        self.front = front
    }
}

private enum Plan {
    case nothing
    case hide(NSRunningApplication)
    case minimize(NSRunningApplication, [AXUIElement])
    case restore(pid_t)
}

/// Windows this app minimized, front to back, so that the next click on the
/// icon brings back all of them. macOS by itself brings back one.
private struct Stowed {
    let app: NSRunningApplication
    var windows: [AXUIElement]
}

private struct DockIcon {
    let title: String
    let url: URL

    func belongs(to app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleURL else {
            return false
        }
        if DockClickRules.samePlace(url, bundle) {
            return true
        }
        // One app can go by two paths that no link connects. Then the bundle
        // identifier decides, read only for a bundle of the same name.
        guard url.lastPathComponent == bundle.lastPathComponent,
              let identifier = app.bundleIdentifier else {
            return false
        }
        return Bundle(url: url)?.bundleIdentifier == identifier
    }
}

private enum AX {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        return value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        return value(element, attribute) as? Bool
    }

    static func url(_ element: AXUIElement, _ attribute: String) -> URL? {
        let found = value(element, attribute)
        if let url = found as? URL {
            return url
        }
        return (found as? String).flatMap { URL(string: $0) }
    }
}

final class DockClickController {
    static let shared = DockClickController()

    /// How long the Dock gets, after the button comes up, to finish its own
    /// handling of the click. That is when the Dock activates the app, and
    /// activating an app brings it straight back if it was hidden a moment
    /// too early.
    private static let settleTime: TimeInterval = ProcessInfo.processInfo
        .environment["SUPERSURFER_DOCK_CLICK_SETTLE"].flatMap { Double($0) } ?? 0.12
    /// The Dock answers in well under a millisecond. Nothing waits longer
    /// than this for it, or for an app that is asked about its windows.
    private static let answerTimeout: Float = 0.4
    /// Minimizing is animated, and an app may answer only once the animation
    /// has run.
    private static let animationTimeout: Float = 2

    // Main thread only.
    private var monitor: Any?
    /// Whether the monitor was installed with the permission already given.
    private var monitorHasPermission = false
    private var activationObserver: NSObjectProtocol?
    private var frontPID: pid_t = 0
    private var frontSince: TimeInterval = 0
    /// The press whose button is down right now.
    private var press: Press?
    /// The last complete click, which may still be waiting out `settleTime`.
    private var lastClick: Press?

    // Worker queue only.
    private let worker = DispatchQueue(label: "dev.supersurfer.dock-click", qos: .userInitiated)
    private var dock: (app: NSRunningApplication, element: AXUIElement)?
    private var stowed: [pid_t: Stowed] = [:]

    private init() {}

    // MARK: - Switching it on and off

    /// Starts or stops listening so that it matches the choice in the menu.
    /// While the choice is "off" nothing is installed.
    func refresh() {
        let mode = DockClick.current
        guard mode != .off else {
            if let installed = monitor {
                NSEvent.removeMonitor(installed)
            }
            monitor = nil
            if let observer = activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            activationObserver = nil
            monitorHasPermission = false
            press = nil
            lastClick = nil
            return
        }

        if activationObserver == nil {
            // This process uses Accessibility for nothing else, so the
            // timeout can be set for all of it.
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), DockClickController.answerTimeout)
            noteFront(NSWorkspace.shared.frontmostApplication)
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self = self else {
                    return
                }
                self.noteFront(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                // Leaving System Settings after giving the permission is a
                // moment to notice that it is there now.
                if !self.monitorHasPermission {
                    self.refresh()
                }
            }
        }

        // Mouse buttons can be watched without any permission; it is the
        // question to the Dock that needs Accessibility. An event tap set up
        // before a permission is given stays deaf, though. In case a monitor
        // ever does the same, it is replaced once the permission is there.
        if monitor != nil && monitorHasPermission {
            return
        }
        let permitted = AXIsProcessTrusted()
        if monitor != nil && !permitted {
            return
        }
        if let installed = monitor {
            NSEvent.removeMonitor(installed)
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
        }
        monitorHasPermission = permitted
        press = nil
        DockClickController.trace("\(mode.rawValue), Accessibility permission: \(permitted ? "yes" : "no")")
    }

    private func choose(_ mode: DockClick) {
        DockClick.current = mode
        // What was minimized under the old choice is the user's to bring back.
        worker.async {
            self.stowed.removeAll()
        }
        refresh()
        if mode != .off && !AXIsProcessTrusted() {
            // The system's own request. It puts SuperSurfer on the list under
            // Accessibility and offers to open that page. It does not block.
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
    }

    // MARK: - Menu

    /// The "Dock Click" entry of the status menu, built for the state as it
    /// is right now.
    func menuItem(app: AppDelegate) -> NSMenuItem {
        refresh()
        let current = DockClick.current
        let needsPermission = current != .off && !AXIsProcessTrusted()

        var entries: [NSMenuItem] = [MenuItems.note(tr(
            "Clicking the Dock icon of the app in front",
            "Klick auf das Dock-Symbol der App im Vordergrund"
        ))]
        for mode in DockClick.allCases {
            let item = ActionMenuItem(mode.title) { [weak self] in
                self?.choose(mode)
            }
            item.state = mode == current ? .on : .off
            entries.append(item)
        }
        if needsPermission {
            entries.append(.separator())
            entries.append(ActionMenuItem(tr(
                "⚠︎ Needs the Accessibility permission. Show…",
                "⚠︎ Benötigt die Berechtigung „Bedienungshilfen“. Anzeigen …"
            )) { [weak self] in
                self?.explainPermission(app)
            })
        }

        let title = tr("Dock Click: \(current.title)", "Dock-Klick: \(current.title)")
        return MenuItems.submenu(needsPermission ? "⚠︎ " + title : title, items: entries)
    }

    private func explainPermission(_ app: AppDelegate) {
        app.showAlert(
            title: tr(
                "Dock Click needs the Accessibility permission",
                "Dock-Klick benötigt die Berechtigung „Bedienungshilfen“"
            ),
            text: tr(
                "SuperSurfer asks the Dock which icon a click hit, and hides or minimizes the app in front. macOS allows both only with this permission.\n\nOpen System Settings > Privacy & Security > Accessibility and switch on SuperSurfer. It works from the next click, without a restart.\n\nAlready switched on there? macOS ties the permission to the app's signature, and releases are not signed with a Developer ID yet. After an update the switch still looks on but no longer counts. Remove SuperSurfer from the list with the minus button and add it again with the plus button.",
                "SuperSurfer fragt das Dock, welches Symbol ein Klick getroffen hat, und blendet die App im Vordergrund aus oder minimiert sie. Beides erlaubt macOS nur mit dieser Berechtigung.\n\nÖffne Systemeinstellungen > Datenschutz & Sicherheit > Bedienungshilfen und schalte SuperSurfer ein. Es wirkt ab dem nächsten Klick, ohne Neustart.\n\nDort schon eingeschaltet? macOS bindet die Berechtigung an die Signatur der App, und die Releases sind noch nicht mit einer Developer ID signiert. Nach einem Update sieht der Schalter weiter eingeschaltet aus, zählt aber nicht mehr. Entferne SuperSurfer mit dem Minus-Knopf aus der Liste und füge es mit dem Plus-Knopf wieder hinzu."
            ),
            action: AlertAction(title: tr("Open System Settings", "Systemeinstellungen öffnen")) {
                PrivacySettings.openAccessibility()
            }
        )
    }

    // MARK: - Main thread: watching clicks

    private func noteFront(_ app: NSRunningApplication?) {
        frontPID = app?.processIdentifier ?? 0
        frontSince = ProcessInfo.processInfo.systemUptime
    }

    /// The app in front, provided it already was when the click began.
    private func appInFront(before click: TimeInterval) -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        guard app.processIdentifier == frontPID else {
            // Came to the front without this process having heard of it yet,
            // possibly through this very click. Remember it for the next one.
            noteFront(app)
            return nil
        }
        return DockClickRules.wasInFront(since: frontSince, before: click) ? app : nil
    }

    private func handle(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        let fresh = DockClickRules.isFresh(eventTime: event.timestamp, now: now)

        switch event.type {
        case .leftMouseDown:
            press = nil
            let mode = DockClick.current
            if !fresh {
                DockClickController.trace(String(
                    format: "a click dated %.2f s before now was left alone",
                    now - event.timestamp
                ))
            }
            // A double click has to end where it began. Its second click
            // stops the first one if that is still waiting, and never puts
            // anything away itself: it counts as a click on an app that was
            // not in front. Under "minimize" that still brings back what the
            // first click sent into the Dock.
            let repeated = event.clickCount > 1
            if repeated {
                lastClick?.cancelled = true
            }
            guard mode != .off, fresh,
                  DockClickRules.isPlain(event.modifierFlags),
                  let point = event.cgEvent?.location else {
                return
            }
            let started = Press(
                time: event.timestamp,
                point: point,
                mode: mode,
                front: repeated ? nil : appInFront(before: event.timestamp)
            )
            press = started
            worker.async {
                self.prepare(started)
            }
            started.mainTime = ProcessInfo.processInfo.systemUptime - now

        case .leftMouseUp:
            guard let ended = press else {
                return
            }
            press = nil
            guard fresh, let point = event.cgEvent?.location,
                  DockClickRules.isClick(from: ended.point, at: ended.time, to: point, at: event.timestamp) else {
                return
            }
            let wait = max(0, DockClickController.settleTime - (now - event.timestamp))
            ended.mainTime += ProcessInfo.processInfo.systemUptime - now
            lastClick = ended
            worker.asyncAfter(deadline: .now() + wait) {
                self.perform(ended)
            }

        default:
            break
        }
    }

    // MARK: - Worker queue: the Dock and the windows

    /// Runs while the button is still down: works out what a click here would
    /// mean, from the state before the Dock has done anything about it.
    private func prepare(_ press: Press) {
        let began = ProcessInfo.processInfo.systemUptime
        defer {
            press.workerTime = ProcessInfo.processInfo.systemUptime - began
        }
        switch press.mode {
        case .off:
            return

        case .hide:
            guard let app = press.front, let icon = dockIcon(at: press.point) else {
                return
            }
            guard icon.belongs(to: app) else {
                DockClickController.trace("\(icon.title): left to the Dock, it was not in front")
                return
            }
            // Without a window to hide, the click is a request for one:
            // many apps open a new window when their icon is clicked.
            guard DockClickController.hasWindowOnScreen(app.processIdentifier) else {
                DockClickController.trace("\(icon.title): left to the Dock, no window on screen")
                return
            }
            press.plan = .hide(app)

        case .minimize:
            stowed = stowed.filter { !$0.value.app.isTerminated }
            guard press.front != nil || !stowed.isEmpty, let icon = dockIcon(at: press.point) else {
                return
            }
            if let app = press.front, icon.belongs(to: app) {
                let windows = minimizableWindows(of: app.processIdentifier)
                if !windows.isEmpty {
                    press.plan = .minimize(app, windows)
                    return
                }
            }
            if let entry = stowed.first(where: { icon.belongs(to: $0.value.app) }) {
                press.plan = .restore(entry.key)
            } else {
                DockClickController.trace("\(icon.title): left to the Dock, nothing to minimize or bring back")
            }
        }
    }

    /// Runs once the click is complete and the Dock has had `settleTime` for
    /// its own part.
    private func perform(_ press: Press) {
        if case .nothing = press.plan {
            return
        }
        DockClickController.trace(String(
            format: "%.3f ms on the main thread, %.2f ms to ask the Dock and look at the windows",
            press.mainTime * 1000,
            press.workerTime * 1000
        ))
        switch press.plan {
        case .nothing:
            return

        case .hide(let app):
            DispatchQueue.main.async {
                guard !press.cancelled, DockClickController.isInFront(app), !app.isHidden else {
                    return
                }
                // What hide() returns is not worth reading: it says false
                // for requests that go through.
                app.hide()
                DockClickController.trace("\(app.localizedName ?? "?"): hidden")
            }

        case .minimize(let app, let windows):
            DispatchQueue.main.async {
                guard !press.cancelled, DockClickController.isInFront(app) else {
                    return
                }
                self.worker.async {
                    self.minimize(windows, of: app)
                }
            }

        case .restore(let pid):
            restore(pid)
        }
    }

    private func minimize(_ windows: [AXUIElement], of app: NSRunningApplication) {
        let pid = app.processIdentifier
        var entry = stowed[pid] ?? Stowed(app: app, windows: [])
        var count = 0
        for window in windows {
            AXUIElementSetMessagingTimeout(window, DockClickController.animationTimeout)
            let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            // No answer in time may still mean the window is on its way, so
            // it is remembered either way. But an app that does not answer is
            // not asked again for every other window.
            if result == .success || result == .cannotComplete {
                if !entry.windows.contains(where: { CFEqual($0, window) }) {
                    entry.windows.append(window)
                }
                count += 1
            }
            if result == .cannotComplete {
                break
            }
        }
        if !entry.windows.isEmpty {
            stowed[pid] = entry
        }
        DockClickController.trace("\(app.localizedName ?? "?"): minimized \(count) of \(windows.count) windows")
    }

    private func restore(_ pid: pid_t) {
        guard var entry = stowed.removeValue(forKey: pid) else {
            return
        }
        // Back to front, so the window that was in front ends up there again.
        var count = 0
        while let window = entry.windows.popLast() {
            let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            if result == .cannotComplete {
                entry.windows.append(window)
                stowed[pid] = entry
                break
            }
            count += 1
        }
        DockClickController.trace("\(entry.app.localizedName ?? "?"): brought back \(count) windows")
    }

    /// The app icon in the Dock at this point, if there is one.
    private func dockIcon(at point: CGPoint) -> DockIcon? {
        guard AXIsProcessTrusted() else {
            DockClickController.trace("no Accessibility permission")
            return nil
        }
        guard let dock = dockElement() else {
            return nil
        }
        // Asked of the Dock alone. The same question to the whole system
        // would go to whichever app owns the window under the pointer.
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit,
              AX.string(element, kAXSubroleAttribute) == "AXApplicationDockItem",
              let url = AX.url(element, kAXURLAttribute) else {
            return nil
        }
        let title = AX.string(element, kAXTitleAttribute) ?? url.deletingPathExtension().lastPathComponent
        return DockIcon(title: title, url: url)
    }

    private func dockElement() -> AXUIElement? {
        if let known = dock, !known.app.isTerminated {
            return known.element
        }
        dock = nil
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        dock = (app: app, element: element)
        return element
    }

    /// The app's windows on this Space that can go into the Dock, front to
    /// back. Accessibility does not list windows on other Spaces, so those
    /// stay where they are.
    private func minimizableWindows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = AX.value(app, kAXWindowsAttribute) as? [AXUIElement] else {
            return []
        }
        var found: [AXUIElement] = []
        for window in windows {
            var settable: DarwinBoolean = false
            let result = AXUIElementIsAttributeSettable(window, kAXMinimizedAttribute as CFString, &settable)
            if result == .cannotComplete {
                // The app is not answering. Better nothing than half of it.
                return []
            }
            guard result == .success, settable.boolValue,
                  AX.bool(window, kAXMinimizedAttribute) == false,
                  AX.bool(window, "AXFullScreen") != true else {
                continue
            }
            found.append(window)
        }
        return found
    }

    /// Whether the app shows an ordinary window on this Space right now. The
    /// window server is asked, not the app, so a hung app cannot hold this up.
    private static func hasWindowOnScreen(_ pid: pid_t) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                return false
            }
            return frame.width >= 40 && frame.height >= 40
        }
    }

    private static func isInFront(_ app: NSRunningApplication) -> Bool {
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    /// With `--resident`, one line on stderr per Dock click that was looked
    /// at, saying what was done or why not.
    private static func trace(_ message: String) {
        guard AppDelegate.traceToStderr else {
            return
        }
        fputs("SuperSurfer: dock click: \(message)\n", stderr)
    }

    // MARK: - Self-test

    static func selfTest(_ check: (String, Bool) -> Void) {
        let spot = CGPoint(x: 600, y: 1050)
        check(
            "dock click: a short press in place is a click",
            DockClickRules.isClick(from: spot, at: 10, to: CGPoint(x: 602, y: 1049), at: 10.09)
        )
        check(
            "dock click: a long press is not",
            !DockClickRules.isClick(from: spot, at: 10, to: spot, at: 10.6)
        )
        check(
            "dock click: a drag is not",
            !DockClickRules.isClick(from: spot, at: 10, to: CGPoint(x: 630, y: 1050), at: 10.09)
        )
        check(
            "dock click: modifier keys are left to the Dock",
            DockClickRules.isPlain([]) && DockClickRules.isPlain(.capsLock)
                && !DockClickRules.isPlain(.option) && !DockClickRules.isPlain([.command, .shift])
        )
        check(
            "dock click: a late or undated event is left alone",
            DockClickRules.isFresh(eventTime: 99.99, now: 100)
                && !DockClickRules.isFresh(eventTime: 99, now: 100)
                && !DockClickRules.isFresh(eventTime: 0, now: 100)
        )
        check(
            "dock click: an app brought to the front by the click was not in front",
            DockClickRules.wasInFront(since: 50, before: 100)
                && !DockClickRules.wasInFront(since: 100.01, before: 100)
        )
        check(
            "dock click: one app, two spellings of its path",
            DockClickRules.samePlace(
                URL(fileURLWithPath: "/System/Applications/Calculator.app", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications/Utilities/../Calculator.app")
            ) && !DockClickRules.samePlace(
                URL(fileURLWithPath: "/System/Applications/Calculator.app"),
                URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            )
        )
        check(
            "dock click: off unless chosen",
            DockClick(rawValue: "") == nil && DockClick(rawValue: "hide") == .hide
        )
    }
}
