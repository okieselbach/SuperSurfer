import Cocoa

/// A link that went through SuperSurfer since it was started. Kept in memory
/// only; the decision log on disk is the permanent record.
struct RecentLink {
    let decision: Decision
    /// Where the link actually went. Differs from `decision.browser` after a
    /// manual pick.
    let browser: String
    /// SuperSurfer's own share of the click: from receiving the event to
    /// handing the URL to Launch Services.
    let elapsedMs: Double?
    let pickedByHand: Bool
}

/// When a link passed which point on its way through the app. Only read for
/// the `--resident` trace and the time shown under Recent Links.
struct RouteTimes {
    /// The URL event arrived.
    let received: DispatchTime
    /// Keyboard and frontmost app are read; the request is queued.
    let queued: DispatchTime
    /// The engine was asked.
    let asked: DispatchTime
    /// The engine answered.
    let answered: DispatchTime
    /// Of the time between `asked` and `answered`, what the engine itself
    /// used. The rest is the trip to its thread and back.
    let coreMs: Double?

    static func milliseconds(from start: DispatchTime, to end: DispatchTime) -> Double {
        return Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }
}

/// True when this very app bundle already has a running instance. Launch
/// Services never starts a second one on its own, but `--resident` from a
/// shell or `open -n` would, and two menu bar icons help nobody.
func anotherInstanceIsRunning() -> Bool {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        return false
    }
    let me = ProcessInfo.processInfo.processIdentifier
    let ourBundle = Bundle.main.bundleURL.standardizedFileURL
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { other in
        other.processIdentifier != me && other.bundleURL?.standardizedFileURL == ourBundle
    }
}

func isRoutableInput(_ value: String) -> Bool {
    if value.hasPrefix("http://") || value.hasPrefix("https://") || value.hasPrefix("file://") {
        return true
    }
    return value.hasPrefix("/") || value.hasPrefix("~/")
}

extension OpenerInfo {
    /// SuperSurfer never activates itself for a link, so the frontmost
    /// application at the moment the event arrives is the one the link was
    /// clicked in (Slack, Mail, ...). This is what `ctx.opener` reports.
    static func frontmostApplication() -> OpenerInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let name = app.localizedName else {
            return nil
        }
        return OpenerInfo(name: name, bundleId: app.bundleIdentifier, path: app.bundleURL?.path)
    }
}

extension ModifierState {
    init(_ flags: NSEvent.ModifierFlags) {
        self.init(
            shift: flags.contains(.shift),
            alt: flags.contains(.option),
            ctrl: flags.contains(.control),
            cmd: flags.contains(.command)
        )
    }
}

/// A second button for a message, and what it does.
struct AlertAction {
    let title: String
    let run: () -> Void
}

/// A question that is answered with one line of text.
struct TextQuestion {
    let title: String
    let text: String
    let value: String
    let confirm: String
    let then: (String) -> Void
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let recentLimit = 10

    /// Set when the app was started with `--resident` from a shell: one line
    /// per link on stderr, with SuperSurfer's own time and the time the
    /// browser took to accept the link.
    static var traceToStderr = false

    let engine = EngineBridge()
    private(set) var recents: [RecentLink] = []
    private(set) var configError: String?

    /// Engine calls for links run here, so a slow one (config.js being
    /// reloaded, a `resolve` rule on the network) never blocks the menu bar.
    private let routeQueue = DispatchQueue(label: "dev.supersurfer.route", qos: .userInteractive)
    private var statusMenu: StatusMenuController?
    private var pendingPickers: [Decision] = []
    private var pickerMenu: NSMenu?
    private var pendingAlerts: [(title: String, text: String, action: AlertAction?)] = []
    private var pendingQuestions: [TextQuestion] = []
    private var activity: NSObjectProtocol?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An app without windows is a candidate for App Nap, which lowers its
        // priority while idle. Being quick on the next click is the whole
        // point of staying loaded, so opt out. This does not keep the Mac
        // awake and costs nothing while no link arrives.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Answering link clicks without delay"
        )
        statusMenu = StatusMenuController(app: self)
        warmUp()
        // Does nothing unless Dock Click was chosen in the menu.
        DockClickController.shared.refresh()
    }

    /// Opening the app again (Finder, Spotlight, `open -a`) shows its menu,
    /// and brings the icon back if it was dragged out of the menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusMenu?.reveal()
        return false
    }

    /// Every link click arrives here: macOS sends the URL to the default
    /// browser as an Apple Event, and to this running instance without
    /// starting anything.
    func application(_ application: NSApplication, open urls: [URL]) {
        let started = DispatchTime.now()
        // A Dock shortcut for a browser profile asks with a link of its own
        // kind, which is not routed.
        for url in urls where ProfileShortcutRules.isLink(url) {
            ProfileShortcuts.shared.open(url, engine: engine)
        }
        // Read the keyboard now; by the time routing answers the key may be up.
        let flags = NSEvent.modifierFlags
        let opener = OpenerInfo.frontmostApplication()
        let inputs = urls.map { $0.absoluteString }.filter(isRoutableInput)
        // One picker per click. Several URLs at once follow the rules.
        let askUser = inputs.count == 1 && PickerKey.current.isHeld(in: flags)
        for input in inputs {
            route(input, opener: opener, modifiers: ModifierState(flags), askUser: askUser, started: started)
        }
    }

    // MARK: - Routing

    private func warmUp() {
        // The first use of the preferences and of the workspace's view of the
        // frontmost app is slower than later ones. Pay for that now instead
        // of on the first click.
        _ = PickerKey.current
        _ = OpenerInfo.frontmostApplication()

        // Loads config.js and the browser list before the first click needs
        // them, and runs first-time setup.
        let engine = self.engine
        routeQueue.async {
            let status = engine.status()
            DispatchQueue.main.async {
                self.setConfigError(status?.configError)
                if status?.freshBootstrap == true,
                   let landing = status?.landingUrl,
                   let manual = URL(string: landing) {
                    NSWorkspace.shared.open(manual)
                }
            }
        }
    }

    private func route(
        _ input: String,
        opener: OpenerInfo?,
        modifiers: ModifierState,
        askUser: Bool,
        started: DispatchTime?
    ) {
        let engine = self.engine
        let queued = DispatchTime.now()
        routeQueue.async {
            let asked = DispatchTime.now()
            let reply = engine.route(url: input, opener: opener, modifiers: modifiers, preview: askUser)
            let answered = DispatchTime.now()
            let coreMs = reply?.engineMicros.map { Double($0) / 1_000 }
            let times = started.map { received in
                RouteTimes(received: received, queued: queued, asked: asked, answered: answered, coreMs: coreMs)
            }
            DispatchQueue.main.async {
                self.finishRoute(input: input, reply: reply, askUser: askUser, times: times)
            }
        }
    }

    private func finishRoute(input: String, reply: RouteReply?, askUser: Bool, times: RouteTimes?) {
        guard let reply = reply else {
            // No usable answer from the engine. Do not swallow the click.
            Launcher.openInSafari(input)
            return
        }
        setConfigError(reply.configError)
        guard reply.ok, let decision = reply.decision else {
            NSLog("SuperSurfer: not opened: %@ (%@)", input, reply.error ?? "no reason given")
            return
        }
        guard let plan = reply.launch else {
            // The engine refuses to hand this URL to any browser (for example
            // a `javascript:` link), so there is nothing to pick either.
            NSLog("SuperSurfer: not opened: %@", reply.launchError ?? "no launch plan")
            return
        }
        if askUser {
            presentPicker(for: decision)
            return
        }
        let browser = Format.browserLabel(decision.browser, profile: decision.profile)
        launch(plan, decision: decision, browser: browser, pickedByHand: false, times: times)
    }

    private func launch(
        _ plan: LaunchPlan,
        decision: Decision,
        browser: String,
        pickedByHand: Bool,
        times: RouteTimes?
    ) {
        let handedOver = DispatchTime.now()
        let elapsedMs = times.map { RouteTimes.milliseconds(from: $0.received, to: handedOver) }
        let engine = self.engine
        let queue = routeQueue
        let trace = AppDelegate.traceToStderr
        if trace, let times = times, let elapsedMs = elapsedMs {
            let eventMs = RouteTimes.milliseconds(from: times.received, to: times.queued)
            let queueMs = RouteTimes.milliseconds(from: times.queued, to: times.asked)
            let engineMs = RouteTimes.milliseconds(from: times.asked, to: times.answered)
            let backMs = RouteTimes.milliseconds(from: times.answered, to: handedOver)
            let parts = String(
                format: "event %.2f, queue %.2f, engine %.2f of which core %.2f, back to main %.2f",
                eventMs, queueMs, engineMs, times.coreMs ?? 0, backMs
            )
            fputs("SuperSurfer: routed \(decision.inputUrl) to \(browser) in \(Format.milliseconds(elapsedMs)) (\(parts))\n", stderr)
        }
        Launcher.open(plan) { error in
            if trace {
                let waited = RouteTimes.milliseconds(from: handedOver, to: DispatchTime.now())
                fputs("SuperSurfer: \(browser) accepted it after \(Format.milliseconds(waited))\n", stderr)
            }
            guard let error = error else {
                return
            }
            NSLog("SuperSurfer: could not open %@ in %@: %@", plan.url, browser, error.localizedDescription)
            // The browser may have been moved or removed. Look again so the
            // next click does not hit the same stale path.
            queue.async {
                _ = engine.reload()
            }
        }
        recents.insert(
            RecentLink(decision: decision, browser: browser, elapsedMs: elapsedMs, pickedByHand: pickedByHand),
            at: 0
        )
        if recents.count > AppDelegate.recentLimit {
            recents.removeLast(recents.count - AppDelegate.recentLimit)
        }
    }

    /// Remembers whether config.js currently fails to load and shows it in
    /// the menu bar icon.
    func setConfigError(_ error: String?) {
        guard error != configError else {
            return
        }
        configError = error
        statusMenu?.refreshIcon()
    }

    // MARK: - Picker

    private func presentPicker(for decision: Decision) {
        // Menu tracking runs its own event loop until the menu closes. We are
        // inside a block on the main dispatch queue here, and that queue does
        // not hand out the next block before this one returns. So schedule
        // the menu on the run loop instead and return, which keeps the main
        // queue draining for other links while the menu is up.
        pendingPickers.append(decision)
        if pendingPickers.count == 1 {
            perform(#selector(showPendingPicker), with: nil, afterDelay: 0)
        }
    }

    @objc private func showPendingPicker() {
        guard let decision = pendingPickers.first else {
            return
        }
        let browsers = engine.browsers()?.browsers ?? []
        let menu = PickerMenu.make(app: self, decision: decision, browsers: browsers)
        // Kept until the next picker replaces it: the chosen item has to
        // outlive the tracking loop to deliver its action.
        pickerMenu = menu
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)

        // `popUp` returns once the menu has closed. A link that asked for the
        // picker meanwhile gets its turn now.
        pendingPickers.removeFirst()
        if !pendingPickers.isEmpty {
            perform(#selector(showPendingPicker), with: nil, afterDelay: 0)
        }
    }

    /// The picker for a link that is not being clicked right now. Doubles as
    /// "what would happen to this link?": the menu says how it would be routed.
    func chooseBrowserForClipboardLink() {
        guard let text = Clipboard.text(), !text.isEmpty, isRoutableInput(text) else {
            showAlert(
                title: tr("No link in the clipboard", "Kein Link in der Zwischenablage"),
                text: tr(
                    "Copy a web address first, then choose this command again.",
                    "Kopiere zuerst eine Webadresse und wähle den Befehl dann erneut."
                )
            )
            return
        }
        route(text, opener: nil, modifiers: ModifierState(), askUser: true, started: nil)
    }

    // MARK: - Actions from the menus

    /// Opens a link in the browser the user chose, and optionally saves that
    /// choice for a domain first.
    func open(_ decision: Decision, in browser: BrowserInfo, profile: String?, rememberFor domain: String?) {
        let engine = self.engine
        routeQueue.async {
            let rememberError: String? = domain.flatMap { domain in
                let saved = engine.remember(domain: domain, browserId: browser.id, profile: profile)
                return saved?.ok == true ? nil : (saved?.error ?? "no answer from the routing engine")
            }
            let reply = engine.plan(
                url: decision.launchUrl,
                inputUrl: decision.inputUrl,
                browserId: browser.id,
                profile: profile
            )
            DispatchQueue.main.async {
                if let reply = reply, reply.ok, let plan = reply.launch {
                    let label = Format.browserLabel(browser.name, profile: profile)
                    self.launch(plan, decision: decision, browser: label, pickedByHand: true, times: nil)
                } else {
                    self.showAlert(
                        title: tr("The link could not be opened", "Der Link konnte nicht geöffnet werden"),
                        text: reply?.error ?? ""
                    )
                }
                if let rememberError = rememberError {
                    self.showAlert(
                        title: tr("The rule could not be saved", "Die Regel konnte nicht gespeichert werden"),
                        text: rememberError
                    )
                }
            }
        }
    }

    func remember(domain: String, browser: BrowserInfo, profile: String?) {
        let engine = self.engine
        routeQueue.async {
            let saved = engine.remember(domain: domain, browserId: browser.id, profile: profile)
            guard saved?.ok != true else {
                return
            }
            let reason = saved?.error ?? "no answer from the routing engine"
            DispatchQueue.main.async {
                self.showAlert(
                    title: tr("The rule could not be saved", "Die Regel konnte nicht gespeichert werden"),
                    text: reason
                )
            }
        }
    }

    func forget(domain: String) {
        let engine = self.engine
        routeQueue.async {
            let reply = engine.forget(domain: domain)
            guard reply?.ok != true else {
                return
            }
            let reason = reply?.error ?? "no answer from the routing engine"
            DispatchQueue.main.async {
                self.showAlert(
                    title: tr("The rule could not be removed", "Die Regel konnte nicht entfernt werden"),
                    text: reason
                )
            }
        }
    }

    func reloadConfiguration() {
        let engine = self.engine
        routeQueue.async {
            let status = engine.reload()
            DispatchQueue.main.async {
                self.setConfigError(status?.configError)
                if status?.configError != nil {
                    self.showConfigError()
                }
            }
        }
    }

    func showConfigError() {
        showAlert(
            title: tr("config.js could not be loaded", "config.js konnte nicht geladen werden"),
            text: (configError ?? "") + "\n\n" + tr(
                "Until the file loads again, links follow the last version that worked, or open in Safari if none has loaded since SuperSurfer started. Fix the file and save it; it is reloaded automatically.",
                "Bis die Datei wieder lädt, folgen Links der letzten funktionierenden Version oder öffnen in Safari, falls seit dem Start von SuperSurfer keine geladen wurde. Korrigiere die Datei und speichere sie; sie wird automatisch neu geladen."
            )
        )
    }

    /// macOS 27 and later keep apps away from the data of browsers until the
    /// user allows it. Links are routed regardless; what is missing is the
    /// list of profiles.
    func showProfilesBlocked(_ browsers: [String]) {
        let names = browsers.joined(separator: ", ")
        showAlert(
            title: tr("Browser profiles cannot be read", "Browser-Profile sind nicht lesbar"),
            text: tr(
                "macOS does not let SuperSurfer read the profile list of: \(names). macOS 27 and later protect browser data from other apps.\n\nLinks are routed all the same. SuperSurfer uses the profile lists it read last, if any. A profile it does not know opens in the profile that browser used last, unless config.js names it by its folder (\"Default\", \"Profile 1\").\n\nTo allow access, open System Settings > Privacy & Security > Files & Folders and switch on the browsers under SuperSurfer. If SuperSurfer is not listed there, add it under Full Disk Access instead. Then quit SuperSurfer and open it again.\n\nDoes a switch jump back to off? Then it probably belongs to an older version of SuperSurfer. Quit SuperSurfer, run \"tccutil reset All dev.supersurfer.app\" in Terminal, open SuperSurfer and its menu once, quit it again, and only then switch the browsers on.",
                "macOS lässt SuperSurfer die Profilliste nicht lesen von: \(names). Ab macOS 27 sind Browser-Daten vor anderen Apps geschützt.\n\nLinks werden trotzdem geroutet. SuperSurfer nutzt die zuletzt gelesenen Profillisten, falls vorhanden. Ein unbekanntes Profil öffnet im zuletzt genutzten Profil des Browsers, außer config.js nennt es mit seinem Ordnernamen („Default“, „Profile 1“).\n\nZugriff erlauben: Systemeinstellungen > Datenschutz & Sicherheit > Dateien & Ordner öffnen und unter SuperSurfer die Browser einschalten. Steht SuperSurfer dort nicht, füge es stattdessen unter Festplattenvollzugriff hinzu. Danach SuperSurfer beenden und neu öffnen.\n\nSpringt ein Schalter zurück auf Aus? Dann gehört er vermutlich zu einer älteren Version von SuperSurfer. Beende SuperSurfer, führe im Terminal „tccutil reset All dev.supersurfer.app“ aus, öffne SuperSurfer und einmal sein Menü, beende es wieder und schalte erst dann die Browser ein."
            ),
            action: AlertAction(title: tr("Open System Settings", "Systemeinstellungen öffnen")) {
                PrivacySettings.openFilesAndFolders()
            }
        )
    }

    func toggleLoginItem() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            showAlert(
                title: tr("Launch at Login could not be changed", "Start beim Anmelden konnte nicht geändert werden"),
                text: error.localizedDescription
            )
        }
    }

    func claimDefaultBrowser() {
        DefaultBrowser.claim { error in
            if let error = error {
                NSLog("SuperSurfer: default browser not changed: %@", error.localizedDescription)
            }
        }
    }

    /// Shows a message without holding up links. A modal alert started from a
    /// block on the main dispatch queue would stall that queue, and with it
    /// every routed link, until someone clicks OK. Started from the run loop
    /// it does not.
    func showAlert(title: String, text: String, action: AlertAction? = nil) {
        pendingAlerts.append((title: title, text: text, action: action))
        if pendingAlerts.count == 1 {
            perform(#selector(showPendingAlert), with: nil, afterDelay: 0)
        }
    }

    /// Asks for one line of text and hands it to `then`, unless the question
    /// was cancelled. It starts from the run loop like `showAlert`, so no
    /// link waits for the answer.
    func askForText(title: String, text: String, value: String, confirm: String, then: @escaping (String) -> Void) {
        pendingQuestions.append(TextQuestion(title: title, text: text, value: value, confirm: confirm, then: then))
        if pendingQuestions.count == 1 {
            perform(#selector(showPendingQuestion), with: nil, afterDelay: 0)
        }
    }

    @objc private func showPendingQuestion() {
        guard let question = pendingQuestions.first else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = question.value
        alert.accessoryView = field
        // The first button is the default one and answers Return.
        alert.addButton(withTitle: question.confirm)
        alert.addButton(withTitle: tr("Cancel", "Abbrechen")).keyEquivalent = "\u{1b}"
        // The name is there to be typed over.
        alert.window.initialFirstResponder = field
        let response = alert.runModal()

        pendingQuestions.removeFirst()
        if response == .alertFirstButtonReturn {
            question.then(field.stringValue)
        }
        if !pendingQuestions.isEmpty {
            perform(#selector(showPendingQuestion), with: nil, afterDelay: 0)
        }
    }

    @objc private func showPendingAlert() {
        guard let message = pendingAlerts.first else {
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message.title
        alert.informativeText = message.text
        if let action = message.action {
            // The first button is the default one and answers Return.
            alert.addButton(withTitle: action.title)
            alert.addButton(withTitle: "OK").keyEquivalent = "\u{1b}"
        } else {
            alert.addButton(withTitle: "OK")
        }
        let response = alert.runModal()

        pendingAlerts.removeFirst()
        if let action = message.action, response == .alertFirstButtonReturn {
            action.run()
        }
        if !pendingAlerts.isEmpty {
            perform(#selector(showPendingAlert), with: nil, afterDelay: 0)
        }
    }
}
