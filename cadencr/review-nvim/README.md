# review.nvim for CadencR

A custom `Review` tab for **CadencR 0.16.0+**. Opening it starts your installed
Neovim in an embedded terminal, with the review.nvim runtime bundled in the tab.
The conversation's MR/PR URL opens automatically. Without a URL, Neovim asks
for one through Telescope; without Telescope, it uses `vim.ui.input`.

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
runtime before your configuration runs and pins every `review`/`review.*` Lua
module to that bundle. Your separately installed review.nvim cannot override
the tab's version, even when a plugin manager resets `runtimepath` or another
version is already cached. Missing bundled modules fail instead of falling back
to an installed version.

Configured review options and shortcuts are preserved. For `lazy.nvim`, the tab
also loads the review plugin's configuration when it is deferred until a
`:Review` command; that configuration uses the pinned modules. Review commands
are then restored from the bundle. Drafts and Git cache use CadencR's writable
plugin state directory.
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
do not depend on a system libc. Backend tests use a native fake Neovim. Runtime
tests use real Neovim with isolated configuration and mocked review opening;
they never publish a review. They verify bundle selection despite cached modules,
runtime resets and conflicting commands. Set `LAZY_PATH` to an installed
`lazy.nvim` directory to also check its deferred options and config callbacks:

```sh
LAZY_PATH=/path/to/lazy.nvim npm test
```

`npm run dev` watches the web UI and bundled Lua runtime. After Go changes,
rerun `npm run build:backend` and stop the existing backend
in the tab's **Activity** panel before reopening it.

### Browser and Neovim smoke tests

The browser checks use a real Neovim PTY and the tab SDK's MessagePort protocol.
A local fixture replaces review loading, so no Git provider is contacted.
They cover opening a conversation URL, resizing, preserving the session and
Telescope input across a webview reload, live font
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
marketplace metadata, and fills the real SHA-256 digests and sizes.

The `Qualify review.nvim tab` workflow builds the clean exact source on macOS
arm64, macOS Intel and Linux x86_64. Each runner executes the Go race tests,
Lua/runtime tests, the real-Neovim browser tests and a compiled-backend protocol
check. It records toolchain versions, dependency input digests, executable
digests and test logs. Successful push/tag runs also produce GitHub build
attestations for the executables and final archives.

The packaging job verifies all three native receipts, preserves the exact tested
Linux frontend and refuses stale, changed or unqualified outputs. Cross-compiling
with `--all` is useful for development but cannot replace native qualification.
It generates the package/submission JSON files and validates a complete candidate
against the trusted registry base pinned in `ci/toolchains.json`. This is author
validation; the registry's own checks and maintainer consent remain required.

If `cadencr` is not on `PATH`, set `CADENCR_CLI` to its executable path.
After downloading the native artifacts to the repository's `artifacts/native/`
and restoring the binaries under `bin/`, run `npm run package`. The destination
defaults to `artifacts/release-0.1.6/` at the repository root and must not exist.
The workflow's `release-candidate` artifact contains:

| File | Contents |
| --- | --- |
| `tab.tar.gz` | `tab.json`, icon, compiled UI and bundled Lua runtime |
| `tab-backend-darwin-aarch64.tar.gz` | Signed macOS Apple silicon backend |
| `tab-backend-darwin-x86_64.tar.gz` | macOS Intel backend |
| `tab-backend-linux-x86_64.tar.gz` | Linux backend |
| `marketplace.json` | Schema-2 tab package with exact archive/executable digests |
| `packages/`, `submissions/` | Registry contribution generated from those bytes |
| `build-receipt.json` | Exact source, toolchains, dependency inputs and native receipts |
| `native-evidence.tar.gz` | Native test logs, receipts and backend dependency notices |
| `registry-validation.json` | Author validation against the pinned trusted base |

The author release URLs use
`https://github.com/edjubert/review.nvim/releases/download/cadencr-v0.1.6/`.
Update `tab.json`, `package.json` and the lockfile's root version together.
Minimum app compatibility is `0.16.0`.

`dist/runtime/source.json` records the bundled source commit and whether local
source changes were included. Release packaging requires `modified: false`
and a commit matching the current clean checkout. Frontend and backend dependency
licenses are in `dist/LICENSES/`, with an index in `dist/THIRD_PARTY_NOTICES.md`.
The Lua runtime also contains the project's `LICENSES/`, including gemoji.
The manifest version identifies the CadencR integration, independently of any
review.nvim source release.

Packaging is local. Publishing the `cadencr-v0.1.6` source release and submitting
the generated metadata to CadencR's registry are separate, explicit operations.
No unsigned feed or direct marketplace installation is created.

See [RELEASE.md](RELEASE.md) for immutable publication and registry evidence.
