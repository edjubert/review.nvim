# review.nvim

Repository: [edjubert/review.nvim](https://github.com/edjubert/review.nvim).

Read a GitLab merge request commit by commit, view each file as an inline diff,
and draft comments on a line or a line range directly in Neovim.

- Open an MR URL, including a URL ending in `/commits` or `/diffs`.
- Browse the exact commit list returned by GitLab, oldest first.
- Switch between individual commits and the complete MR.
- Read additions, deletions and context in one read-only buffer with both line numbers
  and intraline highlights.
- Select deleted lines as well as added lines.
- Save, edit and delete persistent local comment drafts.
- Preview and explicitly publish drafts as GitLab discussions.
- Read existing discussions for the current file.
- Refresh the open MR without losing local drafts.

The first provider is GitLab. The plugin name and UI are platform-neutral;
provider code lives in `lua/review/providers/`.

## Requirements

- Neovim 0.11+.
- `git`.
- An authenticated [`glab`](https://gitlab.com/gitlab-org/cli).
- Git access to the repository (SSH by default).

For a self-hosted GitLab instance:

```sh
glab auth login --hostname gitlab.example.com
```

The plugin uses `glab api` for authentication. It does not read token files or
require a token in your Neovim configuration.

## Local installation

With lazy.nvim:

```lua
{
  dir = vim.fn.expand("~/workspace/edjubert/review.nvim"),
  name = "review.nvim",
  cmd = {
    "Review", "ReviewComment", "ReviewDrafts",
    "ReviewThreads", "ReviewRefresh", "ReviewSubmit", "ReviewClose",
  },
  opts = {},
}
```

Or add the directory to `runtimepath`:

```lua
vim.opt.runtimepath:prepend(vim.fn.expand("~/workspace/edjubert/review.nvim"))
require("review").setup({})
```

## Open a review

```vim
:Review https://gitlab.example.com/group/project/-/merge_requests/123
```

Or `:Review` to enter the URL interactively. A new tab contains the commit/file
panel on the left and the inline diff on the right. The first commit opens
automatically. The panel also has a complete-MR entry.

No checkout is needed. When Neovim's current repository matches the URL, the
plugin fetches an MR ref into `refs/review/<iid>/head` in that repository. It
does not switch branches or change working files. Otherwise it fetches into a
bare repository in Neovim's cache directory.

The commit list and the comparison base come from GitLab rather than a possibly
stale local `origin/main`.

### Commands

| Command | Action |
| --- | --- |
| `:Review [url]` | Open a merge request |
| `:ReviewComment` | Compose a local draft on the current line |
| `:'<,'>ReviewComment` | Compose a local draft on a line range |
| `:ReviewDrafts` | Inspect, edit or delete local drafts |
| `:ReviewThreads` | Read existing discussions |
| `:ReviewRefresh` | Reload the MR, commits, diffs and discussions |
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
| `gA` | Complete MR |
| `<leader>rc` in the diff, normal or visual mode | Comment on the line / range |
| `<leader>rs` in the panel or diff | Preview drafts and choose whether to publish |
| `<leader>rr` in the panel or diff | Refresh the MR |
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
latest MR metadata, commits, diffs and discussions in the existing tab.
The current commit and file stay selected when they still exist. If a rebase
replaced the selected commit, the complete MR view opens instead. The cursor
position is retained when the displayed Git revisions are unchanged.

Local drafts keep their original positions. If the MR diff changed, publication
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

Creating, saving or opening a draft never posts it to GitLab.
`Ctrl-S` writes the draft to disk, exits insertion and closes the comment editor.
The draft remains available after a restart; publication requires `:ReviewSubmit`.

Drafts survive Neovim restarts, under `stdpath("state")/review/drafts/`.
Before publication, the plugin checks that GitLab's diff refs still match each
draft. If the MR changed, it preserves the draft and asks for an updated position.
It records each successful post before proceeding to the next comment.
If a request's outcome is uncertain, it blocks automatic retry: inspect GitLab
and use `:ReviewDrafts` to delete the draft or authorize a retry.

### Line positions in commit views

A comment written in a commit view is attached to the current **MR discussion**.
The plugin maps the selected commit's lines to the current MR diff. This lets
comments on an early commit appear in the MR when subsequent commits left those
lines unchanged.

If later commits rewrote or removed a selected line, its position is ambiguous;
use `gA` to choose a line in the complete MR. GitLab also requires a line to be
inside its diff hunks. Lines outside that context remain readable but cannot
receive an inline discussion.

Ranges must be contiguous on one side of the diff. Select additions or deletions
separately when a replacement contains both.

GitLab's discussion card can show up to 16 diff lines ending at the comment's
last line, even for a shorter selection. The range shown below that excerpt is
the actual comment range. The discussion API does not expose a context-size option.

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

- GitLab only; GitHub support can be added through another provider.
- Text files; binary files display a notice.
- Commit diffs compare against the first parent. Root commits are not supported.
- Discussion reading and new comments; replies/resolution are not implemented.
- GitLab must expose the file's diff to accept a positional comment.
- The inline view contains selectable deleted lines; it does not depend on
  `diffview.nvim` or `inline-diff.nvim`.

## Development

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua
```

The suite checks line mappings, positions, persistence, Git snapshot loading and
publication behavior with a mocked GitLab transport. It never posts comments to
a real service.

An optional integration check reads a real MR, renders every commit/file view,
and saves one comment as a temporary local draft. Its transport rejects writes:

```sh
nvim --headless -u NONE -i NONE -l tests/smoke_read.lua \
  https://gitlab.example.com/group/project/-/merge_requests/123 \
  /path/to/local/repository
```
