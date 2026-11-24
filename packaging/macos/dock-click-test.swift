import ApplicationServices
import Cocoa

// Plays the person at the Mac for dock-click-test.sh. It finds an app's Dock
// icon through Accessibility, clicks it with mouse events posted the way the
// hardware posts them, and checks what became of the app's windows.
//
//   dock-click-test preflight   can this session do that at all? (77: no)
//   dock-click-test control     SuperSurfer is not running
//   dock-click-test hide        SuperSurfer runs with Dock Click on "hide"
//   dock-click-test minimize    SuperSurfer runs with Dock Click on "minimize"
//   dock-click-test menu        SuperSurfer runs with Dock Click off; the
//                               test switches it on and off in the menu

func say(_ text: String) {
    print(text)
    fflush(stdout)
}

func stop(_ why: String) -> Never {
    say("FAIL  \(why)")
    exit(1)
}

/// Waits while the run loop keeps turning: that is what keeps
/// `NSRunningApplication` current in a command line tool. The run loop
/// returns at once when nothing is attached to it, hence the sleep.
func pause(_ seconds: TimeInterval) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        CFRunLoopRunInMode(.defaultMode, 0.01, false)
        usleep(5_000)
    }
}

func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() {
            return true
        }
        pause(0.05)
    }
    return condition()
}

// MARK: - Accessibility

func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var found: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &found) == .success else {
        return nil
    }
    return found
}

func text(_ element: AXUIElement, _ attribute: String) -> String? {
    return value(element, attribute) as? String
}

func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
    return (value(element, attribute) as? [AXUIElement]) ?? []
}

/// The middle of an element on screen, where a click on it goes. Nil while
/// the element has no size, which is how a menu entry looks that is not shown.
func middle(of element: AXUIElement) -> CGPoint? {
    guard let position = value(element, kAXPositionAttribute),
          let size = value(element, kAXSizeAttribute) else {
        return nil
    }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &extent),
          extent.width > 0, extent.height > 0 else {
        return nil
    }
    return CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
}

struct Icon {
    let title: String
    let url: URL?
    let element: AXUIElement

    var centre: CGPoint? {
        return middle(of: element)
    }
}

func dockElement() -> AXUIElement? {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
        return nil
    }
    return AXUIElementCreateApplication(dock.processIdentifier)
}

func appIcons() -> [Icon] {
    guard let dock = dockElement() else {
        return []
    }
    var icons: [Icon] = []
    for list in elements(dock, kAXChildrenAttribute) where text(list, kAXRoleAttribute) == "AXList" {
        for item in elements(list, kAXChildrenAttribute)
        where text(item, kAXSubroleAttribute) == "AXApplicationDockItem" {
            icons.append(Icon(
                title: text(item, kAXTitleAttribute) ?? "?",
                url: value(item, kAXURLAttribute) as? URL,
                element: item
            ))
        }
    }
    return icons
}

func icon(of app: NSRunningApplication) -> Icon? {
    let icons = appIcons()
    if let bundle = app.bundleURL?.resolvingSymlinksInPath().path,
       let match = icons.first(where: { $0.url?.resolvingSymlinksInPath().path == bundle }) {
        return match
    }
    return icons.first { $0.title == app.localizedName }
}

// MARK: - Mouse

let mouse = CGEventSource(stateID: .hidSystemState)

/// `count` is 1 for a click and 2 for the second click of a double click.
func post(_ type: CGEventType, at point: CGPoint, count: Int64 = 1) {
    guard let event = CGEvent(
        mouseEventSource: mouse,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: .left
    ) else {
        stop("could not make a mouse event")
    }
    if type != .mouseMoved {
        event.setIntegerValueField(.mouseEventClickState, value: count)
    }
    event.post(tap: .cghidEventTap)
}

/// One click on the app's Dock icon, the way a hand does it: the pointer
/// arrives and rests, the button goes down and comes up. A tap on a trackpad
/// is the same with `held` at a few milliseconds.
func click(_ app: NSRunningApplication, held: TimeInterval = 0.08) {
    guard let spot = icon(of: app)?.centre else {
        stop("no Dock icon found for \(name(app))")
    }
    post(.mouseMoved, at: spot)
    pause(0.3)
    post(.leftMouseDown, at: spot)
    usleep(useconds_t(held * 1_000_000))
    post(.leftMouseUp, at: spot)
}

/// Two clicks in a row, the second `gap` seconds after the first.
func doubleClick(_ app: NSRunningApplication, gap: TimeInterval) {
    guard let spot = icon(of: app)?.centre else {
        stop("no Dock icon found for \(name(app))")
    }
    post(.mouseMoved, at: spot)
    pause(0.3)
    for count: Int64 in [1, 2] {
        post(.leftMouseDown, at: spot, count: count)
        usleep(50_000)
        post(.leftMouseUp, at: spot, count: count)
        if count == 1 {
            usleep(useconds_t(gap * 1_000_000))
        }
    }
}

func press(at spot: CGPoint) {
    post(.leftMouseDown, at: spot)
    usleep(60_000)
    post(.leftMouseUp, at: spot)
}

// MARK: - SuperSurfer's menu

func superSurfer() -> AXUIElement {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.supersurfer.app").first else {
        stop("SuperSurfer is not running")
    }
    return AXUIElementCreateApplication(app.processIdentifier)
}

/// SuperSurfer's icon in the menu bar.
func statusItem() -> AXUIElement? {
    guard let bar = value(superSurfer(), "AXExtrasMenuBar") else {
        return nil
    }
    return elements(bar as! AXUIElement, kAXChildrenAttribute).first
}

/// The entries of the menu under that icon, as they were built when it last
/// opened. The menu is rebuilt on every opening, so nothing here is kept.
func statusMenuEntries() -> [AXUIElement] {
    guard let item = statusItem() else {
        return []
    }
    return elements(item, kAXChildrenAttribute).flatMap { elements($0, kAXChildrenAttribute) }
}

func dockClickEntry() -> AXUIElement? {
    return statusMenuEntries().first { (text($0, kAXTitleAttribute) ?? "").contains("Dock") }
}

/// Opens the menu with a click on the icon and the Dock Click submenu with a
/// click on its entry, then clicks the choice with one of the given titles
/// (English or German). Returns the title the Dock Click entry had.
func chooseDockClick(_ wanted: [String]) -> String {
    guard let item = statusItem(), let icon = middle(of: item) else {
        stop("SuperSurfer has no icon in the menu bar")
    }
    post(.mouseMoved, at: icon)
    pause(0.3)
    press(at: icon)
    pause(0.8)

    var found: CGPoint?
    guard waitUntil(6, {
        found = dockClickEntry().flatMap(middle)
        return found != nil
    }), let row = found else {
        let entries = statusMenuEntries().map { text($0, kAXTitleAttribute) ?? "" }
        stop("SuperSurfer's menu did not open, or has no Dock Click entry: \(entries)")
    }
    let title = dockClickEntry().flatMap { text($0, kAXTitleAttribute) } ?? ""

    // A click on an entry with a submenu opens the submenu and keeps the
    // menu up.
    post(.mouseMoved, at: row)
    pause(0.3)
    press(at: row)
    pause(0.8)

    var target: CGPoint?
    var offered: [String] = []
    guard waitUntil(6, {
        let choices = dockClickEntry()
            .map { elements($0, kAXChildrenAttribute).flatMap { elements($0, kAXChildrenAttribute) } } ?? []
        offered = choices.map { text($0, kAXTitleAttribute) ?? "" }
        target = choices.first { wanted.contains(text($0, kAXTitleAttribute) ?? "") }.flatMap(middle)
        return target != nil
    }), let spot = target else {
        stop("no choice \(wanted) under \(title): \(offered)")
    }
    // Sideways first, then up or down, so the pointer never crosses another
    // entry of the main menu on its way.
    post(.mouseMoved, at: CGPoint(x: spot.x, y: row.y))
    pause(0.3)
    post(.mouseMoved, at: spot)
    pause(0.3)
    press(at: spot)
    pause(1)
    return title
}

// MARK: - What can be seen of an app

func name(_ app: NSRunningApplication) -> String {
    return app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
}

/// Ordinary windows of the app that the window server has on screen. Zero
/// while the app is hidden or all its windows sit in the Dock.
func windowsOnScreen(_ app: NSRunningApplication) -> Int {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return 0
    }
    return list.filter { window in
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
            return false
        }
        return frame.width >= 40 && frame.height >= 40
    }.count
}

func minimizedWindows(_ app: NSRunningApplication) -> Int {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    return elements(element, kAXWindowsAttribute)
        .filter { (value($0, kAXMinimizedAttribute) as? Bool) == true }
        .count
}

func isInFront(_ app: NSRunningApplication) -> Bool {
    return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
}

/// Hidden the way ⌘H hides: no window left on screen and the app says so.
/// Which app is in front afterwards is not asked: macOS 26 leaves a hidden
/// Finder there.
func isHidden(_ app: NSRunningApplication) -> Bool {
    return windowsOnScreen(app) == 0 && app.isHidden
}

func state(of app: NSRunningApplication) -> String {
    let front = NSWorkspace.shared.frontmostApplication.map(name) ?? "nothing"
    return "\(name(app)): \(windowsOnScreen(app)) windows on screen, \(minimizedWindows(app)) minimized, "
        + "hidden: \(app.isHidden), in front: \(front)"
}

func expect(
    _ what: String,
    of app: NSRunningApplication,
    within timeout: TimeInterval = 6,
    _ condition: () -> Bool
) {
    guard waitUntil(timeout, condition) else {
        say("FAIL  \(what)")
        say("      \(state(of: app))")
        exit(1)
    }
    say("ok    \(what)")
}

/// The condition must hold now and keep holding: for what must not happen.
func stays(_ what: String, of app: NSRunningApplication, for duration: TimeInterval, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(duration)
    while Date() < end {
        guard condition() else {
            say("FAIL  \(what)")
            say("      \(state(of: app))")
            exit(1)
        }
        pause(0.1)
    }
    say("ok    \(what)")
}

// MARK: - Apps to click on

/// Where the two text files for TextEdit go while a test needs them.
let documents = FileManager.default.temporaryDirectory
    .appendingPathComponent("supersurfer-dock-click-\(ProcessInfo.processInfo.processIdentifier)")

func run(_ tool: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    do {
        try process.run()
    } catch {
        stop("\(tool) did not start: \(error.localizedDescription)")
    }
    process.waitUntilExit()
}

/// Opens the app, or brings it to the front if it is running, and waits
/// until it is there with its windows.
func bringToFront(
    _ appName: String,
    _ bundleID: String,
    files: [String] = [],
    windows: Int = 0
) -> NSRunningApplication {
    run("/usr/bin/open", ["-a", appName] + files)
    var found: NSRunningApplication?
    let arrived = waitUntil(40) {
        found = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        guard let app = found else {
            return false
        }
        return isInFront(app) && windowsOnScreen(app) >= windows
    }
    guard arrived, let app = found else {
        stop("\(appName) did not come to the front")
    }
    // A person does not click the Dock in the same instant either.
    pause(1)
    return app
}

func finderToFront() {
    _ = bringToFront("Finder", "com.apple.finder")
}

// MARK: - Tests

func preflight() -> Never {
    guard AXIsProcessTrusted() else {
        say("this shell may not use Accessibility")
        exit(77)
    }
    let icons = appIcons()
    guard let first = icons.first, let spot = first.centre, let dock = dockElement() else {
        say("Accessibility shows no app icons in the Dock")
        exit(77)
    }
    // What Dock Click itself relies on: asked what is at a point, the Dock
    // answers with the icon there.
    var hit: AXUIElement?
    let result = AXUIElementCopyElementAtPosition(dock, Float(spot.x), Float(spot.y), &hit)
    let subrole = hit.flatMap { text($0, kAXSubroleAttribute) } ?? "nothing"
    guard result == .success, subrole == "AXApplicationDockItem" else {
        stop("asked what is at the \(first.title) icon, the Dock answers \(subrole) (error \(result.rawValue))")
    }
    say("the Dock shows \(icons.count) app icons and answers for the one at \(Int(spot.x)),\(Int(spot.y))")
    exit(0)
}

/// The app in front goes away with a click on its icon and is back, and
/// stays, with the next one.
func hideAndBack(_ app: NSRunningApplication, held: TimeInterval = 0.08) {
    click(app, held: held)
    expect("\(name(app)) is hidden", of: app) {
        isHidden(app)
    }
    pause(0.8)
    click(app, held: held)
    expect("\(name(app)) is back", of: app) {
        windowsOnScreen(app) > 0 && isInFront(app) && !app.isHidden
    }
    stays("and stays", of: app, for: 2) {
        windowsOnScreen(app) > 0 && isInFront(app) && !app.isHidden
    }
}

func closeWindows(of app: NSRunningApplication) {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    for window in elements(element, kAXWindowsAttribute) {
        if let button = value(window, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }
}

func finderWithWindow() -> NSRunningApplication {
    run("/usr/bin/open", ["/Applications"])
    return bringToFront("Finder", "com.apple.finder", windows: 1)
}

/// What the other tests take for granted: by itself, macOS does nothing when
/// the icon of the app in front is clicked. If a later macOS did, Dock Click
/// would undo it.
func testControl() {
    let calculator = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    for (label, held) in [("click", 0.08), ("tap", 0.004)] {
        click(calculator, held: held)
        stays("a \(label) on the icon of the app in front changes nothing", of: calculator, for: 2) {
            windowsOnScreen(calculator) > 0 && isInFront(calculator)
        }
    }
    calculator.terminate()

    // Why Dock Click keeps track of the windows it minimizes: for the record,
    // how many of two minimized windows a click on the icon brings back when
    // nobody helps.
    let textEdit = twoTextEditWindows()
    for window in elements(AXUIElementCreateApplication(textEdit.processIdentifier), kAXWindowsAttribute) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }
    expect("two windows minimized by hand", of: textEdit, within: 10) {
        windowsOnScreen(textEdit) == 0 && minimizedWindows(textEdit) == 2
    }
    pause(1)
    click(textEdit)
    pause(3)
    say("      macOS alone brings back \(windowsOnScreen(textEdit)) of 2 windows")
    textEdit.terminate()
    try? FileManager.default.removeItem(at: documents)
}

/// TextEdit in front with two documents, which are two windows.
func twoTextEditWindows() -> NSRunningApplication {
    let folder = documents
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var files: [String] = []
    for title in ["one", "two"] {
        let file = folder.appendingPathComponent("\(title).txt")
        try? title.write(to: file, atomically: true, encoding: .utf8)
        files.append(file.path)
    }
    return bringToFront("TextEdit", "com.apple.TextEdit", files: files, windows: 2)
}

func testHide() {
    let calculator = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    say("      \(state(of: calculator))")

    for (label, held) in [("click", 0.08), ("tap", 0.004)] {
        say("-- \(label): the app in front is hidden, the next \(label) brings it back")
        hideAndBack(calculator, held: held)

        say("-- \(label): an app that only comes to the front with it is left alone")
        finderToFront()
        click(calculator, held: held)
        expect("Calculator comes to the front", of: calculator) {
            isInFront(calculator)
        }
        stays("and is not hidden", of: calculator, for: 2.5) {
            windowsOnScreen(calculator) > 0 && isInFront(calculator)
        }
    }

    for gap in [0.05, 0.25] {
        say("-- a double click, second click after \(gap) s, ends where it began")
        _ = bringToFront("Calculator", "com.apple.calculator", windows: 1)
        doubleClick(calculator, gap: gap)
        pause(1.5)
        stays("Calculator is there", of: calculator, for: 2) {
            windowsOnScreen(calculator) > 0 && isInFront(calculator)
        }
    }

    say("-- Safari: its Dock icon and the running app need not name the same path")
    let safari = bringToFront("Safari", "com.apple.Safari", windows: 1)
    say("      icon: \(icon(of: safari)?.url?.path ?? "?")")
    say("      app:  \(safari.bundleURL?.path ?? "?")")
    hideAndBack(safari)

    say("-- Finder, which is always running")
    let finder = finderWithWindow()
    hideAndBack(finder)

    say("-- an app without a window is left alone: there the click asks for one")
    closeWindows(of: finder)
    expect("Finder has no window", of: finder) {
        windowsOnScreen(finder) == 0 && isInFront(finder)
    }
    pause(1)
    click(finder)
    expect("Finder opens a window", of: finder) {
        windowsOnScreen(finder) > 0
    }
    stays("and is not hidden", of: finder, for: 2.5) {
        windowsOnScreen(finder) > 0 && isInFront(finder)
    }

    closeWindows(of: finder)
    safari.terminate()
    calculator.terminate()
}

/// Dock Click the way it is really switched on: in the menu. The app was
/// started without a choice in its environment, so this also goes through
/// what is stored.
func testMenu() {
    let calculator = bringToFront("Calculator", "com.apple.calculator", windows: 1)

    say("-- off: a click on the icon of the app in front changes nothing")
    click(calculator)
    stays("Calculator is there", of: calculator, for: 2) {
        windowsOnScreen(calculator) > 0 && isInFront(calculator)
    }

    say("-- choosing Hide App in the menu")
    say("      the menu said: \(chooseDockClick(["Hide App", "App ausblenden"]))")
    _ = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    hideAndBack(calculator)

    say("-- choosing Off in the menu")
    say("      the menu said: \(chooseDockClick(["Off", "Aus"]))")
    _ = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    click(calculator)
    stays("Calculator is there", of: calculator, for: 2) {
        windowsOnScreen(calculator) > 0 && isInFront(calculator)
    }

    calculator.terminate()
}

func testMinimize() {
    let textEdit = twoTextEditWindows()
    say("      \(state(of: textEdit))")

    say("-- every window of the app in front goes into the Dock, the next click brings all back")
    click(textEdit)
    expect("both windows are minimized", of: textEdit, within: 10) {
        windowsOnScreen(textEdit) == 0 && minimizedWindows(textEdit) == 2
    }
    say(textEdit.isHidden ? "FAIL  TextEdit was hidden instead" : "ok    TextEdit is not hidden")
    if textEdit.isHidden {
        exit(1)
    }
    pause(0.8)
    click(textEdit)
    expect("both windows are back", of: textEdit, within: 10) {
        windowsOnScreen(textEdit) >= 2 && minimizedWindows(textEdit) == 0
    }
    stays("and stay", of: textEdit, for: 2) {
        windowsOnScreen(textEdit) >= 2 && minimizedWindows(textEdit) == 0
    }
    say("      \(state(of: textEdit))")

    for gap in [0.05, 0.25] {
        say("-- a double click, second click after \(gap) s, ends where it began")
        doubleClick(textEdit, gap: gap)
        pause(1)
        expect("both windows are there", of: textEdit, within: 10) {
            windowsOnScreen(textEdit) >= 2 && minimizedWindows(textEdit) == 0
        }
        stays("and stay", of: textEdit, for: 2) {
            windowsOnScreen(textEdit) >= 2 && minimizedWindows(textEdit) == 0
        }
    }

    say("-- they also come back when another app was in front in between")
    click(textEdit)
    expect("both windows are minimized", of: textEdit, within: 10) {
        windowsOnScreen(textEdit) == 0 && minimizedWindows(textEdit) == 2
    }
    finderToFront()
    click(textEdit)
    expect("both windows are back", of: textEdit, within: 10) {
        windowsOnScreen(textEdit) >= 2 && minimizedWindows(textEdit) == 0 && isInFront(textEdit)
    }

    say("-- an app that only comes to the front with the click is left alone")
    finderToFront()
    click(textEdit)
    expect("TextEdit comes to the front", of: textEdit) {
        isInFront(textEdit)
    }
    stays("and keeps its windows", of: textEdit, for: 2.5) {
        windowsOnScreen(textEdit) >= 2 && minimizedWindows(textEdit) == 0
    }

    say("-- Finder")
    let finder = finderWithWindow()
    let open = windowsOnScreen(finder)
    say("      \(state(of: finder))")
    click(finder)
    expect("its windows are minimized", of: finder, within: 10) {
        windowsOnScreen(finder) == 0 && minimizedWindows(finder) == open
    }
    pause(0.8)
    click(finder)
    expect("and back", of: finder, within: 10) {
        windowsOnScreen(finder) >= open && minimizedWindows(finder) == 0
    }
    pause(1.5)
    say("      \(state(of: finder))")

    closeWindows(of: finder)
    textEdit.terminate()
    try? FileManager.default.removeItem(at: documents)
}

// TEMPORARY: what does the Dock look like to Accessibility in Mission
// Control, App Exposé and Show Desktop, and what does a click on the icon of
// the app in front do there when nobody helps?
func dumpDock(_ label: String) {
    guard let dock = dockElement() else {
        return
    }
    for child in elements(dock, kAXChildrenAttribute) {
        let kids = elements(child, kAXChildrenAttribute)
        say("PROBE \(label): role \(text(child, kAXRoleAttribute) ?? "-")"
            + " subrole \(text(child, kAXSubroleAttribute) ?? "-")"
            + " id \(text(child, "AXIdentifier") ?? "-")"
            + " desc \(text(child, kAXDescriptionAttribute) ?? "-")"
            + " title \(text(child, kAXTitleAttribute) ?? "-")"
            + " children \(kids.count)")
        if text(child, kAXRoleAttribute) != "AXList" {
            for kid in kids.prefix(6) {
                say("PROBE \(label):   - role \(text(kid, kAXRoleAttribute) ?? "-")"
                    + " id \(text(kid, "AXIdentifier") ?? "-")"
                    + " desc \(text(kid, kAXDescriptionAttribute) ?? "-")")
            }
        }
    }
}

func probeModes() {
    let calculator = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    dumpDock("normal")
    let missionControl = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
    for (label, arguments) in [("mission control", []), ("app expose", ["2"]), ("show desktop", ["1"])] {
        run(missionControl, arguments)
        pause(2)
        dumpDock(label)
        say("PROBE \(label): \(state(of: calculator))")
        click(calculator)
        pause(2)
        dumpDock("\(label), after a click on the icon")
        say("PROBE \(label), after a click on the icon: \(state(of: calculator))")
        for keyDown in [true, false] {
            CGEvent(keyboardEventSource: mouse, virtualKey: 53, keyDown: keyDown)?.post(tap: .cghidEventTap)
        }
        pause(1.5)
        _ = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    }
    calculator.terminate()
}

switch CommandLine.arguments.dropFirst().first {
case "probe-modes":
    probeModes()
case "preflight":
    preflight()
case "control":
    testControl()
case "hide":
    testHide()
case "minimize":
    testMinimize()
case "menu":
    testMenu()
default:
    say("usage: dock-click-test preflight | control | hide | minimize | menu")
    exit(2)
}
say("passed")
