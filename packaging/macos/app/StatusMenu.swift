import Cocoa

/// The menu bar icon and its menu. The menu is rebuilt from the engine's
/// current state each time it opens; nothing is kept or polled in between.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private unowned let app: AppDelegate
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(app: AppDelegate) {
        self.app = app
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        // The icon can be dragged out of the menu bar with Command held.
        // Opening the app again brings it back (see `reveal`).
        statusItem.behavior = .removalAllowed
        statusItem.autosaveName = "dev.supersurfer.status"
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
    }

    func refreshIcon() {
        guard let button = statusItem.button else {
            return
        }
        let healthy = app.configError == nil
        let symbol = healthy ? "arrow.triangle.branch" : "exclamationmark.triangle"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SuperSurfer") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.image = nil
            button.title = healthy ? "S" : "S!"
        }
        button.toolTip = healthy
            ? "SuperSurfer"
            : tr("SuperSurfer: config.js has an error", "SuperSurfer: config.js enthält einen Fehler")
    }

    func reveal() {
        statusItem.isVisible = true
        // Showing the menu blocks until it closes, so do it on the next turn
        // of the run loop rather than inside the reopen event that brought us
        // here.
        perform(#selector(showMenu), with: nil, afterDelay: 0)
    }

    @objc private func showMenu() {
        statusItem.button?.performClick(nil)
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        let app = self.app
        let status = app.engine.status()
        let installed = app.engine.browsers()
        let browsers = installed?.browsers ?? []
        let profilesBlocked = installed?.profilesBlocked ?? []
        let rules = app.engine.rules()
        app.setConfigError(status?.configError)

        menu.removeAllItems()
        menu.addItem(MenuItems.note("SuperSurfer \(status?.version ?? "")"))
        if let name = status?.defaultBrowser {
            menu.addItem(MenuItems.note(tr("Default browser: \(name)", "Standardbrowser: \(name)")))
        }
        if status?.configError != nil {
            menu.addItem(ActionMenuItem(tr(
                "⚠︎ config.js has an error. Show…",
                "⚠︎ config.js enthält einen Fehler. Anzeigen …"
            )) {
                app.showConfigError()
            })
        }
        if !profilesBlocked.isEmpty {
            menu.addItem(ActionMenuItem(tr(
                "⚠︎ Browser profiles cannot be read. Show…",
                "⚠︎ Browser-Profile sind nicht lesbar. Anzeigen …"
            )) {
                app.showProfilesBlocked(profilesBlocked)
            })
        }

        menu.addItem(.separator())
        menu.addItem(MenuItems.note(tr("Recent Links", "Letzte Links")))
        if app.recents.isEmpty {
            menu.addItem(MenuItems.note(tr("None since SuperSurfer started", "Noch keine seit dem Start")))
        }
        for recent in app.recents {
            menu.addItem(recentItem(recent, browsers: browsers))
        }

        menu.addItem(.separator())
        menu.addItem(rulesItem(rules))
        menu.addItem(pickerKeyItem())
        menu.addItem(ActionMenuItem(tr(
            "Choose Browser for Copied Link…",
            "Browser für kopierten Link wählen …"
        )) {
            app.chooseBrowserForClipboardLink()
        })

        menu.addItem(.separator())
        if let configPath = status?.configPath {
            let config = URL(fileURLWithPath: configPath)
            menu.addItem(ActionMenuItem(tr("Edit config.js", "config.js bearbeiten")) {
                NSWorkspace.shared.open(config)
            })
            menu.addItem(ActionMenuItem(tr("Show Config Folder", "Konfigurationsordner zeigen")) {
                NSWorkspace.shared.activateFileViewerSelecting([config])
            })
        }
        if let logPath = status?.logPath, FileManager.default.fileExists(atPath: logPath) {
            menu.addItem(ActionMenuItem(tr("Show Decision Log", "Entscheidungsprotokoll zeigen")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
            })
        }
        menu.addItem(ActionMenuItem(tr("Reload Configuration", "Konfiguration neu laden")) {
            app.reloadConfiguration()
        })

        menu.addItem(.separator())
        if LoginItem.isSupported {
            let item = ActionMenuItem(tr("Launch at Login", "Beim Anmelden starten")) {
                app.toggleLoginItem()
            }
            item.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(item)
        }
        if !DefaultBrowser.isSuperSurfer {
            menu.addItem(ActionMenuItem(tr(
                "Make SuperSurfer the Default Browser",
                "SuperSurfer als Standardbrowser festlegen"
            )) {
                app.claimDefaultBrowser()
            })
        }
        menu.addItem(ActionMenuItem(tr("Quit SuperSurfer", "SuperSurfer beenden")) {
            NSApp.terminate(nil)
        })
    }

    // MARK: - Sections

    private func recentItem(_ recent: RecentLink, browsers: [BrowserInfo]) -> NSMenuItem {
        let app = self.app
        let decision = recent.decision
        var entries: [NSMenuItem] = []
        entries.append(MenuItems.note(Format.shortURL(decision.routedUrl)))
        entries.append(MenuItems.note(explanation(recent)))
        entries.append(.separator())

        let openItems = MenuItems.browsers(browsers) { browser, profile in
            app.open(decision, in: browser, profile: profile, rememberFor: nil)
        }
        entries.append(MenuItems.submenu(tr("Open Again in", "Erneut öffnen in"), items: openItems))
        for host in decision.rememberHosts {
            let rememberItems = MenuItems.browsers(browsers) { browser, profile in
                app.remember(domain: host, browser: browser, profile: profile)
            }
            entries.append(MenuItems.submenu(
                tr("Always Open \(host) in", "\(host) immer öffnen in"),
                items: rememberItems
            ))
        }
        entries.append(.separator())
        entries.append(ActionMenuItem(tr("Copy Link", "Link kopieren")) {
            Clipboard.copy(decision.routedUrl)
        })

        let place = decision.host ?? Format.shortURL(decision.routedUrl, limit: 40)
        let item = MenuItems.submenu("\(place) → \(recent.browser)", items: entries)
        item.toolTip = decision.inputUrl
        return item
    }

    private func explanation(_ recent: RecentLink) -> String {
        var parts: [String] = []
        if recent.pickedByHand {
            parts.append(tr("picked by hand", "von Hand gewählt"))
        } else {
            switch recent.decision.source {
            case "handler":
                parts.append("config.js")
            case "rule":
                let domain = recent.decision.ruleDomain ?? "?"
                parts.append(tr("saved rule for \(domain)", "gemerkte Regel für \(domain)"))
            case "emergency":
                parts.append(tr("config.js not loaded", "config.js nicht geladen"))
            default:
                parts.append(tr("default browser", "Standardbrowser"))
            }
        }
        if let elapsed = recent.elapsedMs {
            let time = Format.milliseconds(elapsed)
            parts.append(tr("routed in \(time)", "geroutet in \(time)"))
        }
        return parts.joined(separator: " · ")
    }

    private func rulesItem(_ reply: RulesReply?) -> NSMenuItem {
        let app = self.app
        let rules = reply?.rules ?? []
        var entries: [NSMenuItem] = []

        if reply?.ok != true {
            let reason = reply?.error ?? ""
            entries.append(ActionMenuItem(tr(
                "⚠︎ rules.json cannot be read. Show…",
                "⚠︎ rules.json ist nicht lesbar. Anzeigen …"
            )) {
                app.showAlert(title: "rules.json", text: reason)
            })
        } else if rules.isEmpty {
            let key = PickerKey.current
            if key == .off {
                entries.append(MenuItems.note(tr("None yet", "Noch keine")))
            } else {
                entries.append(MenuItems.note(tr(
                    "None yet. Hold \(key.symbol) while clicking a link.",
                    "Noch keine. Halte \(key.symbol) beim Klick auf einen Link."
                )))
            }
        }
        for rule in rules {
            let target = Format.browserLabel(rule.browserName, profile: rule.profile)
            let domain = rule.domain
            let remove = ActionMenuItem(tr("Remove Rule", "Regel entfernen")) {
                app.forget(domain: domain)
            }
            entries.append(MenuItems.submenu("\(domain) → \(target)", items: [remove]))
        }
        if let path = reply?.path, FileManager.default.fileExists(atPath: path) {
            entries.append(.separator())
            entries.append(ActionMenuItem(tr("Edit rules.json", "rules.json bearbeiten")) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            })
        }

        let title = rules.isEmpty
            ? tr("Saved Rules", "Gemerkte Regeln")
            : tr("Saved Rules (\(rules.count))", "Gemerkte Regeln (\(rules.count))")
        return MenuItems.submenu(title, items: entries)
    }

    private func pickerKeyItem() -> NSMenuItem {
        let current = PickerKey.current
        var entries: [NSMenuItem] = []
        for key in PickerKey.allCases {
            let item = ActionMenuItem(key.title) {
                PickerKey.current = key
            }
            item.state = key == current ? .on : .off
            entries.append(item)
        }
        let title = tr("Picker Key: \(current.title)", "Auswahl-Taste: \(current.title)")
        return MenuItems.submenu(title, items: entries)
    }
}
