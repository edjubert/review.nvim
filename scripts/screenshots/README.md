# Screenshot demo

This launcher opens a fully simulated GitLab MR in the real review.nvim UI.
Git content comes from an isolated temporary repository with three real commits.
GitLab reads, comments, decisions and resolutions operate on in-memory fixtures.

## Launch

Use a **fresh Neovim session** with your usual configuration. Close the old
GitHub screenshot session before switching demos.

From the review.nvim checkout:

```sh
nvim -c 'luafile scripts/screenshots/demo.lua'
```

Open a particular scene directly:

```sh
nvim -c 'luafile scripts/screenshots/demo.lua' -c DemoPipelines
nvim -c 'luafile scripts/screenshots/demo.lua' -c DemoInline
```

Requirements: Neovim 0.11+, Git, `glab` in PATH, and already installed
`telescope.nvim` with `plenary.nvim`. No GitLab authentication is needed.
The launcher does not install dependencies.
It explicitly enables the optional mappings shown in the plugin README for
this demo session; review.nvim itself has no mappings enabled by default.

## Scenes

Each command resets the MR fixtures, drafts and viewed markers. Close the current
dialog with **Cancel**, **Keep local** or **Esc** before switching scenes.
Close Markdown windows with `q`.

| Command | Image | Expected content |
| --- | --- | --- |
| `:DemoOverview` | `overview.png` | Complete MR, folded docs/tests, two viewed files, approvals and change request |
| `:DemoCommit` | `commit-navigation.png` | First commit, its files and SHA |
| `:DemoInfo` | `review-info.png` | MR title and Markdown description |
| `:DemoCompose` | `range-comment.png` | Local Markdown comment editor on the filter range |
| `:DemoDrafts` | `local-drafts.png` | Two local drafts with paths and excerpts |
| `:DemoSubmit` | `submission-preview.png` | Preview and all three publication choices, initially Keep local |
| `:DemoThreads` | `discussion.png` | Individually resolved conversation, participants and reaction users |
| `:DemoFiles` | `file-search.png` | Search for inbox, Git statuses and viewed markers |
| `:DemoPipelines` | `pipelines.png` | Three pipelines and grouped jobs with five status colors |
| `:DemoJob` | `pipeline-job.png` | Failed integration checks job, runner, timings and failure reason |
| `:DemoRequestChanges` | `request-changes.png` | Standalone change request dialog with Cancel selected |
| `:DemoInline` | `inline-comments.png` | Comment and reply below the filter range, with reactions |
| `:DemoResolveAll` | `resolve-all.png` | Warning for two conversations, including an outdated one, initially Cancel |

`DemoOverview` exercises `:ReviewApprove` against the fake transport.
`DemoThreads` exercises `:ReviewResolve` before opening the conversation.
`DemoInline` starts with inline comments hidden and invokes `:ReviewToggleComments`.
The editor title uses diff buffer row numbers; discussion anchors and published
positions use Git file line numbers.

## Screenshot setup

- Keep your normal colorscheme, font, Markdown renderer and selection UI.
- Target a 150-column, 50-line terminal, with the panel at 44 columns.
- Keep the same window size and font for a complete capture series.
- Save native-resolution PNGs with a consistent crop.
- Keep useful titles, paths and key hints visible.
- Wait for transient notifications to disappear before capturing.
- In the pipeline preview, scroll with Telescope's preview keys if necessary.
  Stage names appear once, above their jobs.
- Keep Cancel or Keep local selected when capturing confirmation dialogs.

Snacks' default select dialog is too narrow for the full bulk-resolution warning.
For this long prompt, the launcher temporarily widens the existing select preset
and restores it immediately after opening the picker. Your colors, choices and
configuration files are preserved. Use a terminal at least 140 columns wide.

## Isolation

The synthetic URL is `https://gitlab.example.com/demo/inbox/-/merge_requests/42`.
It is not a real GitLab page.

The launcher intercepts GitLab methods before opening it. Process execution is
limited to fixture Git commands in the temporary repository; Git fetch/clone/push
and other programs are rejected. Browser actions are recorded locally.
All local drafts and viewed markers use the demo's temporary state directory.

Inspect that directory and the simulated-action log:

```vim
:lua print(vim.g.review_screenshot_root)
:lua print(vim.inspect(vim.g.review_screenshot_demo.actions))
```

Closing Neovim restores the original provider functions and process handling.
Re-running the launcher in an existing demo session is rejected; start a fresh
session instead.

## Capture checklist

- [ ] Directory tree shows both expanded and collapsed folders.
- [ ] Complete comparison has exactly five changed files and two viewed files.
- [ ] Commit scene selects the actual first commit.
- [ ] Drafts and comment ranges use the exact fixture Git refs.
- [ ] Publication preview shows all three choices.
- [ ] File picker searches source and test paths.
- [ ] Pipeline preview shows four stages and eight jobs.
- [ ] Success green, failure red, pending orange, running blue, inactive grey.
- [ ] Failed job shows 83 seconds, demo-runner and script_failure.
- [ ] Change request confirmation keeps local drafts.
- [ ] Discussion shows resolved state, participants and reactions.
- [ ] Inline comment, reply and reactions appear below their code range.
- [ ] Bulk resolution warning counts two conversations and includes outdated ones.
- [ ] No private review data appears in screenshots.
