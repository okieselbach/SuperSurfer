import ApplicationServices
import Cocoa

// Plays the person at the Mac for dock-click-test.sh. It finds an app's Dock
// icon through Accessibility, clicks it with mouse events posted the way the
// hardware posts them, and checks what became of the app's windows.
//
//   dock-click-test preflight   can this session do that at all? (77: no)
//   dock-click-test hide        SuperSurfer runs with Dock Click on "hide"
//   dock-click-test minimize    SuperSurfer runs with Dock Click on "minimize"

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

struct Icon {
    let title: String
    let url: URL?
    let element: AXUIElement

    var centre: CGPoint? {
        guard let position = value(element, kAXPositionAttribute),
              let size = value(element, kAXSizeAttribute) else {
            return nil
        }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
            return nil
        }
        return CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
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

func post(_ type: CGEventType, at point: CGPoint) {
    guard let event = CGEvent(
        mouseEventSource: mouse,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: .left
    ) else {
        stop("could not make a mouse event")
    }
    if type != .mouseMoved {
        event.setIntegerValueField(.mouseEventClickState, value: 1)
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
    say("screens: \(NSScreen.screens.map { $0.frame })")
    for icon in icons {
        let centre = icon.centre.map { "\(Int($0.x)),\(Int($0.y))" } ?? "?"
        say("dock:  \(icon.title) at \(centre)  \(icon.url?.path ?? "-")")
    }
    var hit: AXUIElement?
    let result = AXUIElementCopyElementAtPosition(dock, Float(spot.x), Float(spot.y), &hit)
    let role = hit.flatMap { text($0, kAXRoleAttribute) } ?? "-"
    let subrole = hit.flatMap { text($0, kAXSubroleAttribute) } ?? "-"
    say("hit test on \(first.title): error \(result.rawValue), role \(role), subrole \(subrole)")
    exit(0)
}

func testHide() {
    let calculator = bringToFront("Calculator", "com.apple.calculator", windows: 1)
    say("      \(state(of: calculator))")
    say("      icon: \(icon(of: calculator)?.url?.path ?? "?"), app: \(calculator.bundleURL?.path ?? "?")")

    for (label, held) in [("click", 0.08), ("tap", 0.004)] {
        say("-- \(label): the app in front is hidden, the next \(label) brings it back")
        click(calculator, held: held)
        expect("Calculator is hidden", of: calculator) {
            windowsOnScreen(calculator) == 0 && !isInFront(calculator)
        }
        pause(0.8)
        click(calculator, held: held)
        expect("Calculator is back", of: calculator) {
            windowsOnScreen(calculator) > 0 && isInFront(calculator)
        }
        stays("and stays", of: calculator, for: 2) {
            windowsOnScreen(calculator) > 0 && isInFront(calculator)
        }

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

    calculator.terminate()
}

func testMinimize() {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("supersurfer-dock-click-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var files: [String] = []
    for title in ["one", "two"] {
        let file = folder.appendingPathComponent("\(title).txt")
        try? title.write(to: file, atomically: true, encoding: .utf8)
        files.append(file.path)
    }

    let textEdit = bringToFront("TextEdit", "com.apple.TextEdit", files: files, windows: 2)
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

    textEdit.terminate()
}

switch CommandLine.arguments.dropFirst().first {
case "preflight":
    preflight()
case "hide":
    testHide()
case "minimize":
    testMinimize()
default:
    say("usage: dock-click-test preflight | hide | minimize")
    exit(2)
}
say("passed")
