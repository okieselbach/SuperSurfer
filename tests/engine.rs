//! End-to-end tests for the resident routing engine, through the same JSON
//! interface the macOS app uses.
//!
//! They run against a private HOME so nothing touches the real configuration.
//! Config and log directories cannot be redirected through the environment on
//! Windows, which is why this file is Unix-only (like the bootstrap tests).
#![cfg(unix)]

use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};
use supersurfer::browser::registry::BrowserRegistry;
use supersurfer::engine::{handle_json, Engine};

const SAFELINK: &str = "https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fgist.github.com%2Forg%2Frepo%3Futm_source%3Dmail&data=abc&reserved=0";

/// One shared environment for the whole test binary: HOME is process-wide, so
/// the tests take turns.
struct Sandbox {
    /// Installed browser ids, sorted. Never empty.
    browsers: Vec<String>,
}

fn sandbox() -> (&'static Sandbox, MutexGuard<'static, ()>) {
    static LOCK: Mutex<()> = Mutex::new(());
    static SANDBOX: OnceLock<Sandbox> = OnceLock::new();
    let guard = LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let sandbox = SANDBOX.get_or_init(|| {
        let home = std::env::temp_dir().join(format!("supersurfer-engine-{}", std::process::id()));
        let _ = fs::remove_dir_all(&home);
        fs::create_dir_all(&home).unwrap();
        std::env::set_var("HOME", &home);
        std::env::remove_var("XDG_CONFIG_HOME");
        std::env::remove_var("XDG_DATA_HOME");
        plant_browsers(&home);

        let registry = BrowserRegistry::discover_fresh().expect("browser discovery");
        let browsers: Vec<String> = registry.list().iter().map(|b| b.id.clone()).collect();
        assert!(
            !browsers.is_empty(),
            "these tests need at least one known browser on the machine"
        );
        Sandbox { browsers }
    });
    // Every test starts from a clean slate.
    let _ = fs::remove_file(rules_path());
    let _ = fs::remove_file(log_path());
    (sandbox, guard)
}

/// Linux discovers browsers through `.desktop` files, including the per-user
/// directory, so two can be planted there. On macOS the real `/Applications`
/// is scanned (Safari is always present). Chrome profile data lives under
/// HOME on both, so profiles are deterministic wherever Chrome exists.
fn plant_browsers(home: &std::path::Path) {
    #[cfg(target_os = "linux")]
    {
        let apps = home.join(".local/share/applications");
        fs::create_dir_all(&apps).unwrap();
        for id in ["firefox.desktop", "google-chrome.desktop"] {
            fs::write(
                apps.join(id),
                "[Desktop Entry]\nType=Application\nName=Test Browser\nExec=/usr/bin/true %U\n",
            )
            .unwrap();
        }
    }
    let chrome_data = chrome_data_dir(home);
    fs::create_dir_all(&chrome_data).unwrap();
    fs::write(
        chrome_data.join("Local State"),
        r#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 1":{"name":"Work"}}}}"#,
    )
    .unwrap();
}

fn chrome_data_dir(home: &std::path::Path) -> PathBuf {
    if cfg!(target_os = "macos") {
        home.join("Library/Application Support/Google/Chrome")
    } else {
        home.join(".config/google-chrome")
    }
}

/// Chrome's profile list, taken away for one test. It comes back however the
/// test ends, because every test shares the sandbox.
struct ProfileListTaken {
    path: PathBuf,
    content: Vec<u8>,
}

impl ProfileListTaken {
    fn remember() -> Self {
        let home = PathBuf::from(std::env::var_os("HOME").expect("the sandbox sets HOME"));
        let path = chrome_data_dir(&home).join("Local State");
        let content = fs::read(&path).expect("the sandbox plants Chrome's profile list");
        ProfileListTaken { path, content }
    }

    /// Other profiles than the two the sandbox plants.
    fn replaced_with(local_state: &str) -> Self {
        let taken = Self::remember();
        fs::write(&taken.path, local_state).unwrap();
        taken
    }

    /// A directory where the file should be: it exists, and reading it
    /// fails. macOS 27 looks like this from the inside, where `stat` on
    /// another app's browser data succeeds and `open` is refused.
    fn by_a_directory() -> Self {
        let taken = Self::remember();
        fs::remove_file(&taken.path).unwrap();
        fs::create_dir(&taken.path).unwrap();
        taken
    }

    /// File mode 000: a real "permission denied". `None` when this user
    /// reads the file anyway, as root does.
    fn by_file_mode() -> Option<Self> {
        use std::os::unix::fs::PermissionsExt;
        let taken = Self::remember();
        fs::set_permissions(&taken.path, fs::Permissions::from_mode(0o000)).unwrap();
        fs::read(&taken.path).is_err().then_some(taken)
    }
}

impl Drop for ProfileListTaken {
    fn drop(&mut self) {
        let _ = fs::remove_dir(&self.path);
        let _ = fs::remove_file(&self.path);
        let _ = fs::write(&self.path, &self.content);
    }
}

fn config_path() -> PathBuf {
    supersurfer::config::config_path().unwrap()
}

fn rules_path() -> PathBuf {
    config_path().with_file_name("rules.json")
}

fn log_path() -> PathBuf {
    supersurfer::logging::log_file().unwrap()
}

/// The decision log as it is once the engine got around to writing it. The
/// log is written after the reply, in `maintain`, so a click never waits for
/// the disk.
fn log_text(engine: &mut Engine) -> String {
    engine.maintain();
    fs::read_to_string(log_path()).unwrap_or_default()
}

/// Write `config.js`. Each call produces a different file size, because the
/// engine notices changes by modification time and size, and two writes
/// within one test can share a timestamp.
fn write_config(default_browser: &str, handlers: &str) {
    static REVISION: AtomicUsize = AtomicUsize::new(1);
    let revision = REVISION.fetch_add(1, Ordering::SeqCst);
    fs::write(
        config_path(),
        format!(
            "// {}\nexport default {{\n  defaultBrowser: \"{default_browser}\",\n  handlers: [{handlers}],\n}};\n",
            "r".repeat(revision)
        ),
    )
    .unwrap();
}

fn call(engine: &mut Engine, request: Value) -> Value {
    serde_json::from_str(&handle_json(engine, &request.to_string())).expect("reply is JSON")
}

fn route(engine: &mut Engine, url: &str) -> Value {
    call(engine, json!({ "op": "route", "url": url }))
}

/// A fresh engine on top of a valid config with no handlers.
fn engine_with_default(default_browser: &str) -> Engine {
    write_config(default_browser, "");
    Engine::new()
}

#[test]
fn routes_to_the_default_browser_and_reports_how_to_launch_it() {
    let (sandbox, _guard) = sandbox();
    let default = &sandbox.browsers[0];
    let mut engine = engine_with_default(default);

    let reply = route(&mut engine, "https://www.example.com/page?utm_source=x");
    assert_eq!(reply["ok"], true, "{reply}");
    let decision = &reply["decision"];
    assert_eq!(decision["browserId"], default.as_str());
    assert_eq!(decision["source"], "default");
    assert_eq!(decision["fallback"], false);
    assert_eq!(decision["host"], "www.example.com");
    assert_eq!(decision["rememberHosts"], json!(["example.com"]));
    // Tracking parameters are stripped before the browser sees the URL.
    assert_eq!(decision["launchUrl"], "https://www.example.com/page");

    let launch = &reply["launch"];
    assert!(!launch["appPath"].as_str().unwrap().is_empty());
    assert_eq!(launch["url"], decision["launchUrl"]);
    assert_eq!(launch["args"], json!([]));
    assert_eq!(launch["newInstance"], false);
    assert_eq!(reply["launchError"], Value::Null);
    assert_eq!(reply["configError"], Value::Null);

    // Nothing touches the log before the reply is out.
    assert!(!log_path().exists());
    assert!(log_text(&mut engine).contains("https://www.example.com/page"));
}

#[test]
fn reply_shapes_match_what_the_app_decodes() {
    let (sandbox, _guard) = sandbox();
    let mut engine = engine_with_default(&sandbox.browsers[0]);
    let keys = |value: &Value| -> Vec<String> {
        let mut keys: Vec<String> = value.as_object().unwrap().keys().cloned().collect();
        keys.sort();
        keys
    };

    let reply = route(&mut engine, "https://example.com/");
    assert_eq!(
        keys(&reply),
        [
            "configError",
            "decision",
            "engineMicros",
            "error",
            "launch",
            "launchError",
            "ok"
        ]
    );
    assert_eq!(
        keys(&reply["decision"]),
        [
            "browser",
            "browserId",
            "fallback",
            "host",
            "inputUrl",
            "launchUrl",
            "privateWindow",
            "profile",
            "rememberHosts",
            "routedUrl",
            "ruleDomain",
            "source"
        ]
    );
    assert_eq!(
        keys(&reply["launch"]),
        ["appPath", "args", "newInstance", "url"]
    );

    let reply = call(
        &mut engine,
        json!({ "op": "plan", "url": "https://example.com/", "browser": sandbox.browsers[0] }),
    );
    assert_eq!(
        keys(&reply),
        ["browser", "error", "launch", "ok", "profile"]
    );

    let reply = call(&mut engine, json!({ "op": "browsers" }));
    assert_eq!(
        keys(&reply),
        [
            "browsers",
            "defaultBrowserId",
            "error",
            "ok",
            "profilesBlocked"
        ]
    );
    assert_eq!(
        keys(&reply["browsers"][0]),
        ["appPath", "id", "name", "profiles"]
    );

    call(
        &mut engine,
        json!({ "op": "remember", "domain": "example.com", "browser": sandbox.browsers[0] }),
    );
    let reply = call(&mut engine, json!({ "op": "rules" }));
    assert_eq!(keys(&reply), ["error", "ok", "path", "rules"]);
    assert_eq!(
        keys(&reply["rules"][0]),
        [
            "browser",
            "browserName",
            "domain",
            "privateWindow",
            "profile"
        ]
    );

    let reply = call(&mut engine, json!({ "op": "status" }));
    assert_eq!(
        keys(&reply),
        [
            "configError",
            "configPath",
            "defaultBrowser",
            "defaultBrowserId",
            "defaultBrowserName",
            "defaultBrowserProfile",
            "freshBootstrap",
            "landingUrl",
            "logPath",
            "ok",
            "rulesError",
            "rulesPath",
            "version"
        ]
    );
    assert_eq!(reply["version"], env!("CARGO_PKG_VERSION"));
}

#[test]
fn safelink_is_matched_and_remembered_by_its_destination() {
    let (sandbox, _guard) = sandbox();
    let mut engine = engine_with_default(&sandbox.browsers[0]);

    let decision = route(&mut engine, SAFELINK)["decision"].clone();
    assert_eq!(decision["routedUrl"], "https://gist.github.com/org/repo");
    // Default cleaning mode: the browser still gets the wrapper.
    assert_eq!(decision["launchUrl"], SAFELINK);
    assert_eq!(decision["host"], "gist.github.com");
    assert_eq!(
        decision["rememberHosts"],
        json!(["gist.github.com", "github.com"])
    );
}

#[test]
fn config_changes_are_picked_up_without_a_restart() {
    let (sandbox, _guard) = sandbox();
    let default = &sandbox.browsers[0];
    let other = sandbox.browsers.last().unwrap();
    let mut engine = engine_with_default(default);
    assert_eq!(
        route(&mut engine, "https://example.org/")["decision"]["source"],
        "default"
    );

    write_config(
        default,
        &format!("{{ match: domain(\"example.org\"), browser: \"{other}\" }}"),
    );
    let decision = route(&mut engine, "https://sub.example.org/")["decision"].clone();
    assert_eq!(decision["source"], "handler");
    assert_eq!(decision["browserId"], other.as_str());
    assert_eq!(
        route(&mut engine, "https://example.com/")["decision"]["source"],
        "default"
    );
}

#[test]
fn saved_rules_apply_until_forgotten() {
    let (sandbox, _guard) = sandbox();
    let default = &sandbox.browsers[0];
    let other = sandbox.browsers.last().unwrap();
    let mut engine = engine_with_default(default);

    let reply = call(
        &mut engine,
        json!({ "op": "remember", "domain": "https://Docs.Example.net/intro", "browser": other }),
    );
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["rules"][0]["domain"], "docs.example.net");
    assert!(!reply["rules"][0]["browserName"]
        .as_str()
        .unwrap()
        .is_empty());
    assert!(rules_path().exists());

    let decision = route(&mut engine, "https://api.docs.example.net/v1")["decision"].clone();
    assert_eq!(decision["source"], "rule");
    assert_eq!(decision["ruleDomain"], "docs.example.net");
    assert_eq!(decision["browserId"], other.as_str());
    assert_eq!(
        route(&mut engine, "https://example.net/")["decision"]["source"],
        "default"
    );

    let reply = call(
        &mut engine,
        json!({ "op": "forget", "domain": "docs.example.net" }),
    );
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["rules"], json!([]));
    assert_eq!(
        route(&mut engine, "https://docs.example.net/")["decision"]["source"],
        "default"
    );
}

#[test]
fn rules_edited_by_hand_are_picked_up() {
    let (sandbox, _guard) = sandbox();
    let default = &sandbox.browsers[0];
    let mut engine = engine_with_default(default);
    assert_eq!(
        route(&mut engine, "https://wiki.example.net/")["decision"]["source"],
        "default"
    );

    fs::write(
        rules_path(),
        format!(r#"{{ "rules": [ {{ "domain": "example.net", "browser": "{default}" }} ] }}"#),
    )
    .unwrap();
    let decision = route(&mut engine, "https://wiki.example.net/")["decision"].clone();
    assert_eq!(decision["source"], "rule");
    assert_eq!(decision["ruleDomain"], "example.net");
}

#[test]
fn config_handlers_win_over_saved_rules() {
    let (sandbox, _guard) = sandbox();
    let default = &sandbox.browsers[0];
    write_config(
        default,
        &format!("{{ match: host(\"example.org\"), browser: \"{default}\" }}"),
    );
    let mut engine = Engine::new();
    call(
        &mut engine,
        json!({ "op": "remember", "domain": "example.org", "browser": default }),
    );

    assert_eq!(
        route(&mut engine, "https://example.org/")["decision"]["source"],
        "handler"
    );
    // The handler is for the exact host; the saved rule covers subdomains.
    assert_eq!(
        route(&mut engine, "https://sub.example.org/")["decision"]["source"],
        "rule"
    );
}

#[test]
fn a_broken_rules_file_is_reported_and_never_overwritten() {
    let (sandbox, _guard) = sandbox();
    let default = &sandbox.browsers[0];
    let mut engine = engine_with_default(default);
    fs::write(rules_path(), "{ definitely not json").unwrap();

    // Routing carries on without saved rules.
    let reply = route(&mut engine, "https://example.com/");
    assert_eq!(reply["decision"]["source"], "default");
    let status = call(&mut engine, json!({ "op": "status" }));
    assert!(status["rulesError"]
        .as_str()
        .unwrap()
        .contains("rules.json"));

    let reply = call(
        &mut engine,
        json!({ "op": "remember", "domain": "example.com", "browser": default }),
    );
    assert_eq!(reply["ok"], false);
    assert!(reply["error"].as_str().unwrap().contains("rules.json"));
    assert_eq!(
        fs::read_to_string(rules_path()).unwrap(),
        "{ definitely not json"
    );
}

#[test]
fn a_config_that_stops_loading_keeps_the_last_good_version() {
    let (sandbox, _guard) = sandbox();
    let default = &sandbox.browsers[0];
    let mut engine = engine_with_default(default);
    assert_eq!(route(&mut engine, "https://example.com/")["ok"], true);

    fs::write(config_path(), "export default { defaultBrowser: ").unwrap();
    let reply = route(&mut engine, "https://example.com/");
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["decision"]["source"], "default");
    assert_eq!(reply["decision"]["browserId"], default.as_str());
    assert!(reply["configError"].is_string(), "{reply}");
    let status = call(&mut engine, json!({ "op": "status" }));
    assert!(status["configError"].is_string());

    write_config(default, "");
    let reply = route(&mut engine, "https://example.com/");
    assert_eq!(reply["configError"], Value::Null);
}

#[test]
fn links_still_open_when_the_config_never_loaded() {
    let (_sandbox, _guard) = sandbox();
    fs::create_dir_all(config_path().parent().unwrap()).unwrap();
    fs::write(config_path(), "this is not javascript {{{").unwrap();
    let mut engine = Engine::new();

    let reply = route(&mut engine, "https://example.com/?utm_source=x");
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["decision"]["source"], "emergency");
    assert_eq!(reply["decision"]["fallback"], true);
    // Without a config there is no cleaning mode to apply: the URL is untouched.
    assert_eq!(reply["launch"]["url"], "https://example.com/?utm_source=x");
    assert!(reply["configError"].is_string());
    assert!(log_text(&mut engine).contains("[config.js not loaded]"));

    // The picker still works too.
    let browsers = call(&mut engine, json!({ "op": "browsers" }));
    assert_eq!(browsers["ok"], true, "{browsers}");
    assert!(!browsers["browsers"].as_array().unwrap().is_empty());
}

#[test]
fn preview_leaves_the_log_alone_and_a_pick_is_logged() {
    let (sandbox, _guard) = sandbox();
    let default = &sandbox.browsers[0];
    let other = sandbox.browsers.last().unwrap();
    let mut engine = engine_with_default(default);

    let reply = call(
        &mut engine,
        json!({ "op": "route", "url": SAFELINK, "preview": true }),
    );
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(log_text(&mut engine), "");

    let decision = &reply["decision"];
    let reply = call(
        &mut engine,
        json!({
            "op": "plan",
            "url": decision["launchUrl"],
            "inputUrl": decision["inputUrl"],
            "browser": other,
        }),
    );
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["launch"]["url"], SAFELINK);
    assert!(!reply["browser"].as_str().unwrap().is_empty());
    let log = log_text(&mut engine);
    assert_eq!(log.lines().count(), 1);
    assert!(log.trim_end().ends_with("[picked]"), "{log}");
}

#[test]
fn urls_that_must_not_be_launched_get_no_launch_plan() {
    let (sandbox, _guard) = sandbox();
    let default = &sandbox.browsers[0];
    let mut engine = engine_with_default(default);

    let reply = route(&mut engine, "javascript:alert(1)");
    assert_eq!(reply["launch"], Value::Null, "{reply}");
    assert!(
        reply["ok"] == false || reply["launchError"].is_string(),
        "{reply}"
    );

    for url in [
        "javascript:alert(1)",
        "file://fileserver/share/page.html",
        "not a url",
    ] {
        let reply = call(
            &mut engine,
            json!({ "op": "plan", "url": url, "browser": default }),
        );
        assert_eq!(reply["ok"], false, "{url}: {reply}");
        assert_eq!(reply["launch"], Value::Null);
    }

    let reply = call(
        &mut engine,
        json!({ "op": "plan", "url": "https://example.com/", "browser": "no-such-browser" }),
    );
    assert_eq!(reply["ok"], false);
    assert!(reply["error"].as_str().unwrap().contains("no-such-browser"));
}

#[test]
fn opener_and_modifier_keys_reach_config_js() {
    let (sandbox, _guard) = sandbox();
    let default = &sandbox.browsers[0];
    let other = sandbox.browsers.last().unwrap();
    write_config(
        default,
        &format!(
            "{{ match: (url, ctx) => ctx.modifiers.shift && !ctx.modifiers.alt, browser: \"{other}\" }},\n\
             {{ match: (url, ctx) => ctx.opener?.bundleId === \"com.tinyspeck.slackmacgap\", browser: \"{other}\" }}"
        ),
    );
    let mut engine = Engine::new();
    let source = |engine: &mut Engine, extra: Value| -> Value {
        let mut request = json!({ "op": "route", "url": "https://example.com/" });
        request
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        call(engine, request)["decision"]["source"].clone()
    };

    assert_eq!(source(&mut engine, json!({})), "default");
    assert_eq!(
        source(&mut engine, json!({ "modifiers": { "shift": true } })),
        "handler"
    );
    assert_eq!(
        source(
            &mut engine,
            json!({ "modifiers": { "shift": true, "alt": true } })
        ),
        "default"
    );
    assert_eq!(
        source(
            &mut engine,
            json!({ "opener": { "name": "Slack", "bundleId": "com.tinyspeck.slackmacgap" } })
        ),
        "handler"
    );
    assert_eq!(
        source(&mut engine, json!({ "opener": { "name": "Mail" } })),
        "default"
    );
}

#[test]
fn profiles_are_listed_and_turned_into_launch_arguments() {
    let (sandbox, _guard) = sandbox();
    if !sandbox.browsers.iter().any(|id| id == "chrome") {
        eprintln!("skipped: Google Chrome is not installed on this machine");
        return;
    }
    let mut engine = engine_with_default("chrome");

    let browsers = call(&mut engine, json!({ "op": "browsers" }));
    assert_eq!(browsers["defaultBrowserId"], "chrome");
    // defaultBrowser is listed first, profiles by name.
    assert_eq!(browsers["browsers"][0]["id"], "chrome");
    assert_eq!(
        browsers["browsers"][0]["profiles"],
        json!(["Personal", "Work"])
    );

    call(
        &mut engine,
        json!({ "op": "remember", "domain": "example.net", "browser": "chrome", "profile": "work" }),
    );
    let reply = route(&mut engine, "https://example.net/");
    assert_eq!(reply["decision"]["source"], "rule");
    assert_eq!(reply["decision"]["profile"], "work");
    assert_eq!(
        reply["launch"]["args"],
        json!(["--profile-directory=Profile 1"])
    );
    assert_eq!(reply["launch"]["newInstance"], true);

    let reply = call(
        &mut engine,
        json!({
            "op": "plan",
            "url": "https://example.com/",
            "browser": "Google Chrome",
            "profile": "Personal",
            "privateWindow": true,
        }),
    );
    assert_eq!(
        reply["launch"]["args"],
        json!(["--profile-directory=Default", "--incognito"])
    );
}

#[test]
fn the_default_browser_is_reported_whole_and_in_parts() {
    let (sandbox, _guard) = sandbox();
    if !sandbox.browsers.iter().any(|id| id == "chrome") {
        eprintln!("skipped: Google Chrome is not installed on this machine");
        return;
    }
    // By the folder of the profile, as config.js may name it. The parts keep
    // it the way it is written: a menu with names of its own for profiles
    // looks the profile up itself.
    let mut engine = engine_with_default("chrome:Profile 1");
    let status = call(&mut engine, json!({ "op": "status" }));
    let name = status["defaultBrowserName"].as_str().unwrap_or_default();
    assert!(!name.is_empty(), "{status}");
    assert_eq!(status["defaultBrowserId"], "chrome", "{status}");
    assert_eq!(status["defaultBrowserProfile"], "Profile 1", "{status}");
    assert_eq!(
        status["defaultBrowser"],
        format!("{name} (Profile 1)"),
        "{status}"
    );

    // Without a profile there is none to report.
    let mut engine = engine_with_default("chrome");
    let status = call(&mut engine, json!({ "op": "status" }));
    assert_eq!(status["defaultBrowserId"], "chrome", "{status}");
    assert_eq!(status["defaultBrowserProfile"], Value::Null, "{status}");
    assert_eq!(status["defaultBrowser"], name, "{status}");
}

#[test]
fn dock_shortcuts_are_offered_for_profiles_of_browsers_with_a_profile_menu() {
    let (sandbox, _guard) = sandbox();
    if !sandbox.browsers.iter().any(|id| id == "chrome") {
        eprintln!("skipped: Google Chrome is not installed on this machine");
        return;
    }
    // "Work" is signed in and was named by the user, so Chrome's menu shows
    // the account with it. Two profiles may share a name; their folders tell
    // them apart.
    let _profiles = ProfileListTaken::replaced_with(
        r#"{"profile":{"info_cache":{
            "Default":{"name":"Personal"},
            "Profile 1":{"name":"Work","is_using_default_name":false,"gaia_given_name":"Ada"},
            "Profile 7":{"name":"personal"}
        }}}"#,
    );
    let mut engine = engine_with_default("chrome");
    let keys = |value: &Value| -> Vec<String> {
        let mut keys: Vec<String> = value.as_object().unwrap().keys().cloned().collect();
        keys.sort();
        keys
    };

    let reply = call(&mut engine, json!({ "op": "shortcuts" }));
    assert_eq!(keys(&reply), ["browsers", "error", "ok", "profilesBlocked"]);
    assert_eq!(reply["ok"], true);
    let browsers = reply["browsers"].as_array().unwrap();
    let chrome = browsers
        .iter()
        .find(|browser| browser["id"] == "chrome")
        .expect("Chrome is offered");
    assert_eq!(
        keys(chrome),
        ["appPath", "bundleId", "id", "name", "profiles", "shortName"]
    );
    assert_eq!(chrome["name"], "Google Chrome");
    assert_eq!(chrome["shortName"], "Chrome");
    assert_eq!(
        chrome["profiles"],
        json!([
            {
                "name": "Personal",
                "chosenName": null,
                "directory": "Default",
                "menuTitles": ["Personal"],
                "launchArgs": ["--profile-directory=Default"],
            },
            {
                "name": "personal",
                "chosenName": null,
                "directory": "Profile 7",
                "menuTitles": ["personal"],
                "launchArgs": ["--profile-directory=Profile 7"],
            },
            {
                "name": "Work",
                "chosenName": null,
                "directory": "Profile 1",
                "menuTitles": ["Ada (Work)", "Work", "Ada"],
                "launchArgs": ["--profile-directory=Profile 1"],
            },
        ])
    );
    // Firefox keeps each profile in a process of its own and Safari has no
    // way in from outside: neither is offered.
    assert!(browsers
        .iter()
        .all(|browser| browser["id"] != "firefox" && browser["id"] != "safari"));
}

/// Dock shortcuts in the sandbox, as the macOS app writes them: each a small
/// app whose Info.plist says which profile it is for. They go away however
/// the test ends, because every test shares the sandbox.
#[cfg(target_os = "macos")]
struct ShortcutsPlanted {
    folder: PathBuf,
}

#[cfg(target_os = "macos")]
impl ShortcutsPlanted {
    fn new() -> Self {
        let home = PathBuf::from(std::env::var_os("HOME").expect("the sandbox sets HOME"));
        let folder = home.join("Applications/SuperSurfer Shortcuts");
        let _ = fs::remove_dir_all(&folder);
        ShortcutsPlanted { folder }
    }

    /// The shortcut SuperSurfer makes for the profile that Chrome keeps in
    /// `directory` and calls `profile`, under the name it gets at first.
    fn plant(&self, directory: &str, profile: &str) {
        let contents = self
            .folder
            .join(format!("Chrome {profile}.app"))
            .join("Contents");
        fs::create_dir_all(&contents).unwrap();
        fs::write(
            contents.join("Info.plist"),
            format!(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Chrome {profile}</string>
	<key>SuperSurferBrowser</key>
	<string>chrome</string>
	<key>SuperSurferProfileDirectory</key>
	<string>{directory}</string>
	<key>SuperSurferProfileName</key>
	<string>{profile}</string>
	<key>SuperSurferBrowserPath</key>
	<string>/Applications/Google Chrome.app</string>
	<key>SuperSurferBrowserNames</key>
	<array>
		<string>Chrome</string>
		<string>Google Chrome</string>
	</array>
</dict>
</plist>
"#
            ),
        )
        .unwrap();
    }

    /// What a rename in the Finder does: the app gets another name, and
    /// nothing inside it changes.
    fn rename(&self, from: &str, to: &str) {
        fs::rename(
            self.folder.join(format!("{from}.app")),
            self.folder.join(format!("{to}.app")),
        )
        .unwrap();
    }

    fn remove(&self, title: &str) {
        fs::remove_dir_all(self.folder.join(format!("{title}.app"))).unwrap();
    }
}

#[cfg(target_os = "macos")]
impl Drop for ShortcutsPlanted {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.folder);
    }
}

#[cfg(target_os = "macos")]
#[test]
fn a_profile_goes_by_the_name_its_dock_shortcut_was_given() {
    let (sandbox, _guard) = sandbox();
    if !sandbox.browsers.iter().any(|id| id == "chrome") {
        eprintln!("skipped: Google Chrome is not installed on this machine");
        return;
    }
    let shortcuts = ShortcutsPlanted::new();
    shortcuts.plant("Default", "Personal");
    shortcuts.plant("Profile 1", "Work");
    // The user calls the first profile "Home". The second shortcut keeps
    // the name SuperSurfer gave it, which nobody chose.
    shortcuts.rename("Chrome Personal", "Chrome Home");

    let chosen_names = |engine: &mut Engine| -> Value {
        let reply = call(engine, json!({ "op": "shortcuts" }));
        let chrome = reply["browsers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|browser| browser["id"] == "chrome")
            .expect("Chrome is offered")
            .clone();
        // By the browser's name: "Personal" (Default), then "Work".
        json!([
            chrome["profiles"][0]["chosenName"],
            chrome["profiles"][1]["chosenName"]
        ])
    };
    let arguments = |engine: &mut Engine, profile: &str| -> Value {
        let reply = call(
            engine,
            json!({ "op": "plan", "url": "https://example.com/", "browser": "chrome", "profile": profile }),
        );
        reply["launch"]["args"].clone()
    };

    // config.js names the profile the user's way, capitals aside.
    let mut engine = engine_with_default("chrome:home");
    let reply = route(&mut engine, "https://example.com/");
    assert_eq!(reply["decision"]["profile"], "home", "{reply}");
    assert_eq!(
        reply["launch"]["args"],
        json!(["--profile-directory=Default"]),
        "{reply}"
    );
    let status = call(&mut engine, json!({ "op": "status" }));
    assert_eq!(status["defaultBrowser"], "Google Chrome (home)", "{status}");
    assert_eq!(status["defaultBrowserProfile"], "home", "{status}");

    // The menus are told what each profile is called.
    assert_eq!(chosen_names(&mut engine), json!(["Home", null]));

    // What the browser calls a profile, and its folder, go on working.
    for (profile, folder) in [
        ("Home", "Default"),
        ("Personal", "Default"),
        ("Default", "Default"),
        ("Work", "Profile 1"),
        ("Profile 1", "Profile 1"),
    ] {
        assert_eq!(
            arguments(&mut engine, profile),
            json!([format!("--profile-directory={folder}")]),
            "{profile}"
        );
    }

    // Renamed again: whatever is asked next goes by the new name.
    shortcuts.rename("Chrome Home", "Chrome Office");
    assert_eq!(chosen_names(&mut engine), json!(["Office", null]));
    assert_eq!(
        arguments(&mut engine, "office"),
        json!(["--profile-directory=Default"])
    );

    // And again, with an "ü" the way a Mac's disk may hand it back: a "u"
    // and the dots after it. A saved rule names the profile by it, with the
    // "ü" in one piece. The name is known with the next link: the engine
    // sees that the folder of shortcuts is not what it was.
    shortcuts.rename("Chrome Office", "Chrome Bu\u{308}ro");
    fs::write(
        rules_path(),
        "{ \"rules\": [ { \"domain\": \"example.net\", \"browser\": \"chrome\", \"profile\": \"B\u{fc}ro\" } ] }",
    )
    .unwrap();
    let reply = route(&mut engine, "https://example.net/");
    assert_eq!(reply["decision"]["source"], "rule", "{reply}");
    assert_eq!(reply["decision"]["profile"], "B\u{fc}ro", "{reply}");
    assert_eq!(
        reply["launch"]["args"],
        json!(["--profile-directory=Default"]),
        "{reply}"
    );
    // The name before that one is no name any more. An unknown profile is
    // left out, as it always was.
    let reply = route(&mut engine, "https://example.com/");
    assert_eq!(reply["decision"]["profile"], "home", "{reply}");
    assert_eq!(reply["launch"]["args"], json!([]), "{reply}");

    // A shortcut called what another profile is called says nothing about
    // its own: "work" stays the profile that Chrome calls "Work".
    shortcuts.remove("Chrome Work");
    shortcuts.rename("Chrome Bu\u{308}ro", "Chrome work");
    assert_eq!(chosen_names(&mut engine), json!([null, null]));
    assert_eq!(
        arguments(&mut engine, "work"),
        json!(["--profile-directory=Profile 1"])
    );
}

#[test]
fn a_profile_list_that_cannot_be_read_does_not_stop_anything() {
    let (sandbox, _guard) = sandbox();
    if !sandbox.browsers.iter().any(|id| id == "chrome") {
        eprintln!("skipped: Google Chrome is not installed on this machine");
        return;
    }
    let mut engine = engine_with_default("chrome:Profile 1");
    let listed = |engine: &mut Engine| -> (Value, Value) {
        let reply = call(engine, json!({ "op": "browsers" }));
        assert_eq!(reply["ok"], true, "{reply}");
        let chrome = reply["browsers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|browser| browser["id"] == "chrome")
            .expect("Chrome stays listed");
        (chrome["profiles"].clone(), reply["profilesBlocked"].clone())
    };
    // A complete scan first. macOS keeps a copy of it on disk.
    assert_eq!(
        listed(&mut engine),
        (json!(["Personal", "Work"]), json!([]))
    );

    let taken = ProfileListTaken::by_a_directory();
    // Look again now rather than when the browser list has aged.
    let status = call(&mut engine, json!({ "op": "reload" }));
    assert_eq!(status["ok"], true, "{status}");
    assert_eq!(status["configError"], Value::Null, "{status}");

    // macOS falls back to the profiles of the last complete scan; Linux has
    // no such copy and scans from scratch every time.
    let remembered = cfg!(target_os = "macos");
    let (profiles, blocked) = listed(&mut engine);
    let expected = if remembered {
        json!(["Personal", "Work"])
    } else {
        json!([])
    };
    assert_eq!(profiles, expected);
    // The file is damaged, not refused, so there is no permission to ask for.
    assert_eq!(blocked, json!([]));

    // A profile named by its folder needs no list.
    let reply = route(&mut engine, "https://example.com/");
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["decision"]["browserId"], "chrome");
    assert_eq!(reply["decision"]["profile"], "Profile 1");
    assert_eq!(
        reply["launch"]["args"],
        json!(["--profile-directory=Profile 1"])
    );

    // A profile named the way Chrome shows it does. Without the list the
    // link still opens, in whichever profile Chrome used last.
    write_config("chrome:Work", "");
    call(&mut engine, json!({ "op": "reload" }));
    let reply = route(&mut engine, "https://example.com/");
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["decision"]["profile"], "Work");
    let expected = if remembered {
        json!(["--profile-directory=Profile 1"])
    } else {
        json!([])
    };
    assert_eq!(reply["launch"]["args"], expected);

    drop(taken);
    call(&mut engine, json!({ "op": "reload" }));
    assert_eq!(
        listed(&mut engine),
        (json!(["Personal", "Work"]), json!([]))
    );
    let reply = route(&mut engine, "https://example.com/");
    assert_eq!(
        reply["launch"]["args"],
        json!(["--profile-directory=Profile 1"])
    );
}

#[test]
fn a_refused_profile_list_is_reported_as_blocked() {
    let (sandbox, _guard) = sandbox();
    if !sandbox.browsers.iter().any(|id| id == "chrome") {
        eprintln!("skipped: Google Chrome is not installed on this machine");
        return;
    }
    let Some(taken) = ProfileListTaken::by_file_mode() else {
        eprintln!("skipped: this user reads files whatever their mode");
        return;
    };
    let mut engine = engine_with_default("chrome");

    let reply = call(&mut engine, json!({ "op": "browsers" }));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["profilesBlocked"], json!(["Google Chrome"]));
    assert_eq!(reply["browsers"][0]["id"], "chrome");

    let routed = route(&mut engine, "https://example.com/");
    assert_eq!(routed["ok"], true, "{routed}");
    assert_eq!(routed["decision"]["browserId"], "chrome");
    assert!(routed["launch"].is_object(), "{routed}");

    drop(taken);
    call(&mut engine, json!({ "op": "reload" }));
    let reply = call(&mut engine, json!({ "op": "browsers" }));
    assert_eq!(reply["profilesBlocked"], json!([]));
    assert_eq!(
        reply["browsers"][0]["profiles"],
        json!(["Personal", "Work"])
    );
}

/// What happened on the first Mac with macOS 27: setup stopped at the first
/// profile list it was not allowed to read, before `config.js` was written.
#[test]
fn first_run_setup_gets_past_a_profile_list_it_cannot_read() {
    let (sandbox, _guard) = sandbox();
    if !sandbox.browsers.iter().any(|id| id == "chrome") {
        eprintln!("skipped: Google Chrome is not installed on this machine");
        return;
    }
    let _taken = ProfileListTaken::by_a_directory();
    // As on a machine SuperSurfer has never run on.
    let config = config_path();
    fs::remove_dir_all(config.parent().unwrap()).unwrap();

    let mut engine = Engine::new();
    let status = call(&mut engine, json!({ "op": "status" }));
    assert_eq!(status["ok"], true, "{status}");
    assert_eq!(status["freshBootstrap"], true, "{status}");
    assert_eq!(status["configError"], Value::Null, "{status}");
    assert!(config.exists(), "first run writes config.js");

    let reply = route(&mut engine, "https://example.com/");
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["decision"]["source"], "default");
    assert!(reply["launch"].is_object(), "{reply}");
}

#[test]
fn the_c_interface_reaches_the_same_engine() {
    let (sandbox, _guard) = sandbox();
    write_config(&sandbox.browsers[0], "");
    let ask = |request: Value| -> Value {
        let request = CString::new(request.to_string()).unwrap();
        // SAFETY: valid NUL-terminated request; the reply is freed exactly once.
        unsafe {
            let raw = supersurfer::ffi::supersurfer_call(request.as_ptr());
            assert!(!raw.is_null());
            let text = CStr::from_ptr(raw).to_string_lossy().into_owned();
            supersurfer::ffi::supersurfer_free(raw);
            serde_json::from_str(&text).expect("reply is JSON")
        }
    };

    let status = ask(json!({ "op": "reload" }));
    assert_eq!(status["ok"], true, "{status}");
    assert_eq!(status["configError"], Value::Null);
    assert!(status["configPath"]
        .as_str()
        .unwrap()
        .ends_with("config.js"));

    let reply = ask(json!({ "op": "route", "url": "https://example.com/", "preview": true }));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["decision"]["browserId"], sandbox.browsers[0].as_str());
}
