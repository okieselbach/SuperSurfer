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

// A test that drives the screen must not hang. No question to another app
// waits longer than this, and no run takes longer than five minutes.
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.5)
DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
    say("FAIL  not finished after five minutes")
    exit(1)
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

/// The last click, for as long as nothing was checked after it: how long the
/// button was really down, and how to click again. A hand holds it for 80 ms.
/// A virtual machine that stalls between down and up makes a second of that,
/// and a press of a second is a long press: the Dock opens the icon's menu,
/// and Dock Click leaves it alone.
struct Clicked {
    let longestPress: TimeInterval
    let again: () -> Void

    var wasNoClick: Bool {
        return longestPress > 0.3
    }
}

var lastClick: Clicked?

/// One click on the app's Dock icon, the way a hand does it: the pointer
/// arrives and rests, the button goes down and comes up. A tap on a trackpad
/// is the same with `held` at a few milliseconds.
func click(_ app: NSRunningApplication, held: TimeInterval = 0.08) {
    guard let spot = icon(of: app)?.centre else {
        stop("no Dock icon found for \(name(app))")
    }
    post(.mouseMoved, at: spot)
    pause(0.3)
    let took = press(at: spot, held: held)
    lastClick = Clicked(longestPress: took, again: { click(app, held: held) })
}

/// Two clicks in a row, the second `gap` seconds after the first. The
/// second one looks for the icon again: while windows go into the Dock, the
/// Dock makes room for them and its icons move.
func doubleClick(_ app: NSRunningApplication, gap: TimeInterval) {
    guard var spot = icon(of: app)?.centre else {
        stop("no Dock icon found for \(name(app))")
    }
    post(.mouseMoved, at: spot)
    pause(0.3)
    var longest: TimeInterval = 0
    for count: Int64 in [1, 2] {
        longest = max(longest, press(at: spot, held: 0.05, count: count))
        if count == 1 {
            usleep(useconds_t(gap * 1_000_000))
            spot = icon(of: app)?.centre ?? spot
        }
    }
    lastClick = Clicked(longestPress: longest, again: { doubleClick(app, gap: gap) })
}

/// A click at a point, on whatever is there.
func click(at spot: CGPoint) {
    post(.mouseMoved, at: spot)
    pause(0.3)
    let took = press(at: spot)
    lastClick = Clicked(longestPress: took, again: { click(at: spot) })
}

/// A spot in the title bar of the app's front window: a click there goes to
/// the app and does nothing.
func titleBar(of app: NSRunningApplication) -> CGPoint? {
    let element = AXUIElementCreateApplication(app.processIdentifier)
    guard let window = elements(element, kAXWindowsAttribute).first,
          let position = value(window, kAXPositionAttribute),
          let size = value(window, kAXSizeAttribute) else {
        return nil
    }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
        return nil
    }
    return CGPoint(x: origin.x + extent.width / 2, y: origin.y + 12)
}

/// Puts a small window of this program over the app's Dock icon, the way a
/// menu or a notification can lie over it. Clicks there go to that window and
/// never reach the Dock. It does not take the front from the app.
func cover(_ app: NSRunningApplication) -> (panel: NSPanel, spot: CGPoint) {
    guard let spot = icon(of: app)?.centre, let primary = NSScreen.screens.first else {
        stop("no Dock icon found for \(name(app))")
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    let side: CGFloat = 60
    // Accessibility counts from the top of the main display, AppKit from its
    // bottom.
    let frame = NSRect(
        x: spot.x - side / 2,
        y: primary.frame.height - spot.y - side / 2,
        width: side,
        height: side
    )
    let panel = NSPanel(
        contentRect: frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.level = .popUpMenu
    panel.backgroundColor = .systemOrange
    panel.isOpaque = true
    panel.hidesOnDeactivate = false
    panel.orderFrontRegardless()
    panel.display()
    pause(0.5)
    return (panel, spot)
}

/// Mission Control (""), Show Desktop ("1") or App Exposé ("2"), the way the
/// keyboard opens them.
func openMissionControl(_ argument: String) {
    let tool = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
    run(tool, argument.isEmpty ? [] : [argument])
    pause(2)
}

func pressEscape() {
    for keyDown in [true, false] {
        CGEvent(keyboardEventSource: mouse, virtualKey: 53, keyDown: keyDown)?.post(tap: .cghidEventTap)
    }
    pause(1)
}

/// Button down and up. Returns how long that really took.
@discardableResult
func press(at spot: CGPoint, held: TimeInterval = 0.06, count: Int64 = 1) -> TimeInterval {
    let began = ProcessInfo.processInfo.systemUptime
    post(.leftMouseDown, at: spot, count: count)
    usleep(useconds_t(held * 1_000_000))
    post(.leftMouseUp, at: spot, count: count)
    return ProcessInfo.processInfo.systemUptime - began
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
    var arrived = waitUntil(timeout, condition)
    // Repeated is only a press that was no click. A click that did not do
    // what it should is what this test is there to find.
    var repeats = 0
    while !arrived, repeats < 2, let last = lastClick, last.wasNoClick {
        repeats += 1
        say("      " + notAClick(last) + ": once more")
        lastClick = nil
        // Such a press may have opened the icon's menu.
        pressEscape()
        last.again()
        arrived = waitUntil(timeout, condition)
    }
    lastClick = nil
    guard arrived else {
        say("FAIL  \(what)")
        say("      \(state(of: app))")
        exit(1)
    }
    say("ok    \(what)")
}

/// The condition must hold now and keep holding: for what must not happen.
func stays(_ what: String, of app: NSRunningApplication, for duration: TimeInterval, _ condition: () -> Bool) {
    if let last = lastClick, last.wasNoClick {
        // Not repeated: for some of these checks it matters when the click
        // came.
        say("      " + notAClick(last) + ", so this says less than it should")
    }
    lastClick = nil
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

func notAClick(_ click: Clicked) -> String {
    return String(format: "this machine held the button down for %.2f s, which is no click", click.longestPress)
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
    let running = (value(first.element, "AXIsApplicationRunning") as? Bool).map { "\($0)" } ?? "not said"
    say("the Dock shows \(icons.count) app icons and answers for the one at \(Int(spot.x)),\(Int(spot.y))"
        + " (\(first.title), running: \(running))")
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

    say("-- clicks that do not go to the Dock are not looked at")
    _ = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    if let bar = titleBar(of: calculator) {
        for _ in 1...4 {
            click(at: bar)
            pause(0.7)
        }
    }
    stays("Calculator is there", of: calculator, for: 1) {
        windowsOnScreen(calculator) > 0 && isInFront(calculator)
    }

    say("-- a window lying over the icon gets the click, and the app stays")
    let lid = cover(calculator)
    click(at: lid.spot)
    stays("Calculator is there", of: calculator, for: 2.5) {
        windowsOnScreen(calculator) > 0 && isInFront(calculator)
    }
    lid.panel.orderOut(nil)
    pause(1)
    say("-- with that window gone the same click hides it again")
    hideAndBack(calculator)

    say("-- a second click soon after switching to an app is left alone")
    finderToFront()
    click(calculator)
    expect("Calculator comes to the front", of: calculator) {
        isInFront(calculator)
    }
    click(calculator)
    stays("and is not hidden by the second click", of: calculator, for: 2.5) {
        windowsOnScreen(calculator) > 0 && isInFront(calculator)
    }

    for (label, argument) in [("Mission Control", ""), ("App Exposé", "2"), ("Show Desktop", "1")] {
        say("-- in \(label) a click on the icon is a way back to the app")
        _ = bringToFront("Calculator", "com.apple.calculator", windows: 1)
        openMissionControl(argument)
        click(calculator)
        pause(1.5)
        stays("Calculator is there", of: calculator, for: 2.5) {
            windowsOnScreen(calculator) > 0 && !calculator.isHidden
        }
        pressEscape()
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

    say("-- a window brought back by hand: the other one stays where the user left it")
    click(textEdit)
    expect("both windows are minimized", of: textEdit, within: 10) {
        windowsOnScreen(textEdit) == 0 && minimizedWindows(textEdit) == 2
    }
    let minimized = elements(AXUIElementCreateApplication(textEdit.processIdentifier), kAXWindowsAttribute)
        .filter { (value($0, kAXMinimizedAttribute) as? Bool) == true }
    if let first = minimized.first {
        AXUIElementSetAttributeValue(first, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    expect("one is back by hand", of: textEdit, within: 10) {
        windowsOnScreen(textEdit) == 1 && minimizedWindows(textEdit) == 1
    }
    finderToFront()
    click(textEdit)
    expect("TextEdit comes to the front", of: textEdit) {
        isInFront(textEdit)
    }
    stays("and the other window stays minimized", of: textEdit, for: 2.5) {
        minimizedWindows(textEdit) == 1
    }
    for window in elements(AXUIElementCreateApplication(textEdit.processIdentifier), kAXWindowsAttribute) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    expect("both windows are there again", of: textEdit, within: 10) {
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

// TEMPORARY: for the question whether a Dock icon per browser profile can
// bring that profile's window to the front. What tells the windows of the
// profiles apart, and what brings one of them forward?

func whoIsInFront() -> String {
    return NSWorkspace.shared.frontmostApplication
        .map { "\(name($0)) (pid \($0.processIdentifier))" } ?? "nothing"
}

func outputOf(_ tool: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return "?"
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func axWindows(_ app: NSRunningApplication) -> [AXUIElement] {
    return elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute)
}

func isMain(_ window: AXUIElement) -> Bool {
    return (value(window, kAXMainAttribute) as? Bool) == true
}

func windowLines(_ tag: String, _ label: String, _ app: NSRunningApplication) {
    say("PROBE \(tag), \(label): \(windowsOnScreen(app)) windows on screen, in front: \(whoIsInFront())")
    for window in axWindows(app) {
        let title = text(window, kAXTitleAttribute) ?? "?"
        let minimized = (value(window, kAXMinimizedAttribute) as? Bool) ?? false
        say("PROBE \(tag), \(label):   \"\(title)\" main: \(isMain(window)), minimized: \(minimized)")
    }
}

func probeChromium(_ tag: String, _ appPath: String, _ binaryName: String, _ bundleID: String) {
    let binary = appPath + "/Contents/MacOS/" + binaryName
    guard FileManager.default.fileExists(atPath: binary) else {
        say("PROBE \(tag): not installed")
        return
    }
    let data = FileManager.default.temporaryDirectory
        .appendingPathComponent("supersurfer-\(tag)-probe-\(ProcessInfo.processInfo.processIdentifier)").path
    func launch(_ profile: String, _ url: String?) {
        var arguments = [
            "--user-data-dir=\(data)", "--profile-directory=\(profile)",
            "--no-first-run", "--no-default-browser-check", "--password-store=basic", "--use-mock-keychain",
        ]
        if let url = url {
            arguments.append(url)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            say("PROBE \(tag): started with profile folder \(profile), pid \(process.processIdentifier)")
        } catch {
            say("PROBE \(tag): could not start: \(error.localizedDescription)")
        }
    }
    func running() -> NSRunningApplication? {
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.activationPolicy == .regular }
    }
    defer {
        for instance in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            instance.forceTerminate()
        }
        pause(2)
        try? FileManager.default.removeItem(atPath: data)
    }

    launch("Default", "about:blank")
    guard waitUntil(40, { running().map { windowsOnScreen($0) > 0 } ?? false }), let app = running() else {
        say("PROBE \(tag): no window after 40 s")
        return
    }
    pause(4)
    windowLines(tag, "one profile", app)
    launch("Profile 1", "about:blank")
    pause(6)
    launch("Profile 2", "about:blank")
    pause(6)
    windowLines(tag, "three profiles", app)

    let element = AXUIElementCreateApplication(app.processIdentifier)
    /// The entries of the menu that lists the profiles, read afresh each
    /// time: the browser builds that menu again when windows come and go.
    func profileMenu() -> [AXUIElement] {
        guard let bar = value(element, kAXMenuBarAttribute) else {
            return []
        }
        for menu in elements(bar as! AXUIElement, kAXChildrenAttribute)
        where (text(menu, kAXTitleAttribute) ?? "").lowercased().contains("profil") {
            return elements(menu, kAXChildrenAttribute).flatMap { elements($0, kAXChildrenAttribute) }
        }
        return []
    }
    func choose(_ index: Int, _ label: String) {
        let items = profileMenu()
        guard index < items.count else {
            say("PROBE \(tag), \(label): the menu has only \(items.count) entries")
            return
        }
        let title = text(items[index], kAXTitleAttribute) ?? "?"
        let result = AXUIElementPerformAction(items[index], kAXPressAction as CFString)
        pause(2.5)
        say("PROBE \(tag), \(label): chose \"\(title)\" in the menu (error \(result.rawValue))")
        windowLines(tag, label, app)
    }
    if let bar = value(element, kAXMenuBarAttribute) {
        let titles = elements(bar as! AXUIElement, kAXChildrenAttribute).map { text($0, kAXTitleAttribute) ?? "?" }
        say("PROBE \(tag): menus \(titles)")
    } else {
        say("PROBE \(tag): no menu bar through Accessibility")
    }
    say("PROBE \(tag): profile menu \(profileMenu().map { text($0, kAXTitleAttribute) ?? "" })")
    say("PROBE \(tag): its identifiers \(profileMenu().map { text($0, "AXIdentifier") ?? "-" })")

    choose(0, "first entry")
    choose(1, "second entry")

    // From behind another app.
    let calculator = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    choose(2, "third entry, Calculator in front")
    if !isInFront(app) {
        app.activate(options: [])
        pause(1.5)
        say("PROBE \(tag): asked forward after that: in front: \(whoIsInFront())")
    }

    // The profile's window is in the Dock.
    if let main = axWindows(app).first(where: isMain) {
        AXUIElementSetAttributeValue(main, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        pause(2)
        windowLines(tag, "its window minimized", app)
        choose(2, "third entry, its window minimized")
    }

    // The profile has no window.
    if let main = axWindows(app).first(where: isMain), let button = value(main, kAXCloseButtonAttribute) {
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        pause(2)
        windowLines(tag, "its window closed", app)
        say("PROBE \(tag): profile menu now \(profileMenu().map { text($0, kAXTitleAttribute) ?? "" })")
        choose(2, "third entry, its window closed")
    }

    // Without the menu: one window raised through Accessibility, then the app
    // asked forward.
    _ = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    if let other = axWindows(app).first(where: { !isMain($0) }) {
        let wanted = text(other, kAXTitleAttribute) ?? "?"
        let raised = AXUIElementPerformAction(other, kAXRaiseAction as CFString)
        app.activate(options: [])
        pause(2)
        say("PROBE \(tag): raised \"\(wanted)\" (error \(raised.rawValue)) and asked the app forward")
        windowLines(tag, "after raising", app)
    }

    _ = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    launch("Default", nil)
    pause(5)
    windowLines(tag, "started again with the first profile and no address", app)
    calculator.terminate()
}

func probeFirefox() {
    let binary = "/Applications/Firefox.app/Contents/MacOS/firefox"
    guard FileManager.default.fileExists(atPath: binary) else {
        say("PROBE firefox: not installed")
        return
    }
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("supersurfer-firefox-probe-\(ProcessInfo.processInfo.processIdentifier)")
    func instances() -> [NSRunningApplication] {
        return NSRunningApplication.runningApplications(withBundleIdentifier: "org.mozilla.firefox")
    }
    func launch(_ profile: String, _ more: [String]) {
        let folder = base.appendingPathComponent(profile)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let quiet = [
            "user_pref(\"browser.shell.checkDefaultBrowser\", false);",
            "user_pref(\"browser.aboutwelcome.enabled\", false);",
            "user_pref(\"datareporting.policy.dataSubmissionEnabled\", false);",
            "user_pref(\"browser.startup.homepage_override.mstone\", \"ignore\");",
        ].joined(separator: "\n")
        try? quiet.write(to: folder.appendingPathComponent("user.js"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--profile", folder.path] + more
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            say("PROBE firefox: started with profile \(profile) and \(more), pid \(process.processIdentifier)")
        } catch {
            say("PROBE firefox: could not start: \(error.localizedDescription)")
        }
    }
    func report(_ label: String) {
        let all = instances()
        let icons = appIcons().filter { $0.title.contains("Firefox") }.count
        say("PROBE firefox, \(label): \(all.count) running, Dock icons: \(icons), in front: \(whoIsInFront())")
        for instance in all {
            let pid = instance.processIdentifier
            let arguments = outputOf("/bin/ps", ["-ww", "-o", "args=", "-p", "\(pid)"])
            say("PROBE firefox, \(label):   pid \(pid), \(windowsOnScreen(instance)) windows on screen: \(arguments)")
            for window in axWindows(instance) {
                say("PROBE firefox, \(label):     \"\(text(window, kAXTitleAttribute) ?? "?")\"")
            }
        }
    }
    defer {
        for instance in instances() {
            instance.forceTerminate()
        }
        pause(2)
        try? FileManager.default.removeItem(at: base)
    }

    launch("one", ["--new-instance", "about:blank"])
    guard waitUntil(60, { instances().contains { windowsOnScreen($0) > 0 } }) else {
        say("PROBE firefox: no window after 60 s")
        report("no window")
        return
    }
    pause(5)
    report("one profile")
    launch("two", ["--new-instance", "about:blank"])
    pause(12)
    report("two profiles")

    let calculator = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    for instance in instances() {
        instance.activate(options: [])
        pause(1.5)
        say("PROBE firefox: asked pid \(instance.processIdentifier) forward: in front: \(whoIsInFront())")
        _ = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    }

    launch("one", [])
    pause(8)
    report("started again with the first profile and no address")
    calculator.terminate()
}

/// A helper app in the Dock that only runs a script: how long from the click
/// until the script runs, and what does the Dock make of it?
func probeStub(_ path: String, _ marker: String) {
    let wanted = URL(fileURLWithPath: path).lastPathComponent
    var found: Icon?
    let there = waitUntil(30) {
        found = appIcons().first { $0.url?.lastPathComponent == wanted }
        return found != nil
    }
    guard there, let stub = found, let spot = stub.centre else {
        say("PROBE stub: the Dock does not show \(wanted); it shows \(appIcons().map { $0.title })")
        return
    }
    say("PROBE stub: in the Dock as \"\(stub.title)\" at \(Int(spot.x)),\(Int(spot.y))")
    let calculator = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    for round in 1...3 {
        try? FileManager.default.removeItem(atPath: marker)
        post(.mouseMoved, at: spot)
        pause(0.3)
        let took = press(at: spot)
        let released = ProcessInfo.processInfo.systemUptime
        var ran: TimeInterval?
        while ProcessInfo.processInfo.systemUptime - released < 10 {
            if FileManager.default.fileExists(atPath: marker) {
                ran = ProcessInfo.processInfo.systemUptime - released
                break
            }
            usleep(2_000)
        }
        let after = ran.map { String(format: "%.0f ms after the button came up", $0 * 1000) } ?? "not within 10 s"
        say("PROBE stub, click \(round): " + String(format: "button down for %.0f ms, the script ran ", took * 1000)
            + after)
        for wait in [0.2, 0.8, 2.0] {
            pause(wait)
            let running = (value(stub.element, "AXIsApplicationRunning") as? Bool).map { "\($0)" } ?? "not said"
            say("PROBE stub, click \(round): later, shown as running: \(running), in front: \(whoIsInFront())")
        }
    }
    calculator.terminate()
}

switch CommandLine.arguments.dropFirst().first {
case "probe-edge":
    probeChromium("edge", "/Applications/Microsoft Edge.app", "Microsoft Edge", "com.microsoft.edgemac")
case "probe-chrome":
    probeChromium("chrome", "/Applications/Google Chrome.app", "Google Chrome", "com.google.Chrome")
case "probe-firefox":
    probeFirefox()
case "probe-stub":
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    if arguments.count == 2 {
        probeStub(arguments[0], arguments[1])
    }
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
