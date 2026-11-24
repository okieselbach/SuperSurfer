# SuperSurfer manual

SuperSurfer registers as your default browser, intercepts link opens, runs your JavaScript routing config, and forwards each URL to the right browser and profile.

## First run

The first time you start SuperSurfer it creates:

- `config.js` — your routing rules
- `supersurfer.d.ts` — type definitions for editor autocomplete (via JSDoc)

Config locations:

| Platform | Path |
|---|---|
| macOS | `~/Library/Application Support/SuperSurfer/config.js` |
| Windows | `%APPDATA%\SuperSurfer\config.js` |
| Linux | `~/.config/SuperSurfer/config.js` |

## Install per platform

Download the matching artifact from [Releases](https://github.com/okieselbach/SuperSurfer/releases).

### macOS

Unzip `SuperSurfer.app.zip` into `/Applications`, then:

```bash
xattr -cr /Applications/SuperSurfer.app
/Applications/SuperSurfer.app/Contents/MacOS/SuperSurfer register
```

The first line is needed once per download: the app is not notarized yet, and macOS refuses to open a downloaded app it cannot verify. (Or try to open it, then allow it under System Settings → Privacy & Security → **Open Anyway**.)

`register` also starts the app. It stays in the menu bar from then on (no Dock icon); turn on **Launch at Login** in its menu to have it there after a restart. See [Menu bar app](#menu-bar-app-macos).

From source: `mise run package-macos` and copy `dist/SuperSurfer.app` into `/Applications`.

### Windows

Download `supersurfer.exe`, then:

```powershell
.\supersurfer.exe init --register
```

Set SuperSurfer as default under **Settings → Apps → Default apps**.

### Linux

```bash
tar -xzf supersurfer-linux-x86_64.tar.gz   # or aarch64
cd linux && ./install.sh                   # linux-aarch64 on ARM
supersurfer register
```

## Everyday commands

```bash
supersurfer doctor              # browsers, config, registration
supersurfer test https://example.com
supersurfer test https://example.com --open
supersurfer register            # (re)register as default browser
supersurfer rules               # saved rules: list / add / remove
supersurfer logs
```

On macOS, `supersurfer` is `/Applications/SuperSurfer.app/Contents/MacOS/SuperSurfer`.

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
    { match: host("meet.google.com"), browser: "chrome:work" },
    { match: (url, ctx) => ctx.opener?.name === "Slack", browser: "firefox" },
  ],
};
```

Matcher helpers: `host`, `domain`, `suffix`, `glob`, `path`, `regex`, `all`, `not`, `processRunning`.

`urlCleaning` decides how far built-in safelink unwrapping reaches: `"route"` (default) decodes for the matching decision but hands the browser the URL as it arrived, so the wrapper's link scanning stays intact; `"direct"` opens the decoded destination and skips the redirector; `"off"` disables decoding entirely. `rewrite` and `resolve` results always reach the browser regardless. `supersurfer test <url>` prints `routed:` and `opens:` separately.

`processRunning(name)` returns whether a browser is running (e.g. `"edge"`, `"Microsoft Edge"`). The process list is snapshotted on the first call in each route, then reused for that link.

Browser targets: `"chrome"`, `"firefox:Profile Name"`, `{ name: "Microsoft Edge", profile: "Work" }`.

`ctx.modifiers` (`shift`, `alt`, `ctrl`, `cmd`) says which modifier keys were held while the link was clicked — macOS menu bar app only; `false` everywhere else.

## Menu bar app (macOS)

SuperSurfer stays loaded on macOS, so a link is routed in a fraction of a millisecond instead of starting an app for every click. The menu bar icon is its whole interface:

- **Recent Links** — the last ten links since the app started. Each shows how it was routed and how long SuperSurfer took, and can be opened again in another browser or turned into a saved rule.
- **Saved Rules** — what the picker saved; remove a rule or open `rules.json`.
- **Picker Key** — the modifier key that opens the picker (⌥ Option by default, or off).
- **Choose Browser for Copied Link…** — the picker for the link in the clipboard.
- **Edit config.js**, **Show Config Folder**, **Show Decision Log**, **Reload Configuration**.
- **Launch at Login** (macOS 13 or later).

Changes to `config.js` take effect with the next link; there is nothing to restart. If the file has an error, links keep following the last version that worked and the icon turns into a warning triangle. Newly installed browsers and new browser profiles are noticed in the background within a few minutes; **Reload Configuration** re-reads everything at once.

### Choosing a browser for one link

Hold ⌥ Option while clicking a link. A menu opens at the pointer with your browsers and profiles; the one your rules would have used has a checkmark. Choose one to open the link there this once, or use **Always Open _site_ in** to also save a rule for the site. Escape cancels and the link is not opened.

Without the key nothing asks: links follow `config.js`, then the saved rules, then `defaultBrowser`.

### Browser profiles on macOS 27 and later

macOS 27 keeps apps away from the data of browsers, and that is where Chrome, Edge, Firefox and the others keep the names of their profiles. SuperSurfer routes every link all the same. What it loses is the list of profiles:

- The menu shows **⚠︎ Browser profiles cannot be read**. Browsers are listed without profiles, or with the profiles SuperSurfer read the last time it could.
- A Chromium profile named the way the browser shows it (`"edge:Work"`) cannot be found without that list, and the link opens in the profile the browser used last. Named by its folder (`"edge:Profile 1"`, `"chrome:Default"`) it keeps working, because that needs no list. The folder is the last part of "Profile Path" on `chrome://version` or `edge://version`.
- Firefox profiles keep working by name.

To give the list back, open System Settings → Privacy & Security → **Files & Folders** and switch on the browsers under SuperSurfer. macOS adds those switches the first time it refuses SuperSurfer. If SuperSurfer is not listed there, add it under **Full Disk Access** instead. Then quit SuperSurfer and open it again.

Commands in a terminal run with the permissions of the terminal app. Give that app the same access if `supersurfer doctor` should list profiles too.

macOS ties the permission to the app's signature. Releases are not signed with a Developer ID yet, so expect to give it again after an update.

## Saved rules

Rules saved from the picker live in `rules.json`, next to `config.js`:

```json
{
  "version": 1,
  "rules": [
    { "domain": "github.com", "browser": "edge", "profile": "Work" }
  ]
}
```

A rule covers the domain and its subdomains; the most specific domain wins. `handlers` in `config.js` are checked first, then these rules, then `defaultBrowser`. The file is honoured on every platform — edit it by hand, or:

```bash
supersurfer rules add github.com edge:Work
supersurfer rules remove github.com
```

## From Finicky

Copy your `~/.finicky.js` into `config.js`, add a `/** @type {import('./supersurfer').RouterConfig} */` comment above `export default`. Replace `finicky.matchHostnames([...])` with a local helper or built-in matchers. Use an LLM plus `supersurfer.d.ts` for one-shot migration. Validate with `supersurfer doctor` and `supersurfer test <url>`.

## Troubleshooting

**No browsers in `doctor` (Linux)** — Snap browsers use names like `firefox_firefox.desktop`. Use a current SuperSurfer build; native `.deb` installs are detected most reliably.

**Wrong architecture (Linux)** — ARM machines need `supersurfer-linux-aarch64.tar.gz`, not the x86_64 build.

**Routing falls back to default** — run `supersurfer test <url>` and fix config errors shown on stderr.

**No profiles, or links open in the wrong profile (macOS 27 and later)** — macOS no longer lets apps read browser data unasked. See [Browser profiles on macOS 27 and later](#browser-profiles-on-macos-27-and-later).

**"Apple could not verify…" when opening the app (macOS)** — run `xattr -cr /Applications/SuperSurfer.app` once after downloading.

**No menu bar icon (macOS)** — start the app with `open -a SuperSurfer`. If the icon was dragged out of the menu bar, this also brings it back.

**The picker does not appear (macOS)** — the app the link is in may use ⌥-click itself. Choose another **Picker Key** in the menu.

**A saved rule is ignored** — a `handlers` entry in `config.js` matches the same link and comes first. `supersurfer test <url>` prints a `rule:` line when a saved rule decided.

Repository: [github.com/okieselbach/SuperSurfer](https://github.com/okieselbach/SuperSurfer)
