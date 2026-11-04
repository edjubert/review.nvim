# review.nvim for CadencR

A custom `Review` tab for **CadencR 0.16.0+**. Opening it starts your installed
Neovim in an embedded terminal, with the review.nvim runtime bundled in the tab.
The conversation's MR/PR URL opens automatically. Without a URL, Neovim asks
for one through Telescope; without Telescope, it uses `vim.ui.input`.
The picker also offers previously loaded MR/PRs, with titles and searchable
URLs. This history survives Neovim restarts and is shared across the tab's
conversations.

The tab preserves the Neovim process when hidden or when its webview reloads.
Closing the tab lets CadencR stop its backend after its normal grace period.
After `:qa`, **Start Neovim** opens a new session.
Terminal reads slow down while idle and rapid keyboard events are grouped.
If CadencR returns HTTP 429, the tab pauses its requests and resumes the same
Neovim session automatically once the quota window has elapsed. Queued keys
keep their order. Other failures remain visible and are not replayed.

## Requirements

- Neovim 0.11+, `git`, and `glab`, `gh` or `curl` for your review provider.
- Existing CLI and Git authentication, as described in the repository README.
- Optional `telescope.nvim` and `plenary.nvim` in your Neovim configuration.
- macOS (Apple silicon or Intel), or Linux x86_64. CadencR's v1 backend
  protocol has no Windows target.

Neovim loads your usual configuration. The tab adds its bundled review.nvim
runtime, keeps configured review options and shortcuts, and stores its review
drafts and Git cache under CadencR's writable plugin state directory.
The **Neovim executable** setting accepts a program name or absolute path,
useful when the desktop application's `PATH` differs from your terminal's.

The terminal follows CadencR's `mono_font_family` preference. As in CadencR's
Terminal tab, Alacritty's `font.size` supplies the size and `font.normal.family`
supplies the fallback family when no CadencR family is configured. Changes are
applied while the tab is visible, with the terminal grid resized to fit.
For CadencR 0.16.0, whose tab SDK does not expose fonts, the native adapter reads
only the font fields from the standard local CadencR preferences and Alacritty
TOML configuration, including its `general.import` chain. It uses CadencR's
fallback font stack and size when configuration is absent or unreadable.

This is a native-code plugin: Neovim and its configured plugins run with your
user permissions. The manifest explains this before activation. The backend
uses argument arrays and never invokes a shell. It passes the review URL as
environment data, never as an Ex command, Lua source or a shell argument.
Authentication remains with the installed CLI; the tab does not read token
files or use CadencR's API token. Saving a draft stays local. Publication,
approval, change requests and resolution remain explicit review.nvim commands.

## Build and test

Run from this directory. Building requires Node.js 22+ and Go 1.23+:

```sh
npm ci
npm run build
npm test
npm run test:backend
```

The build produces `dist/` (web UI and Lua runtime) and the current platform's
native executable under `bin/`. Build every declared platform for packaging:

```sh
npm run build:backend -- --all
cadencr plugin validate . --kind tab
```

Go cross-compiles without CGO. Build macOS arm64 on macOS to run the explicit
ad-hoc signing step; CadencR rejects unsigned arm64 executables. Linux binaries
do not depend on a system libc. Tests use a native fake Neovim and mocked
transports; they never publish a review.

`npm run dev` watches the web UI and bundled Lua runtime. After Go changes,
rerun `npm run build:backend` and stop the existing backend
in the tab's **Activity** panel before reopening it.

### Browser and Neovim smoke tests

The browser checks use a real Neovim PTY and the tab SDK's MessagePort protocol.
A local fixture replaces review loading, so no Git provider is contacted.
They cover opening a conversation URL, resizing, preserving the session and
Telescope input across a webview reload, persisted review history, live font
changes, idle request frequency, recovery from HTTP 429 with queued input,
other transport errors and restarting an exited Neovim.
They do not replace checking the installed tab inside CadencR.

```sh
npx playwright install chromium
npm run test:ui
```

Set `PLAYWRIGHT_CHANNEL=chrome` to use an installed Chrome instead. To run the
Telescope check as well, point `TELESCOPE_PATH` and `PLENARY_PATH` at installed
plugin directories:

```sh
TELESCOPE_PATH=/path/to/telescope.nvim \
PLENARY_PATH=/path/to/plenary.nvim \
npm run test:ui
```

## Try as a local custom tab

Build first, then copy the runtime to a new local tab folder named `review-nvim`:

```sh
mkdir -p ~/.cadencr/plugins/tabs/review-nvim
cp -R tab.json icon.svg dist bin ~/.cadencr/plugins/tabs/review-nvim/
```

In CadencR, open **Settings → Custom tabs**, enable `review.nvim`, accept its
native-code permissions, then add **Review** from the conversation's **+** menu.
The tab uses that conversation's working directory. Only the target provider's
CLI is required. If there is no MR/PR link, enter one in Neovim and press
`Enter`; `Esc` cancels the Telescope prompt.

## Prepare a marketplace submission

CadencR distributes the web UI and each platform's native backend as separate
archives. The packaging command uses CadencR's own validators and deterministic
archive writers, verifies backend conformance, binds the manifest to the
marketplace metadata, and fills the real SHA-256 digests and sizes:

```sh
npm run build
npm run build:backend -- --all
npm run package -- /absolute/path/to/new-release-directory
```

If `cadencr` is not on `PATH`, set `CADENCR_CLI` to its executable path.
The destination must not already exist. The output contains:

| File | Contents |
| --- | --- |
| `tab.tar.gz` | `tab.json`, icon, compiled UI and bundled Lua runtime |
| `tab-backend-darwin-aarch64.tar.gz` | Signed macOS Apple silicon backend |
| `tab-backend-darwin-x86_64.tar.gz` | macOS Intel backend |
| `tab-backend-linux-x86_64.tar.gz` | Linux backend |
| `marketplace.json` | Schema-2 tab package with exact archive/executable digests |

The author release URLs use
`https://github.com/edjubert/review.nvim/releases/download/cadencr-v0.1.2/`.
Update `tab.json` and `package.json` together for a new integration version.
Minimum app compatibility is `0.16.0`.

`dist/runtime/source.json` records the bundled source commit, the fetched
`origin/main` revision and whether local runtime changes were included.
The manifest version identifies the CadencR integration, independently of any
review.nvim source release.

Packaging is local. Publishing the `cadencr-v0.1.2` source release and submitting
the generated metadata to CadencR's registry are separate, explicit operations.
No unsigned feed or direct marketplace installation is created.
