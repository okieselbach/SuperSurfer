use anyhow::{Context as _, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
use std::fs;
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
use std::path::Path;
#[cfg(any(target_os = "macos", target_os = "linux"))]
use std::path::PathBuf;

#[cfg(target_os = "windows")]
#[path = "discover_windows.rs"]
mod discover_windows;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ProfileKind {
    None,
    Gecko,
    Chromium,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BrowserProfile {
    pub name: String,
    pub directory: Option<String>,
    pub path: Option<String>,
    /// What a Chromium browser may call this profile in its own profile
    /// menu, most likely first. Empty for other browsers, and in a cache
    /// file written before this was read.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub menu_titles: Vec<String>,
}

impl BrowserProfile {
    /// The titles to look for in the browser's profile menu. A list read
    /// from a cache file written before the titles were kept has none; until
    /// the next scan the profile's name is the best guess.
    pub fn menu_titles_or_name(&self) -> Vec<String> {
        if self.menu_titles.is_empty() {
            vec![self.name.clone()]
        } else {
            self.menu_titles.clone()
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BrowserInstall {
    pub id: String,
    pub display_name: String,
    pub app_path: Option<String>,
    pub bundle_id: Option<String>,
    pub profiles: Vec<BrowserProfile>,
}

#[derive(Debug, Clone)]
pub struct ResolvedBrowser {
    pub id: String,
    pub display_name: String,
    pub app_path: Option<String>,
    pub profile: Option<String>,
    pub profile_directory: Option<String>,
    pub private: bool,
}

/// A browser whose profile list could not be read by the last scan. The
/// browser itself stays usable; only its profiles are unknown.
#[derive(Debug, Clone)]
pub struct UnreadableProfiles {
    pub browser_id: String,
    /// Display name of the browser.
    pub browser: String,
    /// The operating system refused the read. macOS 27 and later do that for
    /// the data of other apps' browsers until the user allows it in System
    /// Settings; a file that exists but is damaged is not a denial.
    pub denied: bool,
    pub reason: String,
}

impl UnreadableProfiles {
    #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
    fn warn(&self) {
        warn_once(format!(
            "warning: profiles of {} are not available: {}",
            self.browser, self.reason
        ));
    }
}

#[derive(Debug)]
pub struct BrowserRegistry {
    browsers: HashMap<String, BrowserInstall>,
    unreadable: Vec<UnreadableProfiles>,
}

impl BrowserRegistry {
    pub fn discover() -> Result<Self> {
        discover_inner(false)
    }

    /// Full discovery with profiles; bypasses the on-disk cache.
    pub fn discover_fresh() -> Result<Self> {
        discover_inner(true)
    }

    pub fn list(&self) -> Vec<&BrowserInstall> {
        let mut items: Vec<_> = self.browsers.values().collect();
        items.sort_by(|a, b| a.id.cmp(&b.id));
        items
    }

    /// Browsers whose profile list the last scan could not read, by display
    /// name. Empty when the list came from the on-disk cache, which only ever
    /// holds complete scans.
    pub fn unreadable_profiles(&self) -> &[UnreadableProfiles] {
        &self.unreadable
    }

    pub fn id_for_bundle_id(&self, bundle_id: &str) -> Option<String> {
        self.browsers
            .values()
            .find_map(|install| {
                install
                    .bundle_id
                    .as_deref()
                    .filter(|id| id.eq_ignore_ascii_case(bundle_id))
                    .map(|_| install.id.clone())
            })
            .or_else(|| browser_id_for_bundle_id(bundle_id).map(str::to_string))
    }

    pub fn id_for_prog_id(&self, prog_id: &str) -> Option<String> {
        browser_id_for_prog_id(prog_id)
            .map(str::to_string)
            .filter(|id| self.browsers.contains_key(id))
    }

    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub fn id_for_desktop_id(&self, desktop_id: &str) -> Option<String> {
        browser_id_for_desktop_id(desktop_id).map(str::to_string)
    }

    pub fn resolve(&self, id: &str, profile: Option<&str>) -> Result<ResolvedBrowser> {
        let install = self
            .browsers
            .get(id)
            .with_context(|| format!("unknown browser '{id}'"))?;

        let listed_unreadable = self.unreadable.iter().any(|entry| entry.browser_id == id);
        let (profiles, unreadable) = if profile.is_some() && install.profiles.is_empty() {
            #[cfg(target_os = "windows")]
            {
                match known_browsers().into_iter().find(|s| s.id == id) {
                    Some(spec) => {
                        let (profiles, failure) = profiles_if_readable(
                            &spec,
                            discover_windows::discover_profiles_for(&spec),
                        );
                        if let Some(failure) = &failure {
                            failure.warn();
                        }
                        (profiles, listed_unreadable || failure.is_some())
                    }
                    None => (install.profiles.clone(), listed_unreadable),
                }
            }
            #[cfg(not(target_os = "windows"))]
            {
                (install.profiles.clone(), listed_unreadable)
            }
        } else {
            (install.profiles.clone(), listed_unreadable)
        };

        let profile_match = profile.and_then(|wanted| {
            profiles
                .iter()
                .find(|p| p.name.eq_ignore_ascii_case(wanted))
                // A Chromium profile may also be named by its folder, which
                // is what its own `--profile-directory` takes.
                .or_else(|| {
                    profiles.iter().find(|p| {
                        p.directory
                            .as_deref()
                            .is_some_and(|dir| dir.eq_ignore_ascii_case(wanted))
                    })
                })
        });

        // Without the list a profile name cannot be turned into its folder.
        // A name that already is a folder name needs no list, so that still
        // reaches the right profile. Anything else is left out: Chromium
        // would create a new, empty profile for an unknown folder.
        let unlisted_directory = profile
            .filter(|_| profile_match.is_none() && unreadable && is_chromium_browser(id))
            .and_then(chromium_profile_folder);

        Ok(ResolvedBrowser {
            id: install.id.clone(),
            display_name: install.display_name.clone(),
            app_path: install.app_path.clone(),
            profile: profile.map(str::to_string),
            profile_directory: profile_match
                .and_then(|p| p.directory.clone())
                .or_else(|| profile_match.and_then(|p| p.path.clone()))
                .or(unlisted_directory),
            private: false,
        })
    }
}

/// The folder Chromium keeps a profile in, when `name` is such a folder name:
/// `Default` or `Profile <number>`, in the spelling Chromium uses.
fn chromium_profile_folder(name: &str) -> Option<String> {
    let name = name.trim();
    if name.eq_ignore_ascii_case("default") {
        return Some("Default".to_string());
    }
    let (word, number) = name.split_once(' ')?;
    let numbered = !number.is_empty() && number.bytes().all(|byte| byte.is_ascii_digit());
    (word.eq_ignore_ascii_case("profile") && numbered).then(|| format!("Profile {number}"))
}

/// A browser stays usable when its profile list cannot be read: the file may
/// be locked or damaged, or the operating system may keep other programs away
/// from browser data, as macOS 27 does. The browser is then listed without
/// profiles. Failing discovery instead would take first-run setup and every
/// routed link down with it.
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn profiles_if_readable(
    spec: &KnownBrowser,
    profiles: Result<Vec<BrowserProfile>>,
) -> (Vec<BrowserProfile>, Option<UnreadableProfiles>) {
    match profiles {
        Ok(profiles) => (profiles, None),
        Err(err) => {
            let denied = err.chain().any(|cause| {
                cause
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|io| io.kind() == std::io::ErrorKind::PermissionDenied)
            });
            let failure = UnreadableProfiles {
                browser_id: spec.id.to_string(),
                browser: spec.display_name.to_string(),
                denied,
                reason: format!("{err:#}"),
            };
            (Vec::new(), Some(failure))
        }
    }
}

/// A profile list that cannot be read now was usually readable once: before
/// an update of macOS, or of SuperSurfer, took the permission away. Profiles
/// change rarely, so the list from the last complete scan beats none at all.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn keep_last_known_profiles(
    browsers: &mut HashMap<String, BrowserInstall>,
    unreadable: &[UnreadableProfiles],
    last_scan: &HashMap<String, BrowserInstall>,
) {
    for failure in unreadable {
        if let (Some(install), Some(known)) = (
            browsers.get_mut(&failure.browser_id),
            last_scan.get(&failure.browser_id),
        ) {
            install.profiles = known.profiles.clone();
        }
    }
}

/// Says on stderr what a scan could not read. Each distinct message appears
/// once per process: the resident app scans again every few minutes.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn report_unreadable(unreadable: &[UnreadableProfiles]) {
    for failure in unreadable.iter().filter(|failure| !failure.denied) {
        failure.warn();
    }
    let denied: Vec<&str> = unreadable
        .iter()
        .filter(|failure| failure.denied)
        .map(|failure| failure.browser.as_str())
        .collect();
    if !denied.is_empty() {
        warn_once(format!(
            "warning: no permission to read the profile lists of {}. {}",
            denied.join(", "),
            DENIED_PROFILES_HINT
        ));
    }
}

/// What a refused profile list means and how to get it back.
#[cfg(target_os = "macos")]
pub const DENIED_PROFILES_HINT: &str = "Links are still routed. SuperSurfer uses the profile \
lists it read last, if any; a Chromium profile it does not know is only used when named \
by its folder (\"Default\", \"Profile 1\"). macOS 27 and later keep apps away from browser \
data until you allow it: System Settings > Privacy & Security > Files & Folders, under \
SuperSurfer for the menu bar app and under your terminal app for commands. Full Disk Access \
works as well.";

#[cfg(not(target_os = "macos"))]
pub const DENIED_PROFILES_HINT: &str = "Links are still routed, but profiles are not listed, \
and a Chromium profile is only used when named by its folder (\"Default\", \"Profile 1\").";

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn warn_once(message: String) {
    static SHOWN: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
    let mut shown = SHOWN
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if !shown.contains(&message) {
        eprintln!("{message}");
        shown.push(message);
    }
}

pub fn is_chromium_browser(id: &str) -> bool {
    known_browsers()
        .into_iter()
        .find(|b| b.id == id)
        .is_some_and(|b| b.profile_kind == ProfileKind::Chromium)
}

/// Browsers whose own profile menu can bring a profile's window to the
/// front, which is what a Dock shortcut for a profile relies on. Tried with
/// Edge and Chrome; their other channels and Chromium share that menu.
pub fn has_profile_menu(id: &str) -> bool {
    matches!(
        id,
        "chrome" | "chrome-canary" | "chromium" | "edge" | "edge-beta" | "edge-canary"
    )
}

/// What a browser goes by for short: "Edge" for "Microsoft Edge".
pub fn short_name(id: &str) -> Option<&'static str> {
    known_browsers()
        .into_iter()
        .find(|b| b.id == id)
        .map(|b| b.aliases.first().copied().unwrap_or(b.display_name))
}

pub fn is_gecko_browser(id: &str) -> bool {
    known_browsers()
        .into_iter()
        .find(|b| b.id == id)
        .is_some_and(|b| b.profile_kind == ProfileKind::Gecko)
}

pub fn normalize_browser_id(name: &str) -> &str {
    let lower = name.to_lowercase();
    for spec in known_browsers() {
        if spec.id == lower || spec.display_name.to_lowercase() == lower {
            return spec.id;
        }
        for alias in spec.aliases {
            if alias.eq_ignore_ascii_case(name) {
                return spec.id;
            }
        }
    }
    name
}

/// Path and bundle markers used to detect a running browser on macOS.
pub fn running_path_markers(browser_id: &str) -> Vec<String> {
    let mut markers = Vec::new();
    for spec in known_browsers() {
        if spec.id != browser_id {
            continue;
        }
        for app_name in spec.mac_app_names {
            let app = app_name.to_ascii_lowercase();
            markers.push(app.clone());
            markers.push(app.trim_end_matches(".app").to_string());
        }
        for bundle_id in spec.mac_bundle_ids {
            markers.push(bundle_id.to_ascii_lowercase());
        }
        break;
    }
    markers.sort_unstable();
    markers.dedup();
    markers
}

/// Names and aliases to match against running process comm/exe values.
pub fn process_name_candidates(query: &str) -> Vec<String> {
    let browser_id = normalize_browser_id(query);
    let mut candidates = vec![query.to_string(), browser_id.to_string()];

    for spec in known_browsers() {
        if spec.id != browser_id {
            continue;
        }
        candidates.push(spec.display_name.to_string());
        for alias in spec.aliases {
            candidates.push((*alias).to_string());
        }
        for bundle_id in spec.mac_bundle_ids {
            candidates.push((*bundle_id).to_string());
        }
        for app_name in spec.mac_app_names {
            candidates.push(app_name.trim_end_matches(".app").to_string());
        }
        candidates.extend(platform_process_names(spec.id));
        break;
    }

    candidates.sort_unstable();
    candidates.dedup();
    candidates
}

fn platform_process_names(browser_id: &str) -> Vec<String> {
    let names: &[&str] = match browser_id {
        "safari" => &["safari", "com.apple.webkit"],
        "chrome" => &[
            "chrome",
            "google chrome",
            "google-chrome",
            "google-chrome-stable",
        ],
        "chrome-canary" => &["chrome", "google chrome canary", "google-chrome-canary"],
        "chromium" => &["chromium", "chromium-browser"],
        "firefox" => &["firefox", "firefox-esr", "org.mozilla.firefox"],
        "firefox-developer-edition" => &["firefox", "firefox developer edition"],
        "zen" => &["zen", "zen-bin", "zen-browser"],
        "waterfox" => &["waterfox", "waterfox-bin"],
        "tor" => &["firefox", "tor browser", "tor-browser"],
        "edge" => &[
            "msedge",
            "microsoft edge",
            "microsoft-edge",
            "microsoft-edge-stable",
        ],
        "edge-beta" => &["msedge", "microsoft edge beta", "microsoft-edge-beta"],
        "edge-canary" => &["msedge", "microsoft edge canary", "microsoft-edge-sxs"],
        "brave" => &["brave", "brave-browser", "brave browser"],
        "brave-beta" => &["brave", "brave-browser-beta", "brave beta"],
        "brave-nightly" => &["brave", "brave-browser-nightly", "brave nightly"],
        "arc" => &["arc", "arc browser"],
        "dia" => &["dia"],
        "opera" => &["opera", "opera stable"],
        "opera-gx" => &["opera", "opera gx"],
        "vivaldi" => &["vivaldi", "vivaldi-bin", "vivaldi-stable"],
        "ungoogled-chromium" => &["chromium", "ungoogled-chromium"],
        _ => &[],
    };
    names.iter().map(|name| (*name).to_string()).collect()
}

pub fn browser_id_for_bundle_id(bundle_id: &str) -> Option<&'static str> {
    for spec in known_browsers() {
        for id in spec.mac_bundle_ids {
            if id.eq_ignore_ascii_case(bundle_id) {
                return Some(spec.id);
            }
        }
    }
    None
}

pub fn browser_id_for_prog_id(prog_id: &str) -> Option<&'static str> {
    let lower = prog_id.to_ascii_lowercase();
    if lower.contains("firefox") {
        return Some("firefox");
    }
    if lower.contains("brave") {
        if lower.contains("nightly") {
            return Some("brave-nightly");
        }
        if lower.contains("beta") {
            return Some("brave-beta");
        }
        return Some("brave");
    }
    if lower.contains("vivaldi") {
        return Some("vivaldi");
    }
    if lower.contains("operagx") || (lower.contains("opera") && lower.contains("gx")) {
        return Some("opera-gx");
    }
    if lower.contains("opera") {
        return Some("opera");
    }
    if lower.contains("msedge") || lower.contains("edgehtm") || lower.contains("edge") {
        if lower.contains("beta") {
            return Some("edge-beta");
        }
        if lower.contains("canary") || lower.contains("sxs") {
            return Some("edge-canary");
        }
        if lower.contains("dev") {
            return Some("edge-dev");
        }
        return Some("edge");
    }
    if lower.contains("chrome") {
        if lower.contains("sx") || lower.contains("canary") {
            return Some("chrome-canary");
        }
        return Some("chrome");
    }
    None
}

#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn browser_id_for_desktop_id(desktop_id: &str) -> Option<&'static str> {
    let needle = desktop_id.trim_end_matches(".desktop");
    for spec in known_browsers() {
        for id in spec.linux_desktop_ids {
            if id.trim_end_matches(".desktop").eq_ignore_ascii_case(needle) {
                return Some(spec.id);
            }
        }
    }
    None
}

struct KnownBrowser {
    id: &'static str,
    display_name: &'static str,
    aliases: &'static [&'static str],
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    mac_app_names: &'static [&'static str],
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    mac_bundle_ids: &'static [&'static str],
    profile_kind: ProfileKind,
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    chromium_data_dir: Option<&'static str>,
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))]
    gecko_profiles_ini: Option<&'static str>,
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    linux_desktop_ids: &'static [&'static str],
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    linux_config_dir: Option<&'static str>,
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    linux_gecko_dir: Option<&'static str>,
}

impl KnownBrowser {
    fn linux(
        mut self,
        desktop_ids: &'static [&'static str],
        config_dir: Option<&'static str>,
        gecko_dir: Option<&'static str>,
    ) -> Self {
        self.linux_desktop_ids = desktop_ids;
        self.linux_config_dir = config_dir;
        self.linux_gecko_dir = gecko_dir;
        self
    }
}

fn known_browsers() -> Vec<KnownBrowser> {
    vec![
        browser(
            "safari",
            "Safari",
            &[],
            &["Safari.app"],
            &["com.apple.Safari"],
            ProfileKind::None,
            None,
            None,
        ),
        browser(
            "chrome",
            "Google Chrome",
            &["Chrome"],
            &["Google Chrome.app"],
            &["com.google.Chrome"],
            ProfileKind::Chromium,
            Some("Google/Chrome"),
            None,
        )
        .linux(&["google-chrome.desktop"], Some("google-chrome"), None),
        browser(
            "chrome-canary",
            "Google Chrome Canary",
            &["Chrome Canary"],
            &["Google Chrome Canary.app"],
            &["com.google.Chrome.canary"],
            ProfileKind::Chromium,
            Some("Google/Chrome Canary"),
            None,
        ),
        browser(
            "chromium",
            "Chromium",
            &[],
            &["Chromium.app"],
            &["org.chromium.Chromium"],
            ProfileKind::Chromium,
            Some("Chromium"),
            None,
        )
        .linux(
            &[
                "chromium.desktop",
                "chromium-browser.desktop",
                "chromium_chromium.desktop",
            ],
            Some("chromium"),
            None,
        ),
        browser(
            "firefox",
            "Firefox",
            &[],
            &["Firefox.app"],
            &["org.mozilla.firefox"],
            ProfileKind::Gecko,
            None,
            Some("Firefox/profiles.ini"),
        )
        .linux(
            &[
                "firefox.desktop",
                "firefox-esr.desktop",
                "firefox_firefox.desktop",
                "org.mozilla.firefox.desktop",
            ],
            None,
            Some(".mozilla/firefox"),
        ),
        browser(
            "firefox-developer-edition",
            "Firefox Developer Edition",
            &["Firefox Developer Edition", "Firefox Dev"],
            &["Firefox Developer Edition.app"],
            &["org.mozilla.firefoxdeveloperedition"],
            ProfileKind::Gecko,
            None,
            Some("Firefox/profiles.ini"),
        )
        .linux(
            &["firefox-developer-edition.desktop"],
            None,
            Some(".mozilla/firefox"),
        ),
        browser(
            "zen",
            "Zen",
            &["Zen Browser"],
            &["Zen.app", "Zen Browser.app"],
            &["app.zen-browser.zen"],
            ProfileKind::Gecko,
            None,
            Some("zen/profiles.ini"),
        )
        .linux(
            &[
                "zen.desktop",
                "zen-browser.desktop",
                "app.zen_browser.zen.desktop",
            ],
            None,
            Some(".zen"),
        ),
        browser(
            "waterfox",
            "Waterfox",
            &[],
            &["Waterfox.app"],
            &["org.waterfox.waterfox"],
            ProfileKind::Gecko,
            None,
            Some("Waterfox/profiles.ini"),
        )
        .linux(&["waterfox.desktop"], None, Some(".waterfox")),
        browser(
            "tor",
            "Tor Browser",
            &["Tor"],
            &["Tor Browser.app"],
            &["org.torproject.torbrowser"],
            ProfileKind::Gecko,
            None,
            Some("Tor Browser/Browser/TorBrowser/Data/Browser/profiles.ini"),
        )
        .linux(
            &[
                "torbrowser.desktop",
                "org.torproject.torbrowser-launcher.desktop",
            ],
            None,
            None,
        ),
        browser(
            "edge",
            "Microsoft Edge",
            &["Edge"],
            &["Microsoft Edge.app"],
            &["com.microsoft.edgemac"],
            ProfileKind::Chromium,
            Some("Microsoft Edge"),
            None,
        )
        .linux(
            &["microsoft-edge.desktop", "microsoft-edge-dev.desktop"],
            Some("microsoft-edge"),
            None,
        ),
        browser(
            "edge-beta",
            "Microsoft Edge Beta",
            &["Edge Beta"],
            &["Microsoft Edge Beta.app"],
            &["com.microsoft.edgemac.Beta"],
            ProfileKind::Chromium,
            Some("Microsoft Edge Beta"),
            None,
        )
        .linux(
            &["microsoft-edge-beta.desktop"],
            Some("microsoft-edge-beta"),
            None,
        ),
        browser(
            "edge-canary",
            "Microsoft Edge Canary",
            &["Edge Canary"],
            &["Microsoft Edge Canary.app"],
            &["com.microsoft.edgemac.Canary"],
            ProfileKind::Chromium,
            Some("Microsoft Edge Canary"),
            None,
        ),
        browser(
            "brave",
            "Brave Browser",
            &["Brave"],
            &["Brave Browser.app"],
            &["com.brave.Browser"],
            ProfileKind::Chromium,
            Some("BraveSoftware/Brave-Browser"),
            None,
        )
        .linux(
            &["brave-browser.desktop", "brave_brave.desktop"],
            Some("BraveSoftware/Brave-Browser"),
            None,
        ),
        browser(
            "brave-beta",
            "Brave Browser Beta",
            &["Brave Beta"],
            &["Brave Browser Beta.app"],
            &["com.brave.Browser.beta"],
            ProfileKind::Chromium,
            Some("BraveSoftware/Brave-Browser-Beta"),
            None,
        )
        .linux(
            &["brave-browser-beta.desktop"],
            Some("BraveSoftware/Brave-Browser-Beta"),
            None,
        ),
        browser(
            "brave-nightly",
            "Brave Browser Nightly",
            &["Brave Nightly"],
            &["Brave Browser Nightly.app"],
            &["com.brave.Browser.nightly"],
            ProfileKind::Chromium,
            Some("BraveSoftware/Brave-Browser-Nightly"),
            None,
        )
        .linux(
            &["brave-browser-nightly.desktop"],
            Some("BraveSoftware/Brave-Browser-Nightly"),
            None,
        ),
        browser(
            "arc",
            "Arc",
            &[],
            &["Arc.app"],
            &["company.thebrowser.Browser"],
            ProfileKind::Chromium,
            Some("Arc/User Data"),
            None,
        ),
        browser(
            "dia",
            "Dia",
            &[],
            &["Dia.app"],
            &["company.thebrowser.dia"],
            ProfileKind::Chromium,
            Some("Dia/User Data"),
            None,
        ),
        browser(
            "vivaldi",
            "Vivaldi",
            &[],
            &["Vivaldi.app"],
            &["com.vivaldi.Vivaldi"],
            ProfileKind::Chromium,
            Some("Vivaldi"),
            None,
        )
        .linux(
            &["vivaldi-stable.desktop", "vivaldi.desktop"],
            Some("vivaldi"),
            None,
        ),
        browser(
            "opera",
            "Opera",
            &[],
            &["Opera.app"],
            &["com.operasoftware.Opera"],
            ProfileKind::Chromium,
            Some("com.operasoftware.Opera"),
            None,
        )
        .linux(
            &["opera.desktop", "opera_opera.desktop"],
            Some("opera"),
            None,
        ),
        browser(
            "opera-gx",
            "Opera GX",
            &["OperaGX"],
            &["Opera GX.app"],
            &["com.operasoftware.OperaGX"],
            ProfileKind::Chromium,
            Some("com.operasoftware.OperaGX"),
            None,
        ),
        browser(
            "orion",
            "Orion",
            &["Orion Browser"],
            &["Orion.app", "Orion Browser.app"],
            &["com.kagi.kagimacOS"],
            ProfileKind::Chromium,
            Some("Orion/Data"),
            None,
        ),
        browser(
            "sigmaos",
            "SigmaOS",
            &["Sigma OS"],
            &["SigmaOS.app"],
            &["com.sigmaos.sigmaosmacos"],
            ProfileKind::Chromium,
            Some("SigmaOS"),
            None,
        ),
        browser(
            "sidekick",
            "Sidekick",
            &[],
            &["Sidekick.app"],
            &["com.pushplaylabs.sidekick"],
            ProfileKind::Chromium,
            Some("Sidekick"),
            None,
        ),
        browser(
            "helium",
            "Helium",
            &[],
            &["Helium.app"],
            &["com.imput.helium"],
            ProfileKind::Chromium,
            Some("Helium"),
            None,
        ),
        browser(
            "wavebox",
            "Wavebox",
            &[],
            &["Wavebox.app"],
            &["com.bookry.wavebox"],
            ProfileKind::Chromium,
            Some("Wavebox"),
            None,
        ),
        browser(
            "ungoogled-chromium",
            "Ungoogled Chromium",
            &["Ungoogled-Chromium"],
            &["Chromium.app", "Ungoogled Chromium.app"],
            &["org.ungoogled.chromium"],
            ProfileKind::Chromium,
            Some("Chromium"),
            None,
        )
        .linux(
            &["ungoogled-chromium.desktop", "chromium.desktop"],
            Some("chromium"),
            None,
        ),
    ]
}

#[allow(clippy::too_many_arguments)]
fn browser(
    id: &'static str,
    display_name: &'static str,
    aliases: &'static [&'static str],
    mac_app_names: &'static [&'static str],
    mac_bundle_ids: &'static [&'static str],
    profile_kind: ProfileKind,
    chromium_data_dir: Option<&'static str>,
    gecko_profiles_ini: Option<&'static str>,
) -> KnownBrowser {
    KnownBrowser {
        id,
        display_name,
        aliases,
        mac_app_names,
        mac_bundle_ids,
        profile_kind,
        chromium_data_dir,
        gecko_profiles_ini,
        linux_desktop_ids: &[],
        linux_config_dir: None,
        linux_gecko_dir: None,
    }
}

#[cfg(target_os = "macos")]
fn discover_inner(fresh: bool) -> Result<BrowserRegistry> {
    use crate::browser::cache;

    // Cheap pass: resolve each known browser's .app bundle path (a couple of
    // stats per browser) and the mtime of its Info.plist. This snapshot is the
    // cache key and invalidates on install/update/reinstall.
    let mut snapshot: Vec<(String, std::time::SystemTime)> = Vec::new();
    let mut resolved: Vec<(KnownBrowser, PathBuf)> = Vec::new();
    for spec in known_browsers() {
        if let Some(path) = resolve_app_path_macos(&spec) {
            let plist = path.join("Contents/Info.plist");
            let mtime = fs::metadata(&plist)
                .and_then(|m| m.modified())
                .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
            snapshot.push((path.to_string_lossy().to_string(), mtime));
            resolved.push((spec, path));
        }
    }
    let fingerprint = cache::macos_fingerprint(&snapshot);

    // Always build live path installs first so a poisoned cache cannot supply
    // the executable path. Profiles may still come from cache on a hit.
    let mut live = HashMap::new();
    for (spec, app_path) in &resolved {
        live.insert(
            spec.id.to_string(),
            BrowserInstall {
                id: spec.id.to_string(),
                display_name: spec.display_name.to_string(),
                app_path: Some(app_path.to_string_lossy().to_string()),
                bundle_id: read_bundle_id(app_path)
                    .or_else(|| spec.mac_bundle_ids.first().map(|s| s.to_string())),
                profiles: vec![],
            },
        );
    }

    if !fresh {
        if let Some(cached) = load_cache(&fingerprint) {
            if let Some(browsers) = cache::rebind_app_paths(cached, live.clone()) {
                return Ok(BrowserRegistry {
                    browsers,
                    unreadable: Vec::new(),
                });
            }
        }
    }

    // Cache miss: do the expensive work (plist parse + profile discovery) for
    // each resolved bundle, then persist.
    let mut browsers = HashMap::new();
    let mut unreadable = Vec::new();
    for (spec, app_path) in &resolved {
        let (install, failure) = discover_browser_macos(spec, app_path);
        unreadable.extend(failure);
        browsers.insert(spec.id.to_string(), install);
    }

    // Only a complete scan is saved. The cache is keyed on the app bundles,
    // not on profile data, so a scan that could not read some profile list
    // would stick until that browser is updated. It would also overwrite the
    // one place that still knows those profiles.
    if unreadable.is_empty() {
        save_cache(&fingerprint, &browsers);
    } else {
        keep_last_known_profiles(&mut browsers, &unreadable, &cache::last_complete_scan());
    }
    report_unreadable(&unreadable);

    Ok(BrowserRegistry {
        browsers,
        unreadable,
    })
}

/// The cache only saves work. Not being able to read or write it must never
/// cost a routed link.
#[cfg(any(target_os = "macos", target_os = "windows"))]
fn load_cache(fingerprint: &str) -> Option<HashMap<String, BrowserInstall>> {
    match crate::browser::cache::load(fingerprint) {
        Ok(cached) => cached,
        Err(err) => {
            warn_once(format!("warning: browser cache not read: {err:#}"));
            None
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
fn save_cache(fingerprint: &str, browsers: &HashMap<String, BrowserInstall>) {
    if let Err(err) = crate::browser::cache::save(fingerprint, browsers) {
        warn_once(format!("warning: browser cache not written: {err:#}"));
    }
}

/// Resolve a known browser's `.app` bundle path by checking the system and
/// user Applications directories. Returns the first existing match.
#[cfg(target_os = "macos")]
fn resolve_app_path_macos(spec: &KnownBrowser) -> Option<PathBuf> {
    spec.mac_app_names
        .iter()
        .map(|name| PathBuf::from("/Applications").join(name))
        .chain(spec.mac_app_names.iter().map(|name| {
            directories::UserDirs::new()
                .map(|u| u.home_dir().to_path_buf())
                .unwrap_or_default()
                .join("Applications")
                .join(name)
        }))
        .find(|p| p.exists())
}

#[cfg(target_os = "windows")]
fn discover_inner(fresh: bool) -> Result<BrowserRegistry> {
    discover_windows_cached(fresh)
}

#[cfg(target_os = "linux")]
fn discover_inner(_fresh: bool) -> Result<BrowserRegistry> {
    let dirs = linux_application_dirs();
    let mut browsers = HashMap::new();
    let mut unreadable = Vec::new();
    for spec in known_browsers() {
        if let Some((install, failure)) = discover_browser_linux(&spec, &dirs)? {
            unreadable.extend(failure);
            browsers.insert(spec.id.to_string(), install);
        }
    }
    report_unreadable(&unreadable);
    Ok(BrowserRegistry {
        browsers,
        unreadable,
    })
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
fn discover_inner(_fresh: bool) -> Result<BrowserRegistry> {
    Ok(BrowserRegistry {
        browsers: HashMap::new(),
        unreadable: Vec::new(),
    })
}

#[cfg(target_os = "linux")]
fn linux_application_dirs() -> Vec<PathBuf> {
    let xdg_data_dirs = std::env::var("XDG_DATA_DIRS")
        .unwrap_or_else(|_| "/usr/local/share:/usr/share".to_string());
    let mut extra = Vec::new();
    for entry in xdg_data_dirs.split(':') {
        if entry.is_empty() {
            continue;
        }
        let dir = Path::new(entry).join("applications");
        // XDG_DATA_DIRS is session environment. Only root-owned, non-writable
        // directories may add a browser ahead of the per-user applications dir.
        if system_desktop_dir_is_trusted(&dir) {
            extra.push(dir);
        }
    }
    let user = directories::BaseDirs::new().map(|base| base.data_local_dir().join("applications"));
    desktop_dir_search_order(user, &extra)
}

/// System locations first, then other trusted data dirs, then the per-user
/// applications directory. A `google-chrome.desktop` in the home directory
/// must not override `/usr/share`.
#[cfg(any(target_os = "linux", test))]
fn desktop_dir_search_order(user: Option<PathBuf>, extra: &[PathBuf]) -> Vec<PathBuf> {
    let mut dirs = vec![
        PathBuf::from("/usr/local/share/applications"),
        PathBuf::from("/usr/share/applications"),
        PathBuf::from("/var/lib/snapd/desktop/applications"),
        PathBuf::from("/var/lib/flatpak/exports/share/applications"),
    ];
    for dir in extra {
        if !dirs.contains(dir) {
            dirs.push(dir.clone());
        }
    }
    if let Some(user) = user {
        dirs.retain(|dir| dir != &user);
        dirs.push(user);
    }
    dirs
}

#[cfg(any(target_os = "linux", test))]
fn system_desktop_dir_is_trusted(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let Ok(meta) = std::fs::symlink_metadata(path) else {
            return false;
        };
        meta.is_dir() && meta.uid() == 0 && meta.mode() & 0o022 == 0
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        false
    }
}

#[cfg(target_os = "linux")]
fn discover_browser_linux(
    spec: &KnownBrowser,
    dirs: &[PathBuf],
) -> Result<Option<(BrowserInstall, Option<UnreadableProfiles>)>> {
    let desktop_file = spec.linux_desktop_ids.iter().find_map(|id| {
        dirs.iter()
            .map(|dir| dir.join(id))
            .find(|path| path.exists())
    });

    let Some(desktop_file) = desktop_file else {
        return Ok(None);
    };

    let Some(token) = parse_desktop_exec(&desktop_file) else {
        return Ok(None);
    };
    let Some(exec) = resolve_desktop_exec(&token) else {
        return Ok(None);
    };
    if !exec_path_is_plausible(&exec) {
        return Ok(None);
    }

    let (profiles, failure) = profiles_if_readable(spec, discover_profiles_linux(spec));

    let install = BrowserInstall {
        id: spec.id.to_string(),
        display_name: spec.display_name.to_string(),
        app_path: Some(exec),
        bundle_id: None,
        profiles,
    };
    Ok(Some((install, failure)))
}

#[cfg(target_os = "linux")]
fn parse_desktop_exec(desktop_file: &Path) -> Option<String> {
    let content = fs::read_to_string(desktop_file).ok()?;
    let mut in_entry = false;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_entry = trimmed == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        if let Some(value) = trimmed.strip_prefix("Exec=") {
            return parse_desktop_exec_value(value);
        }
    }
    None
}

/// Parse an `Exec=` value from a `.desktop` file, skipping `env VAR=…` prefixes
/// used by Snap/Flatpak entries.
#[cfg(any(target_os = "linux", test))]
fn parse_desktop_exec_value(value: &str) -> Option<String> {
    let mut tokens = value.split_whitespace().peekable();

    if tokens.peek() == Some(&"env") {
        tokens.next();
        while tokens.peek().is_some_and(|token| {
            token.contains('=') && !token.starts_with('/') && !token.starts_with('%')
        }) {
            tokens.next();
        }
    }

    for token in tokens {
        if token.starts_with('%') {
            continue;
        }
        let token = unquote_desktop_token(token);
        if token.is_empty() || token.starts_with('%') {
            continue;
        }
        return Some(token);
    }
    None
}

#[cfg(any(target_os = "linux", test))]
fn unquote_desktop_token(token: &str) -> String {
    let token = token.trim();
    if token.len() >= 2 && token.starts_with('"') && token.ends_with('"') {
        return unescape_desktop_quotes(&token[1..token.len() - 1]);
    }
    token.to_string()
}

#[cfg(any(target_os = "linux", test))]
fn unescape_desktop_quotes(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some(escaped) => out.push(escaped),
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Absolute `Exec=` paths are used as written. A bare name is resolved from
/// system directories before `~/.local/bin`, so a PATH entry cannot replace
/// `/usr/bin/firefox`.
#[cfg(target_os = "linux")]
fn resolve_desktop_exec(token: &str) -> Option<String> {
    if token.starts_with('/') {
        return Some(token.to_string());
    }
    if token.contains('/') || token.contains('\\') {
        return None;
    }
    for dir in exec_search_dirs() {
        let candidate = dir.join(token);
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    None
}

#[cfg(any(target_os = "linux", test))]
fn exec_search_dirs() -> Vec<PathBuf> {
    let mut dirs = vec![
        PathBuf::from("/usr/bin"),
        PathBuf::from("/bin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/snap/bin"),
    ];
    if let Some(base) = directories::BaseDirs::new() {
        dirs.push(base.home_dir().join(".local/bin"));
    }
    dirs
}

#[cfg(any(target_os = "linux", test))]
fn exec_path_is_plausible(path: &str) -> bool {
    let lower = path.replace('\\', "/").to_ascii_lowercase();
    const BAD_PREFIXES: &[&str] = &["/tmp/", "/var/tmp/", "/dev/shm/", "/private/tmp/"];
    !BAD_PREFIXES.iter().any(|prefix| lower.starts_with(prefix))
}

#[cfg(target_os = "linux")]
fn discover_profiles_linux(spec: &KnownBrowser) -> Result<Vec<BrowserProfile>> {
    let Some(base) = directories::BaseDirs::new() else {
        return Ok(vec![]);
    };
    match spec.profile_kind {
        ProfileKind::None => Ok(vec![]),
        ProfileKind::Gecko => {
            let mut candidates = Vec::new();
            if let Some(relative) = spec.linux_gecko_dir {
                candidates.push(base.home_dir().join(relative).join("profiles.ini"));
            }
            if spec.id == "firefox" {
                candidates.push(
                    base.home_dir()
                        .join("snap/firefox/common/.mozilla/firefox/profiles.ini"),
                );
            }
            for path in candidates {
                let profiles = discover_gecko_profiles(&path)?;
                if !profiles.is_empty() {
                    return Ok(profiles);
                }
            }
            Ok(vec![])
        }
        ProfileKind::Chromium => {
            let mut candidates = Vec::new();
            if let Some(relative) = spec.linux_config_dir {
                candidates.push(base.config_dir().join(relative));
            }
            if spec.id == "chromium" {
                candidates.push(base.home_dir().join("snap/chromium/common/chromium"));
            }
            for path in candidates {
                let profiles = discover_chromium_profiles(&path)?;
                if !profiles.is_empty() {
                    return Ok(profiles);
                }
            }
            Ok(vec![])
        }
    }
}

#[cfg(target_os = "windows")]
fn discover_windows_cached(fresh: bool) -> Result<BrowserRegistry> {
    use crate::browser::cache;

    let start_menu = discover_windows::enumerate_start_menu_browsers()?;
    let fingerprint = cache::registry_fingerprint(&start_menu);

    // Live path resolution (no profile scan) — authoritative for app_path.
    let mut live = HashMap::new();
    for spec in known_browsers() {
        if let Some(install) = discover_windows::discover_one(&spec, &start_menu, false)? {
            live.insert(spec.id.to_string(), install);
        }
    }

    if !fresh {
        if let Some(cached) = load_cache(&fingerprint) {
            if let Some(browsers) = cache::rebind_app_paths(cached, live.clone()) {
                return Ok(BrowserRegistry {
                    browsers,
                    unreadable: Vec::new(),
                });
            }
        }
    }

    // Cache miss / fresh: load profiles and persist.
    let mut browsers = HashMap::new();
    for spec in known_browsers() {
        if let Some(install) = discover_windows::discover_one(&spec, &start_menu, true)? {
            browsers.insert(spec.id.to_string(), install);
        }
    }

    save_cache(&fingerprint, &browsers);

    Ok(BrowserRegistry {
        browsers,
        unreadable: Vec::new(),
    })
}

/// Returns the install and, when its profile list could not be read, why.
#[cfg(target_os = "macos")]
fn discover_browser_macos(
    spec: &KnownBrowser,
    app_path: &Path,
) -> (BrowserInstall, Option<UnreadableProfiles>) {
    let bundle_id =
        read_bundle_id(app_path).or_else(|| spec.mac_bundle_ids.first().map(|s| s.to_string()));
    let (profiles, failure) = profiles_if_readable(spec, discover_profiles(spec, app_path));

    let install = BrowserInstall {
        id: spec.id.to_string(),
        display_name: spec.display_name.to_string(),
        app_path: Some(app_path.to_string_lossy().to_string()),
        bundle_id,
        profiles,
    };
    (install, failure)
}

#[cfg(target_os = "macos")]
fn read_bundle_id(app_path: &Path) -> Option<String> {
    let plist_path = app_path.join("Contents/Info.plist");
    let file = fs::File::open(plist_path).ok()?;
    let value: plist::Value = plist::from_reader(file).ok()?;
    value
        .as_dictionary()?
        .get("CFBundleIdentifier")?
        .as_string()
        .map(str::to_string)
}

#[cfg(target_os = "macos")]
fn discover_profiles(spec: &KnownBrowser, _app_path: &Path) -> Result<Vec<BrowserProfile>> {
    let home = directories::UserDirs::new()
        .map(|u| u.home_dir().to_path_buf())
        .context("no home directory")?;

    match spec.profile_kind {
        ProfileKind::None => Ok(vec![]),
        ProfileKind::Gecko => {
            let Some(relative) = spec.gecko_profiles_ini else {
                return Ok(vec![]);
            };
            discover_gecko_profiles(&home.join("Library/Application Support").join(relative))
        }
        ProfileKind::Chromium => {
            let Some(relative) = spec.chromium_data_dir else {
                return Ok(vec![]);
            };
            discover_chromium_profiles(&home.join("Library/Application Support").join(relative))
        }
    }
}

/// The text of the file a browser keeps its profiles in. `None` when there is
/// no such file: the browser has not been started yet and has no profiles.
///
/// Only "not found" counts as absent. A file that is there but may not be
/// opened, or a folder that may not even be looked into, is an error, so the
/// caller can tell "no profiles" from "cannot tell". macOS 27 answers `stat`
/// for another app's browser data and refuses `open`.
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn read_profile_list(path: &Path) -> Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(content) => Ok(Some(content)),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => {
            Err(anyhow::Error::new(err).context(format!("failed to read {}", path.display())))
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn discover_gecko_profiles(ini_path: &Path) -> Result<Vec<BrowserProfile>> {
    let Some(content) = read_profile_list(ini_path)? else {
        return Ok(vec![]);
    };
    let mut profiles = Vec::new();
    let mut current_name = None;
    let mut current_path = None;
    for line in content.lines() {
        if let Some(name) = line.strip_prefix("Name=") {
            current_name = Some(name.to_string());
        } else if let Some(path) = line.strip_prefix("Path=") {
            current_path = Some(path.to_string());
        } else if line == "Default=1" || line.starts_with('[') {
            if let (Some(name), Some(path)) = (current_name.take(), current_path.take()) {
                profiles.push(BrowserProfile {
                    name: name.clone(),
                    directory: Some(name),
                    path: Some(path),
                    menu_titles: Vec::new(),
                });
            }
        }
    }
    if let (Some(name), Some(path)) = (current_name, current_path) {
        profiles.push(BrowserProfile {
            name: name.clone(),
            directory: Some(name),
            path: Some(path),
            menu_titles: Vec::new(),
        });
    }
    Ok(profiles)
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn discover_chromium_profiles(support_dir: &Path) -> Result<Vec<BrowserProfile>> {
    let state_path = support_dir.join("Local State");
    let Some(content) = read_profile_list(&state_path)? else {
        return Ok(vec![]);
    };
    let json: serde_json::Value = serde_json::from_str(&content)
        .with_context(|| format!("{} is not valid JSON", state_path.display()))?;
    let mut profiles = Vec::new();
    if let Some(info_cache) = json
        .pointer("/profile/info_cache")
        .and_then(|v| v.as_object())
    {
        let names: Vec<(&String, ChromiumNames)> = info_cache
            .iter()
            .map(|(dir, info)| (dir, ChromiumNames::read(dir, info)))
            .collect();
        for (index, (dir, own)) in names.iter().enumerate() {
            let others = names
                .iter()
                .enumerate()
                .filter(|(other, _)| *other != index)
                .map(|(_, (_, names))| names);
            profiles.push(BrowserProfile {
                name: own.name.clone(),
                directory: Some((*dir).clone()),
                path: None,
                menu_titles: chromium_menu_titles(own, others),
            });
        }
    }
    Ok(profiles)
}

/// What Chromium keeps about the names of a profile in `Local State`.
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
struct ChromiumNames {
    /// The profile's own name.
    name: String,
    /// A name an organization gave the profile. Where there is one, the
    /// browser shows it in place of `name`.
    label: String,
    /// The name of the account the profile is signed in to, the given name
    /// where there is one. Empty for a profile that is not signed in.
    account: String,
    /// `name` is one the browser made up ("Person 1").
    made_up_name: bool,
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
impl ChromiumNames {
    fn read(directory: &str, info: &serde_json::Value) -> Self {
        let text = |key: &str| {
            info.get(key)
                .and_then(|v| v.as_str())
                .map(str::trim)
                .unwrap_or_default()
                .to_string()
        };
        let account = ["gaia_given_name", "gaia_name", "oidc_identity_name"]
            .into_iter()
            .map(text)
            .find(|name| !name.is_empty())
            .unwrap_or_default();
        ChromiumNames {
            name: info
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or(directory)
                .to_string(),
            label: text("enterprise_label"),
            account,
            made_up_name: info
                .get("is_using_default_name")
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
        }
    }

    /// The name the browser shows for the profile itself.
    fn local(&self) -> &str {
        if self.label.is_empty() {
            self.name.trim()
        } else {
            &self.label
        }
    }
}

/// What a Chromium browser may call a profile in its own profile menu, most
/// likely first.
///
/// The menu does not always show the profile's name. This follows
/// `ProfileAttributesEntry::GetName` in Chromium's source: a profile that is
/// not signed in goes by its own name. One that is signed in goes by the name
/// of its account while its own name is one the browser made up ("Person 1"),
/// and by both, as "Account (Profile)", once it was given a name, or when
/// another profile already goes by that account name alone.
///
/// The first entry is what that rule yields. The others are the remaining
/// forms, for a browser that follows another rule.
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn chromium_menu_titles<'a>(
    own: &ChromiumNames,
    mut others: impl Iterator<Item = &'a ChromiumNames>,
) -> Vec<String> {
    let local = own.local();
    let account = own.account.as_str();
    let both = format!("{account} ({local})");
    let account_taken = !account.is_empty()
        && others.any(|other| {
            other.account.eq_ignore_ascii_case(account)
                && (other.made_up_name || other.local().eq_ignore_ascii_case(&other.account))
        });
    let expected: Vec<&str> = if account.is_empty() {
        vec![local]
    } else if account.eq_ignore_ascii_case(local) {
        vec![account, local]
    } else if !own.made_up_name || !own.label.is_empty() || account_taken {
        vec![&both, local, account]
    } else {
        vec![account, &both, local]
    };
    let mut titles: Vec<String> = Vec::new();
    // The profile's own name last, for when a label stands in front of it.
    for candidate in expected.into_iter().chain([own.name.trim()]) {
        if !candidate.is_empty() && !titles.iter().any(|title| title == candidate) {
            titles.push(candidate.to_string());
        }
    }
    titles
}

#[cfg(test)]
mod tests {
    use super::*;

    fn install(id: &str, profiles: &[(&str, &str)]) -> BrowserInstall {
        BrowserInstall {
            id: id.to_string(),
            display_name: id.to_string(),
            app_path: Some(format!("/apps/{id}")),
            bundle_id: None,
            profiles: profiles
                .iter()
                .map(|(name, directory)| BrowserProfile {
                    name: name.to_string(),
                    directory: Some(directory.to_string()),
                    path: None,
                    menu_titles: Vec::new(),
                })
                .collect(),
        }
    }

    fn unreadable(id: &str) -> UnreadableProfiles {
        UnreadableProfiles {
            browser_id: id.to_string(),
            browser: id.to_string(),
            denied: true,
            reason: "Operation not permitted (os error 1)".to_string(),
        }
    }

    fn registry(
        installs: Vec<BrowserInstall>,
        unreadable: Vec<UnreadableProfiles>,
    ) -> BrowserRegistry {
        BrowserRegistry {
            browsers: installs
                .into_iter()
                .map(|install| (install.id.clone(), install))
                .collect(),
            unreadable,
        }
    }

    fn folder(registry: &BrowserRegistry, id: &str, profile: &str) -> Option<String> {
        registry
            .resolve(id, Some(profile))
            .unwrap()
            .profile_directory
    }

    #[test]
    fn recognizes_chromium_profile_folders() {
        assert_eq!(
            chromium_profile_folder("Default").as_deref(),
            Some("Default")
        );
        assert_eq!(
            chromium_profile_folder("default").as_deref(),
            Some("Default")
        );
        assert_eq!(
            chromium_profile_folder("Profile 1").as_deref(),
            Some("Profile 1")
        );
        assert_eq!(
            chromium_profile_folder(" profile 12 ").as_deref(),
            Some("Profile 12")
        );
        for name in [
            "Work",
            "Profile",
            "Profile ",
            "Profile x",
            "Profile 1 2",
            "Profile -1",
            "Guest Profile",
            "",
        ] {
            assert_eq!(chromium_profile_folder(name), None, "{name:?}");
        }
    }

    #[test]
    fn a_profile_resolves_by_name_or_by_folder() {
        let registry = registry(
            vec![install(
                "chrome",
                &[("Personal", "Default"), ("Work", "Profile 1")],
            )],
            vec![],
        );
        assert_eq!(
            folder(&registry, "chrome", "work").as_deref(),
            Some("Profile 1")
        );
        assert_eq!(
            folder(&registry, "chrome", "profile 1").as_deref(),
            Some("Profile 1")
        );
        assert_eq!(
            folder(&registry, "chrome", "Default").as_deref(),
            Some("Default")
        );
        // The list is known and has no such profile: passing the folder on
        // would make Chromium create it.
        assert_eq!(folder(&registry, "chrome", "Profile 7"), None);
        assert_eq!(folder(&registry, "chrome", "Elsewhere"), None);
    }

    #[test]
    fn a_name_wins_over_a_folder_of_the_same_spelling() {
        // Someone named a profile "Default" that lives in "Profile 2".
        let registry = registry(
            vec![install(
                "chrome",
                &[("Main", "Default"), ("Default", "Profile 2")],
            )],
            vec![],
        );
        assert_eq!(
            folder(&registry, "chrome", "Default").as_deref(),
            Some("Profile 2")
        );
    }

    #[test]
    fn a_folder_name_still_reaches_its_profile_when_the_list_is_unreadable() {
        let registry = registry(
            vec![
                install("chrome", &[]),
                install("firefox", &[]),
                install("edge", &[]),
            ],
            vec![unreadable("chrome"), unreadable("firefox")],
        );
        assert_eq!(
            folder(&registry, "chrome", "profile 3").as_deref(),
            Some("Profile 3")
        );
        assert_eq!(
            folder(&registry, "chrome", "Default").as_deref(),
            Some("Default")
        );
        // A display name cannot be turned into a folder without the list.
        assert_eq!(folder(&registry, "chrome", "Work"), None);
        // Gecko takes the profile name itself; there is no folder to pass.
        assert_eq!(folder(&registry, "firefox", "Default"), None);
        // Edge was readable and simply has no profiles listed.
        assert_eq!(folder(&registry, "edge", "Profile 3"), None);
        // The wanted profile is kept either way, for Gecko's `-P` and for display.
        let resolved = registry.resolve("chrome", Some("Work")).unwrap();
        assert_eq!(resolved.profile.as_deref(), Some("Work"));
    }

    #[test]
    fn last_known_profiles_fill_in_for_an_unreadable_list() {
        let mut browsers: HashMap<String, BrowserInstall> =
            [install("chrome", &[]), install("edge", &[])]
                .into_iter()
                .map(|install| (install.id.clone(), install))
                .collect();
        let last_scan: HashMap<String, BrowserInstall> = [
            install("chrome", &[("Work", "Profile 1")]),
            install("edge", &[("Old", "Profile 5")]),
            install("brave", &[("Gone", "Default")]),
        ]
        .into_iter()
        .map(|install| (install.id.clone(), install))
        .collect();

        keep_last_known_profiles(
            &mut browsers,
            &[unreadable("chrome"), unreadable("vivaldi")],
            &last_scan,
        );

        assert_eq!(browsers["chrome"].profiles.len(), 1);
        assert_eq!(browsers["chrome"].profiles[0].name, "Work");
        // Edge was read just now and has no profiles; the old list is not revived.
        assert!(browsers["edge"].profiles.is_empty());
        // Nothing is added for browsers that are no longer installed.
        assert_eq!(browsers.len(), 2);
        // Launch paths never come from the old scan.
        assert_eq!(browsers["chrome"].app_path.as_deref(), Some("/apps/chrome"));
    }

    #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
    #[test]
    fn a_refused_read_counts_as_denied_and_a_damaged_file_does_not() {
        let chrome = known_browsers()
            .into_iter()
            .find(|spec| spec.id == "chrome")
            .unwrap();

        let refused: Result<Vec<BrowserProfile>> =
            Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied))
                .context("failed to read /somewhere/Local State");
        let (profiles, failure) = profiles_if_readable(&chrome, refused);
        let failure = failure.expect("a failure is reported");
        assert!(profiles.is_empty());
        assert!(failure.denied);
        assert_eq!(failure.browser_id, "chrome");
        assert_eq!(failure.browser, "Google Chrome");
        assert!(
            failure.reason.contains("/somewhere/Local State"),
            "{}",
            failure.reason
        );

        let damaged: Result<Vec<BrowserProfile>> = serde_json::from_str::<serde_json::Value>("{")
            .map(|_| vec![])
            .context("not valid JSON");
        let (_, failure) = profiles_if_readable(&chrome, damaged);
        assert!(!failure.expect("a failure is reported").denied);

        let (profiles, failure) = profiles_if_readable(&chrome, Ok(vec![]));
        assert!(profiles.is_empty() && failure.is_none());
    }

    fn names(name: &str, account: &str, made_up_name: bool) -> ChromiumNames {
        ChromiumNames {
            name: name.to_string(),
            label: String::new(),
            account: account.to_string(),
            made_up_name,
        }
    }

    #[test]
    fn menu_titles_follow_what_chromium_shows_for_a_profile() {
        let titles = |own: &ChromiumNames, others: &[ChromiumNames]| {
            chromium_menu_titles(own, others.iter())
        };
        // Not signed in: the profile's name.
        assert_eq!(titles(&names("Work", "", false), &[]), ["Work"]);
        // Signed in under a name the browser made up: the account's name.
        assert_eq!(
            titles(&names("Person 1", "Ada", true), &[]),
            ["Ada", "Ada (Person 1)", "Person 1"]
        );
        // Signed in and named by the user: both.
        assert_eq!(
            titles(&names("Work", "Ada", false), &[]),
            ["Ada (Work)", "Work", "Ada"]
        );
        // Never "Ada (ada)".
        assert_eq!(titles(&names("ada", "Ada", false), &[]), ["Ada", "ada"]);

        // A second profile of the same account that goes by the account's
        // name alone: both then show their own names with it.
        assert_eq!(
            titles(
                &names("Person 2", "Ada", true),
                &[names("Person 1", "ada", true)]
            ),
            ["Ada (Person 2)", "Person 2", "Ada"]
        );
        assert_eq!(
            titles(
                &names("Person 2", "Ada", true),
                &[names("Ada", "Ada", false)]
            ),
            ["Ada (Person 2)", "Person 2", "Ada"]
        );
        // A second profile of the account that shows its own name anyway
        // leaves the account's name to this one.
        assert_eq!(
            titles(
                &names("Person 2", "Ada", true),
                &[names("Work", "Ada", false), names("Dev", "", false)]
            ),
            ["Ada", "Ada (Person 2)", "Person 2"]
        );

        // A name given by an organization stands in for the profile's own
        // and is always shown.
        let mut managed = names("Person 3", "Ada", true);
        managed.label = "Contoso".to_string();
        assert_eq!(
            titles(&managed, &[]),
            ["Ada (Contoso)", "Contoso", "Ada", "Person 3"]
        );
        managed.account = String::new();
        assert_eq!(titles(&managed, &[]), ["Contoso", "Person 3"]);
    }

    #[test]
    fn menu_titles_are_read_with_the_profiles() {
        let dir = std::env::temp_dir().join(format!("supersurfer-titles-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("Local State"),
            r#"{"profile":{"info_cache":{
                "Default":{"name":"Person 1","is_using_default_name":true,
                           "gaia_name":"Ada Lovelace","gaia_given_name":"Ada"},
                "Profile 1":{"name":"Work","is_using_default_name":false,
                             "gaia_name":"Grace Hopper","gaia_given_name":""},
                "Profile 2":{"name":"Dev"},
                "Profile 3":{"name":"Person 4","is_using_default_name":true,
                             "gaia_name":"ADA","gaia_given_name":"ada"},
                "Profile 4":{"name":"Person 5","is_using_default_name":true,
                             "oidc_identity_name":"Linus","enterprise_label":"Contoso"}
            }}}"#,
        )
        .unwrap();
        let mut profiles = discover_chromium_profiles(&dir).unwrap();
        profiles.sort_by(|a, b| a.directory.cmp(&b.directory));
        let titles: Vec<(&str, &[String])> = profiles
            .iter()
            .map(|p| (p.directory.as_deref().unwrap(), p.menu_titles.as_slice()))
            .collect();
        // "Default" and "Profile 3" share an account name, so both show
        // their own name with it.
        assert_eq!(titles[0].0, "Default");
        assert_eq!(titles[0].1, ["Ada (Person 1)", "Person 1", "Ada"]);
        // The full name where the account has no given name.
        assert_eq!(titles[1].0, "Profile 1");
        assert_eq!(titles[1].1, ["Grace Hopper (Work)", "Work", "Grace Hopper"]);
        assert_eq!(titles[2].0, "Profile 2");
        assert_eq!(titles[2].1, ["Dev"]);
        assert_eq!(titles[3].0, "Profile 3");
        assert_eq!(titles[3].1, ["ada (Person 4)", "Person 4", "ada"]);
        // Signed in through an organization, which also named the profile.
        assert_eq!(titles[4].0, "Profile 4");
        assert_eq!(
            titles[4].1,
            ["Linus (Contoso)", "Contoso", "Linus", "Person 5"]
        );
        // The profile's own name stays what the rest of SuperSurfer goes by.
        assert_eq!(profiles[4].name, "Person 5");
        let _ = std::fs::remove_dir_all(&dir);

        // A profile from a cache file that knew no titles yet.
        let cached: BrowserProfile =
            serde_json::from_str(r#"{"name":"Work","directory":"Profile 1","path":null}"#).unwrap();
        assert!(cached.menu_titles.is_empty());
        assert_eq!(cached.menu_titles_or_name(), ["Work"]);
        // And nothing is written for a profile without titles.
        assert_eq!(
            serde_json::to_string(&cached).unwrap(),
            r#"{"name":"Work","directory":"Profile 1","path":null}"#
        );
    }

    #[test]
    fn only_browsers_with_a_profile_menu_get_dock_shortcuts() {
        assert!(has_profile_menu("edge"));
        assert!(has_profile_menu("chrome"));
        assert!(has_profile_menu("chrome-canary"));
        assert!(!has_profile_menu("vivaldi"));
        assert!(!has_profile_menu("firefox"));
        assert!(!has_profile_menu("safari"));
        assert_eq!(short_name("edge"), Some("Edge"));
        assert_eq!(short_name("chrome"), Some("Chrome"));
        assert_eq!(short_name("edge-beta"), Some("Edge Beta"));
        assert_eq!(short_name("chromium"), Some("Chromium"));
        assert_eq!(short_name("no-such-browser"), None);
    }

    /// A directory where the file should be: present, but not readable as a
    /// file. This is what macOS 27 looks like from the inside, where `stat`
    /// succeeds and `open` is refused.
    #[cfg(unix)]
    #[test]
    fn an_unreadable_profile_file_is_an_error_that_names_the_file() {
        let dir = std::env::temp_dir().join(format!("supersurfer-profiles-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("Local State")).unwrap();
        std::fs::create_dir_all(dir.join("profiles.ini")).unwrap();

        let chromium = discover_chromium_profiles(&dir).unwrap_err();
        assert!(
            format!("{chromium:#}").contains("Local State"),
            "{chromium:#}"
        );
        let gecko = discover_gecko_profiles(&dir.join("profiles.ini")).unwrap_err();
        assert!(format!("{gecko:#}").contains("profiles.ini"), "{gecko:#}");

        // No file at all is not an error: the browser has never been started.
        assert!(discover_chromium_profiles(&dir.join("missing"))
            .unwrap()
            .is_empty());
        assert!(discover_gecko_profiles(&dir.join("missing.ini"))
            .unwrap()
            .is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn process_name_candidates_include_browser_aliases() {
        let names = process_name_candidates("Microsoft Edge");
        assert!(names.iter().any(|n| n.eq_ignore_ascii_case("msedge")));
        assert!(names.iter().any(|n| n.eq_ignore_ascii_case("edge")));
        assert!(names
            .iter()
            .any(|n| n.eq_ignore_ascii_case("Microsoft Edge")));
    }

    #[test]
    fn normalizes_common_display_names() {
        assert_eq!(normalize_browser_id("Google Chrome"), "chrome");
        assert_eq!(normalize_browser_id("Brave Browser"), "brave");
        assert_eq!(
            normalize_browser_id("Firefox Developer Edition"),
            "firefox-developer-edition"
        );
        assert_eq!(normalize_browser_id("Opera GX"), "opera-gx");
    }

    #[test]
    fn classifies_chromium_browsers() {
        assert!(is_chromium_browser("vivaldi"));
        assert!(is_chromium_browser("opera-gx"));
        assert!(!is_chromium_browser("firefox"));
        assert!(!is_chromium_browser("safari"));
    }

    #[test]
    fn maps_windows_prog_ids() {
        assert_eq!(browser_id_for_prog_id("ChromeHTML"), Some("chrome"));
        assert_eq!(browser_id_for_prog_id("BraveHTML"), Some("brave"));
        assert_eq!(browser_id_for_prog_id("MSEdgeHTM"), Some("edge"));
        assert_eq!(browser_id_for_prog_id("FirefoxURL"), Some("firefox"));
    }

    #[test]
    fn maps_linux_desktop_ids() {
        assert_eq!(
            browser_id_for_desktop_id("firefox_firefox.desktop"),
            Some("firefox")
        );
        assert_eq!(
            browser_id_for_desktop_id("chromium_chromium.desktop"),
            Some("chromium")
        );
    }

    #[test]
    fn parses_snap_desktop_exec_lines() {
        assert_eq!(
            parse_desktop_exec_value(
                "env BAMF_DESKTOP_FILE_HINT=/var/lib/snapd/desktop/applications/firefox_firefox.desktop /snap/bin/firefox %u"
            ),
            Some("/snap/bin/firefox".to_string())
        );
        assert_eq!(
            parse_desktop_exec_value("google-chrome-stable %U"),
            Some("google-chrome-stable".to_string())
        );
        assert_eq!(
            parse_desktop_exec_value("\"/usr/bin/firefox\" %u"),
            Some("/usr/bin/firefox".to_string())
        );
    }

    #[test]
    fn user_desktop_dir_does_not_override_system_dirs() {
        let user = PathBuf::from("/home/user/.local/share/applications");
        let extra = [PathBuf::from("/tmp/evil/applications")];
        let dirs = desktop_dir_search_order(Some(user.clone()), &extra);
        let user_at = dirs.iter().position(|dir| dir == &user).unwrap();
        let system_at = dirs
            .iter()
            .position(|dir| dir == Path::new("/usr/share/applications"))
            .unwrap();
        assert!(system_at < user_at);
        assert_eq!(dirs.last(), Some(&user));
        assert!(exec_search_dirs()
            .last()
            .is_some_and(|dir| dir.ends_with(".local/bin")));
        assert_eq!(
            exec_search_dirs().first().map(PathBuf::as_path),
            Some(Path::new("/usr/bin"))
        );
    }

    #[test]
    fn temp_executables_are_not_plausible_browsers() {
        assert!(!exec_path_is_plausible("/tmp/chrome"));
        assert!(!exec_path_is_plausible("/var/tmp/chrome"));
        assert!(!exec_path_is_plausible("/dev/shm/chrome"));
        assert!(exec_path_is_plausible("/usr/bin/firefox"));
    }

    #[test]
    fn user_writable_desktop_dir_is_not_a_trusted_system_dir() {
        let dir =
            std::env::temp_dir().join(format!("supersurfer-desktop-trust-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        assert!(!system_desktop_dir_is_trusted(&dir));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
