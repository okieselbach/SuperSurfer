//! A routing engine that stays loaded between link clicks.
//!
//! The command line builds a [`Router`] per invocation: read `config.js`, start
//! QuickJS, discover browsers, route one URL, exit. A host that stays in memory
//! (the macOS menu bar app) pays for that once and answers every later click
//! from the warm state. This module owns that state and decides when it has to
//! be refreshed:
//!
//! - `config.js` and `rules.json` are re-read when their modification time or
//!   size changed, checked on demand rather than by polling.
//! - The browser list is refreshed while idle, after a reply has gone out, and
//!   on the spot when a browser cannot be resolved.
//! - The decision log is written after the reply as well ([`Engine::maintain`]),
//!   so a click never waits for the disk.
//! - A `config.js` that stops loading does not take routing down: the last
//!   version that worked stays in use and the error is reported.
//!
//! Requests and replies are plain serializable structs with camelCase JSON
//! names; [`handle_json`] is the single entry point the C interface uses.

use crate::browser::launch::{self, LaunchPlan};
use crate::browser::registry::{normalize_browser_id, BrowserInstall, BrowserRegistry};
use crate::context::{Context, Modifiers, Opener, Platform};
use crate::routing::{parse_browser_spec, RouteDecision, RouteSource, Router};
use crate::rules::{self, Rule, RuleSet};
use anyhow::{Context as _, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};
use url::Url;

/// How old the browser list may get before it is refreshed after a reply.
const REGISTRY_MAX_AGE: Duration = Duration::from_secs(300);
/// A list shown to the user (picker, menu) should reflect a profile created a
/// moment ago, so it is refreshed first when it is older than this.
const REGISTRY_UI_MAX_AGE: Duration = Duration::from_secs(15);
/// Minimum spacing of the "browser not found, look again" refresh, so a config
/// naming a browser that is not installed does not rescan on every click.
const REGISTRY_RETRY_AGE: Duration = Duration::from_secs(10);

type FileStamp = Option<(SystemTime, u64)>;

fn stamp(path: &Path) -> FileStamp {
    let meta = std::fs::metadata(path).ok()?;
    Some((meta.modified().ok()?, meta.len()))
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum Request {
    /// Decide where a URL goes.
    Route(RouteRequest),
    /// Build the launch for a browser the user picked by hand.
    Plan(PlanRequest),
    /// Installed browsers and their profiles.
    Browsers,
    /// Saved rules from `rules.json`.
    Rules,
    /// Save "always open this domain in that browser".
    Remember(RememberRequest),
    /// Delete the saved rule for a domain.
    Forget(ForgetRequest),
    /// Re-read everything now.
    Reload,
    /// Paths, version and current problems.
    Status,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RouteRequest {
    pub url: String,
    pub opener: Option<OpenerInfo>,
    pub modifiers: Modifiers,
    /// Decide without writing the decision log: the caller is about to ask
    /// the user and will report the final choice through [`Request::Plan`].
    pub preview: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenerInfo {
    pub name: String,
    pub bundle_id: Option<String>,
    pub path: Option<String>,
}

impl From<OpenerInfo> for Opener {
    fn from(info: OpenerInfo) -> Self {
        Opener {
            name: info.name,
            bundle_id: info.bundle_id,
            path: info.path,
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PlanRequest {
    /// URL to hand to the browser, normally `launchUrl` of an earlier decision.
    pub url: String,
    /// The URL as it originally arrived, for the decision log.
    pub input_url: Option<String>,
    pub browser: String,
    pub profile: Option<String>,
    pub private_window: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RememberRequest {
    pub domain: String,
    pub browser: String,
    pub profile: Option<String>,
    pub private_window: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ForgetRequest {
    pub domain: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchInfo {
    pub app_path: String,
    pub url: String,
    pub args: Vec<String>,
    /// Arguments only reach a browser that is started as a new instance (what
    /// `open -n` does); Chromium and Gecko then hand the URL to the instance
    /// that is already running.
    pub new_instance: bool,
}

impl From<LaunchPlan> for LaunchInfo {
    fn from(plan: LaunchPlan) -> Self {
        LaunchInfo {
            new_instance: !plan.args.is_empty(),
            app_path: plan.app_path,
            url: plan.url,
            args: plan.args,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DecisionInfo {
    pub input_url: String,
    pub routed_url: String,
    pub launch_url: String,
    /// Host of the routed URL, for display.
    pub host: Option<String>,
    pub browser_id: String,
    pub browser: String,
    pub profile: Option<String>,
    pub private_window: bool,
    /// `"handler"` (config.js), `"rule"` (rules.json), `"default"`, or
    /// `"emergency"` when config.js could not be loaded at all.
    pub source: &'static str,
    pub rule_domain: Option<String>,
    pub fallback: bool,
    /// Domains to offer for "always open … in", most specific first.
    pub remember_hosts: Vec<String>,
}

impl DecisionInfo {
    fn new(decision: &RouteDecision, source: &'static str) -> Self {
        let routed = Url::parse(&decision.routed_url).ok();
        DecisionInfo {
            input_url: decision.input_url.clone(),
            routed_url: decision.routed_url.clone(),
            launch_url: decision.launch_url.clone(),
            host: routed
                .as_ref()
                .and_then(|url| url.host_str())
                .filter(|host| !host.is_empty())
                .map(str::to_string),
            browser_id: decision.browser_id.clone(),
            browser: decision.browser.clone(),
            profile: decision.profile.clone(),
            private_window: decision.private,
            source,
            rule_domain: decision.rule_domain.clone(),
            fallback: decision.fallback,
            remember_hosts: routed
                .as_ref()
                .map(rules::remember_candidates)
                .unwrap_or_default(),
        }
    }
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RouteReply {
    pub ok: bool,
    pub error: Option<String>,
    pub decision: Option<DecisionInfo>,
    /// How to start the browser. Missing when the URL may not be launched.
    pub launch: Option<LaunchInfo>,
    pub launch_error: Option<String>,
    /// Set while `config.js` fails to load, even when routing still works from
    /// the last good version.
    pub config_error: Option<String>,
    /// Time the engine itself spent on this request, in microseconds. What a
    /// caller measures on top of this is the trip to the engine and back.
    pub engine_micros: u64,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanReply {
    pub ok: bool,
    pub error: Option<String>,
    pub browser: Option<String>,
    pub profile: Option<String>,
    pub launch: Option<LaunchInfo>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserInfo {
    pub id: String,
    pub name: String,
    pub app_path: String,
    pub profiles: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowsersReply {
    pub ok: bool,
    pub error: Option<String>,
    /// Id of `defaultBrowser`; listed first.
    pub default_browser_id: Option<String>,
    pub browsers: Vec<BrowserInfo>,
    /// Names of browsers whose profile list the operating system would not
    /// let SuperSurfer read. They are listed without profiles, or with the
    /// profiles of the last complete scan where that is kept.
    pub profiles_blocked: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RuleInfo {
    pub domain: String,
    pub browser: String,
    pub browser_name: String,
    pub profile: Option<String>,
    pub private_window: bool,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RulesReply {
    pub ok: bool,
    pub error: Option<String>,
    pub path: Option<String>,
    pub rules: Vec<RuleInfo>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusReply {
    pub ok: bool,
    pub version: &'static str,
    pub config_path: Option<String>,
    pub rules_path: Option<String>,
    pub log_path: Option<String>,
    pub config_error: Option<String>,
    pub rules_error: Option<String>,
    /// Display name of `defaultBrowser`.
    pub default_browser: Option<String>,
    /// True once, right after this run created the initial config.
    pub fresh_bootstrap: bool,
    pub landing_url: &'static str,
}

struct Paths {
    config: PathBuf,
    rules: PathBuf,
}

pub struct Engine {
    router: Option<Router>,
    paths: Option<Paths>,
    /// Stamp of `config.js` at the last load attempt, successful or not, so a
    /// broken config is parsed again only after it changed.
    config_attempt: Option<FileStamp>,
    rules_stamp: FileStamp,
    config_error: Option<String>,
    registry_checked: Instant,
    /// False until the browser list has been rebuilt without the on-disk cache
    /// once. Startup answers from the cache; the full scan follows when idle.
    registry_fresh: bool,
    bootstrapped: bool,
    fresh_bootstrap: bool,
    /// Decision-log lines waiting to be written by [`Engine::maintain`].
    pending_log: Vec<String>,
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

impl Engine {
    /// Creates an empty engine. Nothing is read until the first request.
    pub fn new() -> Self {
        Engine {
            router: None,
            paths: None,
            config_attempt: None,
            rules_stamp: None,
            config_error: None,
            registry_checked: Instant::now(),
            registry_fresh: false,
            bootstrapped: false,
            fresh_bootstrap: false,
            pending_log: Vec::new(),
        }
    }

    pub fn route(&mut self, request: &RouteRequest) -> RouteReply {
        let started = Instant::now();
        let mut reply = self.route_inner(request);
        reply.engine_micros = u64::try_from(started.elapsed().as_micros()).unwrap_or(u64::MAX);
        reply
    }

    fn route_inner(&mut self, request: &RouteRequest) -> RouteReply {
        self.refresh();
        let context = Context {
            opener: request.opener.clone().map(Opener::from),
            platform: Platform::current(),
            modifiers: request.modifiers.clone(),
        };

        let Some(mut decided) = self.preview(&request.url, &context) else {
            return self.route_without_config(&request.url, request.preview);
        };
        // A browser installed, moved or removed since the last look makes
        // resolution fail or fall back. Look again once before settling.
        let unresolved = match &decided {
            Ok(decision) => decision.fallback,
            Err(_) => true,
        };
        if unresolved && self.registry_checked.elapsed() > REGISTRY_RETRY_AGE {
            self.refresh_registry();
            if let Some(retried) = self.preview(&request.url, &context) {
                decided = retried;
            }
        }

        match decided {
            Ok(decision) => {
                if !request.preview {
                    self.pending_log.push(decision.log_line());
                }
                let source = decision.source.as_str();
                self.reply(&decision, source)
            }
            Err(err) => RouteReply {
                error: Some(format!("{err:#}")),
                config_error: self.config_error.clone(),
                ..RouteReply::default()
            },
        }
    }

    pub fn plan(&mut self, request: &PlanRequest) -> PlanReply {
        self.refresh();
        match self.plan_inner(request) {
            Ok(reply) => reply,
            Err(err) => PlanReply {
                error: Some(format!("{err:#}")),
                ..PlanReply::default()
            },
        }
    }

    pub fn browsers(&mut self) -> BrowsersReply {
        self.refresh();
        if !self.registry_fresh || self.registry_checked.elapsed() > REGISTRY_UI_MAX_AGE {
            self.refresh_registry();
        }
        let default_browser_id = self
            .router
            .as_ref()
            .and_then(|router| router.default_browser_spec().ok())
            .map(|spec| parse_browser_spec(&spec).0);
        let listed = self.with_registry(|registry| {
            let browsers = registry
                .list()
                .into_iter()
                .filter_map(browser_info)
                .collect::<Vec<_>>();
            let mut blocked: Vec<String> = registry
                .unreadable_profiles()
                .iter()
                .filter(|failure| failure.denied)
                .map(|failure| failure.browser.clone())
                .collect();
            blocked.sort_by_key(|name| name.to_lowercase());
            (browsers, blocked)
        });
        match listed {
            Ok((mut browsers, profiles_blocked)) => {
                browsers.sort_by_cached_key(|browser| {
                    (
                        Some(&browser.id) != default_browser_id.as_ref(),
                        browser.name.to_lowercase(),
                    )
                });
                BrowsersReply {
                    ok: true,
                    error: None,
                    default_browser_id,
                    browsers,
                    profiles_blocked,
                }
            }
            Err(err) => BrowsersReply {
                error: Some(format!("{err:#}")),
                ..BrowsersReply::default()
            },
        }
    }

    pub fn rules(&mut self) -> RulesReply {
        self.refresh();
        let Some(path) = self.paths.as_ref().map(|paths| paths.rules.clone()) else {
            return RulesReply {
                error: Some("the config directory is not available".to_string()),
                ..RulesReply::default()
            };
        };
        let shown = Some(path.display().to_string());
        let set = match RuleSet::load(&path) {
            Ok(set) => set,
            Err(err) => {
                return RulesReply {
                    error: Some(format!("{err:#}")),
                    path: shown,
                    ..RulesReply::default()
                }
            }
        };
        let rules = self
            .with_registry(|registry| {
                set.rules()
                    .iter()
                    .map(|rule| RuleInfo {
                        domain: rule.domain.clone(),
                        browser: rule.browser.clone(),
                        browser_name: registry
                            .resolve(&rule.browser, None)
                            .map(|resolved| resolved.display_name)
                            .unwrap_or_else(|_| rule.browser.clone()),
                        profile: rule.profile.clone(),
                        private_window: rule.private,
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        RulesReply {
            ok: true,
            error: None,
            path: shown,
            rules,
        }
    }

    pub fn remember(&mut self, request: &RememberRequest) -> RulesReply {
        self.refresh();
        let rule = Rule {
            domain: request.domain.clone(),
            browser: request.browser.clone(),
            profile: request.profile.clone(),
            private: request.private_window,
        };
        match self.edit_rules(|set| set.upsert(rule)) {
            Ok(()) => self.rules(),
            Err(err) => self.rules_unchanged(&err),
        }
    }

    pub fn forget(&mut self, request: &ForgetRequest) -> RulesReply {
        self.refresh();
        let domain = request.domain.clone();
        match self.edit_rules(|set| {
            set.remove(&domain);
            Ok(())
        }) {
            Ok(()) => self.rules(),
            Err(err) => self.rules_unchanged(&err),
        }
    }

    pub fn reload(&mut self) -> StatusReply {
        self.config_attempt = None;
        self.refresh();
        self.refresh_registry();
        self.status()
    }

    pub fn status(&mut self) -> StatusReply {
        self.refresh();
        let default_browser = self.router.as_ref().and_then(|router| {
            let spec = router.default_browser_spec().ok()?;
            let (id, profile) = parse_browser_spec(&spec);
            Some(match router.registry().resolve(&id, profile.as_deref()) {
                Ok(resolved) => match resolved.profile {
                    Some(profile) => format!("{} ({profile})", resolved.display_name),
                    None => resolved.display_name,
                },
                Err(_) => spec,
            })
        });
        StatusReply {
            ok: true,
            version: env!("CARGO_PKG_VERSION"),
            config_path: self
                .paths
                .as_ref()
                .map(|paths| paths.config.display().to_string()),
            rules_path: self
                .paths
                .as_ref()
                .map(|paths| paths.rules.display().to_string()),
            log_path: crate::logging::log_file()
                .ok()
                .map(|path| path.display().to_string()),
            config_error: self.config_error.clone(),
            rules_error: self
                .router
                .as_ref()
                .and_then(|router| router.rules_error().map(str::to_string)),
            default_browser,
            fresh_bootstrap: std::mem::take(&mut self.fresh_bootstrap),
            landing_url: crate::bootstrap::LANDING_URL,
        }
    }

    /// Work that can wait until the answer is out: writing the decision log
    /// and keeping the browser list current. Hosts call this after delivering
    /// a reply, never before, so no click waits for it.
    pub fn maintain(&mut self) {
        self.flush_log();
        if self.router.is_none() {
            return;
        }
        if !self.registry_fresh || self.registry_checked.elapsed() > REGISTRY_MAX_AGE {
            self.refresh_registry();
        }
    }

    fn flush_log(&mut self) {
        for line in self.pending_log.drain(..) {
            // Never gate browser launch on log I/O (permissions, full disk, etc.).
            if let Err(err) = crate::logging::append_decision(&line) {
                eprintln!("warning: failed to append decision log: {err}");
            }
        }
    }

    /// Bring the loaded state in line with the files on disk. Costs two
    /// `stat` calls when nothing changed.
    fn refresh(&mut self) {
        if !self.bootstrapped {
            self.bootstrapped = true;
            match crate::bootstrap::ensure_ready() {
                Ok(fresh) => self.fresh_bootstrap = fresh,
                Err(err) => eprintln!("warning: first-run setup failed: {err:#}"),
            }
        }
        if self.paths.is_none() {
            match crate::config::config_path() {
                Ok(config) => {
                    let rules = RuleSet::path_beside(&config);
                    self.paths = Some(Paths { config, rules });
                }
                Err(err) => {
                    self.config_error = Some(format!("{err:#}"));
                    return;
                }
            }
        }
        let Some(paths) = self.paths.as_ref() else {
            return;
        };
        let config_now = stamp(&paths.config);
        let rules_now = stamp(&paths.rules);

        if self.config_attempt != Some(config_now) {
            self.config_attempt = Some(config_now);
            self.rules_stamp = rules_now;
            match Router::new() {
                Ok(router) => {
                    self.router = Some(router);
                    self.config_error = None;
                    self.registry_checked = Instant::now();
                    self.registry_fresh = false;
                }
                Err(err) => {
                    // Keep routing with whatever loaded before; a typo in
                    // config.js must not turn every click into a dead link.
                    let message = format!("{err:#}");
                    eprintln!("warning: config.js not loaded: {message}");
                    self.config_error = Some(message);
                }
            }
        } else if rules_now != self.rules_stamp {
            self.rules_stamp = rules_now;
            if let Some(router) = self.router.as_mut() {
                router.reload_rules();
            }
        }
    }

    fn refresh_registry(&mut self) {
        self.registry_checked = Instant::now();
        self.registry_fresh = true;
        let Some(router) = self.router.as_mut() else {
            return;
        };
        match BrowserRegistry::discover_fresh() {
            Ok(registry) => router.replace_registry(registry),
            Err(err) => eprintln!("warning: browser discovery failed: {err:#}"),
        }
    }

    fn preview(&self, url: &str, context: &Context) -> Option<Result<RouteDecision>> {
        self.router
            .as_ref()
            .map(|router| router.preview(url, context))
    }

    fn reply(&self, decision: &RouteDecision, source: &'static str) -> RouteReply {
        let (launch, launch_error) = match launch::launch_plan(decision) {
            Ok(plan) => (Some(LaunchInfo::from(plan)), None),
            Err(err) => (None, Some(format!("{err:#}"))),
        };
        RouteReply {
            ok: true,
            error: None,
            decision: Some(DecisionInfo::new(decision, source)),
            launch,
            launch_error,
            config_error: self.config_error.clone(),
            engine_micros: 0,
        }
    }

    /// `config.js` never loaded in this run, so there is no router and no
    /// `defaultBrowser`. A click must still open somewhere: hand the URL,
    /// untouched, to a browser that is certainly there.
    fn route_without_config(&mut self, raw_url: &str, preview: bool) -> RouteReply {
        let emergency = || -> Result<RouteDecision> {
            let normalized = crate::input_url::normalize_input_url(raw_url)?;
            let url = Url::parse(&normalized)
                .with_context(|| format!("invalid URL: {normalized}"))?
                .to_string();
            let registry = BrowserRegistry::discover()?;
            let browser = registry
                .resolve("safari", None)
                .ok()
                .or_else(|| {
                    let first = registry.list().into_iter().next()?;
                    registry.resolve(&first.id, None).ok()
                })
                .context("no browser found")?;
            Ok(RouteDecision {
                input_url: url.clone(),
                routed_url: url.clone(),
                launch_url: url,
                browser_id: browser.id,
                browser: browser.display_name,
                profile: None,
                profile_directory: None,
                private: false,
                matched_handler: false,
                fallback: true,
                app_path: browser.app_path,
                source: RouteSource::Default,
                rule_domain: None,
            })
        };
        match emergency() {
            Ok(decision) => {
                if !preview {
                    self.pending_log
                        .push(format!("{} [config.js not loaded]", decision.log_line()));
                }
                self.reply(&decision, "emergency")
            }
            Err(err) => RouteReply {
                error: Some(format!("{err:#}")),
                config_error: self.config_error.clone(),
                ..RouteReply::default()
            },
        }
    }

    fn plan_inner(&mut self, request: &PlanRequest) -> Result<PlanReply> {
        let url = Url::parse(request.url.trim())
            .with_context(|| format!("invalid URL: {}", request.url))?
            .to_string();
        let browser_id = normalize_browser_id(request.browser.trim()).to_string();
        let profile = request
            .profile
            .as_deref()
            .map(str::trim)
            .filter(|profile| !profile.is_empty());

        let mut resolved = self.with_registry(|registry| registry.resolve(&browser_id, profile))?;
        if resolved.is_err() && self.registry_checked.elapsed() > REGISTRY_RETRY_AGE {
            self.refresh_registry();
            resolved = self.with_registry(|registry| registry.resolve(&browser_id, profile))?;
        }
        let resolved = resolved?;

        let decision = RouteDecision {
            input_url: request
                .input_url
                .clone()
                .filter(|input| !input.trim().is_empty())
                .unwrap_or_else(|| url.clone()),
            routed_url: url.clone(),
            launch_url: url,
            browser_id: resolved.id,
            browser: resolved.display_name,
            profile: resolved.profile,
            profile_directory: resolved.profile_directory,
            private: request.private_window,
            matched_handler: false,
            fallback: false,
            app_path: resolved.app_path,
            source: RouteSource::Default,
            rule_domain: None,
        };
        let plan = launch::launch_plan(&decision)?;
        self.pending_log
            .push(format!("{} [picked]", decision.log_line()));
        Ok(PlanReply {
            ok: true,
            error: None,
            browser: Some(decision.browser),
            profile: decision.profile,
            launch: Some(plan.into()),
        })
    }

    /// Reply for a rule change that did not happen: the reason, plus the
    /// rules as they still are (when the file can be read at all).
    fn rules_unchanged(&mut self, err: &anyhow::Error) -> RulesReply {
        RulesReply {
            ok: false,
            error: Some(format!("{err:#}")),
            ..self.rules()
        }
    }

    /// Change `rules.json` on disk and make the result effective at once.
    /// The file is read strictly first: one that cannot be parsed is left
    /// alone rather than replaced.
    fn edit_rules(&mut self, change: impl FnOnce(&mut RuleSet) -> Result<()>) -> Result<()> {
        let path = self
            .paths
            .as_ref()
            .map(|paths| paths.rules.clone())
            .context("the config directory is not available")?;
        let mut set = RuleSet::load(&path)?;
        change(&mut set)?;
        set.save(&path)?;
        // Do not wait for the stamp check: two saves can land within one
        // timestamp tick and leave the file size unchanged.
        self.rules_stamp = stamp(&path);
        if let Some(router) = self.router.as_mut() {
            router.reload_rules();
        }
        Ok(())
    }

    /// Run `read` against the loaded browser list, or against a fresh one when
    /// no config (and so no router) is loaded.
    fn with_registry<T>(&self, read: impl FnOnce(&BrowserRegistry) -> T) -> Result<T> {
        match self.router.as_ref() {
            Some(router) => Ok(read(router.registry())),
            None => Ok(read(&BrowserRegistry::discover()?)),
        }
    }
}

fn browser_info(install: &BrowserInstall) -> Option<BrowserInfo> {
    let app_path = install.app_path.clone()?;
    let mut profiles: Vec<String> = install
        .profiles
        .iter()
        .map(|profile| profile.name.clone())
        .filter(|name| !name.trim().is_empty())
        .collect();
    profiles.sort_by_key(|name| name.to_lowercase());
    profiles.dedup_by(|a, b| a.eq_ignore_ascii_case(b));
    Some(BrowserInfo {
        id: install.id.clone(),
        name: install.display_name.clone(),
        app_path,
        profiles,
    })
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.flush_log();
    }
}

/// Reply for a request that never reached an operation. Every reply type
/// tolerates this shape: `ok` is false and `error` says why.
pub fn error_json(message: &str) -> String {
    serde_json::json!({ "ok": false, "error": message }).to_string()
}

fn to_json<T: Serialize>(reply: &T) -> String {
    serde_json::to_string(reply)
        .unwrap_or_else(|err| error_json(&format!("reply could not be encoded: {err}")))
}

/// Answer one JSON request. See [`Request`] for the operations. Call
/// [`Engine::maintain`] once the reply has been delivered.
pub fn handle_json(engine: &mut Engine, request: &str) -> String {
    match serde_json::from_str::<Request>(request) {
        Ok(Request::Route(request)) => to_json(&engine.route(&request)),
        Ok(Request::Plan(request)) => to_json(&engine.plan(&request)),
        Ok(Request::Browsers) => to_json(&engine.browsers()),
        Ok(Request::Rules) => to_json(&engine.rules()),
        Ok(Request::Remember(request)) => to_json(&engine.remember(&request)),
        Ok(Request::Forget(request)) => to_json(&engine.forget(&request)),
        Ok(Request::Reload) => to_json(&engine.reload()),
        Ok(Request::Status) => to_json(&engine.status()),
        Err(err) => error_json(&format!("invalid request: {err}")),
    }
}
