//! Saved routing rules in `rules.json`, next to `config.js`.
//!
//! `config.js` is code: it can look at the opener, at running processes or at
//! any part of the URL, so no UI can rewrite it safely. Rules a UI saves
//! ("always open github.com in Edge") therefore live in this plain data file.
//! They are consulted after the `handlers` in `config.js` and before
//! `defaultBrowser`.

use anyhow::{bail, Context as _, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use url::{Host, Url};

pub const RULES_FILE: &str = "rules.json";

const FORMAT_VERSION: u32 = 1;

/// Second-level labels that act as a public suffix under two-letter country
/// TLDs (`co.uk`, `com.au`, …). Only used to *suggest* a parent domain to
/// remember, so a short heuristic is enough: no rule is created without the
/// user picking the suggestion.
const COUNTRY_SECOND_LEVEL: &[&str] = &["ac", "co", "com", "edu", "gov", "ne", "net", "or", "org"];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rule {
    /// Host the rule applies to. Subdomains match too, like the `domain()`
    /// matcher in `config.js`.
    pub domain: String,
    /// Browser id as used in `config.js` (`"chrome"`, `"edge"`, …).
    pub browser: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub private: bool,
}

impl Rule {
    /// Browser target in the `config.js` notation (`"edge"`, `"chrome:Work"`).
    pub fn browser_spec(&self) -> String {
        match &self.profile {
            Some(profile) => format!("{}:{profile}", self.browser),
            None => self.browser.clone(),
        }
    }

    fn normalized(mut self) -> Result<Self> {
        self.domain = normalize_domain(&self.domain)?;
        let browser = self.browser.trim();
        if browser.is_empty() {
            bail!("the rule for {} names no browser", self.domain);
        }
        self.browser = crate::browser::registry::normalize_browser_id(browser).to_string();
        self.profile = self
            .profile
            .map(|profile| profile.trim().to_string())
            .filter(|profile| !profile.is_empty());
        Ok(self)
    }
}

#[derive(Debug, Serialize, Deserialize)]
struct RulesFile {
    #[serde(default = "current_version")]
    version: u32,
    #[serde(default)]
    rules: Vec<Rule>,
}

fn current_version() -> u32 {
    FORMAT_VERSION
}

fn is_false(value: &bool) -> bool {
    !*value
}

#[derive(Debug, Clone, Default)]
pub struct RuleSet {
    rules: Vec<Rule>,
}

impl RuleSet {
    pub fn default_path() -> Result<PathBuf> {
        Ok(crate::config::config_dir()?.join(RULES_FILE))
    }

    /// `rules.json` belongs to the `config.js` it sits next to.
    pub fn path_beside(config_path: &Path) -> PathBuf {
        config_path.with_file_name(RULES_FILE)
    }

    /// A missing or empty file is an empty rule set. Anything unreadable is an
    /// error, so callers that are about to rewrite the file can refuse instead
    /// of replacing what they could not parse.
    pub fn load(path: &Path) -> Result<Self> {
        let content = match fs::read_to_string(path) {
            Ok(content) => content,
            Err(err) if err.kind() == ErrorKind::NotFound => return Ok(Self::default()),
            Err(err) => {
                return Err(err).with_context(|| format!("failed to read {}", path.display()))
            }
        };
        if content.trim().is_empty() {
            return Ok(Self::default());
        }
        let file: RulesFile = serde_json::from_str(&content)
            .with_context(|| format!("{} is not valid", path.display()))?;
        if file.version > FORMAT_VERSION {
            bail!(
                "{} uses format {}, which this SuperSurfer version does not know",
                path.display(),
                file.version
            );
        }
        let mut set = Self::default();
        for (index, rule) in file.rules.into_iter().enumerate() {
            set.upsert(rule)
                .with_context(|| format!("rule {} in {}", index + 1, path.display()))?;
        }
        Ok(set)
    }

    /// Routing must not fail because of a broken rules file: report the problem
    /// and carry on without saved rules.
    pub fn load_lenient(path: &Path) -> (Self, Option<String>) {
        match Self::load(path) {
            Ok(set) => (set, None),
            Err(err) => {
                let message = format!("{err:#}");
                eprintln!("warning: ignoring saved rules: {message}");
                (Self::default(), Some(message))
            }
        }
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        let file = RulesFile {
            version: FORMAT_VERSION,
            rules: self.rules.clone(),
        };
        let mut data = serde_json::to_string_pretty(&file)?;
        data.push('\n');
        // Write beside the target and rename, so a crash mid-write cannot leave
        // a truncated file behind.
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, data).with_context(|| format!("failed to write {}", tmp.display()))?;
        crate::config::restrict_file(&tmp);
        fs::rename(&tmp, path).with_context(|| format!("failed to replace {}", path.display()))?;
        Ok(())
    }

    pub fn rules(&self) -> &[Rule] {
        &self.rules
    }

    pub fn len(&self) -> usize {
        self.rules.len()
    }

    pub fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }

    /// The rule for a web URL, if any. When several domains match, the most
    /// specific one wins regardless of their order in the file.
    pub fn lookup(&self, url: &Url) -> Option<&Rule> {
        if !matches!(url.scheme(), "http" | "https") {
            return None;
        }
        let host = url.host_str()?;
        let host = host.strip_suffix('.').unwrap_or(host);
        self.rules
            .iter()
            .filter(|rule| domain_matches(host, &rule.domain))
            .max_by_key(|rule| rule.domain.len())
    }

    /// Add a rule, replacing an existing one for the same domain.
    pub fn upsert(&mut self, rule: Rule) -> Result<()> {
        let rule = rule.normalized()?;
        match self
            .rules
            .iter_mut()
            .find(|existing| existing.domain == rule.domain)
        {
            Some(existing) => *existing = rule,
            None => self.rules.push(rule),
        }
        Ok(())
    }

    /// Returns whether a rule was removed.
    pub fn remove(&mut self, domain: &str) -> bool {
        let wanted =
            normalize_domain(domain).unwrap_or_else(|_| domain.trim().to_ascii_lowercase());
        let before = self.rules.len();
        self.rules.retain(|rule| rule.domain != wanted);
        self.rules.len() != before
    }
}

fn domain_matches(host: &str, domain: &str) -> bool {
    if host == domain {
        return true;
    }
    // Subdomain: the host ends in ".<domain>". Checked on bytes to avoid an
    // allocation per rule on every link.
    host.len() > domain.len()
        && host.ends_with(domain)
        && host.as_bytes()[host.len() - domain.len() - 1] == b'.'
}

/// Turn what a person types or pastes (`GitHub.com`, `*.github.com`,
/// `https://github.com/org/repo`) into the bare host a rule is keyed on.
pub fn normalize_domain(input: &str) -> Result<String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        bail!("the domain is empty");
    }
    let candidate = if trimmed.contains("://") {
        let lower = trimmed.to_ascii_lowercase();
        if !(lower.starts_with("http://") || lower.starts_with("https://")) {
            bail!("not a web address: {trimmed}");
        }
        trimmed.to_string()
    } else {
        let bare = trimmed.trim_start_matches("*.").trim_start_matches('.');
        format!("https://{bare}")
    };
    // The URL parser lowercases, applies IDNA and drops any port, path or
    // credentials that came along with a pasted link.
    let parsed =
        Url::parse(&candidate).with_context(|| format!("not a valid domain: {trimmed}"))?;
    let host = parsed
        .host_str()
        .unwrap_or_default()
        .trim_end_matches('.')
        .to_string();
    if host.is_empty() {
        bail!("not a valid domain: {trimmed}");
    }
    Ok(host)
}

/// Domains worth offering when the user wants to remember a browser for the
/// site behind `url`: the host itself (without a leading `www.`) and, when it
/// is a subdomain, the site it belongs to. Most specific first.
pub fn remember_candidates(url: &Url) -> Vec<String> {
    if !matches!(url.scheme(), "http" | "https") {
        return Vec::new();
    }
    match url.host() {
        Some(Host::Domain(domain)) => {
            let domain = domain.trim_end_matches('.');
            if domain.is_empty() {
                return Vec::new();
            }
            let host = match domain.strip_prefix("www.") {
                Some(rest) if rest.contains('.') => rest,
                _ => domain,
            };
            let site = site_domain(host);
            if site == host {
                vec![host.to_string()]
            } else {
                vec![host.to_string(), site.to_string()]
            }
        }
        // IP addresses have no parent domain.
        Some(_) => url
            .host_str()
            .map(|host| vec![host.to_string()])
            .unwrap_or_default(),
        None => Vec::new(),
    }
}

fn site_domain(host: &str) -> &str {
    let labels: Vec<&str> = host.split('.').collect();
    let count = labels.len();
    if count <= 2 {
        return host;
    }
    let tld = labels[count - 1];
    let second = labels[count - 2];
    let keep = if tld.len() == 2 && COUNTRY_SECOND_LEVEL.contains(&second) {
        3
    } else {
        2
    };
    if count <= keep {
        return host;
    }
    let skipped: usize = labels[..count - keep]
        .iter()
        .map(|label| label.len() + 1)
        .sum();
    &host[skipped..]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(domain: &str, browser: &str) -> Rule {
        Rule {
            domain: domain.to_string(),
            browser: browser.to_string(),
            profile: None,
            private: false,
        }
    }

    fn url(value: &str) -> Url {
        Url::parse(value).unwrap()
    }

    fn temp_file(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("supersurfer-rules-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir.join(RULES_FILE)
    }

    #[test]
    fn rule_matches_domain_and_subdomains_only() {
        let mut set = RuleSet::default();
        set.upsert(rule("github.com", "edge")).unwrap();

        assert!(set.lookup(&url("https://github.com/org/repo")).is_some());
        assert!(set.lookup(&url("https://gist.github.com/x")).is_some());
        assert!(set.lookup(&url("http://GitHub.com./")).is_some());
        // A label boundary is required: notgithub.com is a different site.
        assert!(set.lookup(&url("https://notgithub.com/")).is_none());
        assert!(set
            .lookup(&url("https://github.com.evil.example/"))
            .is_none());
    }

    #[test]
    fn most_specific_domain_wins_whatever_the_order() {
        let mut set = RuleSet::default();
        set.upsert(rule("gist.github.com", "firefox")).unwrap();
        set.upsert(rule("github.com", "edge")).unwrap();

        let gist = url("https://gist.github.com/x");
        assert_eq!(set.lookup(&gist).unwrap().browser, "firefox");
        let main = url("https://github.com/x");
        assert_eq!(set.lookup(&main).unwrap().browser, "edge");
    }

    #[test]
    fn rules_only_apply_to_web_urls() {
        let mut set = RuleSet::default();
        set.upsert(rule("localhost", "firefox")).unwrap();
        assert!(set.lookup(&url("http://localhost:3000/")).is_some());
        assert!(set.lookup(&url("file://localhost/tmp/page.html")).is_none());
    }

    #[test]
    fn upsert_replaces_the_rule_for_the_same_domain() {
        let mut set = RuleSet::default();
        set.upsert(rule("GitHub.com", "Google Chrome")).unwrap();
        set.upsert(Rule {
            profile: Some(" Work ".to_string()),
            ..rule("*.github.com", "Microsoft Edge")
        })
        .unwrap();

        assert_eq!(set.len(), 1);
        let saved = &set.rules()[0];
        assert_eq!(saved.domain, "github.com");
        assert_eq!(saved.browser, "edge");
        assert_eq!(saved.profile.as_deref(), Some("Work"));
        assert_eq!(saved.browser_spec(), "edge:Work");
    }

    #[test]
    fn remove_reports_whether_a_rule_existed() {
        let mut set = RuleSet::default();
        set.upsert(rule("github.com", "edge")).unwrap();
        assert!(set.remove("https://GitHub.com/org"));
        assert!(!set.remove("github.com"));
        assert!(set.is_empty());
    }

    #[test]
    fn save_and_load_round_trip() {
        let path = temp_file("roundtrip");
        let mut set = RuleSet::default();
        set.upsert(rule("github.com", "edge")).unwrap();
        set.upsert(Rule {
            profile: Some("Work".to_string()),
            private: true,
            ..rule("intranet.example", "chrome")
        })
        .unwrap();
        set.save(&path).unwrap();

        let text = fs::read_to_string(&path).unwrap();
        assert!(text.contains("\"version\": 1"));
        // Defaults are left out so the file stays pleasant to edit by hand.
        assert_eq!(text.matches("\"private\"").count(), 1);
        assert_eq!(text.matches("\"profile\"").count(), 1);

        let loaded = RuleSet::load(&path).unwrap();
        assert_eq!(loaded.rules(), set.rules());
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn missing_and_empty_files_are_empty_rule_sets() {
        let path = temp_file("missing");
        assert!(RuleSet::load(&path).unwrap().is_empty());
        fs::write(&path, "  \n").unwrap();
        assert!(RuleSet::load(&path).unwrap().is_empty());
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn hand_written_file_is_normalized_on_load() {
        let path = temp_file("handwritten");
        fs::write(
            &path,
            r#"{ "rules": [ { "domain": "*.Example.COM", "browser": "Firefox" } ] }"#,
        )
        .unwrap();
        let set = RuleSet::load(&path).unwrap();
        assert_eq!(set.rules()[0].domain, "example.com");
        assert_eq!(set.rules()[0].browser, "firefox");
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn broken_file_is_an_error_but_does_not_stop_routing() {
        let path = temp_file("broken");
        fs::write(&path, "{ not json").unwrap();
        assert!(RuleSet::load(&path).is_err());
        let (set, error) = RuleSet::load_lenient(&path);
        assert!(set.is_empty());
        assert!(error.unwrap().contains("rules.json"));

        fs::write(&path, r#"{ "version": 99, "rules": [] }"#).unwrap();
        let err = RuleSet::load(&path).unwrap_err();
        assert!(format!("{err:#}").contains("format 99"));

        fs::write(
            &path,
            r#"{ "rules": [ { "domain": "", "browser": "edge" } ] }"#,
        )
        .unwrap();
        let err = RuleSet::load(&path).unwrap_err();
        assert!(format!("{err:#}").contains("rule 1"));
        let _ = fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn normalizes_what_people_type() {
        assert_eq!(normalize_domain(" GitHub.com ").unwrap(), "github.com");
        assert_eq!(normalize_domain("*.github.com").unwrap(), "github.com");
        assert_eq!(normalize_domain(".github.com").unwrap(), "github.com");
        assert_eq!(
            normalize_domain("https://user@Gist.GitHub.com:8443/a/b?c#d").unwrap(),
            "gist.github.com"
        );
        assert_eq!(
            normalize_domain("github.com/org/repo").unwrap(),
            "github.com"
        );
        assert_eq!(
            normalize_domain("bücher.example").unwrap(),
            "xn--bcher-kva.example"
        );
        assert_eq!(
            normalize_domain("192.168.1.10:8080").unwrap(),
            "192.168.1.10"
        );
        assert!(normalize_domain("").is_err());
        assert!(normalize_domain("*.").is_err());
        assert!(normalize_domain("file:///etc/hosts").is_err());
        assert!(normalize_domain("two words").is_err());
    }

    #[test]
    fn suggests_host_and_site_to_remember() {
        let candidates = |value: &str| remember_candidates(&url(value));
        assert_eq!(candidates("https://github.com/x"), ["github.com"]);
        assert_eq!(candidates("https://www.heise.de/x"), ["heise.de"]);
        assert_eq!(
            candidates("https://gist.github.com/x"),
            ["gist.github.com", "github.com"]
        );
        assert_eq!(
            candidates("https://contoso.sharepoint.com/sites/x"),
            ["contoso.sharepoint.com", "sharepoint.com"]
        );
        assert_eq!(
            candidates("https://a.b.example.co.uk/"),
            ["a.b.example.co.uk", "example.co.uk"]
        );
        assert_eq!(candidates("https://www.example.co.uk/"), ["example.co.uk"]);
        assert_eq!(candidates("http://localhost:3000/"), ["localhost"]);
        assert_eq!(candidates("http://192.168.1.10/"), ["192.168.1.10"]);
        assert!(candidates("file:///tmp/page.html").is_empty());
    }

    #[test]
    fn every_suggestion_is_a_valid_rule_domain_for_its_url() {
        for value in [
            "https://gist.github.com/x",
            "https://www.heise.de/",
            "https://a.b.example.co.uk/",
            "http://192.168.1.10:8080/",
        ] {
            let target = url(value);
            for candidate in remember_candidates(&target) {
                let mut set = RuleSet::default();
                set.upsert(rule(&candidate, "edge")).unwrap();
                assert!(
                    set.lookup(&target).is_some(),
                    "{candidate} should match {value}"
                );
            }
        }
    }
}
