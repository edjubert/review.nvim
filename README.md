<p align="center">
  <img src="assets/logo.svg" width="128" alt="review.nvim logo">
</p>

# review.nvim

Repository: [edjubert/review.nvim](https://github.com/edjubert/review.nvim).

Read GitLab merge requests and GitHub or Codeberg pull requests commit by commit,
view each file as an inline diff, and draft comments on a line or a line range
in Neovim.

- Open a GitLab MR, GitHub PR or Codeberg PR URL, including commit/file subpages.
- Browse the exact commit list, oldest first.
- Switch between individual commits and the complete MR/PR.
- Read additions, deletions and context in one read-only buffer with both line numbers
  and intraline highlights.
- Select deleted lines as well as added lines.
- Save, edit and delete persistent local comment drafts.
- Preview and explicitly publish drafts as inline discussions on GitLab, GitHub
  or Codeberg.
- Read existing discussions for the current file.
- Refresh the open review without losing local drafts.

The URL selects the provider automatically. GitLab, self-hosted GitLab, GitHub,
GitHub Enterprise Server and Codeberg use the same UI and shortcuts.
Provider code lives in `lua/review/providers/`.

## Requirements

- Neovim 0.11+.
- `git`.
- The API client for the provider you use:
  [`glab`](https://gitlab.com/gitlab-org/cli) for GitLab,
  [`gh`](https://cli.github.com/) for GitHub, or [`curl`](https://curl.se/) for Codeberg.
  GitLab and GitHub need an authenticated CLI. Codeberg needs `CODEBERG_TOKEN`
  for private repositories or publication.
- Git access to the repository (SSH by default).

### Authentication

| Provider | Client | Authentication | API used for publication |
| --- | --- | --- | --- |
| GitLab | `glab` | `glab auth login` | MR discussions |
| GitHub | `gh` | `gh auth login` | PR review comments |
| Codeberg | `curl` | `CODEBERG_TOKEN` environment variable | Forgejo PR reviews, `COMMENT` event |

Authenticate once for the host in the review URL. For GitLab:

```sh
glab auth login --hostname gitlab.example.com
glab auth status --hostname gitlab.example.com
```

For GitHub:

```sh
gh auth login --hostname github.com
gh auth status --hostname github.com
```

For GitHub Enterprise Server, replace `github.com` with your instance's hostname.
The selected CLI must have valid credentials and permission to read the
repository and publish comments. No interactive login session needs to stay open.

For Codeberg, create a personal access token in
[Settings → Applications](https://codeberg.org/user/settings/applications).
Give it repository access (`read:repository` for private reads,
`write:repository` for publication), then expose it as `CODEBERG_TOKEN` in the
environment inherited by Neovim. For example, in Bash:

```bash
read -r -s -p "Codeberg token: " CODEBERG_TOKEN
printf '\n'
export CODEBERG_TOKEN
nvim
```

The token is optional for public API reads. To fetch a public repository without
SSH credentials, configure `clone_protocol = "https"`.

The plugin delegates GitLab/GitHub API requests to `glab api` or `gh api`.
Codeberg uses `curl` against `https://codeberg.org/api/v1`; its token is passed
through stdin rather than command-line arguments or temporary files. The plugin
never reads credential files or requires a token in your Neovim configuration.
Only the selected provider's client is required. Git fetching uses your Git
credentials separately (SSH keys by default); `CODEBERG_TOKEN` authenticates the
API, not Git fetches.

## Installation

With lazy.nvim:

```lua
{
  "edjubert/review.nvim",
  cmd = {
    "Review", "ReviewComment", "ReviewDrafts",
    "ReviewThreads", "ReviewRefresh", "ReviewSubmit", "ReviewClose",
  },
  opts = {},
}
```

For local development, replace `"edjubert/review.nvim"` with
`dir = "/path/to/review.nvim", name = "review.nvim"`.

Or add a local checkout to `runtimepath`:

```lua
vim.opt.runtimepath:prepend("/path/to/review.nvim")
require("review").setup({})
```

## Open a review

```vim
:Review https://gitlab.example.com/group/project/-/merge_requests/123
:Review https://github.com/owner/repo/pull/123
:Review https://codeberg.org/owner/repo/pulls/123
```

Or use `:Review` to enter one URL interactively. A new tab contains the commit/file
panel on the left and the inline diff on the right. The first commit opens
automatically. The panel also has a complete MR/PR entry.

No checkout is needed. When Neovim's current repository matches the URL, the
plugin fetches the MR/PR head ref into `refs/review/<number>/head` in that repository. It
does not switch branches or change working files. Otherwise it fetches into a
bare repository in Neovim's cache directory.

The commit list and the comparison base come from the provider rather than a
possibly stale local `origin/main`. GitHub and Codeberg comparisons use the PR's
merge base.

### Commands

| Command | Action |
| --- | --- |
| `:Review [url]` | Open a GitLab MR, GitHub PR or Codeberg PR |
| `:ReviewComment` | Compose a local draft on the current line |
| `:'<,'>ReviewComment` | Compose a local draft on a line range |
| `:ReviewDrafts` | Inspect, edit or delete local drafts |
| `:ReviewThreads` | Read existing discussions |
| `:ReviewRefresh` | Reload the review, commits, diffs and discussions |
| `:ReviewSubmit` | Preview drafts and choose whether to publish |
| `:ReviewClose` | Close the review tab |
| `:checkhealth review` | Check dependencies |

### Buffer mappings

| Mapping | Action |
| --- | --- |
| `Enter` in the panel | Open a commit or file |
| `]c` / `[c` | Next / previous commit |
| `]f` / `[f` | Next / previous file |
| `]h` / `[h` | Next / previous change block in the current file |
| `gA` | Complete MR/PR |
| `<leader>rc` in the diff, normal or visual mode | Comment on the line / range |
| `<leader>rs` in the panel or diff | Preview drafts and choose whether to publish |
| `<leader>rr` in the panel or diff | Refresh the review |
| `gd` | Local drafts |
| `gt` | Existing discussions |
| `q` | Close the review tab |

The panel uses your colorscheme for commits, directories and Git file statuses.
Shortcut hints stay at the bottom in a muted color, including `gA` and the
configured comment shortcut (default: `<leader>rc`).
Highlight groups such as `ReviewHelp`, `ReviewDirectory`, `ReviewFileAdded`,
`ReviewFileModified` and `ReviewFileDeleted` can be customized.

`3]h` jumps forward three change blocks. A replacement's removed and added lines
form one block; navigation stays within the current file. Use `]f` for the next file.
Opening a file automatically places the cursor on its first change block,
opens any folds covering that line, and centers the diff view there.

### Refresh a review

Run `:ReviewRefresh` or press `<leader>rr` in the panel or diff to fetch the
latest MR/PR metadata, commits, diffs and discussions in the existing tab.
The current commit and file stay selected when they still exist. If a rebase
replaced the selected commit, the complete MR/PR view opens instead. The cursor
position is retained when the displayed Git revisions are unchanged.

Local drafts keep their original positions. If the review diff changed, publication
still requires choosing updated positions. A failed refresh keeps the previously
loaded review available, and the command can also retry a failed initial load.

## Comments

1. Put the cursor on a line, or select a range with `V`.
2. Press `<leader>rc` or run `:ReviewComment`.
3. Write the comment in the Markdown editor.
4. Press `Ctrl-S` or `:w` to **save locally**. `q` cancels.
5. Inspect drafts with `:ReviewDrafts`.
6. Press `<leader>rs` or run `:ReviewSubmit`, inspect the preview, then explicitly
   select publication.

Creating, saving or opening a draft never posts it to the provider.
`Ctrl-S` writes the draft to disk, exits insertion and closes the comment editor.
The draft remains available after a restart; publication requires `:ReviewSubmit`.

Drafts survive Neovim restarts, under `stdpath("state")/review/drafts/`.
Before publication, the plugin checks that the review's diff refs still match each
draft. If the MR/PR changed, it preserves the draft and asks for an updated position.
It records each successful post before proceeding to the next comment.
If a request's outcome is uncertain, it blocks automatic retry: inspect the provider
and use `:ReviewDrafts` to delete the draft or authorize a retry.

### Line positions in commit views

A comment written in a commit view is attached to the current **MR/PR discussion**.
The plugin maps the selected commit's lines to the current review diff. This lets
comments on an early commit appear in the MR/PR when subsequent commits left those
lines unchanged.

If later commits rewrote or removed a selected line, its position is ambiguous;
use `gA` to choose a line in the complete MR/PR. Providers require a line to be
inside its diff hunks. Lines outside that context remain readable but cannot
receive an inline discussion.

Ranges must be contiguous on one side of the diff. Select additions or deletions
separately when a replacement contains both.

GitLab's discussion card can show up to 16 diff lines ending at the comment's
last line, even for a shorter selection. The range shown below that excerpt is
the actual comment range. The discussion API does not expose a context-size option.

On GitHub, selections become review comments with `line` and `side` (`LEFT`
for deleted lines, `RIGHT` for added/current lines). Ranges also include
`start_line` and `start_side`. Each submitted draft creates one published
review comment; submitting does not approve a PR or request changes.

On Codeberg, each draft creates a Forgejo review with the `COMMENT` event.
The first selected line is sent as `old_position` or `new_position`; ranges use
`extra_lines_count` for the following lines. Submitting does not approve a PR
or request changes.

Codeberg can include existing browser drafts when submitting a review. The plugin
checks for a pending review before sending each draft and leaves its local drafts
saved if one exists. Finish or discard that pending review on Codeberg first.

## Configuration

```lua
require("review").setup({
  panel_width = 44,
  keymaps = {
    comment = "<leader>rc", -- normal/visual; false disables this mapping
    submit = "<leader>rs",  -- normal, panel/diff; false disables this mapping
    refresh = "<leader>rr", -- normal, panel/diff; false disables this mapping
  },
  clone_protocol = "ssh", -- or "https"; uses existing Git credentials
  repo = nil,            -- optional repository path; otherwise auto-detected
  cache_dir = vim.fn.stdpath("cache") .. "/review",
  state_dir = vim.fn.stdpath("state") .. "/review",
})
```

## Current scope

- GitLab and GitHub, including their self-hosted instances, plus `codeberg.org`.
  Other Forgejo/Gitea hosts are not supported by the Codeberg provider.
- Text files; binary files display a notice.
- Commit diffs compare against the first parent. Root commits are not supported.
- Discussion reading and new comments; replies/resolution are not implemented.
- The provider must expose the file's diff to accept a positional comment.
- GitHub's files API exposes at most 3000 changed files. Larger PRs are rejected
  instead of presenting an incomplete review. Commit lists above 250 entries
  use the paginated comparison API and must match the PR's commit count.
- GitHub discussions use the REST review-comments API. Outdated comments are
  labeled; the resolved/unresolved state is not exposed by this API.
- Codeberg paginates commits, files and reviews using the server's page size and
  result counts. Inline positions come from the PR's full raw diff.
- Codeberg displays review comments individually, including resolved/stale
  indicators when exposed by the API. Comments whose commit cannot be matched
  to the current diff remain readable in `:ReviewThreads` without an inline marker.
- The inline view contains selectable deleted lines; it does not depend on
  `diffview.nvim` or `inline-diff.nvim`.

## Development

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua
```

The suite checks line mappings, positions, persistence, Git snapshot loading and
publication behavior with a mocked GitLab transport. It never posts comments to
a real service.

An optional integration check reads a real MR/PR, renders every commit/file view,
and saves one comment as a temporary local draft. Its transport rejects writes:

```sh
nvim --headless -u NONE -i NONE -l tests/smoke_read.lua \
  https://gitlab.example.com/group/project/-/merge_requests/123 \
  /path/to/local/repository
```
