import ApplicationServices
import Cocoa

// Dock Click: a click on the Dock icon of the app that is already in front
// hides that app or minimizes its windows, and the next click on the icon
// brings it back. macOS itself leaves such a click without effect, unless
// Mission Control is up or the app has windows on another Space.
//
// None of this has to do with routing links. It lives here because the app is
// loaded anyway, and it is off until chosen in the menu: until then there is
// no event monitor, no observer and no need for the Accessibility permission.
//
// A click is handled in three places:
//
//   main thread   A global event monitor sees the button go down and come up.
//                 It only listens; the Dock gets every click as before. It
//                 asks the window server which window is under the pointer,
//                 and that is all for a click that did not go to the Dock.
//   Dock queue    Asks the Dock, through Accessibility, which icon is under
//                 the pointer. Nothing slow ever runs here, so the answer is
//                 about the Dock as it was when the button went down.
//   worker queue  Asks the app about its windows, and minimizes or restores
//                 them. An app may take its time over that, so none of it
//                 runs on the main thread or on the queue that routes links.

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
    /// A press held longer than this is not a click. The Dock opens the menu
    /// of the icon after 0.45 to 0.55 s, measured on macOS 15.
    static let longestClick: TimeInterval = 0.4
    /// Pointer travel, in points, up to which a press is still a click and
    /// not the start of dragging the icon.
    static let slop: CGFloat = 4
    /// A button going down that is noticed this long after it happened says
    /// nothing reliable about which app was in front at that moment, and is
    /// left alone.
    static let staleAfter: TimeInterval = 0.25
    /// Nothing is put away later than this after the button went down. With
    /// a Dock or an app that is slow to answer, an app vanishing seconds
    /// after the click would be worse than a click that did nothing.
    static let tooLate: TimeInterval = 1
    /// How long an app must have been in front before a click on its icon
    /// puts it away. Somebody who switches to an app and clicks its icon once
    /// more because it is slow to appear wants to see it, not lose it.
    static let shortestTimeInFront: TimeInterval = 0.75

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
        return frontSince < click - shortestTimeInFront
    }

    static func samePlace(_ one: URL, _ other: URL) -> Bool {
        return one.resolvingSymlinksInPath().standardizedFileURL.path
            == other.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// One press of the mouse button on a window of the Dock, from going down to
/// what is done about it.
private final class Press {
    let time: TimeInterval
    /// Where the button went down, in the coordinates Accessibility uses:
    /// points from the top left corner of the main display.
    let point: CGPoint
    let mode: DockClick
    let dockPID: pid_t
    /// The app that had been in front for a while when the press began.
    let front: NSRunningApplication?

    // Set on the Dock queue, read on the worker queue after the hand-over.
    /// The app icon under the pointer, if there was one.
    var icon: DockIcon?
    /// The windows `front` had on screen when the button went down.
    var windowsAtPress: Set<CGWindowID> = []
    /// Mission Control or App Exposé was up already.
    var exposeAtPress = false

    /// Set and read on the worker queue only.
    var plan = Plan.nothing
    /// Main thread only: a second click followed before anything was done.
    var cancelled = false
    /// What the click cost on the main thread and on the Dock queue. Only
    /// read for the `--resident` trace.
    var mainTime: TimeInterval = 0
    var dockTime: TimeInterval = 0

    init(time: TimeInterval, point: CGPoint, mode: DockClick, dockPID: pid_t, front: NSRunningApplication?) {
        self.time = time
        self.point = point
        self.mode = mode
        self.dockPID = dockPID
        self.front = front
    }
}

private enum Plan {
    case nothing
    case hide(NSRunningApplication)
    case minimize(NSRunningApplication, [AXUIElement])
    case restore(pid_t)
}

/// Windows this app minimized, so that the next click on the icon brings back
/// all of them. macOS by itself brings back one.
private struct Stowed {
    let app: NSRunningApplication
    var windows: [AXUIElement]
}

private struct DockIcon {
    let title: String
    let url: URL
    /// Whether the Dock shows the app as running.
    let isRunning: Bool

    func belongs(to app: NSRunningApplication) -> Bool {
        // An icon that is not running is a second copy of the app at best.
        guard isRunning, let bundle = app.bundleURL else {
            return false
        }
        // Two running copies have two icons, and nothing here says which
        // icon is whose.
        if let identifier = app.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).count > 1 {
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

    /// How long after the button comes up a click is carried out. It is the
    /// time the second click of a double click has to call the first one off,
    /// and room for the Dock to deal with the click first. Measured on macOS
    /// 15, hiding and minimizing held in 56 of 56 clicks even with no wait at
    /// all, so the Dock is not what needs it.
    private static let settleTime: TimeInterval = 0.12
    /// The Dock answers within milliseconds. Nothing waits longer than this
    /// for it, or for an app that is asked about its windows.
    private static let answerTimeout: Float = 0.4
    /// Minimizing is animated, and an app may answer only once the animation
    /// has run.
    private static let animationTimeout: Float = 2

    // Main thread only.
    private var monitor: Any?
    /// Whether the monitor was installed with the permission already given.
    private var monitorHasPermission = false
    private var activationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var frontPID: pid_t = 0
    private var frontSince: TimeInterval = 0
    private var spaceChangedAt: TimeInterval = 0
    private var dockApp: NSRunningApplication?
    /// Windows already known to be the Dock's, and windows known not to be.
    private var dockWindows: Set<Int> = []
    private var otherWindows: Set<Int> = []
    /// The press whose button is down right now.
    private var press: Press?
    /// The last complete click, which may still be waiting out `settleTime`.
    private var lastClick: Press?
    private var clicksElsewhere = 0

    /// Questions to the Dock. Nothing slow is ever put on this queue.
    private let dockQueue = DispatchQueue(label: "dev.supersurfer.dock-click.dock", qos: .userInitiated)
    /// Questions to apps about their windows, and minimizing them.
    private let worker = DispatchQueue(label: "dev.supersurfer.dock-click.windows", qos: .userInitiated)
    /// Worker queue only.
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
            for observer in [activationObserver, spaceObserver] {
                if let observer = observer {
                    NSWorkspace.shared.notificationCenter.removeObserver(observer)
                }
            }
            activationObserver = nil
            spaceObserver = nil
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
            let center = NSWorkspace.shared.notificationCenter
            activationObserver = center.addObserver(
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
            spaceObserver = center.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.spaceChangedAt = ProcessInfo.processInfo.systemUptime
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
        if mode != DockClick.current {
            // What was minimized under the old choice is the user's to bring
            // back.
            worker.async {
                self.stowed.removeAll()
            }
        }
        DockClick.current = mode
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

    /// The app in front, provided it had been there for a while when the
    /// click began.
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

    /// The Dock's process ID if the click went to a window of the Dock. The
    /// Dock itself could not tell: asked what is at a point, it answers for
    /// its icons whatever lies over them, and a menu or a notification over
    /// an icon gets the click instead of the icon. The window server knows,
    /// and writes the window it chose into the event.
    private func dockPID(clicked event: NSEvent, at point: CGPoint) -> pid_t? {
        var number = 0
        if let click = event.cgEvent {
            number = Int(click.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent))
        }
        if number <= 0, let primary = NSScreen.screens.first {
            // Not in the event: ask now, by the rules for a real click.
            // AppKit counts from the bottom of the main display, events from
            // its top.
            let spot = NSPoint(x: point.x, y: primary.frame.height - point.y)
            number = NSWindow.windowNumber(at: spot, belowWindowWithWindowNumber: 0)
        }
        guard number > 0, !otherWindows.contains(number) else {
            return nil
        }
        if dockApp?.isTerminated != false {
            dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
            dockWindows.removeAll()
        }
        guard let dock = dockApp?.processIdentifier else {
            return nil
        }
        if dockWindows.contains(number) {
            return dock
        }
        // Whose window it is has to be asked once per window. Window numbers
        // are not handed out twice, so the answer can be kept.
        guard let found = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
              let owner = (found.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else {
            return nil
        }
        if owner == dock {
            dockWindows.insert(number)
            return dock
        }
        if otherWindows.count >= 256 {
            otherWindows.removeAll()
        }
        otherWindows.insert(number)
        return nil
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
            // Nearly every click ends here.
            guard let dockPID = dockPID(clicked: event, at: point) else {
                clicksElsewhere += 1
                if clicksElsewhere == 3 {
                    DockClickController.trace(String(
                        format: "a click that is not on the Dock costs %.3f ms on the main thread",
                        (ProcessInfo.processInfo.systemUptime - now) * 1000
                    ))
                }
                return
            }
            let started = Press(
                time: event.timestamp,
                point: point,
                mode: mode,
                dockPID: dockPID,
                front: repeated ? nil : appInFront(before: event.timestamp)
            )
            press = started
            dockQueue.async {
                self.identify(started)
            }
            started.mainTime = ProcessInfo.processInfo.systemUptime - now

        case .leftMouseUp:
            guard let ended = press else {
                return
            }
            press = nil
            guard let point = event.cgEvent?.location,
                  DockClickRules.isClick(from: ended.point, at: ended.time, to: point, at: event.timestamp) else {
                DockClickController.trace(String(
                    format: "a press of %.2f s on the Dock was not a click",
                    event.timestamp - ended.time
                ))
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

    // MARK: - Dock queue: which icon

    /// Runs while the button is still down, and before anything that could
    /// hold it up: notes what the Dock and the screen looked like before the
    /// Dock did anything about the click.
    private func identify(_ press: Press) {
        let began = ProcessInfo.processInfo.systemUptime
        if let app = press.front {
            press.windowsAtPress = DockClickController.windowsOnScreen(of: app.processIdentifier)
        }
        let dock = AXUIElementCreateApplication(press.dockPID)
        press.icon = DockClickController.appIcon(at: press.point, in: dock)
        if press.icon != nil {
            press.exposeAtPress = DockClickController.showsExpose(dock)
        }
        press.dockTime = ProcessInfo.processInfo.systemUptime - began
        worker.async {
            self.prepare(press)
        }
    }

    // MARK: - Worker queue: the windows

    /// Works out what the click means. This may run late when windows are
    /// still on their way into the Dock, which is why it takes the Dock and
    /// the screen as `identify` found them.
    private func prepare(_ press: Press) {
        guard let icon = press.icon else {
            DockClickController.trace("a click on the Dock, but not on the icon of an app")
            return
        }
        guard !press.exposeAtPress else {
            DockClickController.trace("\(icon.title): left to the Dock, Mission Control was up")
            return
        }
        switch press.mode {
        case .off:
            return

        case .hide:
            guard let app = press.front, icon.belongs(to: app) else {
                DockClickController.trace("\(icon.title): left to the Dock, it had not been in front")
                return
            }
            // Without a window to hide, the click is a request for one:
            // many apps open a new window when their icon is clicked.
            guard !press.windowsAtPress.isEmpty else {
                DockClickController.trace("\(icon.title): left to the Dock, no window on screen")
                return
            }
            press.plan = .hide(app)

        case .minimize:
            stowed = stowed.filter { !$0.value.app.isTerminated }
            if let app = press.front, icon.belongs(to: app), !press.windowsAtPress.isEmpty {
                let windows = minimizableWindows(of: app.processIdentifier)
                if !windows.isEmpty {
                    press.plan = .minimize(app, windows)
                    return
                }
            }
            guard let entry = stowed.first(where: { icon.belongs(to: $0.value.app) }) else {
                DockClickController.trace("\(icon.title): left to the Dock, nothing to minimize or bring back")
                return
            }
            if stillStowed(entry.key) {
                press.plan = .restore(entry.key)
            } else {
                DockClickController.trace("\(icon.title): left to the Dock, its windows were moved by hand since")
            }
        }
    }

    /// Runs once the click is complete and `settleTime` has passed.
    private func perform(_ press: Press) {
        if case .nothing = press.plan {
            return
        }
        DockClickController.trace(String(
            format: "%.3f ms on the main thread, %.2f ms to ask the Dock",
            press.mainTime * 1000,
            press.dockTime * 1000
        ))
        switch press.plan {
        case .nothing:
            return

        case .hide(let app):
            guard dockLeftItAlone(press, app) else {
                return
            }
            DispatchQueue.main.async {
                guard self.stillWanted(press, app), !app.isHidden else {
                    return
                }
                // What hide() returns is not worth reading: it says false
                // for requests that go through.
                app.hide()
                DockClickController.trace("\(app.localizedName ?? "?"): hidden")
            }

        case .minimize(let app, let windows):
            guard dockLeftItAlone(press, app) else {
                return
            }
            DispatchQueue.main.async {
                guard self.stillWanted(press, app) else {
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

    /// Whether the Dock made nothing of the click, as far as can be seen. A
    /// force click opens App Exposé, and a click on the icon of an app with
    /// windows on another Space moves there. Then the click has done its
    /// work, and putting the app away on top of it would undo that.
    private func dockLeftItAlone(_ press: Press, _ app: NSRunningApplication) -> Bool {
        let name = app.localizedName ?? "?"
        if DockClickController.showsExpose(AXUIElementCreateApplication(press.dockPID)) {
            DockClickController.trace("\(name): left to the Dock, which opened Mission Control")
            return false
        }
        if DockClickController.windowsOnScreen(of: app.processIdentifier) != press.windowsAtPress {
            DockClickController.trace("\(name): left to the Dock, its windows changed with the click")
            return false
        }
        return true
    }

    /// Main thread: the last look before an app is put away.
    private func stillWanted(_ press: Press, _ app: NSRunningApplication) -> Bool {
        return !press.cancelled
            && ProcessInfo.processInfo.systemUptime - press.time < DockClickRules.tooLate
            && spaceChangedAt < press.time
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
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

    /// Whether every window that was minimized for the app is still in the
    /// Dock. If one has been brought back by hand since, the user has taken
    /// over: the list is forgotten, and a later click on the icon does not
    /// surprise anybody with windows from hours ago.
    private func stillStowed(_ pid: pid_t) -> Bool {
        guard var entry = stowed[pid] else {
            return false
        }
        var kept: [AXUIElement] = []
        for window in entry.windows {
            // Back to the short timeout: this is a question, not an animation.
            AXUIElementSetMessagingTimeout(window, 0)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
            if result == .cannotComplete {
                // The app is not answering now. Let the attempt decide.
                return true
            }
            guard result == .success, let minimized = value as? Bool else {
                // The window is gone.
                continue
            }
            guard minimized else {
                stowed[pid] = nil
                return false
            }
            kept.append(window)
        }
        entry.windows = kept
        stowed[pid] = kept.isEmpty ? nil : entry
        return !kept.isEmpty
    }

    private func restore(_ pid: pid_t) {
        guard var entry = stowed.removeValue(forKey: pid) else {
            return
        }
        // Last in, first out, so the window that was in front ends up there
        // again.
        var count = 0
        while let window = entry.windows.popLast() {
            AXUIElementSetMessagingTimeout(window, DockClickController.animationTimeout)
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

    // MARK: - Questions that any queue may ask

    /// The app icon in the Dock at this point, if there is one.
    private static func appIcon(at point: CGPoint, in dock: AXUIElement) -> DockIcon? {
        guard AXIsProcessTrusted() else {
            trace("no Accessibility permission")
            return nil
        }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dock, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit,
              AX.string(element, kAXSubroleAttribute) == "AXApplicationDockItem",
              let url = AX.url(element, kAXURLAttribute) else {
            return nil
        }
        return DockIcon(
            title: AX.string(element, kAXTitleAttribute) ?? url.deletingPathExtension().lastPathComponent,
            url: url,
            isRunning: AX.bool(element, "AXIsApplicationRunning") ?? true
        )
    }

    /// Whether the Dock is showing more than its bar: Mission Control or App
    /// Exposé. There a click on a Dock icon leaves the mode and shows the
    /// app, so it is a request to see the app. The Dock draws these modes
    /// itself and shows each to Accessibility as a group next to its list of
    /// icons (seen on macOS 15 and 26 as "mc" and "appexpose").
    private static func showsExpose(_ dock: AXUIElement) -> Bool {
        guard let children = AX.value(dock, kAXChildrenAttribute) as? [AXUIElement] else {
            return false
        }
        return children.contains { AX.string($0, kAXRoleAttribute) == "AXGroup" }
    }

    /// The ordinary windows the app shows on this Space right now. The
    /// window server is asked, not the app, so a hung app cannot hold this
    /// up.
    private static func windowsOnScreen(of pid: pid_t) -> Set<CGWindowID> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var found: Set<CGWindowID> = []
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                  let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 40, frame.height >= 40 else {
                continue
            }
            found.insert(number)
        }
        return found
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
            "dock click: nor was one that arrived half a second ago",
            !DockClickRules.wasInFront(since: 99.5, before: 100)
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
