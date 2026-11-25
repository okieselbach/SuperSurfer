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
//
// and for dock-shortcut-test.sh, which tests the Dock shortcuts for browser
// profiles:
//
//   dock-click-test shortcuts <edge|chrome> <scratch HOME> <SuperSurfer.app>
//                             <SuperSurfer's trace> [dock] [start]

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

/// How many questions to other apps got no answer in the time set above. An
/// app that is busy is silent like that for a moment, and the question then
/// comes back as if there were nothing to tell. A check that must not take
/// that for an answer compares this number before and after it looks.
var unanswered = 0

func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var found: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &found)
    if result == .cannotComplete {
        unanswered += 1
    }
    guard result == .success else {
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
    /// For a click of which it can be told that it was lost on its way: what
    /// became of it, or nil if it arrived.
    var lost: (() -> String?)?

    var wasNoClick: Bool {
        return longestPress > 0.3
    }

    /// Why this click may be made again, if it may. Only a click that never
    /// counted as one is repeated. A click that arrived and did not do what
    /// it should is what these tests are there to find.
    var excuse: String? {
        if wasNoClick {
            return notAClick(self)
        }
        return lost?()
    }
}

var lastClick: Clicked?

/// Where SuperSurfer writes its trace, if the script said so.
let tracePath = ProcessInfo.processInfo.environment["SUPERSURFER_TRACE"]

/// To be asked before a click on a Dock icon. Dock Click drops a click that
/// it can only act on too late, and says so in its trace. There are two
/// such moments: when the click reaches it more than a quarter of a second
/// after it was made, and when the click is more than a second old once
/// everything has been asked that has to be asked before an app is put
/// away. On a virtual machine both happen now and then, the second one seen
/// on macOS 26 while Safari was starting. Such a click says nothing about
/// what Dock Click does with one that comes through in time.
func lateForSuperSurfer() -> (() -> String?)? {
    guard let path = tracePath else {
        return nil
    }
    func droppedForAge() -> Int {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.components(separatedBy: "\n").filter { line in
            line.contains("was left alone")
                || (line.contains("left alone after all") && line.contains("the click is"))
        }.count
    }
    let before = droppedForAge()
    return {
        droppedForAge() > before ? "SuperSurfer got this click too late to act on it" : nil
    }
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
    let late = lateForSuperSurfer()
    let took = press(at: spot, held: held)
    lastClick = Clicked(longestPress: took, again: { click(app, held: held) }, lost: late)
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
    let late = lateForSuperSurfer()
    var longest: TimeInterval = 0
    for count: Int64 in [1, 2] {
        longest = max(longest, press(at: spot, held: 0.05, count: count))
        if count == 1 {
            usleep(useconds_t(gap * 1_000_000))
            spot = icon(of: app)?.centre ?? spot
        }
    }
    lastClick = Clicked(longestPress: longest, again: { doubleClick(app, gap: gap) }, lost: late)
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
    return statusMenuEntries().first { entry in
        let title = text(entry, kAXTitleAttribute) ?? ""
        return title.contains("Dock Click") || title.contains("Dock-Klick")
    }
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

/// What the app itself lists as its windows, for a check that failed. The
/// window server and the app are asked in different ways, and only the app
/// can fail to answer.
func ownAccount(of app: NSRunningApplication) -> String {
    let before = unanswered
    let windows = elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute)
    let listed = windows.map { window -> String in
        let title = text(window, kAXTitleAttribute) ?? "?"
        return (value(window, kAXMainAttribute) as? Bool) == true ? "\"\(title)\" (main)" : "\"\(title)\""
    }
    if unanswered != before {
        return "\(name(app)) gave no answer when asked for its windows"
    }
    return "\(name(app)) itself lists \(listed.count) windows: \(listed.joined(separator: ", "))"
}

/// What the condition of a check saw at its latest look, in words, where the
/// condition says so. A check that fails prints it: what is there a moment
/// later need not be what the look saw.
var lastLook = ""

func fail(_ what: String, of app: NSRunningApplication, because why: String? = nil) -> Never {
    say("FAIL  \(what)")
    if let why = why {
        say("      \(why)")
    }
    if !lastLook.isEmpty {
        say("      the last look saw: \(lastLook)")
    }
    say("      \(state(of: app))")
    say("      \(ownAccount(of: app))")
    exit(1)
}

func expect(
    _ what: String,
    of app: NSRunningApplication,
    within timeout: TimeInterval = 6,
    _ condition: () -> Bool
) {
    lastLook = ""
    var arrived = waitUntil(timeout, condition)
    // Repeated is only a press that was no click. A click that did not do
    // what it should is what this test is there to find.
    var repeats = 0
    while !arrived, repeats < 2, let last = lastClick, let excuse = last.excuse {
        repeats += 1
        say("      " + excuse + ": once more")
        lastClick = nil
        // Such a press may have opened the icon's menu.
        pressEscape()
        last.again()
        arrived = waitUntil(timeout, condition)
    }
    lastClick = nil
    guard arrived else {
        fail(what, of: app)
    }
    say("ok    \(what)")
}

/// How long `stays` goes on asking an app that does not answer, once its
/// time is up.
let patienceWithSilence: TimeInterval = 10

/// The condition must hold now and keep holding: for what must not happen.
///
/// A look during which an app left a question unanswered has seen nothing,
/// so it counts neither way: a browser that is busy for a second has not
/// opened a window by that. The check therefore ends with a look that got
/// its answers, and fails for want of one if the app stays silent.
func stays(_ what: String, of app: NSRunningApplication, for duration: TimeInterval, _ condition: () -> Bool) {
    if let last = lastClick, last.wasNoClick {
        // Not repeated: for some of these checks it matters when the click
        // came.
        say("      " + notAClick(last) + ", so this says less than it should")
    }
    lastClick = nil
    lastLook = ""
    let end = Date().addingTimeInterval(duration)
    var silent = 0
    var answered = false
    while Date() < end || !answered {
        let before = unanswered
        let holds = condition()
        if unanswered == before {
            guard holds else {
                fail(what, of: app)
            }
            answered = true
        } else {
            silent += 1
            answered = false
            guard Date() < end.addingTimeInterval(patienceWithSilence) else {
                fail(what, of: app, because: "an app has left the questions of \(silent) looks unanswered, "
                    + "the latest \(Int(patienceWithSilence)) s after the time was up, so this cannot be told")
            }
        }
        pause(0.1)
    }
    if silent > 0 {
        say("      \(silent) of the looks got no answer from an app in time and were left out")
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

// MARK: - Dock shortcuts for browser profiles

struct TestBrowser {
    let id: String
    /// As SuperSurfer's menu lists it.
    let name: String
    /// What its shortcuts are named after.
    let shortName: String
    let appPath: String
    let binary: String
    let bundleID: String
    /// Where it keeps its profiles, below Library/Application Support.
    let dataFolder: String
}

let testBrowsers = [
    TestBrowser(
        id: "edge",
        name: "Microsoft Edge",
        shortName: "Edge",
        appPath: "/Applications/Microsoft Edge.app",
        binary: "Microsoft Edge",
        bundleID: "com.microsoft.edgemac",
        dataFolder: "Microsoft Edge"
    ),
    TestBrowser(
        id: "chrome",
        name: "Google Chrome",
        shortName: "Chrome",
        appPath: "/Applications/Google Chrome.app",
        binary: "Google Chrome",
        bundleID: "com.google.Chrome",
        dataFolder: "Google/Chrome"
    ),
]

func axWindows(_ app: NSRunningApplication) -> [AXUIElement] {
    return elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute)
}

func isMain(_ window: AXUIElement) -> Bool {
    return (value(window, kAXMainAttribute) as? Bool) == true
}

/// The title of the app's main window, which is the one in front of its
/// others.
func mainWindowTitle(_ app: NSRunningApplication) -> String {
    return axWindows(app).first(where: isMain).flatMap { text($0, kAXTitleAttribute) } ?? ""
}

func window(of app: NSRunningApplication, showing page: String) -> AXUIElement? {
    return axWindows(app).first { (text($0, kAXTitleAttribute) ?? "").contains(page) }
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
        return ""
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Clicks its way down SuperSurfer's menu, one entry per step. A click on an
/// entry with a submenu opens it and keeps the menu up, so the next step
/// finds its entries. False, with the menu closed again, if a step finds
/// nothing to click.
func clickDownMenu(_ steps: [([AXUIElement]) -> AXUIElement?]) -> Bool {
    guard let item = statusItem(), let icon = middle(of: item) else {
        stop("SuperSurfer has no icon in the menu bar")
    }
    post(.mouseMoved, at: icon)
    pause(0.3)
    press(at: icon)
    pause(0.8)

    var entries: () -> [AXUIElement] = { statusMenuEntries() }
    var from: CGPoint?
    for step in steps {
        var target: AXUIElement?
        var spot: CGPoint?
        let found = waitUntil(4) {
            target = step(entries())
            spot = target.flatMap(middle)
            return spot != nil
        }
        guard found, let entry = target, let point = spot else {
            for _ in 1...3 {
                pressEscape()
            }
            return false
        }
        // Sideways first, then up or down, so the pointer never crosses
        // another entry of the menu it comes from on its way.
        if let last = from {
            post(.mouseMoved, at: CGPoint(x: point.x, y: last.y))
            pause(0.3)
        }
        post(.mouseMoved, at: point)
        pause(0.3)
        press(at: point)
        pause(0.8)
        from = point
        entries = { elements(entry, kAXChildrenAttribute).flatMap { elements($0, kAXChildrenAttribute) } }
    }
    return true
}

/// The "Dock Shortcuts" entry of SuperSurfer's menu, English or German.
func dockShortcutsEntry(_ entries: [AXUIElement]) -> AXUIElement? {
    return entries.first { entry in
        let title = text(entry, kAXTitleAttribute) ?? ""
        return title.contains("Dock Shortcuts") || title.contains("Dock-Verknüpfungen")
    }
}

/// The entry for a profile, below the line that names its browser. Where
/// its shortcut has a name of the user's choosing, the entry shows that
/// behind an arrow.
func profileEntry(_ browser: String, _ profile: String) -> ([AXUIElement]) -> AXUIElement? {
    return { entries in
        let titles = entries.map { text($0, kAXTitleAttribute) ?? "" }
        guard let header = titles.firstIndex(of: browser) else {
            return nil
        }
        for index in titles.indices
        where index > header && (titles[index] == profile || titles[index].hasPrefix(profile + " → ")) {
            return entries[index]
        }
        return nil
    }
}

func entryTitled(_ wanted: [String]) -> ([AXUIElement]) -> AXUIElement? {
    return { entries in entries.first { wanted.contains(text($0, kAXTitleAttribute) ?? "") } }
}

/// What the Dock draws for one of its icons, as the screen shows it. Nil
/// where this session may not look at the screen.
func dockPicture(named name: String) -> NSBitmapImageRep? {
    guard CGPreflightScreenCaptureAccess(),
          let icon = appIcons().first(where: { $0.url?.lastPathComponent == name }),
          let position = value(icon.element, kAXPositionAttribute),
          let size = value(icon.element, kAXSizeAttribute) else {
        return nil
    }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
        return nil
    }
    let file = NSTemporaryDirectory() + "supersurfer-dock-\(UUID().uuidString).png"
    let rect = "\(Int(origin.x)),\(Int(origin.y)),\(Int(extent.width)),\(Int(extent.height))"
    run("/usr/sbin/screencapture", ["-x", "-R", rect, file])
    defer { try? FileManager.default.removeItem(atPath: file) }
    return FileManager.default.contents(atPath: file).flatMap { NSBitmapImageRep(data: $0) }
}

/// In how many of their points two such pictures differ. Nil if that
/// cannot be told.
func pointsThatDiffer(_ first: NSBitmapImageRep?, _ second: NSBitmapImageRep?) -> Int? {
    guard let first = first, let second = second,
          first.pixelsWide == second.pixelsWide, first.pixelsHigh == second.pixelsHigh else {
        return nil
    }
    var differing = 0
    for y in 0..<first.pixelsHigh {
        for x in 0..<first.pixelsWide {
            guard let one = first.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  let other = second.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            let apart = abs(one.redComponent - other.redComponent) + abs(one.greenComponent - other.greenComponent)
                + abs(one.blueComponent - other.blueComponent)
            if apart > 0.08 {
                differing += 1
            }
        }
    }
    return differing
}

/// Everything below an element that has this role, a few levels down.
func descendants(of root: AXUIElement, role: String, depth: Int = 5) -> [AXUIElement] {
    var found: [AXUIElement] = []
    for child in elements(root, kAXChildrenAttribute) {
        if text(child, kAXRoleAttribute) == role {
            found.append(child)
        }
        if depth > 0 {
            found += descendants(of: child, role: role, depth: depth - 1)
        }
    }
    return found
}

/// The window in which SuperSurfer asks for a line of text, while it is up:
/// its field and its buttons.
func superSurferQuestion() -> (field: AXUIElement, buttons: [AXUIElement])? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.supersurfer.app").first else {
        return nil
    }
    for window in elements(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) {
        if let field = descendants(of: window, role: kAXTextFieldRole).first {
            return (field, descendants(of: window, role: kAXButtonRole))
        }
    }
    return nil
}

/// Answers that question: the text goes into the field, and the button
/// that says yes is pressed.
func answerQuestion(with answer: String, button wanted: [String]) {
    var question: (field: AXUIElement, buttons: [AXUIElement])?
    let asked = waitUntil(10) {
        question = superSurferQuestion()
        return question != nil
    }
    guard asked, let found = question else {
        stop("SuperSurfer did not ask for a name")
    }
    pause(0.5)
    let set = AXUIElementSetAttributeValue(found.field, kAXValueAttribute as CFString, answer as CFString)
    pause(0.3)
    let shown = text(found.field, kAXValueAttribute) ?? ""
    guard set == .success, shown == answer else {
        stop("the name did not get into SuperSurfer's question: error \(set.rawValue), the field has \"\(shown)\"")
    }
    let titles = found.buttons.map { text($0, kAXTitleAttribute) ?? "?" }
    guard let button = found.buttons.first(where: { wanted.contains(text($0, kAXTitleAttribute) ?? "") }) else {
        stop("SuperSurfer's question has no button \(wanted), it has \(titles)")
    }
    AXUIElementPerformAction(button, kAXPressAction as CFString)
    let gone = waitUntil(10) { superSurferQuestion() == nil }
    if !gone {
        stop("SuperSurfer's question did not go away")
    }
}

/// SuperSurfer reads a browser's profiles when its menu opens, and keeps
/// what it read for a quarter of a minute. A profile made a moment ago may
/// not be in the menu yet, so this tries more than once.
func chooseInDockShortcuts(_ steps: [([AXUIElement]) -> AXUIElement?], what: String) {
    for attempt in 1...4 {
        if clickDownMenu([dockShortcutsEntry] + steps) {
            return
        }
        say("      \(what) is not in the menu (attempt \(attempt))")
        pause(6)
    }
    stop("SuperSurfer's menu has no \(what) under Dock Shortcuts")
}

// MARK: - A browser that does not come

/// The processes of an app's own program, its helpers left out, as `ps`
/// lists them: number, how long it has been running, and what it was
/// started with.
func mainProcesses(of binary: String) -> [String] {
    return outputOf("/bin/ps", ["-axww", "-o", "pid=,etime=,args="])
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.contains("/Contents/MacOS/\(binary)") && !$0.contains("--type=") && !$0.contains("Helper") }
}

/// Where SuperSurfer's threads are, cut down to the lines that name a
/// thread or have to do with starting an app. For a start that SuperSurfer
/// asked macOS for and that did not come.
func superSurferThreads() -> [String] {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.supersurfer.app").first else {
        return ["SuperSurfer is not running"]
    }
    let file = NSTemporaryDirectory() + "supersurfer-sample-\(UUID().uuidString).txt"
    _ = outputOf("/usr/bin/sample", ["\(app.processIdentifier)", "1", "-file", file])
    defer { try? FileManager.default.removeItem(atPath: file) }
    let report = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
    let telling = ["Thread_", "LSOpen", "_LS", "NSWorkspace", "LaunchServices", "xpc_connection_send", "openApplication"]
    let lines = report.components(separatedBy: "\n")
        .filter { line in telling.contains { line.contains($0) } }
        .map { $0.trimmingCharacters(in: .whitespaces) }
    return lines.isEmpty ? ["no sample could be taken"] : Array(lines.prefix(70))
}

// MARK: - The picker

/// What is at a point of the screen, if it is SuperSurfer's.
func superSurferElement(at point: CGPoint) -> AXUIElement? {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.supersurfer.app").first else {
        return nil
    }
    var hit: AXUIElement?
    let asked = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
    guard asked == .success, let element = hit else {
        return nil
    }
    var owner: pid_t = 0
    guard AXUIElementGetPid(element, &owner) == .success, owner == app.processIdentifier else {
        return nil
    }
    return element
}

/// Points just beside the pointer. The picker opens with a corner at the
/// pointer: to the right of it and below, or to the other side where the
/// screen ends.
func besideThePointer() -> [CGPoint] {
    guard let pointer = CGEvent(source: nil)?.location else {
        return []
    }
    let steps: [CGPoint] = [CGPoint(x: 12, y: 12), CGPoint(x: -12, y: 12), CGPoint(x: 12, y: -12), CGPoint(x: -12, y: -12)]
    return steps.map { CGPoint(x: pointer.x + $0.x, y: pointer.y + $0.y) }
}

/// The entries of the menu SuperSurfer has up at the pointer. None while
/// there is no such menu.
func pickerEntries() -> [AXUIElement] {
    for point in besideThePointer() {
        guard var element = superSurferElement(at: point) else {
            continue
        }
        // From the entry at that point up to the menu it is in.
        for _ in 0..<4 {
            if text(element, kAXRoleAttribute) == "AXMenu" {
                return elements(element, kAXChildrenAttribute)
            }
            guard let parent = value(element, kAXParentAttribute) else {
                break
            }
            element = parent as! AXUIElement
        }
    }
    return []
}

func entryTitles(_ entries: [AXUIElement]) -> [String] {
    return entries.map { text($0, kAXTitleAttribute) ?? "" }
}

/// Has SuperSurfer show its picker for a link, by way of the clipboard and
/// the entry its menu has for that, and returns the picker's entries. `mark`
/// is a part of the link that the first line of the picker shows.
func openPicker(for link: String, showing mark: String) -> [AXUIElement] {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(link, forType: .string)
    pause(0.3)
    let entry = entryTitled(["Choose Browser for Copied Link…", "Browser für kopierten Link wählen …"])
    guard clickDownMenu([entry]) else {
        stop("SuperSurfer's menu has no entry that opens the picker")
    }
    var entries: [AXUIElement] = []
    let up = waitUntil(10) {
        entries = pickerEntries()
        return (entryTitles(entries).first ?? "").contains(mark)
    }
    guard up else {
        let found = besideThePointer().map { point -> String in
            guard let element = superSurferElement(at: point) else {
                return "nothing of SuperSurfer's"
            }
            return "\(text(element, kAXRoleAttribute) ?? "?") \"\(text(element, kAXTitleAttribute) ?? "")\""
        }
        let own = elements(superSurfer(), kAXChildrenAttribute).map { text($0, kAXRoleAttribute) ?? "?" }
        for _ in 1...3 {
            pressEscape()
        }
        stop("the picker did not open for \(link). Beside the pointer: \(found). SuperSurfer itself has: \(own)")
    }
    return entries
}

/// Closes the picker without a choice, which opens nothing.
func closePicker(showing mark: String) {
    pressEscape()
    let gone = waitUntil(5) { !(entryTitles(pickerEntries()).first ?? "").contains(mark) }
    if !gone {
        stop("the picker did not close")
    }
}

/// The entries the picker has for the profiles of a browser: as many as the
/// browser has profiles, right below the entry for the browser itself.
func profileBlock(_ entries: [AXUIElement], below browser: String, count: Int) -> [AXUIElement] {
    guard count > 0, let header = entryTitles(entries).firstIndex(of: browser), header + count < entries.count else {
        return []
    }
    return Array(entries[(header + 1)...(header + count)])
}

func testShortcuts(
    _ browser: TestBrowser,
    home: String,
    superSurfer: String,
    trace: String,
    onDock: Bool,
    startToo: Bool
) {
    let binary = browser.appPath + "/Contents/MacOS/" + browser.binary
    guard FileManager.default.fileExists(atPath: binary) else {
        say("skipped: \(browser.name) is not installed")
        return
    }
    let data = home + "/Library/Application Support/" + browser.dataFolder
    let shortcuts = home + "/Applications/SuperSurfer Shortcuts"
    let pages = home + "/pages"
    try? FileManager.default.createDirectory(atPath: pages, withIntermediateDirectories: true)

    func running() -> NSRunningApplication? {
        return NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID)
            .first { $0.activationPolicy == .regular && !$0.isTerminated }
    }
    func quit() {
        for instance in NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID) {
            instance.terminate()
        }
        if !waitUntil(10, { running() == nil }) {
            for instance in NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID) {
                instance.forceTerminate()
            }
            _ = waitUntil(10) { running() == nil }
        }
        pause(1)
        // What macOS lists as apps is not all there can be: a browser that
        // was asked to quit while it was still starting may be in neither
        // state. Whatever is still there three seconds on is put down.
        if !waitUntil(3, { mainProcesses(of: browser.binary).isEmpty }) {
            say("      after it was quit, \(browser.name) still has: \(mainProcesses(of: browser.binary))")
        }
    }
    /// How many starts of a browser macOS has answered SuperSurfer, going
    /// by its trace: for a link, and for a shortcut.
    func answeredStarts() -> Int {
        let text = (try? String(contentsOfFile: trace, encoding: .utf8)) ?? ""
        return text.components(separatedBy: "\n")
            .filter { $0.contains("accepted it after") || $0.contains("was started with the profile") }
            .count
    }
    /// What there is to see when a start that SuperSurfer asked macOS for
    /// did not come.
    func whyNoStart() {
        for other in testBrowsers {
            say("      \(other.name), its own processes: \(mainProcesses(of: other.binary))")
        }
        say("      starts macOS has answered so far: \(answeredStarts())")
        say("      SuperSurfer's threads:")
        for line in superSurferThreads() {
            say("        \(line)")
        }
    }
    /// Waits until macOS has answered SuperSurfer a start it was asked for.
    /// `before` is what `answeredStarts` said before the start was asked for.
    ///
    /// A browser is not quit before that. Launch Services hands on what one
    /// app asks it to open one request at a time, and each waits for its
    /// answer. Runs 63 and 64 quit Edge three seconds after SuperSurfer had
    /// started it, and again seven seconds after it had started it a second
    /// time. The second start was never answered, not even once Edge was
    /// gone, and with that SuperSurfer could start nothing more: Chrome,
    /// asked for a minute and a half later, never came.
    func awaitAnswer(since before: Int) {
        let began = Date()
        guard waitUntil(40, { answeredStarts() > before }) else {
            whyNoStart()
            stop("macOS has not answered the start of \(browser.name) for 40 s, although \(browser.name) is there")
        }
        say(String(format: "      macOS answered that start %.1f s later", Date().timeIntervalSince(began)))
    }

    // Three profiles, each with one window that shows a page of its own. The
    // title of the page tells whose window is in front. The profiles are
    // kept below the scratch HOME, where SuperSurfer looks for them.
    let profiles = [("Default", "sst-first"), ("Profile 1", "sst-second"), ("Profile 2", "sst-third")]
    func start(_ directory: String, showing file: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--user-data-dir=\(data)", "--profile-directory=\(directory)",
            "--no-first-run", "--no-default-browser-check", "--password-store=basic", "--use-mock-keychain",
            URL(fileURLWithPath: file).absoluteString,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            stop("\(browser.name) did not start: \(error.localizedDescription)")
        }
    }
    /// What there is to see of the browser, for when it does not show what
    /// it was started with.
    func whatIsThere() -> String {
        let titles = running().map { axWindows($0).map { text($0, kAXTitleAttribute) ?? "?" } } ?? []
        let processes = outputOf("/bin/ps", ["-axww", "-o", "pid=,args="])
            .components(separatedBy: "\n")
            .filter { $0.contains(browser.binary) && !$0.contains("--type=") }
        return "windows \(titles), processes \(processes)"
    }
    for (directory, page) in profiles {
        let file = pages + "/\(page).html"
        try? "<!doctype html><title>\(page)</title><p>\(page)</p>".write(toFile: file, atomically: true, encoding: .utf8)
        start(directory, showing: file)
        var opened = waitUntil(40) {
            running().map { window(of: $0, showing: page) != nil } ?? false
        }
        if !opened && directory == "Default" {
            // The first start of a browser on a test machine can go astray:
            // it may be updating itself, or busy with whatever it does when
            // it runs for the first time. Nothing depends on it yet, so it
            // gets one more try from the beginning.
            say("      \(browser.name) shows no window with \(page) after 40 s: \(whatIsThere())")
            say("      once more from the beginning")
            quit()
            pause(3)
            start(directory, showing: file)
            opened = waitUntil(40) {
                running().map { window(of: $0, showing: page) != nil } ?? false
            }
        }
        if !opened {
            stop("\(browser.name) shows no window with \(page) for its profile folder \(directory): \(whatIsThere())")
        }
        pause(1)
    }
    guard let app = running() else {
        stop("\(browser.name) is not running")
    }

    // The browser writes the file with its profiles a while after it made
    // them.
    var names: [String: String] = [:]
    let listed = waitUntil(60) {
        guard let raw = FileManager.default.contents(atPath: data + "/Local State"),
              let json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let profile = json["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any] else {
            return false
        }
        names = [:]
        for (directory, info) in cache {
            names[directory] = ((info as? [String: Any])?["name"] as? String) ?? directory
        }
        return profiles.allSatisfy { names[$0.0] != nil }
    }
    let kept = names.sorted { $0.key < $1.key }.map { "\($0.key) is \"\($0.value)\"" }.joined(separator: ", ")
    say("      \(browser.name) keeps its profiles as: \(kept)")
    guard listed, let second = names["Profile 1"], let third = names["Profile 2"] else {
        stop("\(browser.name) did not write its three profiles down")
    }
    // What the shortcut of each profile is called. Two of them get other
    // names further down.
    var titles = [second: "\(browser.shortName) \(second)", third: "\(browser.shortName) \(third)"]
    func bundle(_ profile: String) -> String {
        return "\(shortcuts)/\(titles[profile] ?? "?").app"
    }
    /// What a shortcut notes about itself in its Info.plist.
    func noted(_ profile: String, _ key: String) -> String? {
        return NSDictionary(contentsOfFile: bundle(profile) + "/Contents/Info.plist")?[key] as? String
    }
    /// The number the file system knows a file by. It stays when the file
    /// is renamed, and a file written anew gets another.
    func fileNumber(_ path: String) -> Int? {
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int
    }
    /// What SuperSurfer's menus are to call a profile whose shortcut got a
    /// name of the user's choosing, by the profile's folder: that name
    /// without the browser in front.
    var chosenNames: [String: String] = [:]
    /// What they are to call a profile that is named as `given`. SuperSurfer
    /// looks for a profile of that name first, and for one in a folder of
    /// that name after.
    func shown(_ given: String) -> String {
        var folder = names.first(where: { $0.value == given })?.key
        if folder == nil, names[given] != nil {
            folder = given
        }
        guard let found = folder else {
            return given
        }
        return chosenNames[found] ?? names[found] ?? given
    }

    say("-- a shortcut is made in SuperSurfer's menu")
    for profile in [second, third] {
        chooseInDockShortcuts([profileEntry(browser.name, profile)], what: "\(browser.name), \(profile)")
        let made = waitUntil(15) {
            FileManager.default.isExecutableFile(atPath: bundle(profile) + "/Contents/MacOS/shortcut")
        }
        if !made {
            let found = (try? FileManager.default.contentsOfDirectory(atPath: shortcuts)) ?? []
            stop("no app at \(bundle(profile)); the folder has \(found)")
        }
        say("ok    \(browser.shortName) \(profile).app is there")
        pause(1)
    }

    var inDock: String?
    // The names under which the Dock may list that shortcut: after a rename
    // it keeps the old one until the icon is clicked.
    var dockNames: [String] = []
    if onDock {
        // The real thing for one of them: an icon in the Dock.
        let entry = "<dict><key>tile-data</key><dict><key>file-data</key><dict>"
            + "<key>_CFURLString</key><string>\(bundle(second))</string>"
            + "<key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
        run("/usr/bin/defaults", ["write", "com.apple.dock", "persistent-apps", "-array-add", entry])
        run("/usr/bin/killall", ["Dock"])
        let name = "\(browser.shortName) \(second).app"
        dockNames = [name]
        let shown = waitUntil(40) {
            appIcons().contains { $0.url?.lastPathComponent == name }
        }
        if !shown {
            stop("the Dock does not show \(name); it shows \(appIcons().map { $0.title })")
        }
        say("ok    \(name) is in the Dock")
        inDock = second
        pause(2)
    }

    /// How often SuperSurfer says in its trace that a shortcut asked.
    func asked() -> Int {
        let text = (try? String(contentsOfFile: trace, encoding: .utf8)) ?? ""
        return text.components(separatedBy: "\n").filter { $0.contains("dock shortcut: asked for") }.count
    }
    /// A click on the shortcut. Where it is in the Dock that is a click on
    /// its icon; otherwise Launch Services is asked to start the app, which
    /// is what the Dock does with the click.
    func use(_ profile: String) {
        if profile == inDock,
           let spot = appIcons().first(where: { dockNames.contains($0.url?.lastPathComponent ?? "") })?.centre {
            // Once in some dozen clicks the Dock of a test machine starts
            // nothing. Whether it did shows in SuperSurfer's trace, and only
            // a click that never got that far is repeated.
            let before = asked()
            click(at: spot)
            lastClick = Clicked(
                longestPress: lastClick?.longestPress ?? 0,
                again: { use(profile) },
                lost: { asked() == before ? "nothing came of this click at all" : nil }
            )
        } else {
            lastClick = nil
            run("/usr/bin/open", [bundle(profile)])
        }
    }
    func inFront(_ page: String) -> Bool {
        return isInFront(app) && !app.isHidden && mainWindowTitle(app).contains(page)
    }
    /// Whether the browser lists this many windows. What it lists is noted
    /// for a check that fails.
    func hasWindows(_ count: Int) -> Bool {
        let windows = axWindows(app)
        let listed = windows.map { window -> String in
            let title = text(window, kAXTitleAttribute) ?? "?"
            return isMain(window) ? "\"\(title)\" (main)" : "\"\(title)\""
        }
        lastLook = "\(windows.count) windows: \(listed.joined(separator: ", "))"
        return windows.count == count
    }
    func calculatorInFront() {
        _ = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    }

    say("-- from behind another app the profile's window comes to the front")
    calculatorInFront()
    use(second)
    expect("\(browser.shortName) is in front with the window of \(second)", of: app, within: 20) {
        inFront("sst-second")
    }
    stays("and no window was added", of: app, for: 1.5) {
        hasWindows(3) && inFront("sst-second")
    }

    say("-- the other shortcut brings the other profile's window forward, and back")
    use(third)
    expect("the window of \(third) is in front", of: app, within: 20) {
        inFront("sst-third")
    }
    use(second)
    expect("the window of \(second) is in front again", of: app, within: 20) {
        inFront("sst-second")
    }
    stays("and there are still three windows", of: app, for: 1.5) {
        hasWindows(3)
    }

    say("-- a shortcut gets a name of the user's choosing in SuperSurfer's menu")
    let chosen = "\(browser.shortName) Work"
    let oldBundle = bundle(second)
    let sameFile = fileNumber(oldBundle)
    let oldName = titles[second] ?? "?"
    // The Dock's picture of it, to see further down whether the Dock takes
    // up the new one. That is looked at, not insisted on.
    let pictureBefore = inDock == nil ? nil : dockPicture(named: "\(oldName).app")
    chooseInDockShortcuts(
        [profileEntry(browser.name, second), entryTitled(["Rename…", "Umbenennen …"])],
        what: "\(browser.name), \(second), Rename"
    )
    answerQuestion(with: chosen, button: ["Rename", "Umbenennen"])
    titles[second] = chosen
    let renamed = waitUntil(10) {
        FileManager.default.isExecutableFile(atPath: bundle(second) + "/Contents/MacOS/shortcut")
            && !FileManager.default.fileExists(atPath: oldBundle)
    }
    if !renamed {
        let found = (try? FileManager.default.contentsOfDirectory(atPath: shortcuts)) ?? []
        stop("no app at \(bundle(second)) in place of the old one; the folder has \(found)")
    }
    say("ok    it is \(chosen).app now")
    let followed = waitUntil(10) {
        noted(second, "CFBundleName") == chosen && noted(second, "SuperSurferBadge") == "W"
    }
    let picture = noted(second, "CFBundleIconFile") ?? "?"
    let pictureIsNew = picture != "shortcut"
        && FileManager.default.fileExists(atPath: bundle(second) + "/Contents/Resources/\(picture).icns")
    if !followed || !pictureIsNew || sameFile == nil || fileNumber(bundle(second)) != sameFile {
        stop("its inside did not follow: name \(noted(second, "CFBundleName") ?? "?"), "
            + "letters \(noted(second, "SuperSurferBadge") ?? "?"), picture \(picture), "
            + "the file it was: \(fileNumber(bundle(second)) == sameFile)")
    }
    say("ok    the same app as before, with W on a new picture")
    if inDock != nil {
        // The Dock goes on listing the app under its old name for the time
        // being. It finds it all the same, because it knows the file and
        // not only where it was: seen on macOS 15 and 26. From the click on
        // it has the new name.
        dockNames.append("\(chosen).app")
        calculatorInFront()
        use(second)
        expect("a click on its Dock icon still brings the window of \(second) forward", of: app, within: 20) {
            inFront("sst-second")
        }
        let held = waitUntil(10) {
            appIcons().contains { $0.url?.lastPathComponent == "\(chosen).app" }
        }
        if !held {
            stop("after that click the Dock does not hold \(chosen).app; it holds \(appIcons().map { $0.url?.lastPathComponent ?? $0.title })")
        }
        say("ok    and from then on the Dock holds it as \(chosen).app")
        // macOS 26 drew the new picture within seconds of the rename, and
        // macOS 15 after this click.
        if let changed = pointsThatDiffer(pictureBefore, dockPicture(named: "\(chosen).app")) {
            say("      the Dock's picture of it has \(changed == 0 ? "not changed" : "changed, in \(changed) points")")
        } else {
            say("      the Dock's picture of it could not be looked at")
        }
    }
    use(third)
    expect("the window of \(third) is in front", of: app, within: 20) {
        inFront("sst-third")
    }
    use(second)
    expect("under its new name it brings the window of \(second) forward", of: app, within: 20) {
        inFront("sst-second")
    }

    say("-- a name given in the Finder is taken up when the menu opens")
    let given = "\(browser.shortName) Privat"
    let nameBefore = bundle(third)
    titles[third] = given
    do {
        try FileManager.default.moveItem(atPath: nameBefore, toPath: bundle(third))
    } catch {
        stop("\(nameBefore) could not be renamed: \(error.localizedDescription)")
    }
    // The menu makes its entries when it opens, and that is when SuperSurfer
    // looks at its shortcuts.
    _ = clickDownMenu([dockShortcutsEntry])
    pause(0.5)
    for _ in 1...3 {
        pressEscape()
    }
    let taken = waitUntil(10) {
        noted(third, "CFBundleName") == given && noted(third, "SuperSurferBadge") == "P"
    }
    if !taken {
        stop("\(given).app was not taken up: name \(noted(third, "CFBundleName") ?? "?"), "
            + "letters \(noted(third, "SuperSurferBadge") ?? "?")")
    }
    say("ok    \(given).app has P on its picture")
    use(second)
    expect("the window of \(second) is in front", of: app, within: 20) {
        inFront("sst-second")
    }

    say("-- the picker calls a profile what its shortcut is called")
    chosenNames = ["Profile 1": "Work", "Profile 2": "Privat"]
    // Three sites with a saved rule each. The first names the profile the
    // way the browser does, which is what the picker saves. The others name
    // a folder, as config.js may: the folder of the profile that has no
    // shortcut, and the folder "Profile 2". Chrome calls the profile in
    // that folder "Person 2". Edge calls it "Profile 3", and "Profile 2" is
    // what Edge calls the profile in the folder "Profile 1". SuperSurfer
    // goes by the name before the folder, so in Edge that rule means the
    // second profile.
    let ruled = [("sst-name.example", second), ("sst-first.example", "Default"), ("sst-folder.example", "Profile 2")]
    let savedRules: [String: Any] = [
        "version": 1,
        "rules": ruled.map { ["domain": $0.0, "browser": browser.id, "profile": $0.1] },
    ]
    do {
        let file = URL(fileURLWithPath: home + "/Library/Application Support/SuperSurfer/rules.json")
        try JSONSerialization.data(withJSONObject: savedRules).write(to: file)
    } catch {
        stop("rules.json could not be written: \(error.localizedDescription)")
    }
    let inOrder = names.values.map { shown($0) }.sorted { $0.lowercased() < $1.lowercased() }
    for (domain, profile) in ruled {
        let entries = openPicker(for: "https://\(domain)/page", showing: domain)
        // Read while the picker is up: its entries are gone with it.
        let all = entryTitles(entries)
        let block = profileBlock(entries, below: browser.name, count: names.count)
        let below = entryTitles(block)
        let checked = block
            .filter { !(text($0, "AXMenuItemMarkChar") ?? "").isEmpty }
            .map { text($0, kAXTitleAttribute) ?? "" }
        closePicker(showing: domain)
        let wanted = shown(profile)
        let line = all.count > 1 ? all[1] : ""
        guard below == inOrder else {
            stop("below \(browser.name) the picker lists \(below) and not \(inOrder). All of it: \(all)")
        }
        guard line.hasSuffix("\(browser.name) (\(wanted))") else {
            stop("for a rule that names \"\(profile)\" the picker says \"\(line)\" and not \(browser.name) (\(wanted))")
        }
        guard checked == [wanted] else {
            stop("for a rule that names \"\(profile)\" the picker has its checkmark at \(checked) and not at \(wanted)")
        }
        say("ok    a rule that names \"\(profile)\": \(line), checkmark at \(wanted)")
    }
    say("ok    its profiles are listed as \(inOrder)")

    // The list of saved rules says it the same way.
    let rulesEntry: ([AXUIElement]) -> AXUIElement? = { entries in
        entries.first { entry in
            let title = text(entry, kAXTitleAttribute) ?? ""
            return title.hasPrefix("Saved Rules") || title.hasPrefix("Gemerkte Regeln")
        }
    }
    guard clickDownMenu([rulesEntry]) else {
        stop("SuperSurfer's menu has no Saved Rules")
    }
    let rulesShown = entryTitles(rulesEntry(statusMenuEntries())
        .map { elements($0, kAXChildrenAttribute).flatMap { elements($0, kAXChildrenAttribute) } } ?? [])
    for _ in 1...3 {
        pressEscape()
    }
    for (domain, profile) in ruled where !rulesShown.contains("\(domain) → \(browser.name) (\(shown(profile)))") {
        stop("Saved Rules has no \"\(domain) → \(browser.name) (\(shown(profile)))\"; it has \(rulesShown)")
    }
    say("ok    and so does the list of saved rules")
    use(second)
    expect("the window of \(second) is in front", of: app, within: 20) {
        inFront("sst-second")
    }

    say("-- a link for a profile without a shortcut is left alone")
    run("/usr/bin/open", ["-g", "-a", superSurfer, "supersurfer://profile/\(browser.id)/Default"])
    stays("the window of \(second) stays in front", of: app, for: 3) {
        hasWindows(3) && inFront("sst-second")
    }

    say("-- a window that sits in the Dock comes out of it")
    if let minimized = window(of: app, showing: "sst-third") {
        AXUIElementSetAttributeValue(minimized, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }
    expect("the window of \(third) is minimized", of: app, within: 10) {
        minimizedWindows(app) == 1
    }
    calculatorInFront()
    use(third)
    expect("the window of \(third) is in front", of: app, within: 20) {
        inFront("sst-third") && minimizedWindows(app) == 0
    }

    say("-- a hidden browser is shown again")
    app.hide()
    expect("\(browser.shortName) is hidden", of: app, within: 10) {
        app.isHidden
    }
    pause(1)
    use(second)
    expect("the window of \(second) is in front", of: app, within: 20) {
        inFront("sst-second")
    }

    say("-- a profile without a window gets one")
    if let closing = window(of: app, showing: "sst-third"), let button = value(closing, kAXCloseButtonAttribute) {
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }
    expect("the window of \(third) is closed", of: app, within: 10) {
        hasWindows(2)
    }
    calculatorInFront()
    use(third)
    expect("a third window is in front, and it is none of the other two", of: app, within: 30) {
        let title = mainWindowTitle(app)
        return hasWindows(3) && isInFront(app)
            && !title.isEmpty && !title.contains("sst-first") && !title.contains("sst-second")
    }
    say("      its title: \(mainWindowTitle(app))")

    say("-- a shortcut is removed in SuperSurfer's menu")
    chooseInDockShortcuts(
        [profileEntry(browser.name, third), entryTitled(["Remove Shortcut", "Verknüpfung entfernen"])],
        what: "\(browser.name), \(third), Remove Shortcut"
    )
    let removed = waitUntil(10) { !FileManager.default.fileExists(atPath: bundle(third)) }
    if !removed {
        stop("\(bundle(third)) is still there")
    }
    say("ok    \(titles[third] ?? "?").app is gone, \(titles[second] ?? "?").app is not")
    if !FileManager.default.fileExists(atPath: bundle(second)) {
        stop("\(bundle(second)) is gone as well")
    }
    chosenNames["Profile 2"] = nil

    quit()
    if startToo {
        // SuperSurfer starts the browser the way it does for a link, so with
        // the profiles the browser really has on this Mac, not with the ones
        // made above. What can be checked is what it was started with.
        say("-- a browser that is not running is started with the profile")
        let answeredSoFar = answeredStarts()
        use(second)
        var arguments = ""
        let started = waitUntil(40) {
            guard let pid = running()?.processIdentifier else {
                return false
            }
            arguments = outputOf("/bin/ps", ["-ww", "-o", "args=", "-p", "\(pid)"])
            return arguments.contains("--profile-directory=Profile 1")
        }
        if !started {
            whyNoStart()
            stop("\(browser.name) was not started with the profile: \(arguments.isEmpty ? "not running" : arguments)")
        }
        say("ok    \(browser.shortName) was started with --profile-directory=Profile 1")
        awaitAnswer(since: answeredSoFar)
        pause(2)
        quit()

        // The entry says "Work". What SuperSurfer hands on has to be the
        // profile behind it, by the name the browser has for it.
        say("-- a profile chosen in the picker under its shortcut's name is the one that opens")
        let page = "sst-second.html"
        let entries = openPicker(for: URL(fileURLWithPath: pages + "/" + page).absoluteString, showing: page)
        let block = profileBlock(entries, below: browser.name, count: names.count)
        guard let work = block.first(where: { text($0, kAXTitleAttribute) == "Work" }), let spot = middle(of: work) else {
            let below = entryTitles(block)
            let all = entryTitles(entries)
            closePicker(showing: page)
            stop("the picker has no Work below \(browser.name): \(below) of \(all)")
        }
        let answeredBefore = answeredStarts()
        post(.mouseMoved, at: spot)
        pause(0.3)
        press(at: spot)
        var startedWith = ""
        let opened = waitUntil(40) {
            guard let pid = running()?.processIdentifier else {
                return false
            }
            startedWith = outputOf("/bin/ps", ["-ww", "-o", "args=", "-p", "\(pid)"])
            return startedWith.contains("--profile-directory=Profile 1") && startedWith.contains(page)
        }
        if !opened {
            whyNoStart()
            stop("\(browser.name) was not started with the profile and the link: \(startedWith.isEmpty ? "not running" : startedWith)")
        }
        say("ok    \(browser.shortName) was started with --profile-directory=Profile 1 and the link")
        awaitAnswer(since: answeredBefore)
        // Where the link went is listed under the same name.
        _ = clickDownMenu([])
        let recent = entryTitles(statusMenuEntries())
        for _ in 1...3 {
            pressEscape()
        }
        guard recent.contains(where: { $0.hasSuffix("→ \(browser.name) (Work)") }) else {
            stop("Recent Links has no entry that ends in \(browser.name) (Work): \(recent)")
        }
        say("ok    and Recent Links has it as \(browser.name) (Work)")
        pause(2)
        quit()
    }
}

switch CommandLine.arguments.dropFirst().first {
case "shortcuts":
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    guard arguments.count >= 4, let browser = testBrowsers.first(where: { $0.id == arguments[0] }) else {
        say("usage: dock-click-test shortcuts <edge|chrome> <scratch HOME> <SuperSurfer.app> <trace> [dock] [start]")
        exit(2)
    }
    testShortcuts(
        browser,
        home: arguments[1],
        superSurfer: arguments[2],
        trace: arguments[3],
        onDock: arguments.dropFirst(4).contains("dock"),
        startToo: arguments.dropFirst(4).contains("start")
    )
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
