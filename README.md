# SuperSurfer

**One config. Every browser. macOS · Windows · Linux.**

[![Release](https://img.shields.io/github/v/release/okieselbach/SuperSurfer)](https://github.com/okieselbach/SuperSurfer/releases)
[![CI](https://img.shields.io/github/actions/workflow/status/okieselbach/SuperSurfer/ci.yml?branch=main)](https://github.com/okieselbach/SuperSurfer/actions)
[![License: MIT](https://img.shields.io/github/license/okieselbach/SuperSurfer)](LICENSE)

SuperSurfer registers as your OS default browser, intercepts every link open, evaluates a JavaScript routing config, and forwards the URL to the right browser/profile.

A [Finicky](https://github.com/johnste/finicky)-style router that also runs on Windows and Linux, with built-in safelink unwrapping and tracker stripping.

**Manual:** [docs/manual.md](docs/manual.md) (also opened in your browser on first run)

| | SuperSurfer | Finicky |
|---|---|---|
| Platforms | macOS, Windows, Linux | macOS |
| Config | JavaScript (`config.js`) | JavaScript / TypeScript |
| URL cleaning | Built-in safelink unwrap + tracker strip | Rewrite rules you write |
| Browser profiles | `chrome:work`, `{ name, profile }` | `{ name, profile }` |
| License | MIT | MIT |

## Install

Binaries are on the [Releases](https://github.com/okieselbach/SuperSurfer/releases) page. Direct links always point at the latest:

| Platform | Download |
|---|---|
| Windows x86_64 | [`supersurfer.exe`](https://github.com/okieselbach/SuperSurfer/releases/latest/download/supersurfer.exe) |
| macOS Apple Silicon | [`SuperSurfer.app.zip`](https://github.com/okieselbach/SuperSurfer/releases/latest/download/SuperSurfer.app.zip) |
| Linux x86_64 | [`supersurfer-linux-x86_64.tar.gz`](https://github.com/okieselbach/SuperSurfer/releases/latest/download/supersurfer-linux-x86_64.tar.gz) |
| Linux aarch64 | [`supersurfer-linux-aarch64.tar.gz`](https://github.com/okieselbach/SuperSurfer/releases/latest/download/supersurfer-linux-aarch64.tar.gz) |

Then register SuperSurfer as the default browser and try a dry-run:

**macOS** — unzip into `/Applications`, then:

```bash
/Applications/SuperSurfer.app/Contents/MacOS/SuperSurfer register
/Applications/SuperSurfer.app/Contents/MacOS/SuperSurfer test https://github.com/org/repo
```

`register` also starts the app. It stays in the menu bar from then on — see [Menu bar app](#menu-bar-app-macos).

**Windows:**

```powershell
.\supersurfer.exe init --register
.\supersurfer.exe test https://github.com/org/repo
```

Set SuperSurfer as default under **Settings → Apps → Default apps**.

**Linux:**

```bash
tar -xzf supersurfer-linux-x86_64.tar.gz   # or aarch64
cd linux && ./install.sh                   # linux-aarch64 on ARM
supersurfer register
supersurfer test https://github.com/org/repo
```

First run (no arguments) creates `config.js` and `supersurfer.d.ts`, then opens the [setup guide](docs/manual.md). URL routing (`supersurfer https://…`) also bootstraps config silently when needed.

Config lives at:

- macOS: `~/Library/Application Support/SuperSurfer/config.js`
- Windows: `%APPDATA%\SuperSurfer\config.js`
- Linux: `~/.config/SuperSurfer/config.js`

## Example config

```js
/** @type {import('./supersurfer').RouterConfig} */
export default {
  defaultBrowser: "chrome",
  urlCleaning: "route",
  handlers: [
    {
      match: domain("github.com"),
      browser: (url) => (processRunning("edge") ? "edge" : "chrome"),
    },
    { match: [host("meet.google.com"), suffix(".zoom.us")], browser: "chrome:work" },
    { match: (url, ctx) => ctx.opener?.name === "Slack", browser: "firefox" },
  ],
};
```

`processRunning("edge")` checks whether a browser (by id, display name, or process name) is running — snapshot on first call per route, then cached for that evaluation.

`ctx.modifiers` (`shift`, `alt`, `ctrl`, `cmd`) tells a matcher which modifier keys were held while the link was clicked, e.g. `match: (url, ctx) => ctx.modifiers.shift`. Only the macOS menu bar app can see the keyboard; on Windows and Linux, and from the command line, they are always `false`.

## Menu bar app (macOS)

On macOS SuperSurfer stays loaded once it has been started — by `register`, by the first link, by `open -a SuperSurfer`, or at login. It has no Dock icon and no window; the menu bar icon is the whole interface.

Staying loaded is what makes a click fast. `config.js` is already evaluated and the browser list is in memory, so a link costs a fraction of a millisecond of routing instead of an app launch plus two helper processes. The browser is started in-process through `NSWorkspace`, the same Launch Services path `open` uses. `config.js` and `rules.json` are checked for changes when a link arrives (two `stat` calls), not polled, so the app does nothing at all while idle.

The menu:

| Item | What it does |
|---|---|
| **Recent Links** | The last ten links since the app started (memory only), each with how it was routed and how long SuperSurfer took. Open one again in another browser, save its site as a rule, or copy the cleaned link. |
| **Saved Rules** | The rules in [`rules.json`](#saved-rules-rulesjson). Remove one, or open the file. |
| **Picker Key** | Which modifier key opens the picker: ⌥ Option (default), ⇧ Shift, ⌃ Control, ⌘ Command, fn, or off. |
| **Choose Browser for Copied Link…** | The picker for the link in the clipboard. Also the quickest way to see how a link *would* be routed. |
| **Edit config.js**, **Show Config Folder**, **Show Decision Log**, **Reload Configuration** | Shortcuts to the files. Config changes are picked up on the next link by themselves, and the list of browsers and profiles is refreshed in the background; reloading re-reads all of it at once, e.g. right after adding a browser profile. |
| **Launch at Login** | Start with the Mac (macOS 13 or later), so the first click of the day is as fast as the rest. |
| **Make SuperSurfer the Default Browser** | Shown while something else is the default. |

If `config.js` stops loading — a typo, a half-saved file — links keep following the last version that worked, and the menu bar icon turns into a warning triangle until the file loads again. If it has never loaded in this run, links open in Safari rather than nowhere.

The icon can be dragged out of the menu bar with ⌘ held. Opening the app again (`open -a SuperSurfer`, Spotlight, Finder) brings it back and shows the menu.

### Picker

Hold the picker key (⌥ Option by default) while clicking a link and a menu opens at the pointer instead of the link opening:

- the installed browsers and their profiles — the one the rules would have used has a checkmark; choose one to open the link there, this once;
- **Always Open _site_ in** — open it and save a rule for the site, so the next link goes there without asking;
- **Copy Cleaned Link** — the destination without redirect wrapper and tracking parameters.

Escape closes the menu and the link is not opened. Without the key, nothing ever asks: links follow `config.js`, then the saved rules, then `defaultBrowser`.

Some apps use ⌥-click themselves (browsers download the link target). Pick another key in the menu if that gets in the way.

## Saved rules (`rules.json`)

`config.js` is code, so no menu can edit it safely. What the picker saves goes into a plain data file next to it:

```json
{
  "version": 1,
  "rules": [
    { "domain": "github.com", "browser": "edge", "profile": "Work" },
    { "domain": "intranet.example", "browser": "safari" }
  ]
}
```

- `domain` matches the host and all its subdomains. If several rules match, the most specific domain wins, whatever their order.
- `browser` is a browser id as in `config.js`; `profile` and `private` are optional.
- Order of precedence: `handlers` in `config.js` first, then `rules.json`, then `defaultBrowser`. A rule for a site that a `config.js` handler already claims never fires; the picker says so.
- The file works on every platform, not just with the macOS menu. Edit it by hand or use `supersurfer rules`:

```bash
supersurfer rules                              # list
supersurfer rules add github.com edge:Work     # or: --profile Work, --private
supersurfer rules remove github.com
```

A `rules.json` that cannot be parsed is ignored (and reported by `doctor` and the menu), never overwritten.

## From Finicky

There is no built-in migrate command. SuperSurfer already supports most Finicky config patterns (`{ name, profile }` browser targets, dynamic `browser` handlers, `rewrite` rules). Copy your `~/.finicky.js` into `config.js`, add a `/** @type {import('./supersurfer').RouterConfig} */` comment above `export default`, then adjust:

- `finicky.matchHostnames([...])` → a local `matchHostnames()` helper, or `host` / `suffix` / `regex` matchers
- `finicky.opener` → `ctx.opener`
- custom `rewrite` + built-in URL cleaning may overlap — the built-in rules cover Outlook/Teams safelinks, Google, Slack, LinkedIn and more, so the equivalent `rewrite` rules can usually just go

An LLM plus `supersurfer.d.ts` (written by `supersurfer init`) is the intended migration path. Validate with `supersurfer doctor` and `supersurfer test <url>`.

## URL cleaning

Built-in rules unwrap redirect wrappers (Outlook/Teams safelinks, Azure Communication Services, Google, Slack, Facebook, LinkedIn, Trend Micro, Barracuda, Sophos) and strip tracking parameters (`utm_*`, `fbclid`, `gclid`, …). `urlCleaning` controls how far that reaches:

| Mode | Handlers match on | Browser opens |
|---|---|---|
| `"route"` *(default)* | the decoded destination | the URL as it arrived |
| `"direct"` | the decoded destination | the decoded destination |
| `"off"` | the raw URL | the raw URL |

`route` is the default because it separates two concerns that are easy to conflate. Your handlers get to see that a mailed safelink really points at `github.com` and route it accordingly — while the wrapper still reaches the browser, so link scanning, revocation and click reporting your organisation may depend on keep working.

Pick `direct` to skip the redirector entirely: one HTTP round-trip less and no click reported, at the cost of whatever checks that redirector performs. Pick `off` only if matchers should see raw safelinks, e.g. because you route on the wrapper itself.

A `rewrite` rule or a `resolve` preflight always reaches the browser — both are deliberate moves, not something cleaning should undo. A *resolved* destination is cleaned first, though: whatever sits at the end of a redirect chain is unknown and may be a wrapper itself, so it gets the same treatment as the original input. `rewrite` results are left alone, since those are yours. `file:` URLs are never touched in any mode.

Worth knowing under `route`: allowing a host with `supersurfer resolve allow` gives up wrapper preservation **for that host**. The HEAD request has already been made and the destination is known, so re-opening the redirector would only repeat work you deliberately paid for. If you chose `route` specifically to keep a scanner in the loop, keep that host off the resolve allowlist.

`supersurfer test <url>` prints `routed:` and `opens:` separately, which is the quickest way to see a mode in action.

## CLI

| Command | Purpose |
|---|---|
| `supersurfer init` | Scaffold config + types |
| `supersurfer register` | Register as default browser |
| `supersurfer doctor` | List browsers, validate config |
| `supersurfer test <url>` | Dry-run routing decision |
| `supersurfer rules` | List, add or remove saved rules (`rules.json`) |
| `supersurfer logs` | Tail decision log |
| `supersurfer update-rules` | Fetch signed URL-cleaning rules (planned) |

When registered as the default browser, the OS hands the URL to the packaged app (macOS: a URL event to the running `SuperSurfer.app`; Windows: `supersurfer.exe --from-os "%1"`; Linux: `supersurfer --from-os %u` via `supersurfer.desktop`).

On macOS the command line lives in the app's executable: `/Applications/SuperSurfer.app/Contents/MacOS/SuperSurfer <command>` behaves like `supersurfer <command>` elsewhere, whether or not the menu bar app is running.

## Build from source

This project uses [mise](https://mise.jdx.dev/) for tool versions (Rust, rustfmt, clippy).

```bash
mise trust            # first time in this repo
mise install          # install pinned Rust toolchain
mise run build
mise run dev -- init
mise run dev -- test https://github.com/org/repo
mise run doctor
```

Or without mise tasks:

```bash
cargo build --release
./target/release/supersurfer          # first run: scaffolds config + opens manual
./target/release/supersurfer doctor
./target/release/supersurfer test https://github.com/org/repo
./target/release/supersurfer register
```

Legacy explicit init:

```bash
./target/release/supersurfer init
```

## Packaging (default browser)

### macOS — `SuperSurfer.app`

```bash
mise run package-macos
cp -R dist/SuperSurfer.app /Applications/
mise run register
# or: /Applications/SuperSurfer.app/Contents/MacOS/SuperSurfer register
/Applications/SuperSurfer.app/Contents/MacOS/SuperSurfer test https://github.com/foo
```

Note: if your shell aliases `open` to `xdg-open`, use the full app path above — not `open -a SuperSurfer`.

The bundle holds one executable. The macOS side (URL events, menu bar, picker, launching through `NSWorkspace`) is Swift in `packaging/macos/app/`; the Rust core is linked into it as a static library and reached through a three-function C interface (`src/ffi.rs`, JSON in and out). `build-app.sh` builds both with `cargo` and `swiftc` — no Xcode project.

The same executable is the command line. Started by Launch Services it becomes the menu bar app; started from a shell it runs the given command and exits. Two flags are for development:

```bash
dist/SuperSurfer.app/Contents/MacOS/SuperSurfer --resident    # run the menu bar app from a shell; prints a timing line per link
dist/SuperSurfer.app/Contents/MacOS/SuperSurfer --self-test   # check the Swift/Rust interface against a scratch HOME
bash packaging/macos/smoke-test.sh                            # self-test, then start the app and route a real link
```

When replacing an installed copy, quit the running app first (menu → Quit SuperSurfer); the next link or `open -a SuperSurfer` starts the new one.

To sign with a Developer ID instead of ad hoc (hardened runtime and timestamp, as notarization requires):

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" mise run package-macos
```

### Windows — `supersurfer.exe`

Download `supersurfer.exe` from [Releases](https://github.com/okieselbach/SuperSurfer/releases), or build locally.

On Windows, or cross-compile from macOS/Linux (`mise` installs `zig`; first run may install `cargo-zigbuild`):

```bash
mise run package-windows
```

On Windows:

```powershell
.\dist\supersurfer.exe init --register
.\dist\supersurfer.exe test https://github.com/foo
```

`init --register` writes `StartMenuInternet` registry entries so SuperSurfer appears in **Settings → Apps → Default apps**. Search for SuperSurfer, open it, then click **Set default** (or assign HTTP, HTTPS, `.htm`, and `.html` individually). The old “Web browser” picker was removed in Windows 11.

### Linux — `supersurfer`

Download the tarball for your arch from [Releases](https://github.com/okieselbach/SuperSurfer/releases). Builds are dynamically linked glibc binaries for **x86_64** and **aarch64**. Release artifacts are built on Ubuntu 22.04 (glibc 2.35) as the minimum supported baseline; newer distros work too.

**x86_64 (Intel/AMD):**
```bash
tar -xzf supersurfer-linux-x86_64.tar.gz
cd linux
./install.sh
```

**aarch64 (ARM, e.g. Raspberry Pi, ARM laptops):**
```bash
tar -xzf supersurfer-linux-aarch64.tar.gz
cd linux-aarch64
./install.sh
```

From source (native or cross-compile):
```bash
mise run package-linux          # native x86_64 on Linux
mise run package-linux-arm      # cross-compile aarch64 (needs zig)
```

Then:
```bash
supersurfer init
supersurfer register         # sets default via xdg-settings / xdg-mime
supersurfer doctor
```

`register` installs `supersurfer.desktop` into `~/.local/share/applications/` and runs `xdg-settings set default-web-browser supersurfer.desktop` (with an `xdg-mime` fallback for `http`/`https`). Native browsers are discovered via `.desktop` files in the XDG application directories; Flatpak/Snap browsers are not yet supported.

## Releasing

Bump the version in `Cargo.toml`, `Cargo.lock` and `packaging/macos/Info.plist`, merge to `main`, then publish in one of three ways. Each ends in the same CI run, which builds every platform and attaches the binaries:

- **From the Actions page:** CI → Run workflow → branch `main`, tick *Publish a GitHub release*. This creates the tag `v<version>` and the release.
- **With a tag:** `git tag v0.2.0 && git push origin v0.2.0`.
- **From the Releases page:** create a release with a new tag `v<version>` on `main`. CI adds the binaries a few minutes later, and the notes if you left them empty.

## Architecture

```
OS URL event → SuperSurfer (Rust)
                ├─ Config loader (JS → QuickJS)
                ├─ URL pre-processor (unwrap + tracker strip)
                ├─ handlers / rewrite evaluation
                ├─ saved rules (rules.json)
                ├─ Browser resolver (abstract name → platform launch)
                └─ Launcher (spawn browser, exit)
```

Windows and Linux run this once per link: the OS starts `supersurfer`, it routes, spawns the browser and exits.

On macOS the same core is loaded once and kept warm inside the menu bar app:

```
URL event → SuperSurfer.app (Swift, stays loaded)
              ├─ reads modifier keys and the frontmost app
              ├─ Rust core, linked in (src/engine.rs: warm config, rules and browser list)
              ├─ picker menu, if the picker key is held
              └─ NSWorkspace → browser
```

## Status

v0.2.x is usable as a default browser on macOS, Windows, and Linux:

- Rust core with QuickJS sandboxed config runtime
- JavaScript config with JSDoc types
- Matcher helpers (`host`, `domain`, `suffix`, `glob`, `path`, `regex`, `all`, `not`, `processRunning`)
- Built-in URL cleaning with `route` / `direct` / `off` modes (safelink unwrapping, UTM stripping)
- macOS `SuperSurfer.app` bundle + Launch Services / duti registration
- macOS menu bar app that stays loaded: recent links, picker on a modifier key, launch at login
- Saved rules in `rules.json`, managed by the picker or `supersurfer rules`
- Windows `supersurfer.exe` + registry browser registration
- Linux `supersurfer` binary + `.desktop` / xdg-settings registration
- macOS, Windows, and Linux browser discovery + launch
- CLI: `init`, `doctor`, `test`, `rules`, `logs`

**Not yet:** signed/notarized distribution, signed rules updates. macOS Gatekeeper will warn on first open until the app is notarized — right-click → Open, or `xattr -cr /Applications/SuperSurfer.app`.

## License

MIT
