# review.nvim for CadencR 0.1.9

- Show how far the review is behind its target branch with `Behind: N commit(s)`
  in the panel, or `Behind: none` when it is up to date. GitHub reads it from the
  comparison it already fetches; GitLab and Codeberg compare the head against the
  target branch.
- Open the current review in the browser from anywhere in the panel with
  `:ReviewStackOpen` or the optional `stack_open` mapping. A stack line still
  opens its own review.
- Bundle the updated Neovim plugin with native CadencR backends for macOS arm64,
  macOS Intel and Linux x86_64, retaining dependency notices and build evidence.

Requires CadencR 0.16.0+, Neovim 0.11+ and existing Git/provider CLI authentication.
Draft comments remain local until an explicit review.nvim publication command.
The previously published 0.1.8 tag and assets are preserved.
