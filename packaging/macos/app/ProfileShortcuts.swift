import ApplicationServices
import Cocoa

// Dock shortcuts for browser profiles: one icon in the Dock per profile, the
// way the Windows taskbar has them. A click on "Edge Work" brings the window
// of that profile to the front, opens one if the profile has none, and starts
// the browser with that profile if it is not running.
//
// The Dock only holds apps, so each shortcut is a small app that SuperSurfer
// writes: a shell script that tells SuperSurfer which profile is wanted, and
// ends. What happens then depends on the browser:
//
//   not running   It is started with the profile.
//   running       The entry for the profile in the browser's own profile menu
//                 is pressed through Accessibility. The browser then does
//                 what it does when a person chooses that entry: it brings
//                 the profile's window forward, out of the Dock if need be,
//                 or opens one. Seen with Edge and Chrome on macOS 15 and 26.
//   otherwise     Without the Accessibility permission, or when no entry of
//                 that menu can be told to be the profile's, the browser is
//                 asked for a window of the profile the way it is for a
//                 link. That window is always a new one.
//
// The menu is used because a window's title does not say reliably which
// profile it belongs to: Edge leaves the name out for its first profile.
//
// Like Dock Click this has nothing to do with routing links, and none of it
// runs until a shortcut is clicked or the menu is opened.

/// The decisions that need neither a browser nor the disk, so that
/// `--self-test` can check them.
enum ProfileShortcutRules {
    static let scheme = "supersurfer"
    static let host = "profile"
    /// The action behind the entries of Chromium's profile menu that switch
    /// to a profile. Accessibility reports it as the entry's identifier,
    /// whatever language the menu is in.
    static let switchAction = "switchToProfileFromMenu:"

    /// The link a shortcut sends: `supersurfer://profile/<browser>/<folder>`.
    static func link(browser: String, directory: String) -> String? {
        let plain = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard isPlainName(browser), isPlainName(directory),
              let browserPart = browser.addingPercentEncoding(withAllowedCharacters: plain),
              let directoryPart = directory.addingPercentEncoding(withAllowedCharacters: plain) else {
            return nil
        }
        return "\(scheme)://\(host)/\(browserPart)/\(directoryPart)"
    }

    static func isLink(_ url: URL) -> Bool {
        return url.scheme?.lowercased() == scheme
    }

    /// The browser and the profile folder a link names. Nil for anything
    /// that is not exactly such a link: it can come from any app or web page.
    static func target(of url: URL) -> (browser: String, directory: String)? {
        guard isLink(url), url.host?.lowercased() == host,
              url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil else {
            return nil
        }
        let parts = url.pathComponents
        guard parts.count == 3, parts[0] == "/", isPlainName(parts[1]), isPlainName(parts[2]) else {
            return nil
        }
        return (parts[1], parts[2])
    }

    /// A name of a browser or of a profile folder: one path component with
    /// nothing in it that means something to a shell, a path or a terminal.
    static func isPlainName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128, name != ".", name != "..",
              name == name.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !name.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == ":"
        }
    }

    /// A word for /bin/sh that stands for exactly this text.
    static func shellQuoted(_ text: String) -> String {
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What a shortcut runs. It asks the copy of SuperSurfer that wrote it,
    /// then whichever copy macOS knows, and if there is none it opens a
    /// window of the profile itself, so a shortcut never does nothing.
    static func script(link: String, superSurfer: String, browserPath: String, launchArguments: [String]) -> String {
        var direct = ["/usr/bin/open", "-n", "-a", shellQuoted(browserPath)]
        if !launchArguments.isEmpty {
            direct.append("--args")
            direct.append(contentsOf: launchArguments.map(shellQuoted))
        }
        return """
        #!/bin/sh
        # Written by SuperSurfer for a browser profile in the Dock.
        link=\(shellQuoted(link))
        /usr/bin/open -g -a \(shellQuoted(superSurfer)) "$link" 2>/dev/null && exit 0
        /usr/bin/open -g "$link" 2>/dev/null && exit 0
        exec \(direct.joined(separator: " "))

        """
    }

    /// "Edge Work": what the shortcut is called in the Dock and the Finder.
    static func title(browser: String, profile: String) -> String {
        var cleaned = ""
        var afterSpace = true
        for character in "\(browser) \(profile)" {
            if character.isWhitespace || character.isNewline {
                if !afterSpace {
                    cleaned.append(" ")
                }
                afterSpace = true
            } else if character.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                continue
            } else {
                // Neither can be part of a file name; the Finder shows ":"
                // as "/".
                cleaned.append(character == "/" || character == ":" ? "-" : character)
                afterSpace = false
            }
        }
        if cleaned.hasSuffix(" ") {
            cleaned.removeLast()
        }
        if cleaned.hasPrefix(".") {
            cleaned = "_" + String(cleaned.dropFirst())
        }
        return cleaned.isEmpty ? "Shortcut" : String(cleaned.prefix(100))
    }

    static func bundleIdentifier(browser: String, directory: String) -> String {
        func slug(_ text: String) -> String {
            let kept = text.unicodeScalars.map { scalar -> Character in
                let isLetterOrDigit = (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                    || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                return isLetterOrDigit ? Character(scalar) : "-"
            }
            return String(kept)
        }
        return "dev.supersurfer.shortcut.\(slug(browser)).\(slug(directory))"
    }

    /// One to three characters that stand for a profile on its icon: "W" for
    /// "Work", "P2" for "Profile 2", and "Wo" where another profile of the
    /// browser begins with a W as well.
    static func badge(for name: String, among names: [String]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else {
            return "?"
        }
        let initial = String(first).uppercased()
        // "Profile 2", "Person 1": the number is what tells them apart.
        let digits = String(trimmed.reversed().prefix { $0.isNumber }.reversed())
        if !digits.isEmpty, digits.count < trimmed.count {
            return initial + String(digits.suffix(2))
        }
        let sharesInitial = names.contains { other in
            let otherName = other.trimmingCharacters(in: .whitespacesAndNewlines)
            return otherName != trimmed && otherName.first.map { String($0).uppercased() } == initial
        }
        if sharesInitial, trimmed.count > 1 {
            return initial + String(trimmed.dropFirst().prefix(1)).lowercased()
        }
        return initial
    }

    /// Which entry of the browser's profile menu stands for a profile.
    ///
    /// `wanted` are the titles the profile may have there, most likely
    /// first. The first of them that the menu has at all decides, and only
    /// if exactly one entry carries it: two profiles can go by one name.
    ///
    /// A browser may dress the name up in a way nobody foresaw ("Work -
    /// ada@example.com"). When none of the titles is there, an entry that
    /// has the profile's own name in it as a word of its own is taken, again
    /// only if it is the only one.
    static func entry(for wanted: [String], named name: String, in titles: [String]) -> Int? {
        let shown = titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for candidate in wanted {
            let title = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let hits = shown.indices.filter { shown[$0] == title }
            if !hits.isEmpty {
                return hits.count == 1 ? hits[0] : nil
            }
        }
        let own = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = shown.indices.filter { mentions(shown[$0], own) }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Whether `title` has `name` in it as a word of its own: "Ada (Work)"
    /// mentions "Work", "HomeWork" and "Work2" do not.
    static func mentions(_ title: String, _ name: String) -> Bool {
        guard !name.isEmpty else {
            return false
        }
        func isPartOfWord(_ character: Character?) -> Bool {
            guard let character = character else {
                return false
            }
            return character.isLetter || character.isNumber
        }
        var rest = title.startIndex..<title.endIndex
        while let found = title.range(of: name, options: [], range: rest) {
            let before: Character? = found.lowerBound == title.startIndex
                ? nil
                : title[title.index(before: found.lowerBound)]
            let after: Character? = found.upperBound == title.endIndex ? nil : title[found.upperBound]
            if !isPartOfWord(before) && !isPartOfWord(after) {
                return true
            }
            rest = title.index(after: found.lowerBound)..<title.endIndex
        }
        return false
    }

    /// An .icns file made of PNG images. `pixels` is the width of an image,
    /// which decides the type it is filed under.
    static func icns(_ images: [(pixels: Int, png: Data)]) -> Data? {
        let types = [128: "ic07", 256: "ic08", 512: "ic09", 1024: "ic10"]
        func bigEndian(_ number: Int) -> Data {
            return withUnsafeBytes(of: UInt32(number).bigEndian) { Data($0) }
        }
        var body = Data()
        for image in images {
            guard let type = types[image.pixels] else {
                return nil
            }
            body.append(Data(type.utf8))
            body.append(bigEndian(image.png.count + 8))
            body.append(image.png)
        }
        guard !body.isEmpty else {
            return nil
        }
        var file = Data("icns".utf8)
        file.append(bigEndian(body.count + 8))
        file.append(body)
        return file
    }
}

/// The icon of a shortcut: the browser's own, with a round badge in the
/// lower right corner that names the profile.
enum ShortcutIcon {
    /// Fills for the badge, dark enough for white letters.
    static let palette: [(red: CGFloat, green: CGFloat, blue: CGFloat)] = [
        (0.00, 0.40, 0.85), (0.11, 0.53, 0.25), (0.78, 0.33, 0.00), (0.54, 0.27, 0.72),
        (0.80, 0.13, 0.15), (0.00, 0.48, 0.55), (0.82, 0.16, 0.47), (0.33, 0.35, 0.39),
    ]

    /// Where the badge sits in an icon `side` wide. AppKit counts upwards, so
    /// a small y is the bottom.
    static func badgeFrame(side: CGFloat) -> NSRect {
        let diameter = side * 0.46
        return NSRect(x: side - diameter - side * 0.02, y: side * 0.02, width: diameter, height: diameter)
    }

    static func bitmap(appPath: String, badge: String, color: Int, pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        let fill = palette[abs(color) % palette.count]
        let side = CGFloat(pixels)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSWorkspace.shared.icon(forFile: appPath).draw(
            in: NSRect(x: 0, y: 0, width: side, height: side),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        // A white rim keeps the badge apart from whatever the icon shows.
        let rim = badgeFrame(side: side)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rim).fill()
        let disc = rim.insetBy(dx: side * 0.025, dy: side * 0.025)
        NSColor(deviceRed: fill.red, green: fill.green, blue: fill.blue, alpha: 1).setFill()
        NSBezierPath(ovalIn: disc).fill()

        let share: CGFloat = badge.count <= 1 ? 0.62 : (badge.count == 2 ? 0.48 : 0.36)
        let font = NSFont.systemFont(ofSize: disc.height * share, weight: .bold)
        let text = NSAttributedString(string: badge, attributes: [.font: font, .foregroundColor: NSColor.white])
        // `draw(at:)` takes the lower left corner of the line, which lies
        // below the baseline by the descender. Capital letters are centred.
        text.draw(at: NSPoint(
            x: disc.midX - text.size().width / 2,
            y: disc.midY - font.capHeight / 2 + font.descender
        ))

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func icns(appPath: String, badge: String, color: Int) -> Data? {
        var images: [(pixels: Int, png: Data)] = []
        for pixels in [128, 256, 512] {
            guard let png = bitmap(appPath: appPath, badge: badge, color: color, pixels: pixels)?
                .representation(using: .png, properties: [:]) else {
                return nil
            }
            images.append((pixels: pixels, png: png))
        }
        return ProfileShortcutRules.icns(images)
    }
}

enum ShortcutError: LocalizedError {
    case unusableName(String)
    case notWritten(String)

    var errorDescription: String? {
        switch self {
        case .unusableName(let name):
            return tr(
                "The profile folder \"\(name)\" cannot be named in a shortcut.",
                "Der Profilordner „\(name)“ lässt sich in einer Verknüpfung nicht benennen."
            )
        case .notWritten(let path):
            return tr("Nothing usable was written to \(path).", "Unter \(path) ist nichts Brauchbares entstanden.")
        }
    }
}

/// A shortcut as it lies on disk. What it is for is kept in its Info.plist,
/// so the folder of shortcuts is the only record of them.
struct ProfileShortcut {
    static let executableName = "shortcut"
    static let iconName = "shortcut"

    private enum Key {
        static let browser = "SuperSurferBrowser"
        static let directory = "SuperSurferProfileDirectory"
        static let profileName = "SuperSurferProfileName"
        static let menuTitles = "SuperSurferMenuTitles"
        static let launchArguments = "SuperSurferLaunchArguments"
        static let browserPath = "SuperSurferBrowserPath"
        static let color = "SuperSurferBadgeColor"
    }

    let bundle: URL
    /// The name of the app without ".app".
    let title: String
    let browser: String
    let directory: String
    // As they were when the shortcut was written. The engine's current list
    // is asked first; these are for when it has nothing on the profile.
    let profileName: String
    let menuTitles: [String]
    let launchArguments: [String]
    let browserPath: String
    let color: Int

    /// Reads a shortcut back. Nil for an app that SuperSurfer did not write.
    init?(bundle: URL) {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any],
              let browser = info[Key.browser] as? String,
              let directory = info[Key.directory] as? String,
              let browserPath = info[Key.browserPath] as? String,
              ProfileShortcutRules.isPlainName(browser),
              ProfileShortcutRules.isPlainName(directory) else {
            return nil
        }
        self.bundle = bundle
        self.title = bundle.deletingPathExtension().lastPathComponent
        self.browser = browser
        self.directory = directory
        self.profileName = (info[Key.profileName] as? String) ?? directory
        self.menuTitles = (info[Key.menuTitles] as? [String]) ?? []
        self.launchArguments = (info[Key.launchArguments] as? [String]) ?? []
        self.browserPath = browserPath
        self.color = (info[Key.color] as? Int) ?? 0
    }

    func isFor(browser: String, directory: String) -> Bool {
        return self.browser == browser && self.directory == directory
    }

    /// Every shortcut in `folder`, by name.
    static func all(in folder: URL) -> [ProfileShortcut] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries
            .filter { $0.pathExtension == "app" }
            .compactMap { ProfileShortcut(bundle: $0) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Writes the app for one profile into `folder`, in place of an older
    /// one for the same profile, and returns it as read back from there.
    static func write(
        browser: ShortcutBrowser,
        profile: ShortcutProfile,
        into folder: URL,
        superSurfer: String
    ) throws -> ProfileShortcut {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = all(in: folder)
        let others = existing.filter { !$0.isFor(browser: browser.id, directory: profile.directory) }

        guard let link = ProfileShortcutRules.link(browser: browser.id, directory: profile.directory) else {
            throw ShortcutError.unusableName(profile.directory)
        }
        var title = ProfileShortcutRules.title(browser: browser.shortName, profile: profile.name)
        if others.contains(where: { $0.title == title }) {
            // Two profiles of one name: the folder tells them apart.
            title = ProfileShortcutRules.title(
                browser: browser.shortName,
                profile: "\(profile.name) (\(profile.directory))"
            )
        }
        // The first colour no other shortcut of this browser has.
        let taken = Set(others.filter { $0.browser == browser.id }.map { $0.color })
        let color = (0..<ShortcutIcon.palette.count).first { !taken.contains($0) }
            ?? others.count % ShortcutIcon.palette.count
        let badge = ProfileShortcutRules.badge(for: profile.name, among: browser.profiles.map { $0.name })

        // Built beside its place and moved there in one step, so that
        // nothing ever sees half an app.
        let staging = folder.appendingPathComponent(".\(UUID().uuidString).noindex", isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try files.createDirectory(at: macOS, withIntermediateDirectories: true)
        try files.createDirectory(at: resources, withIntermediateDirectories: true)

        let executable = macOS.appendingPathComponent(executableName)
        let script = ProfileShortcutRules.script(
            link: link,
            superSurfer: superSurfer,
            browserPath: browser.appPath,
            launchArguments: profile.launchArgs
        )
        try Data(script.utf8).write(to: executable)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        var info: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": ProfileShortcutRules.bundleIdentifier(
                browser: browser.id,
                directory: profile.directory
            ),
            "CFBundleName": title,
            "CFBundleDisplayName": title,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1",
            "CFBundleVersion": "1",
            // While it runs it has no menu bar, takes the front from nobody
            // and the Dock shows no dot under it.
            "LSUIElement": true,
            Key.browser: browser.id,
            Key.directory: profile.directory,
            Key.profileName: profile.name,
            Key.menuTitles: profile.menuTitles,
            Key.launchArguments: profile.launchArgs,
            Key.browserPath: browser.appPath,
            Key.color: color,
        ]
        // Without an icon of its own the shortcut still works, under the
        // icon macOS gives every app that has none.
        if let icon = ShortcutIcon.icns(appPath: browser.appPath, badge: badge, color: color) {
            try icon.write(to: resources.appendingPathComponent("\(iconName).icns"))
            info["CFBundleIconFile"] = iconName
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))

        let bundle = folder.appendingPathComponent("\(title).app", isDirectory: true)
        for old in existing where old.isFor(browser: browser.id, directory: profile.directory) {
            try? files.removeItem(at: old.bundle)
        }
        try? files.removeItem(at: bundle)
        try files.moveItem(at: staging, to: bundle)
        guard let written = ProfileShortcut(bundle: bundle) else {
            throw ShortcutError.notWritten(bundle.path)
        }
        return written
    }
}

final class ProfileShortcuts {
    static let shared = ProfileShortcuts()

    /// How long a browser may take to answer one question about its menus.
    private static let answerTimeout: Float = 1.5
    /// Choosing the entry can mean that the browser loads a profile and
    /// opens a window before it answers.
    private static let pressTimeout: Float = 4

    /// Questions to a browser and starting it wait for other apps, so they
    /// run here and never on the main thread.
    private let queue = DispatchQueue(label: "dev.supersurfer.shortcuts", qos: .userInitiated)

    private init() {}

    /// Where the shortcuts are kept. The Finder, Spotlight and the Dock all
    /// know `~/Applications`. HOME is asked first, as the engine does, so a
    /// test with a scratch HOME keeps to it.
    static var folder: URL {
        var home = NSHomeDirectory()
        if let variable = getenv("HOME") {
            let text = String(cString: variable)
            if text.hasPrefix("/") {
                home = text
            }
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("SuperSurfer Shortcuts", isDirectory: true)
    }

    // MARK: - Menu

    /// The "Dock Shortcuts" entry of the status menu, built for the state as
    /// it is right now.
    func menuItem(app: AppDelegate) -> NSMenuItem {
        let browsers = app.engine.shortcuts()?.browsers ?? []
        let existing = ProfileShortcut.all(in: ProfileShortcuts.folder)
        let needsPermission = !existing.isEmpty && !AXIsProcessTrusted()

        var entries: [NSMenuItem] = [MenuItems.note(tr(
            "Makes an app for a browser profile, to drag into the Dock",
            "Legt für ein Browser-Profil eine App an, die du ins Dock ziehst"
        ))]
        var offered = 0
        var listed: [URL] = []
        for browser in browsers where !browser.profiles.isEmpty {
            let header = MenuItems.note(browser.name)
            let icon = NSWorkspace.shared.icon(forFile: browser.appPath)
            icon.size = NSSize(width: 16, height: 16)
            header.image = icon
            entries.append(header)
            for profile in browser.profiles {
                offered += 1
                let item: NSMenuItem
                if let shortcut = existing.first(where: { $0.isFor(browser: browser.id, directory: profile.directory) }) {
                    listed.append(shortcut.bundle)
                    item = shortcutItem(profile.name, shortcut, app: app)
                } else {
                    item = ActionMenuItem(profile.name) { [weak self] in
                        self?.create(browser: browser, profile: profile, app: app)
                    }
                }
                item.indentationLevel = 2
                entries.append(item)
            }
        }
        if offered == 0 {
            entries.append(MenuItems.note(tr(
                "No profiles of Edge or Chrome found",
                "Keine Profile von Edge oder Chrome gefunden"
            )))
        }

        // Shortcuts for profiles the list no longer has can still be removed.
        let unlisted = existing.filter { !listed.contains($0.bundle) }
        if !unlisted.isEmpty {
            entries.append(.separator())
            entries.append(MenuItems.note(tr("Profile not in the list any more", "Profil nicht mehr in der Liste")))
            for shortcut in unlisted {
                let item = shortcutItem(shortcut.title, shortcut, app: app)
                item.indentationLevel = 2
                entries.append(item)
            }
        }
        if !existing.isEmpty {
            entries.append(.separator())
            entries.append(ActionMenuItem(tr("Show Shortcuts in Finder", "Verknüpfungen im Finder zeigen")) {
                NSWorkspace.shared.open(ProfileShortcuts.folder)
            })
        }
        if needsPermission {
            entries.append(ActionMenuItem(tr(
                "⚠︎ Without the Accessibility permission a click opens a new window. Show…",
                "⚠︎ Ohne die Berechtigung „Bedienungshilfen“ öffnet ein Klick ein neues Fenster. Anzeigen …"
            )) { [weak self] in
                self?.explainPermission(app)
            })
        }

        let count = existing.count
        let title = count == 0
            ? tr("Dock Shortcuts", "Dock-Verknüpfungen")
            : tr("Dock Shortcuts (\(count))", "Dock-Verknüpfungen (\(count))")
        return MenuItems.submenu(needsPermission ? "⚠︎ " + title : title, items: entries)
    }

    private func shortcutItem(_ title: String, _ shortcut: ProfileShortcut, app: AppDelegate) -> NSMenuItem {
        let item = MenuItems.submenu(title, items: [
            ActionMenuItem(tr("Show in Finder", "Im Finder zeigen")) {
                NSWorkspace.shared.activateFileViewerSelecting([shortcut.bundle])
            },
            ActionMenuItem(tr("Remove Shortcut", "Verknüpfung entfernen")) { [weak self] in
                self?.remove(shortcut, app: app)
            },
        ])
        item.state = .on
        return item
    }

    private func create(browser: ShortcutBrowser, profile: ShortcutProfile, app: AppDelegate) {
        do {
            let shortcut = try ProfileShortcut.write(
                browser: browser,
                profile: profile,
                into: ProfileShortcuts.folder,
                superSurfer: Bundle.main.bundleURL.path
            )
            ProfileShortcuts.trace("\(shortcut.title): written to \(shortcut.bundle.path)")
            // So that the Finder and the Dock know its name and icon at once.
            LSRegisterURL(shortcut.bundle as CFURL, true)
            // From here it is dragged into the Dock.
            NSWorkspace.shared.activateFileViewerSelecting([shortcut.bundle])
            if !AXIsProcessTrusted() {
                // The system's own request. It puts SuperSurfer on the list
                // under Accessibility and offers to open that page. It does
                // not block.
                let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
            }
        } catch {
            app.showAlert(
                title: tr("The shortcut could not be created", "Die Verknüpfung konnte nicht angelegt werden"),
                text: error.localizedDescription
            )
        }
    }

    private func remove(_ shortcut: ProfileShortcut, app: AppDelegate) {
        do {
            try FileManager.default.removeItem(at: shortcut.bundle)
            ProfileShortcuts.trace("\(shortcut.title): removed")
        } catch {
            app.showAlert(
                title: tr("The shortcut could not be removed", "Die Verknüpfung konnte nicht entfernt werden"),
                text: error.localizedDescription
            )
        }
    }

    private func explainPermission(_ app: AppDelegate) {
        app.showAlert(
            title: tr(
                "Dock shortcuts work better with the Accessibility permission",
                "Dock-Verknüpfungen arbeiten besser mit der Berechtigung „Bedienungshilfen“"
            ),
            text: tr(
                "To bring the window of a profile to the front, SuperSurfer chooses that profile in the browser's own profile menu. macOS allows that only with this permission. Without it a click on a shortcut opens a new window of the profile every time.\n\nOpen System Settings > Privacy & Security > Accessibility and switch on SuperSurfer. It works from the next click, without a restart.\n\nAlready switched on there? macOS ties the permission to the app's signature, and releases are not signed with a Developer ID yet. After an update the switch still looks on but no longer counts. Remove SuperSurfer from the list with the minus button and add it again with the plus button.",
                "Um das Fenster eines Profils nach vorn zu holen, wählt SuperSurfer das Profil im Profil-Menü des Browsers aus. Das erlaubt macOS nur mit dieser Berechtigung. Ohne sie öffnet ein Klick auf eine Verknüpfung jedes Mal ein neues Fenster des Profils.\n\nÖffne Systemeinstellungen > Datenschutz & Sicherheit > Bedienungshilfen und schalte SuperSurfer ein. Es wirkt ab dem nächsten Klick, ohne Neustart.\n\nDort schon eingeschaltet? macOS bindet die Berechtigung an die Signatur der App, und die Releases sind noch nicht mit einer Developer ID signiert. Nach einem Update sieht der Schalter weiter eingeschaltet aus, zählt aber nicht mehr. Entferne SuperSurfer mit dem Minus-Knopf aus der Liste und füge es mit dem Plus-Knopf wieder hinzu."
            ),
            action: AlertAction(title: tr("Open System Settings", "Systemeinstellungen öffnen")) {
                PrivacySettings.openAccessibility()
            }
        )
    }

    // MARK: - A click on a shortcut

    /// The link a shortcut's script sent. Returns at once; the work is done
    /// on a queue of its own.
    func open(_ url: URL, engine: EngineBridge) {
        guard let target = ProfileShortcutRules.target(of: url) else {
            ProfileShortcuts.trace("a link that names no profile was left alone")
            return
        }
        let asked = ProcessInfo.processInfo.systemUptime
        queue.async {
            self.show(browser: target.browser, directory: target.directory, engine: engine, asked: asked)
        }
    }

    private func show(browser browserID: String, directory: String, engine: EngineBridge, asked: TimeInterval) {
        // The link can come from anywhere. It is acted on only for a profile
        // the user made a shortcut for.
        let known = ProfileShortcut.all(in: ProfileShortcuts.folder)
        guard let shortcut = known.first(where: { $0.isFor(browser: browserID, directory: directory) }) else {
            ProfileShortcuts.trace("no shortcut for \(browserID) and \(directory): left alone")
            return
        }
        // What the engine knows now comes first: a profile may have been
        // renamed since the shortcut was written.
        let listed = engine.shortcuts()?.browsers?.first { $0.id == shortcut.browser }
        let profile = listed?.profiles.first { $0.directory == shortcut.directory }
        let browserPath = listed?.appPath ?? shortcut.browserPath
        let titles = profile?.menuTitles ?? shortcut.menuTitles
        let name = profile?.name ?? shortcut.profileName
        let arguments = profile?.launchArgs ?? shortcut.launchArguments
        let bundleID = listed?.bundleId ?? Bundle(path: browserPath)?.bundleIdentifier

        func openWindow(_ why: String) {
            Launcher.openProfileWindow(appPath: browserPath, arguments: arguments) { error in
                if let error = error {
                    NSLog("SuperSurfer: %@ could not be opened: %@", shortcut.title, error.localizedDescription)
                }
                ProfileShortcuts.trace("\(shortcut.title): \(why)")
            }
        }

        let running = bundleID.flatMap { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .first { !$0.isTerminated && $0.activationPolicy == .regular }
        }
        guard let browser = running else {
            openWindow("the browser was not running and was started with the profile")
            return
        }
        guard AXIsProcessTrusted() else {
            openWindow("a new window, for lack of the Accessibility permission")
            return
        }
        if browser.isHidden {
            browser.unhide()
        }
        switch ProfileShortcuts.pressProfileEntry(of: browser.processIdentifier, titled: titles, named: name) {
        case .pressed(let title):
            ProfileShortcuts.bringForward(browser)
            let took = (ProcessInfo.processInfo.systemUptime - asked) * 1000
            ProfileShortcuts.trace(String(
                format: "%@: brought forward through the profile menu, entry \"%@\", %.0f ms after the shortcut asked",
                shortcut.title, title, took
            ))
        case .noEntry(let shown):
            // Worth a line in the system log: this is the case a person
            // would ask about.
            NSLog(
                "SuperSurfer: %@: the browser's profile menu has no single entry called %@; it has %@",
                shortcut.title, titles.description, shown.description
            )
            openWindow("a new window, the profile menu has no single entry called \(titles); it has \(shown)")
        case .noMenu:
            openWindow("a new window, no profile menu was found")
        case .refused(let error):
            openWindow("a new window, the profile menu did not take the choice (error \(error.rawValue))")
        }
    }

    private enum Press {
        case pressed(String)
        case noEntry([String])
        case noMenu
        case refused(AXError)
    }

    /// The same element, with the time this process waits for an answer
    /// about it set to something a busy browser can meet. The default is
    /// six seconds, and Dock Click sets it to less than half a second.
    private static func patient(_ element: AXUIElement, _ seconds: Float = answerTimeout) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, seconds)
        return element
    }

    private static func isProfileEntry(_ item: AXUIElement) -> Bool {
        return AX.string(patient(item), "AXIdentifier") == ProfileShortcutRules.switchAction
    }

    /// Finds the browser's profile menu and presses the entry that stands
    /// for the profile.
    private static func pressProfileEntry(of pid: pid_t, titled wanted: [String], named name: String) -> Press {
        let app = patient(AXUIElementCreateApplication(pid))
        guard let found = AX.value(app, kAXMenuBarAttribute),
              CFGetTypeID(found) == AXUIElementGetTypeID() else {
            return .noMenu
        }
        let bar = patient(found as! AXUIElement)
        // The profile menu is one of the last, before Tab, Window and Help.
        for barItem in AX.elements(bar, kAXChildrenAttribute).reversed() {
            for menu in AX.elements(patient(barItem), kAXChildrenAttribute) {
                let items = AX.elements(patient(menu), kAXChildrenAttribute)
                // The profiles come first in their menu.
                guard items.prefix(3).contains(where: isProfileEntry) else {
                    continue
                }
                let entries = items.filter(isProfileEntry)
                let titles = entries.map { AX.string($0, kAXTitleAttribute) ?? "" }
                guard let index = ProfileShortcutRules.entry(for: wanted, named: name, in: titles) else {
                    return .noEntry(titles)
                }
                let result = AXUIElementPerformAction(
                    patient(entries[index], pressTimeout),
                    kAXPressAction as CFString
                )
                // No answer in time does not mean that nothing happened: the
                // browser may be busy opening the window. Asking for another
                // one on top would make two.
                if result == .success || result == .cannotComplete {
                    return .pressed(titles[index])
                }
                return .refused(result)
            }
        }
        return .noMenu
    }

    /// The browser comes forward by itself when its entry is chosen. This
    /// waits for that for half a second and asks for it if it did not happen.
    private static func bringForward(_ browser: NSRunningApplication) {
        for _ in 0..<10 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == browser.processIdentifier {
                return
            }
            usleep(50_000)
        }
        browser.activate(options: [])
    }

    /// With `--resident`, one line on stderr per shortcut that was clicked,
    /// written or removed, saying what was done.
    private static func trace(_ message: String) {
        guard AppDelegate.traceToStderr else {
            return
        }
        fputs("SuperSurfer: dock shortcut: \(message)\n", stderr)
    }

    // MARK: - Self-test

    static func selfTest(_ check: (String, Bool) -> Void) {
        typealias Rules = ProfileShortcutRules

        let link = Rules.link(browser: "edge", directory: "Profile 1")
        check("dock shortcut: the link for a profile", link == "supersurfer://profile/edge/Profile%201")
        let back = link.flatMap { URL(string: $0) }.flatMap { Rules.target(of: $0) }
        check("dock shortcut: and what it names", back?.browser == "edge" && back?.directory == "Profile 1")
        let odd = Rules.link(browser: "chrome", directory: "Büro & Co")
            .flatMap { URL(string: $0) }
            .flatMap { Rules.target(of: $0) }
        check("dock shortcut: a folder with other letters comes back whole", odd?.directory == "Büro & Co")
        let refused = [
            "supersurfer://profile/edge",
            "supersurfer://profile/edge/a/b",
            "supersurfer://profile/edge/a%2Fb",
            "supersurfer://profile/edge/%2E%2E",
            "supersurfer://profile/edge/Default?x=1",
            "supersurfer://profile/edge/Default#x",
            "supersurfer://other/edge/Default",
            "supersurfer://profile/edge/a%0Ab",
            "https://profile/edge/Default",
        ]
        check(
            "dock shortcut: anything else is no such link",
            refused.allSatisfy { text in URL(string: text).flatMap { Rules.target(of: $0) } == nil }
        )
        check("dock shortcut: no link for a folder that is a path", Rules.link(browser: "edge", directory: "a/b") == nil)

        check("dock shortcut: a word for the shell", Rules.shellQuoted("it's $HOME") == "'it'\\''s $HOME'")
        let script = Rules.script(
            link: "supersurfer://profile/edge/Profile%201",
            superSurfer: "/Applications/SuperSurfer.app",
            browserPath: "/Applications/Microsoft Edge.app",
            launchArguments: ["--profile-directory=Profile 1"]
        )
        check(
            "dock shortcut: the script asks SuperSurfer and can do without it",
            script.hasPrefix("#!/bin/sh\n")
                && script.contains("\nlink='supersurfer://profile/edge/Profile%201'\n")
                && script.contains("\n/usr/bin/open -g -a '/Applications/SuperSurfer.app' \"$link\" 2>/dev/null && exit 0\n")
                && script.hasSuffix(
                    "\nexec /usr/bin/open -n -a '/Applications/Microsoft Edge.app' --args '--profile-directory=Profile 1'\n"
                )
        )

        check("dock shortcut: named after browser and profile", Rules.title(browser: "Edge", profile: "Work") == "Edge Work")
        check(
            "dock shortcut: a name the Finder can take",
            Rules.title(browser: "Edge", profile: " a/b:c \n d ") == "Edge a-b-c d"
        )
        check(
            "dock shortcut: an identifier of its own",
            Rules.bundleIdentifier(browser: "edge-beta", directory: "Profile 1")
                == "dev.supersurfer.shortcut.edge-beta.Profile-1"
        )

        let names = ["Personal", "Work", "Dev", "Web", "Profile 2", "Person 12"]
        check(
            "dock shortcut: letters for the badge",
            Rules.badge(for: "Personal", among: ["Personal", "Work", "Dev"]) == "P"
                && Rules.badge(for: "dev", among: ["Personal", "dev"]) == "D"
                && Rules.badge(for: "Work", among: names) == "Wo"
                && Rules.badge(for: "Web", among: names) == "We"
                && Rules.badge(for: "Profile 2", among: names) == "P2"
                && Rules.badge(for: "Person 12", among: names) == "P12"
                && Rules.badge(for: "  ", among: names) == "?"
        )

        let signedIn = ["Ada (Work)", "Work", "Ada"]
        check(
            "dock shortcut: the menu entry of a profile",
            Rules.entry(for: signedIn, named: "Work", in: ["Ada", "Ada (Work)", "Dev"]) == 1
                && Rules.entry(for: signedIn, named: "Work", in: ["Personal", "Work"]) == 1
                && Rules.entry(for: ["Work"], named: "Work", in: ["Personal", " Work "]) == 1
                && Rules.entry(for: ["Work"], named: "Work", in: ["Ada (Work)", "Work"]) == 1
        )
        check(
            "dock shortcut: no entry where two go by the name, or none",
            Rules.entry(for: ["Work"], named: "Work", in: ["Work", "Work"]) == nil
                && Rules.entry(for: ["Ada", "Work"], named: "Work", in: ["Ada", "Ada", "Work"]) == nil
                && Rules.entry(for: ["Work"], named: "Work", in: ["Personal"]) == nil
                && Rules.entry(for: [], named: "", in: ["Personal"]) == nil
        )
        check(
            "dock shortcut: a name dressed up in a way nobody foresaw is still found",
            Rules.entry(for: ["Work"], named: "Work", in: ["Personal", "Work - ada@example.com"]) == 1
                && Rules.entry(for: ["Work"], named: "Work", in: ["Ada (Work)", "Ada (Dev)"]) == 0
                && Rules.entry(for: ["Work"], named: "Work", in: ["HomeWork", "Work2", "Personal"]) == nil
                && Rules.entry(for: ["Work"], named: "Work", in: ["Ada (Work)", "Bob (Work)"]) == nil
        )

        let wrapped = Rules.icns([(pixels: 128, png: Data([1, 2, 3]))])
        check(
            "dock shortcut: an icon file around its images",
            wrapped == Data([0x69, 0x63, 0x6E, 0x73, 0, 0, 0, 19, 0x69, 0x63, 0x30, 0x37, 0, 0, 0, 11, 1, 2, 3])
                && Rules.icns([(pixels: 100, png: Data([1]))]) == nil
        )

        let reply = EngineBridge().shortcuts()
        check("dock shortcut: the engine's list decodes", reply?.ok == true && reply?.browsers != nil)

        // The badge is drawn where it should be: in the lower right corner,
        // which is the lower part of the picture when read from the top.
        let pixels = 128
        let calculator = "/System/Applications/Calculator.app"
        if let picture = ShortcutIcon.bitmap(appPath: calculator, badge: "E", color: 1, pixels: pixels) {
            let frame = ShortcutIcon.badgeFrame(side: CGFloat(pixels))
            let fill = ShortcutIcon.palette[1]
            func isFill(_ x: CGFloat, fromTop y: CGFloat) -> Bool {
                guard let found = picture.colorAt(x: Int(x), y: Int(y)) else {
                    return false
                }
                return abs(found.redComponent - fill.red) < 0.03
                    && abs(found.greenComponent - fill.green) < 0.03
                    && abs(found.blueComponent - fill.blue) < 0.03
                    && found.alphaComponent > 0.97
            }
            // Left of the letter, at the height of the badge's middle.
            let x = frame.minX + frame.width * 0.14
            let fromTop = CGFloat(pixels) - frame.midY
            check(
                "dock shortcut: the badge is in the lower right corner",
                isFill(x, fromTop: fromTop) && !isFill(x, fromTop: frame.midY)
            )
        } else {
            check("dock shortcut: an icon can be drawn", false)
        }

        // Written to the scratch HOME and read back.
        let work = ShortcutProfile(
            name: "Work",
            directory: "Profile 1",
            menuTitles: ["Ada (Work)", "Work"],
            launchArgs: ["--profile-directory=Profile 1"]
        )
        let web = ShortcutProfile(
            name: "Work",
            directory: "Profile 2",
            menuTitles: ["Work"],
            launchArgs: ["--profile-directory=Profile 2"]
        )
        let edge = ShortcutBrowser(
            id: "edge",
            name: "Microsoft Edge",
            shortName: "Edge",
            appPath: calculator,
            bundleId: nil,
            profiles: [work, web]
        )
        let folder = ProfileShortcuts.folder
        do {
            let first = try ProfileShortcut.write(browser: edge, profile: work, into: folder, superSurfer: "/tmp/S.app")
            check(
                "dock shortcut: written where shortcuts are kept",
                first.bundle.path == folder.appendingPathComponent("Edge Work.app").path
                    && first.isFor(browser: "edge", directory: "Profile 1")
                    && first.menuTitles == ["Ada (Work)", "Work"]
                    && first.launchArguments == ["--profile-directory=Profile 1"]
                    && first.browserPath == calculator
            )
            let executable = first.bundle.appendingPathComponent("Contents/MacOS/shortcut").path
            let info = NSDictionary(contentsOf: first.bundle.appendingPathComponent("Contents/Info.plist"))
            check(
                "dock shortcut: an app the Dock can start",
                FileManager.default.isExecutableFile(atPath: executable)
                    && info?["CFBundleExecutable"] as? String == "shortcut"
                    && info?["CFBundlePackageType"] as? String == "APPL"
                    && info?["LSUIElement"] as? Bool == true
                    && info?["CFBundleIdentifier"] as? String == "dev.supersurfer.shortcut.edge.Profile-1"
            )
            let icon = try? Data(contentsOf: first.bundle.appendingPathComponent("Contents/Resources/shortcut.icns"))
            check(
                "dock shortcut: with an icon of its own",
                info?["CFBundleIconFile"] as? String == "shortcut" && icon?.prefix(4) == Data("icns".utf8)
            )

            let second = try ProfileShortcut.write(browser: edge, profile: web, into: folder, superSurfer: "/tmp/S.app")
            check(
                "dock shortcut: a second profile of the same name gets a name and a colour of its own",
                second.title == "Edge Work (Profile 2)" && second.color != first.color
            )
            let again = try ProfileShortcut.write(browser: edge, profile: work, into: folder, superSurfer: "/tmp/S.app")
            let all = ProfileShortcut.all(in: folder)
            check(
                "dock shortcut: written again it takes the place of the old one",
                all.count == 2 && again.color == first.color && all.map { $0.title } == ["Edge Work", "Edge Work (Profile 2)"]
            )
        } catch {
            check("dock shortcut: could be written (\(error.localizedDescription))", false)
        }
    }
}
