//! The names a user gave their browser profiles: the names of the Dock
//! shortcuts that the macOS app makes for them.
//!
//! A shortcut is a small app in `~/Applications/SuperSurfer Shortcuts`. It is
//! first called after browser and profile, "Edge Oliver", and its name is the
//! user's to change, in SuperSurfer's menu or in the Finder. A name that was
//! changed is what the user calls the profile. The menus show it, and
//! `config.js` and `rules.json` may name the profile by it: "edge:Work".
//!
//! Which name counts is decided here and nowhere else, so that the menus,
//! the routing and the command line agree.

use icu_normalizer::ComposingNormalizerBorrowed;

/// What a Dock shortcut says about itself, as far as names go. The macOS app
/// writes it into the shortcut's Info.plist (ProfileShortcuts.swift).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ShortcutNote {
    /// The app's name without ".app". This is the shortcut's name.
    pub title: String,
    /// The id of the browser and the folder of the profile it is for.
    pub browser: String,
    pub directory: String,
    /// What the browser called the profile when the shortcut was written.
    pub profile_name: Option<String>,
    /// The name inside the app. It follows `title` only once SuperSurfer has
    /// seen a rename that was made in the Finder.
    pub name_inside: Option<String>,
    /// What the browser is called, the short name first. Empty in a shortcut
    /// written before names could be chosen.
    pub browser_names: Vec<String>,
    /// Where the browser's app was when the shortcut was written.
    pub browser_path: Option<String>,
}

/// A profile as its browser has it.
#[derive(Debug, Clone, Copy)]
pub struct NamedProfile<'a> {
    pub name: &'a str,
    pub directory: &'a str,
}

/// File names come decomposed from a Mac's disk and composed from a
/// browser's profile list. Compared byte by byte, "Büro" would not be
/// "Büro".
fn composed(text: &str) -> String {
    ComposingNormalizerBorrowed::new_nfc()
        .normalize(text)
        .into_owned()
}

/// Whether a person would take two names for the same.
fn read_alike(one: &str, other: &str) -> bool {
    composed(one).to_lowercase() == composed(other).to_lowercase()
}

/// A name the Finder can take, made of what was typed or read: one line, no
/// "/" or ":", not hidden and not endless. Empty if nothing is left. The
/// same rule as `ProfileShortcutRules.fileName` in the app, which names the
/// shortcuts.
fn file_name(text: &str) -> String {
    let mut cleaned = String::new();
    let mut after_space = true;
    for character in text.chars() {
        if character.is_whitespace() {
            if !after_space {
                cleaned.push(' ');
            }
            after_space = true;
        } else if (character as u32) < 0x20 || character as u32 == 0x7F {
            continue;
        } else {
            cleaned.push(if character == '/' || character == ':' {
                '-'
            } else {
                character
            });
            after_space = false;
        }
    }
    if cleaned.ends_with(' ') {
        cleaned.pop();
    }
    if let Some(rest) = cleaned.strip_prefix('.') {
        cleaned = format!("_{rest}");
    }
    cleaned.chars().take(100).collect()
}

/// "Edge Work": what a shortcut is called until someone gives it another
/// name.
fn title(browser: &str, profile: &str) -> String {
    let name = file_name(&format!("{browser} {profile}"));
    if name.is_empty() {
        "Shortcut".to_string()
    } else {
        name
    }
}

/// The names SuperSurfer gives a shortcut by itself: after browser and
/// profile, and with the profile's folder behind it where two profiles go by
/// one name. Any other name is one that somebody chose.
fn own_titles(browser: &str, profile: &str, directory: &str) -> [String; 2] {
    [
        title(browser, profile),
        title(browser, &format!("{profile} ({directory})")),
    ]
}

/// `text` without `prefix` in front, capitals aside. None if it does not
/// begin with it.
fn without_front<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    let mut rest = text;
    for wanted in prefix.chars() {
        let mut characters = rest.chars();
        let found = characters.next()?;
        if !found.to_lowercase().eq(wanted.to_lowercase()) {
            return None;
        }
        rest = characters.as_str();
    }
    Some(rest)
}

/// What a shortcut's name says about the profile: the name without the
/// browser in front. "Edge Work" is "Work", and so is "Microsoft Edge
/// Work". A name that is nothing but the browser, or does not begin with
/// it, is taken whole. The letters on the shortcut's icon come from the
/// same reading.
fn label(title: &str, browser_names: &[&str]) -> String {
    let name = title.trim();
    // The longest first: "Edge Beta Work" is "Work" for Edge Beta.
    let mut browsers: Vec<&str> = browser_names
        .iter()
        .copied()
        .filter(|browser| !browser.is_empty())
        .collect();
    browsers.sort_by_key(|browser| std::cmp::Reverse(browser.chars().count()));
    for browser in browsers {
        // With the space: "Edgewise" does not begin with "Edge".
        let Some(rest) = without_front(name, &format!("{browser} ")) else {
            continue;
        };
        let rest = rest.trim();
        if !rest.is_empty() {
            return rest.to_string();
        }
    }
    name.to_string()
}

/// What the browser was called when the shortcut was written, the short
/// name first. A shortcut from before names could be chosen did not note
/// it. Its first name was the browser's short name and the profile's, which
/// gives the short name back.
fn noted_browser_name(note: &ShortcutNote) -> Option<String> {
    if let Some(first) = note.browser_names.first() {
        return Some(first.clone());
    }
    let inside = note.name_inside.as_deref().unwrap_or(&note.title);
    let profile = note.profile_name.as_deref().unwrap_or(&note.directory);
    let ending = format!(" {profile}");
    if inside.len() > ending.len() && inside.ends_with(&ending) {
        return Some(inside[..inside.len() - ending.len()].to_string());
    }
    let path = note.browser_path.as_deref()?;
    std::path::Path::new(path)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .map(str::to_string)
}

/// The name a person gave the shortcut of `profile`, without the browser in
/// front: "Work" for "Edge Work". None while the shortcut has a name that
/// SuperSurfer gave it. That includes the name it got before the profile
/// was renamed in the browser, which nobody chose.
fn candidate(
    note: &ShortcutNote,
    profile: NamedProfile<'_>,
    short_name: &str,
    display_name: &str,
) -> Option<String> {
    let shortcut_title = composed(&note.title);
    let written_as = note.profile_name.as_deref().unwrap_or(&note.directory);
    let mut given: Vec<String> = own_titles(short_name, profile.name, profile.directory).into();
    given.extend(own_titles(short_name, written_as, &note.directory));
    if let Some(noted) = noted_browser_name(note) {
        given.extend(own_titles(&noted, written_as, &note.directory));
    }
    if given.iter().any(|own| composed(own) == shortcut_title) {
        return None;
    }
    let label = label(&shortcut_title, &[short_name, display_name]);
    if label.is_empty() || read_alike(&label, profile.name) {
        None
    } else {
        Some(label)
    }
}

/// The names the user chose for the profiles of one browser, in the order
/// of `profiles`. `notes` are the shortcuts there are, for any browser.
///
/// Two entries of one list must not read alike, and a name in `config.js`
/// must mean one profile. So a chosen name is left out where another
/// profile of the browser goes by it, is kept in a folder of that name, or
/// was given the same name.
pub fn chosen_names(
    browser_id: &str,
    short_name: &str,
    display_name: &str,
    profiles: &[NamedProfile<'_>],
    notes: &[ShortcutNote],
) -> Vec<Option<String>> {
    let candidates: Vec<Option<String>> = profiles
        .iter()
        .map(|profile| {
            notes
                .iter()
                .find(|note| note.browser == browser_id && note.directory == profile.directory)
                .and_then(|note| candidate(note, *profile, short_name, display_name))
        })
        .collect();
    candidates
        .iter()
        .enumerate()
        .map(|(index, chosen)| {
            let name = chosen.as_deref()?;
            let taken = profiles.iter().enumerate().any(|(other, profile)| {
                other != index
                    && (read_alike(name, profile.name)
                        || read_alike(name, profile.directory)
                        || candidates[other]
                            .as_deref()
                            .is_some_and(|theirs| read_alike(name, theirs)))
            });
            (!taken).then(|| name.to_string())
        })
        .collect()
}

/// Whether `wanted`, as `config.js` or `rules.json` has it, is this chosen
/// name. Capitals of the letters A to Z aside, as for the browser's names.
pub fn is_chosen_name(chosen: &str, wanted: &str) -> bool {
    chosen.eq_ignore_ascii_case(wanted) || composed(chosen).eq_ignore_ascii_case(&composed(wanted))
}

/// A name of a browser or of a profile folder as a shortcut may carry it:
/// one path component, with nothing in it that means something to a shell,
/// a path or a terminal. The same rule as `ProfileShortcutRules.isPlainName`
/// in the app, which reads no shortcut that fails it.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn is_plain_name(name: &str) -> bool {
    !name.is_empty()
        && name.chars().count() <= 128
        && name != "."
        && name != ".."
        && name == name.trim()
        && !name.chars().any(|character| {
            (character as u32) < 0x20
                || character as u32 == 0x7F
                || character == '/'
                || character == ':'
        })
}

/// The shortcuts in `folder`, by name. Empty where there is no such folder.
#[cfg(target_os = "macos")]
pub fn read_shortcuts(folder: &std::path::Path) -> Vec<ShortcutNote> {
    let Ok(entries) = std::fs::read_dir(folder) else {
        return Vec::new();
    };
    let mut notes = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|ending| ending.to_str()) != Some("app") {
            continue;
        }
        let Some(title) = path.file_stem().and_then(|stem| stem.to_str()) else {
            continue;
        };
        let Ok(file) = std::fs::File::open(path.join("Contents/Info.plist")) else {
            continue;
        };
        let Ok(value) = plist::from_reader::<_, plist::Value>(file) else {
            continue;
        };
        let Some(info) = value.as_dictionary() else {
            continue;
        };
        let text = |key: &str| {
            info.get(key)
                .and_then(|value| value.as_string())
                .map(str::to_string)
        };
        // An app without these three is none that SuperSurfer wrote.
        let (Some(browser), Some(directory), Some(browser_path)) = (
            text("SuperSurferBrowser"),
            text("SuperSurferProfileDirectory"),
            text("SuperSurferBrowserPath"),
        ) else {
            continue;
        };
        if !is_plain_name(&browser) || !is_plain_name(&directory) {
            continue;
        }
        notes.push(ShortcutNote {
            title: title.to_string(),
            browser,
            directory,
            profile_name: text("SuperSurferProfileName"),
            name_inside: text("CFBundleName"),
            browser_names: info
                .get("SuperSurferBrowserNames")
                .and_then(|value| value.as_array())
                .map(|names| {
                    names
                        .iter()
                        .filter_map(|name| name.as_string().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default(),
            browser_path: Some(browser_path),
        });
    }
    notes.sort_by(|one, other| one.title.cmp(&other.title));
    notes
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(title: &str, directory: &str, written_as: &str) -> ShortcutNote {
        ShortcutNote {
            title: title.to_string(),
            browser: "edge".to_string(),
            directory: directory.to_string(),
            profile_name: Some(written_as.to_string()),
            name_inside: Some(title.to_string()),
            browser_names: vec!["Edge".to_string(), "Microsoft Edge".to_string()],
            browser_path: Some("/Applications/Microsoft Edge.app".to_string()),
        }
    }

    fn profile<'a>(name: &'a str, directory: &'a str) -> NamedProfile<'a> {
        NamedProfile { name, directory }
    }

    fn chosen(profiles: &[NamedProfile<'_>], notes: &[ShortcutNote]) -> Vec<Option<String>> {
        chosen_names("edge", "Edge", "Microsoft Edge", profiles, notes)
    }

    /// Edge counts its profiles from 1 and their folders from "Default": the
    /// profile it calls "Profile 2" is in the folder "Profile 1".
    fn four_profiles() -> [NamedProfile<'static>; 4] {
        [
            profile("DevEnv", "Profile 3"),
            profile("GMail", "Profile 2"),
            profile("Oliver", "Default"),
            profile("Profile 2", "Profile 1"),
        ]
    }

    #[test]
    fn a_name_that_was_given_stands_for_the_profile() {
        let notes = [
            note("Edge DevEnv", "Profile 3", "DevEnv"),
            note("Edge Personal", "Profile 1", "Profile 2"),
            note("Edge Work", "Default", "Oliver"),
        ];
        assert_eq!(
            chosen(&four_profiles(), &notes),
            [
                None,
                None,
                Some("Work".to_string()),
                Some("Personal".to_string())
            ]
        );
        // A shortcut of another browser is none of this one's.
        let mut chrome = note("Chrome Work", "Default", "Person 1");
        chrome.browser = "chrome".to_string();
        assert_eq!(
            chosen(&four_profiles(), &[chrome]),
            [None, None, None, None]
        );
    }

    #[test]
    fn a_name_supersurfer_gave_is_no_chosen_one() {
        // The profile was renamed in the browser since. The shortcut still
        // has the name it was written under.
        let profiles = [profile("Development", "Profile 3")];
        assert_eq!(
            chosen(&profiles, &[note("Edge DevEnv", "Profile 3", "DevEnv")]),
            [None]
        );
        // Two profiles of one name: the second shortcut got the folder
        // behind its name.
        let twins = [profile("Work", "Profile 1"), profile("Work", "Profile 2")];
        let notes = [
            note("Edge Work", "Profile 1", "Work"),
            note("Edge Work (Profile 2)", "Profile 2", "Work"),
        ];
        assert_eq!(chosen(&twins, &notes), [None, None]);
        // Renamed to what the browser calls the profile anyway.
        let profiles = [profile("Oliver", "Default")];
        assert_eq!(
            chosen(
                &profiles,
                &[note("Microsoft Edge oliver", "Default", "Oliver")]
            ),
            [None]
        );
    }

    #[test]
    fn a_name_is_left_out_where_it_would_mean_two_profiles() {
        // Another profile goes by it.
        let notes = [
            note("Edge GMail", "Profile 3", "DevEnv"),
            note("Edge Work", "Default", "Oliver"),
        ];
        assert_eq!(
            chosen(&four_profiles(), &notes),
            [None, None, Some("Work".to_string()), None]
        );
        // Two shortcuts carry it.
        let notes = [
            note("Edge Work", "Default", "Oliver"),
            note("Microsoft Edge work", "Profile 3", "DevEnv"),
        ];
        assert_eq!(chosen(&four_profiles(), &notes), [None, None, None, None]);
        // Another profile is kept in a folder of that name, which config.js
        // may name it by.
        let notes = [note("Edge Profile 2", "Default", "Oliver")];
        assert_eq!(chosen(&four_profiles(), &notes), [None, None, None, None]);
        // Its own folder is no other profile.
        let notes = [note("Edge Default", "Default", "Oliver")];
        assert_eq!(
            chosen(&four_profiles(), &notes),
            [None, None, Some("Default".to_string()), None]
        );
    }

    #[test]
    fn names_from_the_disk_and_from_the_browser_are_compared_composed() {
        // "ü" as one character, and as "u" with the dots after it, which is
        // how a Mac's disk hands a file name back.
        let profiles = [
            profile("B\u{fc}ro", "Default"),
            profile("Oliver", "Profile 1"),
        ];
        let notes = [
            note("Edge Bu\u{308}ro", "Default", "B\u{fc}ro"),
            note("Edge Cafe\u{301}", "Profile 1", "Oliver"),
        ];
        assert_eq!(
            chosen(&profiles, &notes),
            [None, Some("Caf\u{e9}".to_string())]
        );
        assert!(is_chosen_name("Caf\u{e9}", "cafe\u{301}"));
        assert!(is_chosen_name("Work", "wORK"));
        assert!(!is_chosen_name("Work", "Works"));
    }

    #[test]
    fn a_shortcut_from_before_names_could_be_chosen() {
        // It notes neither what the browser is called nor, here, the name
        // inside it that a later version writes.
        let mut old = note("Edge Zuhause", "Profile 1", "Profile 2");
        old.browser_names = Vec::new();
        old.name_inside = Some("Edge Profile 2".to_string());
        assert_eq!(noted_browser_name(&old).as_deref(), Some("Edge"));
        assert_eq!(
            chosen(&four_profiles(), &[old.clone()]),
            [None, None, None, Some("Zuhause".to_string())]
        );
        old.title = "Edge Profile 2".to_string();
        assert_eq!(chosen(&four_profiles(), &[old]), [None, None, None, None]);
    }

    #[test]
    fn the_name_without_the_browser_in_front() {
        let edge = ["Edge", "Microsoft Edge"];
        assert_eq!(label("Edge Work", &edge), "Work");
        assert_eq!(label("microsoft edge  Personal", &edge), "Personal");
        assert_eq!(label("Work", &edge), "Work");
        assert_eq!(label("Edge", &edge), "Edge");
        assert_eq!(label("Edgewise", &edge), "Edgewise");
        assert_eq!(
            label("Edge Beta Dev", &["Edge Beta", "Microsoft Edge Beta"]),
            "Dev"
        );
    }

    #[test]
    fn what_a_shortcut_may_name_as_browser_or_folder() {
        assert!(is_plain_name("edge"));
        assert!(is_plain_name("Profile 1"));
        for name in [
            "", ".", "..", " edge", "edge ", "a/b", "a:b", "a\nb", "a\u{7f}",
        ] {
            assert!(!is_plain_name(name), "{name:?}");
        }
        assert!(!is_plain_name(&"x".repeat(129)));
    }

    #[test]
    fn a_name_the_finder_can_take() {
        assert_eq!(title("Edge", "Work"), "Edge Work");
        assert_eq!(title("Edge", " a/b:c \n d "), "Edge a-b-c d");
        assert_eq!(file_name(".hidden"), "_hidden");
        assert_eq!(file_name(" \n "), "");
        assert_eq!(title("", ""), "Shortcut");
        assert_eq!(
            own_titles("Edge", "Work", "Profile 2"),
            ["Edge Work".to_string(), "Edge Work (Profile 2)".to_string()]
        );
    }
}
