import Foundation

/// A browser and, where one is named, a profile of it: where a link goes.
struct BrowserTarget {
    let browserId: String
    let browser: String
    /// As config.js, rules.json or the browser itself names the profile.
    let profile: String?

    /// In those terms, which is how logs and traces put it. The menus show
    /// a profile under the name `ProfileNames` has for it.
    var label: String {
        return Format.browserLabel(browser, profile: profile)
    }
}

extension Decision {
    /// Where the rules send the link.
    var target: BrowserTarget {
        return BrowserTarget(browserId: browserId, browser: browser, profile: profile)
    }
}

/// What SuperSurfer's menus call the profiles of a browser.
///
/// A profile has the name its browser gives it. Someone who made a Dock
/// shortcut for it and gave that a name of their own knows the profile by
/// that name, so the menus show it: "Work" where the browser says "Oliver".
///
/// This is about what is shown and nothing else. config.js, rules.json and
/// the engine go on naming a profile the browser's way, by its name or by
/// its folder, and what a menu entry hands to the engine is the browser's
/// name for the profile.
struct ProfileNames {
    /// One profile of a browser, as far as its names go.
    struct Profile {
        /// As the browser calls it.
        let name: String
        /// The folder the browser keeps it in.
        let directory: String
        /// As the person calls it, where that is something else.
        let chosen: String?

        var shown: String {
            return chosen ?? name
        }
    }

    /// By browser id. Only browsers whose profiles can have a shortcut are
    /// in here. A profile of any other browser is shown as it is given.
    private let profiles: [String: [Profile]]

    /// Nothing is known: every profile is shown as it is given.
    static let empty = ProfileNames(browsers: [], shortcuts: [])

    init(browsers: [ShortcutBrowser], shortcuts: [ProfileShortcut]) {
        var profiles: [String: [Profile]] = [:]
        for browser in browsers {
            let candidates: [String?] = browser.profiles.map { profile in
                shortcuts
                    .first { $0.isFor(browser: browser.id, directory: profile.directory) }
                    .flatMap { ProfileNames.chosenName(of: $0, for: profile, in: browser) }
            }
            profiles[browser.id] = browser.profiles.indices.map { index -> Profile in
                let profile = browser.profiles[index]
                var chosen = candidates[index]
                // Two entries of one list must not read alike. A chosen name
                // that another profile of the browser goes by, or that was
                // chosen for another profile as well, is left out.
                if let name = chosen {
                    let taken = browser.profiles.indices.contains { other in
                        guard other != index else {
                            return false
                        }
                        if ProfileNames.readAlike(name, browser.profiles[other].name) {
                            return true
                        }
                        return candidates[other].map { ProfileNames.readAlike(name, $0) } ?? false
                    }
                    if taken {
                        chosen = nil
                    }
                }
                return Profile(name: profile.name, directory: profile.directory, chosen: chosen)
            }
        }
        self.profiles = profiles
    }

    /// As the browsers and the folder of shortcuts are right now. This asks
    /// the engine and reads a handful of small files, so it is for the
    /// moment a menu is built and never for the way of a link.
    static func current(engine: EngineBridge) -> ProfileNames {
        let browsers = engine.shortcuts()?.browsers ?? []
        guard !browsers.isEmpty else {
            return .empty
        }
        return ProfileNames(browsers: browsers, shortcuts: ProfileShortcut.all(in: ProfileShortcuts.folder))
    }

    /// The name a person gave the shortcut of `profile`, without the browser
    /// in front: "Work" for "Edge Work". Nil while the shortcut has a name
    /// SuperSurfer gave it. That includes the name it got before the profile
    /// was renamed in the browser, which nobody chose.
    static func chosenName(
        of shortcut: ProfileShortcut,
        for profile: ShortcutProfile,
        in browser: ShortcutBrowser
    ) -> String? {
        var given = ProfileShortcutRules.ownTitles(
            browser: browser.shortName,
            profile: profile.name,
            directory: profile.directory
        )
        var written = [browser.shortName]
        if let noted = shortcut.knownBrowserNames.first {
            written.append(noted)
        }
        for name in written {
            given += ProfileShortcutRules.ownTitles(
                browser: name,
                profile: shortcut.profileName,
                directory: shortcut.directory
            )
        }
        guard !given.contains(shortcut.title) else {
            return nil
        }
        // The same reading of the name that the letters on the shortcut's
        // icon come from.
        let label = ProfileShortcutRules.label(
            of: shortcut.title,
            browserNames: [browser.shortName, browser.name]
        )
        return label.isEmpty || readAlike(label, profile.name) ? nil : label
    }

    /// The profile of a browser that `given` names. The engine looks for a
    /// profile of that name first and for one in a folder of that name
    /// after, and so does this. Edge calls its second profile "Profile 2"
    /// and keeps it in the folder "Profile 1", so the order matters.
    func profile(_ given: String, of browser: String) -> Profile? {
        guard let listed = profiles[browser] else {
            return nil
        }
        let named = listed.filter { ProfileNames.engineSame($0.name, given) }
        if !named.isEmpty {
            // Two profiles of one name: which of them the engine takes is
            // not for a menu to guess.
            return named.count == 1 ? named[0] : nil
        }
        return listed.first { ProfileNames.engineSame($0.directory, given) }
    }

    /// What the menus show for a profile that is named as `given`.
    func shown(_ given: String, of browser: String) -> String {
        return profile(given, of: browser)?.shown ?? given
    }

    /// Whether two ways of naming a profile of a browser mean the same one:
    /// config.js may name the folder where a list has the name.
    func same(_ one: String, _ other: String, of browser: String) -> Bool {
        if let first = profile(one, of: browser), let second = profile(other, of: browser) {
            return first.directory == second.directory
        }
        return ProfileNames.engineSame(one, other)
    }

    /// "Microsoft Edge (Work)": a browser with its profile as the menus
    /// show it.
    func label(_ target: BrowserTarget) -> String {
        let profile = target.profile.map { shown($0, of: target.browserId) }
        return Format.browserLabel(target.browser, profile: profile)
    }

    /// The profiles of a browser as a menu lists them. `given` is what the
    /// engine takes and `shown` what the entry says. Where a name was chosen
    /// the list is put in the order of what it says.
    func listed(_ given: [String], of browser: String) -> [(given: String, shown: String)] {
        let entries = given.map { (given: $0, shown: shown($0, of: browser)) }
        guard entries.contains(where: { $0.shown != $0.given }) else {
            return entries
        }
        return entries.enumerated()
            .sorted { one, other in
                let first = one.element.shown.lowercased()
                let second = other.element.shown.lowercased()
                return first == second ? one.offset < other.offset : first < second
            }
            .map { $0.element }
    }

    /// As the engine compares what a profile is called: the capitals of the
    /// letters A to Z aside, and nothing else.
    static func engineSame(_ one: String, _ other: String) -> Bool {
        func folded(_ text: String) -> [UInt8] {
            return text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        }
        return folded(one) == folded(other)
    }

    /// Whether a person would take two names for the same.
    private static func readAlike(_ one: String, _ other: String) -> Bool {
        return one.caseInsensitiveCompare(other) == .orderedSame
    }

    // MARK: - Self-test

    static func selfTest(_ check: (String, Bool) -> Void) {
        check(
            "profile names: compared the way the engine does",
            engineSame("Work", "wORK") && !engineSame("Büro", "BÜRO") && !engineSame("Work", "Work ")
        )

        let calculator = "/System/Applications/Calculator.app"
        func profile(_ name: String, _ directory: String) -> ShortcutProfile {
            return ShortcutProfile(
                name: name,
                directory: directory,
                menuTitles: [name],
                launchArgs: ["--profile-directory=\(directory)"]
            )
        }
        func edge(_ profiles: [ShortcutProfile]) -> ShortcutBrowser {
            return ShortcutBrowser(
                id: "edge",
                name: "Microsoft Edge",
                shortName: "Edge",
                appPath: calculator,
                bundleId: nil,
                profiles: profiles
            )
        }
        // Edge counts its profiles from 1 and their folders from "Default".
        // The profile it calls "Profile 2" is in the folder "Profile 1", and
        // the folder "Profile 2" belongs to the profile after it.
        let oliver = profile("Oliver", "Default")
        let second = profile("Profile 2", "Profile 1")
        let mail = profile("GMail", "Profile 2")
        let dev = profile("DevEnv", "Profile 3")
        let browser = edge([dev, mail, oliver, second])

        // Next to the folder of shortcuts in the scratch HOME, so that the
        // shortcuts of the other tests are not in the way.
        let folder = ProfileShortcuts.folder
            .deletingLastPathComponent()
            .appendingPathComponent("SuperSurfer Names Test", isDirectory: true)
        do {
            _ = try ProfileShortcut
                .write(browser: browser, profile: oliver, into: folder, superSurfer: "/tmp/S.app")
                .renamed(to: "Edge Work")
            _ = try ProfileShortcut
                .write(browser: browser, profile: second, into: folder, superSurfer: "/tmp/S.app")
                .renamed(to: "Edge Personal")
            let kept = try ProfileShortcut.write(browser: browser, profile: dev, into: folder, superSurfer: "/tmp/S.app")

            let names = ProfileNames(browsers: [browser], shortcuts: ProfileShortcut.all(in: folder))
            check(
                "profile names: the name of its shortcut stands for a profile",
                names.shown("Oliver", of: "edge") == "Work"
                    && names.shown("oliver", of: "edge") == "Work"
                    && names.shown("Profile 2", of: "edge") == "Personal"
            )
            check(
                "profile names: a profile named by its folder is found, after the names",
                names.shown("Default", of: "edge") == "Work"
                    && names.shown("Profile 1", of: "edge") == "Personal"
                    && names.shown("Profile 3", of: "edge") == "DevEnv"
                    && names.profile("Profile 2", of: "edge")?.directory == "Profile 1"
            )
            check(
                "profile names: a shortcut that kept its name changes nothing",
                names.shown("DevEnv", of: "edge") == "DevEnv" && names.shown("GMail", of: "edge") == "GMail"
            )
            check(
                "profile names: what is not known is shown as it is given",
                names.shown("Nobody", of: "edge") == "Nobody"
                    && names.shown("Oliver", of: "firefox") == "Oliver"
                    && ProfileNames.empty.shown("Oliver", of: "edge") == "Oliver"
            )
            check(
                "profile names: two ways of naming one profile",
                names.same("Profile 1", "Profile 2", of: "edge")
                    && names.same("default", "Oliver", of: "edge")
                    && !names.same("Profile 2", "GMail", of: "edge")
                    && names.same("work", "Work", of: "firefox")
                    && !names.same("Work", "Home", of: "firefox")
            )
            check(
                "profile names: a browser with its profile",
                names.label(BrowserTarget(browserId: "edge", browser: "Microsoft Edge", profile: "Profile 1"))
                    == "Microsoft Edge (Personal)"
                    && names.label(BrowserTarget(browserId: "edge", browser: "Microsoft Edge", profile: nil))
                    == "Microsoft Edge"
                    && names.label(BrowserTarget(browserId: "firefox", browser: "Firefox", profile: "Work"))
                    == "Firefox (Work)"
            )
            let listed = names.listed(["DevEnv", "GMail", "Oliver", "Profile 2"], of: "edge")
            check(
                "profile names: a list is in the order of the names it shows",
                listed.map { $0.shown } == ["DevEnv", "GMail", "Personal", "Work"]
                    && listed.map { $0.given } == ["DevEnv", "GMail", "Profile 2", "Oliver"]
            )
            let untouched = ProfileNames.empty.listed(["b", "A"], of: "edge")
            check(
                "profile names: and as it came where no name was chosen",
                untouched.map { $0.given } == ["b", "A"] && untouched.map { $0.shown } == ["b", "A"]
            )

            // The profile was renamed in the browser. Its shortcut still has
            // the name SuperSurfer gave it, and that is not a chosen one.
            let renamed = edge([profile("Development", "Profile 3"), mail, oliver, second])
            let later = ProfileNames(browsers: [renamed], shortcuts: ProfileShortcut.all(in: folder))
            check(
                "profile names: a name the shortcut got from SuperSurfer is no chosen one",
                later.shown("Profile 3", of: "edge") == "Development"
                    && later.shown("Development", of: "edge") == "Development"
                    && later.shown("Oliver", of: "edge") == "Work"
            )

            let other = try kept.renamed(to: "Edge GMail")
            let clash = ProfileNames(browsers: [browser], shortcuts: ProfileShortcut.all(in: folder))
            check(
                "profile names: a name that another profile has is not taken",
                clash.shown("DevEnv", of: "edge") == "DevEnv"
                    && clash.shown("GMail", of: "edge") == "GMail"
                    && clash.shown("Oliver", of: "edge") == "Work"
            )
            _ = try other.renamed(to: "Microsoft Edge work")
            let twice = ProfileNames(browsers: [browser], shortcuts: ProfileShortcut.all(in: folder))
            check(
                "profile names: nor one that two shortcuts carry",
                twice.shown("DevEnv", of: "edge") == "DevEnv"
                    && twice.shown("Oliver", of: "edge") == "Oliver"
                    && twice.shown("Profile 2", of: "edge") == "Personal"
            )
        } catch {
            check("profile names: shortcuts could be written (\(error.localizedDescription))", false)
        }

        let twins = edge([profile("Work", "Profile 1"), profile("Work", "Profile 2")])
        let unsure = ProfileNames(browsers: [twins], shortcuts: [])
        check(
            "profile names: of two profiles with one name neither is guessed",
            unsure.profile("Work", of: "edge") == nil
                && unsure.shown("Work", of: "edge") == "Work"
                && unsure.same("work", "Work", of: "edge")
                && unsure.profile("Profile 2", of: "edge")?.directory == "Profile 2"
        )
    }
}
