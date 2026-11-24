import Cocoa

/// The menu shown at the pointer when a link is clicked with the picker key
/// held: choose a browser for this one link, or for its site from now on.
///
/// A menu rather than a window on purpose. It appears where the click
/// happened, needs no focus change, handles arrow keys, type-to-select and
/// Escape by itself, and costs nothing while it is not showing.
enum PickerMenu {
    static func make(app: AppDelegate, decision: Decision, browsers: [BrowserInfo]) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(MenuItems.note(Format.shortURL(decision.routedUrl)))
        menu.addItem(MenuItems.note(usualRoute(decision)))
        menu.addItem(.separator())

        // The browser the rules would have used carries the checkmark.
        let once = MenuItems.browsers(
            browsers,
            checkedBrowserId: decision.browserId,
            checkedProfile: decision.profile
        ) { browser, profile in
            app.open(decision, in: browser, profile: profile, rememberFor: nil)
        }
        for item in once {
            menu.addItem(item)
        }

        if !decision.rememberHosts.isEmpty {
            menu.addItem(.separator())
        }
        for host in decision.rememberHosts {
            var entries: [NSMenuItem] = []
            if decision.source == "handler" {
                // Saved rules come after config.js, so saving one here would
                // not change where this link goes. Say so instead of
                // pretending.
                entries.append(MenuItems.note(tr(
                    "config.js already decides this link and comes first",
                    "config.js regelt diesen Link bereits und hat Vorrang"
                )))
                entries.append(.separator())
            }
            let always = MenuItems.browsers(browsers) { browser, profile in
                app.open(decision, in: browser, profile: profile, rememberFor: host)
            }
            entries.append(contentsOf: always)
            menu.addItem(MenuItems.submenu(
                tr("Always Open \(host) in", "\(host) immer öffnen in"),
                items: entries
            ))
        }

        menu.addItem(.separator())
        let cleaned = decision.routedUrl != decision.inputUrl
        let copyTitle = cleaned
            ? tr("Copy Cleaned Link", "Bereinigten Link kopieren")
            : tr("Copy Link", "Link kopieren")
        menu.addItem(ActionMenuItem(copyTitle) {
            Clipboard.copy(decision.routedUrl)
        })
        return menu
    }

    private static func usualRoute(_ decision: Decision) -> String {
        let target = Format.browserLabel(decision.browser, profile: decision.profile)
        switch decision.source {
        case "handler":
            return tr("config.js opens this in \(target)", "config.js öffnet das in \(target)")
        case "rule":
            let domain = decision.ruleDomain ?? "?"
            return tr(
                "Saved rule for \(domain) opens this in \(target)",
                "Gemerkte Regel für \(domain) öffnet das in \(target)"
            )
        case "emergency":
            return tr(
                "config.js is not loaded. Fallback: \(target)",
                "config.js ist nicht geladen. Ersatz: \(target)"
            )
        default:
            return tr(
                "No rule matches. Default browser: \(target)",
                "Keine Regel greift. Standardbrowser: \(target)"
            )
        }
    }
}
