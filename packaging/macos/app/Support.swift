import ApplicationServices
import Cocoa

/// The app has a handful of strings, so English and German sit side by side
/// instead of in .lproj bundles: the bundle stays a plain swiftc build with
/// no resource step.
func tr(_ english: String, _ german: String) -> String {
    return prefersGerman ? german : english
}

private let prefersGerman: Bool = {
    let language = Locale.preferredLanguages.first ?? "en"
    return language.lowercased().hasPrefix("de")
}()

enum Format {
    /// A link without its scheme, shortened in the middle so a menu stays narrow.
    static func shortURL(_ text: String, limit: Int = 64) -> String {
        var shown = text
        for scheme in ["https://", "http://"] where shown.hasPrefix(scheme) {
            shown = String(shown.dropFirst(scheme.count))
        }
        if shown.count <= limit {
            return shown
        }
        let head = shown.prefix(limit * 2 / 3)
        let tail = shown.suffix(limit / 3 - 1)
        return "\(head)…\(tail)"
    }

    static func browserLabel(_ name: String, profile: String?) -> String {
        if let profile = profile, !profile.isEmpty {
            return "\(name) (\(profile))"
        }
        return name
    }

    static func milliseconds(_ value: Double) -> String {
        return String(format: value < 10 ? "%.2f ms" : "%.0f ms", value)
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func text() -> String? {
        return NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A menu item that runs a closure. The item is its own target, so no
/// controller has to stay alive or expose selectors for it.
final class ActionMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        self.handler = handler
        self.target = self
    }

    @objc private func runHandler() {
        handler?()
    }
}

enum MenuItems {
    /// Greyed-out text: an item without an action is disabled automatically.
    static func note(_ text: String) -> NSMenuItem {
        return NSMenuItem(title: text, action: nil, keyEquivalent: "")
    }

    static func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for entry in items {
            menu.addItem(entry)
        }
        item.submenu = menu
        return item
    }

    /// One entry per browser with its profiles indented below it. Choosing the
    /// browser itself opens whatever profile it used last.
    ///
    /// A profile is listed under the name `names` has for it: the one its
    /// Dock shortcut was given, where somebody chose one. `onPick` gets the
    /// name the browser has for the profile, which is what the engine goes
    /// by. `checkedProfile` may name the profile either way, or by its
    /// folder as config.js can.
    static func browsers(
        _ browsers: [BrowserInfo],
        names: ProfileNames,
        checkedBrowserId: String? = nil,
        checkedProfile: String? = nil,
        onPick: @escaping (BrowserInfo, String?) -> Void
    ) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for browser in browsers {
            let isChecked = browser.id == checkedBrowserId
            let item = ActionMenuItem(browser.name) { onPick(browser, nil) }
            item.image = appIcon(at: browser.appPath)
            if isChecked && checkedProfile == nil {
                item.state = .on
            }
            items.append(item)

            for profile in names.listed(browser.profiles, of: browser.id) {
                let given = profile.given
                let entry = ActionMenuItem(profile.shown) { onPick(browser, given) }
                entry.indentationLevel = 2
                if profile.shown != given {
                    // Rules in config.js go by the browser's name, so it
                    // has to be findable from here.
                    entry.toolTip = tr(
                        "\(browser.name) calls this profile “\(given)”",
                        "In \(browser.name) heißt dieses Profil „\(given)“"
                    )
                }
                if isChecked, let wanted = checkedProfile, names.same(wanted, given, of: browser.id) {
                    entry.state = .on
                }
                items.append(entry)
            }
        }
        if items.isEmpty {
            items.append(note(tr("No browsers found", "Keine Browser gefunden")))
        }
        return items
    }

    private static func appIcon(at path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

/// Questions to another app through Accessibility. Each one waits for that
/// app's answer, so none of them belongs on the main thread.
enum AX {
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

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        return (value(element, attribute) as? [AXUIElement]) ?? []
    }
}
