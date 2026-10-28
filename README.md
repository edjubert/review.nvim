<p align="center">
  <img src="assets/logo.svg" width="128" alt="review.nvim logo">
</p>

# review.nvim

Read GitLab merge requests and GitHub or Codeberg pull requests commit by commit,
view each file as an inline diff, and draft comments on a line or a line range
in Neovim.

![Complete pull request with the commit panel, inline Lua diff and local draft markers](assets/screenshots/overview.png)

- Open a GitLab MR, GitHub PR or Codeberg PR URL, including commit/file subpages.
- Browse the exact commit list, oldest first.
- Read the MR/PR title and Markdown description.
- Switch between individual commits and the complete MR/PR.
- Read additions, deletions and context in one read-only buffer with both line numbers
  and intraline highlights.
- Select deleted lines as well as added lines.
- Save, edit and delete persistent local comment drafts.
- Draft replies to existing GitLab and GitHub discussions from their diff lines.
- Preview and explicitly publish drafts as inline discussions on GitLab, GitHub
  or Codeberg.
- Open the discussion under the cursor or browse all review discussions.
- Toggle discussion messages and replies directly below their commented lines.
- Jump from a discussion to its commented line.
- Refresh the open review without losing local drafts.

The URL selects the provider automatically. GitLab, self-hosted GitLab, GitHub,
GitHub Enterprise Server and Codeberg use the same UI and shortcuts.
Provider code lives in `lua/review/providers/`.

The screenshots use a demo GitHub pull request; the discussion is simulated
locally. Colors, Markdown rendering and selection menus come from the user's
Neovim configuration.

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
    "Review", "ReviewInfo", "ReviewComment", "ReviewReply", "ReviewDrafts",
    "ReviewThreads", "ReviewToggleComments", "ReviewRefresh", "ReviewSubmit", "ReviewClose",
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

![A single commit expanded to show its changed files and inline diff](assets/screenshots/commit-navigation.png)

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
| `:ReviewInfo` | Show the MR/PR title and Markdown description |
| `:ReviewComment` | Compose a local draft on the current line |
| `:'<,'>ReviewComment` | Compose a local draft on a line range |
| `:ReviewReply` | Draft a reply to a discussion on the current diff line |
| `:ReviewDrafts` | Inspect, edit or delete local drafts |
| `:ReviewThreads` | Read all discussions and jump to their comment lines |
| `:ReviewToggleComments` | Show or hide discussion messages and replies inline |
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
| `<leader>rR` in the diff | Draft a reply to a discussion on the current line |
| `<leader>rs` in the panel or diff | Preview drafts and choose whether to publish |
| `<leader>rr` in the panel or diff | Refresh the review |
| `<leader>ri` in the panel or diff | Show the MR/PR title and description |
| `<leader>rt` in the panel or diff | Toggle inline discussion messages and replies |
| `gd` | Local drafts |
| `gt` in the diff | Open discussions attached to the cursor line or range |
| `gT` | Open all discussions in the MR/PR |
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

### Review title and description

Run `:ReviewInfo` or press `<leader>ri` in the panel or diff to read the review's
title and description in a read-only Markdown window. Press `q` to close it.
An empty description displays "No description provided."

![ReviewInfo displaying the pull request title and Markdown description](assets/screenshots/review-info.png)

The window uses the loaded review metadata. Run `:ReviewRefresh` to retrieve
changes made to the title or description since the review was opened.
Configure `keymaps.info` to change the shortcut, or set it to `false` to disable
the mapping while keeping `:ReviewInfo` available.

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

![Markdown comment editor for a line range, with the local-save shortcut in its title](assets/screenshots/range-comment.png)

Creating, saving or opening a draft never posts it to the provider.
`Ctrl-S` writes the draft to disk, exits insertion and closes the comment editor.
The draft remains available after a restart; publication requires `:ReviewSubmit`.

Drafts survive Neovim restarts, under `stdpath("state")/review/drafts/`.
Before publication, the plugin checks that the review's diff refs still match each
draft. If the MR/PR changed, it preserves the draft and asks for an updated position.
It records each successful post before proceeding to the next comment.
If a request's outcome is uncertain, it blocks automatic retry: inspect the provider
and use `:ReviewDrafts` to delete the draft or authorize a retry.

### Manage local drafts

Run `:ReviewDrafts` or press `gd` to select a saved draft, then choose
`Edit locally` or `Delete locally`.

![Local draft selector showing comment locations and message previews](assets/screenshots/local-drafts.png)

### Preview before publication

`:ReviewSubmit` opens a preview and asks whether to keep the drafts local or
publish them. Choose `Keep local` to retain them without posting.

![Submission preview with the explicit Keep local or Publish confirmation](assets/screenshots/submission-preview.png)

### Browse discussions

Use `gt` on a commented diff line to open its discussion. For a range comment,
any line inside the range works. If several discussions share that line, they
open together. In commit views, current-review discussions are mapped onto
unchanged lines; ranges must remain contiguous and unchanged.

Use `gT` in the panel or diff, or `:ReviewThreads`, to read all discussions across
the MR/PR, including comments without a file position.

![Discussion window with two participants and a comment anchored to a line range](assets/screenshots/discussion.png)

In the discussion window:

| Mapping | Action |
| --- | --- |
| `j` / `k` | Move through discussions and replies |
| `Enter` | Jump to the selected discussion's comment line |
| `q` | Close the window |

`Enter` works on a discussion's heading, location or message text. It focuses the
line in the displayed diff when available. Otherwise it opens the file in the
complete MR/PR view, focuses the commented side (including deleted lines), opens
any folds and centers the cursor.

For an older comment, the plugin maps unchanged lines to the current review.
If its line was rewritten/deleted, its file is no longer in the review diff, or
the provider does not expose its original revision, the discussion stays open
with an explanatory message. Comments without a file line remain readable.

### Inline discussions

Run `:ReviewToggleComments` or press `<leader>rt` to show or hide discussions
directly below their commented lines. A range discussion appears below its last
line, with the author, message and replies. Multiple discussions on the same line
appear together.

Messages use virtual lines, leaving the diff content and comment positions
unchanged. Long lines wrap to the diff window's width. Markdown is displayed as
text; use `gt` to open the complete discussion in a Markdown window.

Inline discussions are hidden by default. Set `inline_comments = true` to show
them when opening a review. The toggle applies to the current review and survives
file/commit navigation and refreshes. Configure `keymaps.toggle_comments` to
change the shortcut, or set it to `false` to keep only the command.

Only discussions that can be mapped to the displayed diff appear inline.
General comments and discussions on unavailable lines remain accessible with
`gT` or `:ReviewThreads`. Local drafts keep their compact markers.
Customize `ReviewCommentBorder`, `ReviewCommentAuthor` and `ReviewCommentBody`
to change the blocks' colors.

### Reply to a discussion

Put the cursor on a commented diff line and run `:ReviewReply` or press
`<leader>rR`. Any line inside a comment range works. If several discussions cover
the line, select the one you want to answer.

The Markdown editor creates a persistent **local reply draft**. `Ctrl-S` or `:w`
saves it locally; `q` cancels. `:ReviewDrafts` lets you edit or delete it, and the
diff marks it as `local reply`. `:ReviewSubmit` previews the original comment and
your reply, then asks for explicit publication.

Replies use the existing discussion ID, preserving the thread instead of creating
a new inline comment. Before publication, the plugin checks the diff refs and
that the original comment still exists. Failed or uncertain requests keep the
draft, with the same retry safeguards as new comments.

| Provider | Replies |
| --- | --- |
| GitLab | Adds a note to the existing MR discussion |
| GitHub | Replies to the top-level PR review comment |
| Codeberg | Reply drafts are not supported by this provider |

Replies leave approval and resolution unchanged. Configure `keymaps.reply` to
change the shortcut, or set it to `false` to keep only `:ReviewReply`.

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
  inline_comments = false, -- initially show only discussion markers
  keymaps = {
    comment = "<leader>rc", -- normal/visual; false disables this mapping
    submit = "<leader>rs",  -- normal, panel/diff; false disables this mapping
    refresh = "<leader>rr", -- normal, panel/diff; false disables this mapping
    info = "<leader>ri",    -- normal, panel/diff; false disables this mapping
    toggle_comments = "<leader>rt", -- normal, panel/diff; false disables this mapping
    reply = "<leader>rR",   -- normal, diff; false disables this mapping
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
- Discussion reading and new comments on all providers; replies on GitLab and
  GitHub. Codeberg reply drafts and discussion resolution are not implemented.
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
