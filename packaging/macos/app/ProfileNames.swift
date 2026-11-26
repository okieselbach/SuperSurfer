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
/// Which name counts is for the engine to say (src/browser/shortcut_names.rs),
/// because config.js and rules.json may name a profile by it as well. This
/// keeps what the engine said, and finds the profile that is meant the way
/// the engine does. What a menu entry hands to the engine is still the
/// browser's name for the profile.
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
    static let empty = ProfileNames(browsers: [])

    init(browsers: [ShortcutBrowser]) {
        var profiles: [String: [Profile]] = [:]
        for browser in browsers {
            profiles[browser.id] = browser.profiles.map {
                Profile(name: $0.name, directory: $0.directory, chosen: $0.chosenName)
            }
        }
        self.profiles = profiles
    }

    /// As the browsers and the names of the Dock shortcuts are right now.
    /// The engine reads a handful of small files for this, so it is for the
    /// moment a menu is built and never for the way of a link.
    static func current(engine: EngineBridge) -> ProfileNames {
        return ProfileNames(browsers: engine.shortcuts()?.browsers ?? [])
    }

    /// The profile of a browser that `given` names. The engine looks for a
    /// profile of that name first, for one in a folder of that name after,
    /// and last for one its user calls that. So does this. Edge calls its
    /// second profile "Profile 2" and keeps it in the folder "Profile 1",
    /// so the order matters.
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
        if let kept = listed.first(where: { ProfileNames.engineSame($0.directory, given) }) {
            return kept
        }
        // The engine gives no two profiles of a browser one such name, and
        // none that is the name or the folder of another.
        return listed.first { profile in
            profile.chosen.map { ProfileNames.chosenSame($0, given) } ?? false
        }
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

    /// As the engine compares a name that was chosen with what config.js
    /// or rules.json has: the same way, once the letters are put together.
    /// A Mac's disk may hand "ü" back as a "u" and the dots after it, and
    /// the name of a shortcut comes from there.
    static func chosenSame(_ chosen: String, _ given: String) -> Bool {
        return engineSame(chosen, given)
            || engineSame(chosen.precomposedStringWithCanonicalMapping, given.precomposedStringWithCanonicalMapping)
    }

    // MARK: - Self-test

    static func selfTest(_ check: (String, Bool) -> Void, engine: EngineBridge) {
        check(
            "profile names: compared the way the engine does",
            engineSame("Work", "wORK") && !engineSame("Büro", "BÜRO") && !engineSame("Work", "Work ")
        )
        check(
            "profile names: a chosen name is compared with its letters put together",
            chosenSame("Caf\u{e9}", "cafe\u{301}") && chosenSame("Work", "wORK")
                && !chosenSame("Work", "Works") && !chosenSame("Büro", "BÜRO")
                && !engineSame("Caf\u{e9}", "Cafe\u{301}")
        )

        let calculator = "/System/Applications/Calculator.app"
        func profile(_ name: String, _ directory: String, _ chosen: String? = nil) -> ShortcutProfile {
            return ShortcutProfile(
                name: name,
                chosenName: chosen,
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
        // the folder "Profile 2" belongs to the profile after it. Two of the
        // four have a name the engine took from their shortcuts.
        let browser = edge([
            profile("DevEnv", "Profile 3"),
            profile("GMail", "Profile 2"),
            profile("Oliver", "Default", "Work"),
            profile("Profile 2", "Profile 1", "Personal"),
        ])
        let names = ProfileNames(browsers: [browser])
        check(
            "profile names: the name the engine has for a profile stands for it",
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
            "profile names: and one named the way its user calls it, after both",
            names.profile("Work", of: "edge")?.directory == "Default"
                && names.profile("personal", of: "edge")?.directory == "Profile 1"
                && names.shown("wORK", of: "edge") == "Work"
        )
        check(
            "profile names: a profile nobody gave a name keeps the browser's",
            names.shown("DevEnv", of: "edge") == "DevEnv" && names.shown("GMail", of: "edge") == "GMail"
        )
        check(
            "profile names: what is not known is shown as it is given",
            names.shown("Nobody", of: "edge") == "Nobody"
                && names.shown("Oliver", of: "firefox") == "Oliver"
                && ProfileNames.empty.shown("Oliver", of: "edge") == "Oliver"
        )
        check(
            "profile names: three ways of naming one profile",
            names.same("Profile 1", "Profile 2", of: "edge")
                && names.same("default", "Oliver", of: "edge")
                && names.same("work", "Oliver", of: "edge")
                && names.same("Work", "Default", of: "edge")
                && !names.same("Work", "Personal", of: "edge")
                && !names.same("Profile 2", "GMail", of: "edge")
                && names.same("work", "Work", of: "firefox")
                && !names.same("Work", "Home", of: "firefox")
        )
        check(
            "profile names: a browser with its profile",
            names.label(BrowserTarget(browserId: "edge", browser: "Microsoft Edge", profile: "Profile 1"))
                == "Microsoft Edge (Personal)"
                && names.label(BrowserTarget(browserId: "edge", browser: "Microsoft Edge", profile: "work"))
                == "Microsoft Edge (Work)"
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

        let twins = edge([profile("Work", "Profile 1"), profile("Work", "Profile 2")])
        let unsure = ProfileNames(browsers: [twins])
        check(
            "profile names: of two profiles with one name neither is guessed",
            unsure.profile("Work", of: "edge") == nil
                && unsure.shown("Work", of: "edge") == "Work"
                && unsure.same("work", "Work", of: "edge")
                && unsure.profile("Profile 2", of: "edge")?.directory == "Profile 2"
        )

        selfTestBothEnds(check, engine: engine)
    }

    /// Both ends of a chosen name. The app writes a shortcut and gives it
    /// another name, as the menu does. The engine reads that, says what the
    /// profile is called now, and takes the name for the profile.
    private static func selfTestBothEnds(_ check: (String, Bool) -> Void, engine: EngineBridge) {
        // Chrome keeps its profile list under HOME, which is a scratch
        // folder here, so the profiles are these two wherever Chrome is.
        let home = ProfileShortcuts.folder.deletingLastPathComponent().deletingLastPathComponent()
        let chromeData = home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        let list = #"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 1":{"name":"Work"}}}}"#
        try? FileManager.default.createDirectory(at: chromeData, withIntermediateDirectories: true)
        try? Data(list.utf8).write(to: chromeData.appendingPathComponent("Local State"))
        _ = engine.reload()

        func chrome() -> ShortcutBrowser? {
            return engine.shortcuts()?.browsers?.first { $0.id == "chrome" }
        }
        func personal(_ browser: ShortcutBrowser?) -> ShortcutProfile? {
            return browser?.profiles.first { $0.directory == "Default" }
        }
        guard let browser = chrome(), let profile = personal(browser) else {
            print("skip  profile names: the engine reads the shortcuts (no Google Chrome on this Mac)")
            return
        }
        do {
            let written = try ProfileShortcut.write(
                browser: browser,
                profile: profile,
                into: ProfileShortcuts.folder,
                superSurfer: "/tmp/S.app"
            )
            let asWritten = personal(chrome())
            check(
                "profile names: the name SuperSurfer gave a shortcut is no chosen one for the engine",
                written.title == "Chrome Personal" && asWritten != nil && asWritten?.chosenName == nil
            )

            _ = try written.renamed(to: "Chrome Büro")
            let names = ProfileNames.current(engine: engine)
            check(
                "profile names: the engine reads the name a shortcut was given",
                personal(chrome())?.chosenName == "Büro"
                    && names.shown("Personal", of: "chrome") == "Büro"
                    && names.shown("Default", of: "chrome") == "Büro"
                    && names.profile("büro", of: "chrome")?.directory == "Default"
                    && names.shown("Work", of: "chrome") == "Work"
            )
            let plan = engine.plan(url: "https://example.com/", inputUrl: nil, browserId: "chrome", profile: "büro")
            check(
                "profile names: and takes that name for the profile, as config.js may write it",
                plan?.ok == true && plan?.launch?.args.contains("--profile-directory=Default") == true
            )
            let other = engine.plan(url: "https://example.com/", inputUrl: nil, browserId: "chrome", profile: "Work")
            check(
                "profile names: the browser's own name for a profile works as before",
                other?.launch?.args.contains("--profile-directory=Profile 1") == true
            )
        } catch {
            check("profile names: a shortcut could be written (\(error.localizedDescription))", false)
        }
    }
}
