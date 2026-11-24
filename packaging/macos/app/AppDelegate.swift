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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let recentLimit = 10

    let engine = EngineBridge()
    private(set) var recents: [RecentLink] = []
    private(set) var configError: String?

    /// Engine calls for links run here, so a slow one (config.js being
    /// reloaded, a `resolve` rule on the network) never blocks the menu bar.
    private let routeQueue = DispatchQueue(label: "dev.supersurfer.route", qos: .userInteractive)
    private var statusMenu: StatusMenuController?
    private var pendingPickers: [Decision] = []
    private var pickerMenu: NSMenu?
    private var pendingAlerts: [(title: String, text: String)] = []
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
        routeQueue.async {
            let reply = engine.route(url: input, opener: opener, modifiers: modifiers, preview: askUser)
            DispatchQueue.main.async {
                self.finishRoute(input: input, reply: reply, askUser: askUser, started: started)
            }
        }
    }

    private func finishRoute(input: String, reply: RouteReply?, askUser: Bool, started: DispatchTime?) {
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
        launch(plan, decision: decision, browser: browser, pickedByHand: false, started: started)
    }

    private func launch(
        _ plan: LaunchPlan,
        decision: Decision,
        browser: String,
        pickedByHand: Bool,
        started: DispatchTime?
    ) {
        let elapsedMs = started.map { start in
            Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        }
        let engine = self.engine
        let queue = routeQueue
        Launcher.open(plan) { error in
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
                    self.launch(plan, decision: decision, browser: label, pickedByHand: true, started: nil)
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
    func showAlert(title: String, text: String) {
        pendingAlerts.append((title: title, text: text))
        if pendingAlerts.count == 1 {
            perform(#selector(showPendingAlert), with: nil, afterDelay: 0)
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
        alert.addButton(withTitle: "OK")
        alert.runModal()

        pendingAlerts.removeFirst()
        if !pendingAlerts.isEmpty {
            perform(#selector(showPendingAlert), with: nil, afterDelay: 0)
        }
    }
}
