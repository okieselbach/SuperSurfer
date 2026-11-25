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
xattr -cr /Applications/SuperSurfer.app    # once per download: the app is not notarized yet
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

That path has a weak spot. Launch Services takes what one app asks it to open one request at a time, and keeps each until the browser has answered. On GitHub's runners Safari answered in hundredths to tenths of a second when it was running, and in one to three seconds when it had to start. Until a browser answers, every later link waits, whichever browser it is for. On the macOS 15 runner a freshly started Edge did not answer for 40 seconds while it was there. And twice, after Edge had been quit in that state, the answer had still not come two minutes later, and a start of Chrome that SuperSurfer asked for in between did not happen. If links stop opening, look for a browser that is waiting with a question. Failing that, quit SuperSurfer and open it again: the waiting is done in SuperSurfer's own process, and a new one starts without it.

The menu:

| Item | What it does |
|---|---|
| **Recent Links** | The last ten links since the app started (memory only), each with how it was routed and how long SuperSurfer took. Open one again in another browser, save its site as a rule, or copy the cleaned link. |
| **Saved Rules** | The rules in [`rules.json`](#saved-rules-rulesjson). Remove one, or open the file. |
| **Picker Key** | Which modifier key opens the picker: ⌥ Option (default), ⇧ Shift, ⌃ Control, ⌘ Command, fn, or off. |
| **Choose Browser for Copied Link…** | The picker for the link in the clipboard. Also the quickest way to see how a link *would* be routed. |
| **Edit config.js**, **Show Config Folder**, **Show Decision Log**, **Reload Configuration** | Shortcuts to the files. Config changes are picked up on the next link by themselves, and the list of browsers and profiles is refreshed in the background; reloading re-reads all of it at once, e.g. right after adding a browser profile. |
| **Dock Click** | Not about links: what a click on the Dock icon of the app in front does. Off unless you choose otherwise. See [Dock Click](#dock-click). |
| **Dock Shortcuts** | Not about links either: an icon in the Dock for one profile of Edge or Chrome, which brings that profile's window to the front. See [Dock Shortcuts](#dock-shortcuts). |
| **Launch at Login** | Start with the Mac (macOS 13 or later), so the first click of the day is as fast as the rest. |
| **Make SuperSurfer the Default Browser** | Shown while something else is the default. |

If `config.js` stops loading — a typo, a half-saved file — links keep following the last version that worked, and the menu bar icon turns into a warning triangle until the file loads again. If it has never loaded in this run, links open in Safari rather than nowhere.

The icon can be dragged out of the menu bar with ⌘ held. Opening the app again (`open -a SuperSurfer`, Spotlight, Finder) brings it back and shows the menu.

macOS 27 and later keep apps away from browser data, which includes the names of browser profiles. Links are routed all the same; the menu then shows **⚠︎ Browser profiles cannot be read** and says how to allow access. Until then a Chromium profile is only found when named by its folder (`"edge:Profile 1"`). Details, and what to do when the switch for a browser jumps back to off after an update: [manual](docs/manual.md#browser-profiles-on-macos-27-and-later).

### Picker

Hold the picker key (⌥ Option by default) while clicking a link and a menu opens at the pointer instead of the link opening:

- the installed browsers and their profiles — the one the rules would have used has a checkmark; choose one to open the link there, this once;
- **Always Open _site_ in** — open it and save a rule for the site, so the next link goes there without asking;
- **Copy Cleaned Link** — the destination without redirect wrapper and tracking parameters.

Escape closes the menu and the link is not opened. Without the key, nothing ever asks: links follow `config.js`, then the saved rules, then `defaultBrowser`.

**What a profile is called.** The picker lists a profile under the name the browser has for it. If you gave the profile's [Dock shortcut](#dock-shortcuts) a name of your own, it is listed under that one instead, without the browser in front: *Work* for a shortcut called "Edge Work", where Edge says *Oliver*. **Recent Links** and **Saved Rules** say it the same way. Rest the pointer on such an entry and it shows what the browser calls the profile. That is still the name for `config.js`, and the one `rules.json` keeps.

`config.js` may also name a profile by its folder (`"edge:Profile 1"`). The line at the top of the picker then names the profile and not the folder, and the checkmark is at that profile. The two are easy to mix up: Edge calls its second profile "Profile 2" and keeps it in the folder "Profile 1".

Some apps use ⌥-click themselves (browsers download the link target). Pick another key in the menu if that gets in the way.

### Dock Click

Clicking the Dock icon of the app you are already in normally does nothing on macOS. **Dock Click** in the menu gives that click a job, as on Windows and most Linux desktops:

| Choice | A click on the icon of the app in front | The next click on the icon |
|---|---|---|
| **Hide App** | hides the app, like ⌘H | shows it again (macOS does that by itself) |
| **Minimize Windows** | sends every window the app has on the current Space into the Dock | brings back all of them, where macOS alone brings back one |
| **Off** *(default)* | nothing | |

This has nothing to do with routing links. It is here because SuperSurfer is loaded anyway, which is cheaper than one more menu bar utility. While it is off, nothing is installed and no permission is needed.

**When it acts.** On a plain click on the Dock icon of the app that has been in front for at least three quarters of a second, and only if the Dock itself makes nothing of that click. Everything else is left to the Dock:

- a click on the icon of another app, which switches to that app, and a second click on it while the app is still arriving;
- a long press, which opens the icon's menu, and a click with ⌘, ⌥, ⌃ or ⇧ held;
- a click while Mission Control, App Exposé or Show Desktop is up, where it is the way back to the app (a force click on the icon opens App Exposé);
- a click on the icon of an app without a window on screen, which is how you ask for one;
- a click on a menu, a notification or any other window that happens to lie over the icon.

A double click ends where it began: its second click never puts anything away, and brings back what the first one put away.

A click that could only be acted on more than a second after it was made is dropped, because an app that vanishes that long after the click comes as a surprise. It takes a Mac that is very busy: on GitHub's macOS 26 runner it happened to a click on Safari's icon while Safari was still starting. The click then does what it does without Dock Click, which is nothing.

**Minimize Windows moves the Dock.** Every minimized window gets a place in the Dock, and the Dock shifts its icons to make room, so after the click the pointer may no longer be on the app's icon. Switch on System Settings → Desktop & Dock → *Minimize windows into application icon* and the icons stay where they are. *Hide App* never moves anything. Windows on other Spaces and full-screen windows are not minimized. If you bring one of the minimized windows back by hand, Dock Click forgets the others; they stay where you left them.

**Permission.** The first time you choose *Hide App* or *Minimize Windows*, macOS asks for the Accessibility permission (System Settings → Privacy & Security → Accessibility). SuperSurfer needs it to ask the Dock which icon is under the pointer and to minimize another app's windows. It works from the next click. Until the permission is there, the menu entry carries a ⚠︎ and clicks behave as always.

macOS ties this permission to the app's signature, and releases are not signed with a Developer ID yet. After an update the switch in System Settings still looks on but no longer counts: remove SuperSurfer from that list and add it again, or run `tccutil reset Accessibility dev.supersurfer.app` and choose the option once more.

**What it costs.** A global event monitor sees the mouse button go down and come up. It only listens, so no click is held back or changed. The window server writes into each click which window it went to, and for a click that did not go to the Dock reading that is all that happens: 0.01 to 0.02 ms on the main thread, measured on GitHub's macOS runners, and 0.2 ms in the one run where the machine was busy. Only a click on the Dock leads to more: a look at which app is in front, on the main thread, and a question to the Dock about the icon, on a queue of its own with a timeout of 0.4 s. Minimizing and restoring windows runs on a second queue. Neither the main thread nor the queue that routes links ever waits for another app. Between clicks the app is as idle as before.

**Tested, and not.** `packaging/macos/dock-click-test.sh` clicks real Dock icons. It runs in CI on macOS 15 and has also passed on GitHub's macOS 26 runner. It covers what is listed above except the force click, which a test cannot produce, and the long press and modifier keys, for which only the rules in `--self-test` are checked. Not tested at all: an app with windows on more than one Space (macOS then answers the click by moving to the other Space; Dock Click steps aside if it sees the Space or the app's windows change in time), several displays, and Stage Manager.

### Dock Shortcuts

On Windows a browser profile can have a button of its own in the taskbar. **Dock Shortcuts** in the menu gives macOS the nearest thing for Microsoft Edge and Google Chrome: an icon in the Dock per profile.

Choose a profile under **Dock Shortcuts** and SuperSurfer writes a small app for it into `~/Applications/SuperSurfer Shortcuts`, named after browser and profile ("Edge Work"), with the browser's icon and a badge for the profile. The Finder shows it; drag it into the Dock. A click on it:

| The profile… | What the click does |
|---|---|
| has a window | brings it to the front, also from behind another app, out of the Dock, or when the browser is hidden |
| has no window | has the browser open one |
| belongs to a browser that is not running | starts the browser with that profile |

Like Dock Click this has nothing to do with routing links, and none of it runs until a shortcut is clicked or the menu is opened.

**A name of your own.** A shortcut is first called what the browser calls the profile: "Edge Oliver", with an O on its icon. If that profile is "Work" to you, give the shortcut that name in one of two ways:

- choose the profile under **Dock Shortcuts**, then **Rename…**, or
- rename the app in the Finder. SuperSurfer takes the name up the next time its menu opens or the shortcut is clicked.

The icon then carries the first letter of the name, not counting the browser in front: W for "Edge Work". The name is only a name. Which profile the shortcut opens is noted inside it and stays the same. Under **Dock Shortcuts** the menu goes on listing the profile as the browser calls it, with the shortcut's name behind an arrow: *Oliver → Edge Work*. An empty name in **Rename…** goes back to the first one.

The name is also what the rest of SuperSurfer's menu calls the profile from then on: the [picker](#picker), **Recent Links** and **Saved Rules** say *Work*. Two things limit that. A name that another profile of the browser already goes by, or that two shortcuts of the browser share, is not used, because two entries of one list would read alike. And `config.js` and `rules.json` know nothing of it: there a profile has the name the browser gives it, or its folder.

A shortcut that is in the Dock stays there when it is renamed. The Dock goes on showing the old name until the shortcut is clicked the next time. The new picture was there within seconds on macOS 26, and after that click on macOS 15.

**How it works.** The app is a few lines of shell script that tell SuperSurfer which profile is wanted. SuperSurfer then chooses that profile in the browser's own *Profiles* menu, and the browser does what it does when you choose it there yourself. The title of a window would be no help: Edge leaves the profile's name out of it for its first profile.

**Permission.** Choosing an entry in another app's menu takes the Accessibility permission, the one Dock Click uses; macOS asks for it when a shortcut is made. Without it a shortcut still works, but every click opens a new window of the profile, and the menu entry carries a ⚠︎. What the app's signature does to this permission after an update is described under [Dock Click](#dock-click).

**What stays different from Windows.**

- A shortcut is an icon of its own. While the browser runs, the browser's icon is in the Dock as well, and the dot for a running app is under that one.
- The click first starts the small app. On GitHub's macOS runners that took 0.1 to 0.2 s, and two to three seconds the first time a new shortcut was used. SuperSurfer then needed another 0.01 to 0.3 s, most of it waiting for the browser.
- A shortcut remembers the folder the browser keeps the profile in, so renaming the profile in the browser does not break it. Its own name stays what it is until you change it.
- **Remove Shortcut** deletes the app. The Dock keeps a question mark in its place until you drag that out.

**Signed-in profiles.** The *Profiles* menu does not always list a profile under its name. For a profile that is signed in to an account, Chrome shows the account's name, or both, as "Ada (Work)", and a name an organization gave the profile in place of the profile's own. SuperSurfer works out which of these to expect the way Chromium's source does, looks for the other forms after that, and then for an entry that has the profile's name in it as a word of its own. If no entry fits, or more than one, it opens a new window of the profile instead and writes the entries it saw to the system log:

```bash
log show --last 5m --predicate 'eventMessage CONTAINS "SuperSurfer"'
```

The same command shows it when a shortcut could not reach SuperSurfer at all, for instance because the app was moved away. The shortcut then opens a window of the profile by itself.

**Which browsers.** Edge and Chrome. Their Beta and Canary builds and Chromium have the same menu and are offered as well, untried. Firefox is not offered: it runs every profile as an app of its own, which has its own Dock icon while it runs. Safari is not offered either: its profiles cannot be reached from outside.

**Tested, and not.** `packaging/macos/dock-shortcut-test.sh` starts Edge and Chrome with three profiles each, makes shortcuts in the menu and uses them in each of the situations above. It renames one of them in the menu while it is in the Dock and one the way the Finder does, and goes on with both. It then opens the picker for links with a saved rule and reads what the picker and **Saved Rules** call the profiles. With Chrome it also chooses a profile in the picker under its shortcut's name, and looks at which profile Chrome is started with and what **Recent Links** calls it. With Edge that passed in two runs and has been left out since: it starts Edge a second time, and on the runner macOS does not always answer a start of Edge, which holds up everything after it (see [Menu bar app](#menu-bar-app-macos)). It runs in CI on macOS 15. As it was before the steps on the picker, it has also passed on GitHub's macOS 26 runner. Not tested: profiles that are signed in to an account (the rule for their names follows Chromium's source and is checked against made-up data; what Edge does with a Microsoft account is not known), a browser in another language, the Beta and Canary builds, and macOS 27. Whether the Dock draws the new picture of a shortcut that was renamed in the Finder before SuperSurfer could take the name up, and so changes its picture without changing its name, has not been looked at either.

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

The app's icon is drawn by `packaging/macos/icon/make-icon.py` (Python with Pillow and numpy) into `packaging/macos/AppIcon.iconset`, one picture per size. Those pictures are in the repository, and `build-app.sh` packs them with `iconutil`, so the script only has to run when the icon is to change. Its glyph, a link that fans out to the browsers, is drawn from dots and curves. It is not the branching arrow of the menu bar: that is one of Apple's SF Symbols, which may be used in an app's interface and not in its icon.

The same executable is the command line. Started by Launch Services it becomes the menu bar app; started from a shell it runs the given command and exits. Two flags are for development:

```bash
dist/SuperSurfer.app/Contents/MacOS/SuperSurfer --resident    # run the menu bar app from a shell; prints a timing line per link
dist/SuperSurfer.app/Contents/MacOS/SuperSurfer --self-test   # check the Swift/Rust interface against a scratch HOME
bash packaging/macos/smoke-test.sh                            # self-test, then start the app and route a real link
```

Dock Click has a test of its own, which clicks real Dock icons and checks what happens to the windows. It needs the Accessibility permission for the terminal it runs in, and the Mac to itself for three minutes:

```bash
bash packaging/macos/dock-click-test.sh
SUPERSURFER_DOCK_CLICK=hide dist/SuperSurfer.app/Contents/MacOS/SuperSurfer --resident   # or minimize: try it without storing the choice; prints a line per Dock click, and one for each other window that gets a click
```

The Dock shortcuts have one too. It starts Edge and Chrome with profiles of its own, so quit both first, and it takes five minutes:

```bash
bash packaging/macos/dock-shortcut-test.sh
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
- **With a tag:** `git tag v0.3.3 && git push origin v0.3.3`.
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

v0.3.x is usable as a default browser on macOS, Windows, and Linux:

- Rust core with QuickJS sandboxed config runtime
- JavaScript config with JSDoc types
- Matcher helpers (`host`, `domain`, `suffix`, `glob`, `path`, `regex`, `all`, `not`, `processRunning`)
- Built-in URL cleaning with `route` / `direct` / `off` modes (safelink unwrapping, UTM stripping)
- macOS `SuperSurfer.app` bundle + Launch Services / duti registration
- macOS menu bar app that stays loaded: recent links, picker on a modifier key, launch at login
- macOS Dock Click (optional): a click on the Dock icon of the app in front hides the app or minimizes its windows
- macOS Dock shortcuts (optional): an icon in the Dock per Edge or Chrome profile that brings the profile's window to the front
- Saved rules in `rules.json`, managed by the picker or `supersurfer rules`
- Windows `supersurfer.exe` + registry browser registration
- Linux `supersurfer` binary + `.desktop` / xdg-settings registration
- macOS, Windows, and Linux browser discovery + launch
- CLI: `init`, `doctor`, `test`, `rules`, `logs`

**Not yet:** signed/notarized distribution, signed rules updates. Until the app is notarized, macOS refuses to open a downloaded copy — run `xattr -cr /Applications/SuperSurfer.app` once, or allow it under System Settings → Privacy & Security → Open Anyway. Without a Developer ID signature, macOS also forgets two permissions with every update: reading browser profiles (macOS 27 and later) and Accessibility, which only [Dock Click](#dock-click) and [Dock Shortcuts](#dock-shortcuts) need.

## License

MIT
