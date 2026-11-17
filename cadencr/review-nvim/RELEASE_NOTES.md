# review.nvim for CadencR 0.1.8

- Navigate a stack of merge or pull requests. The panel lists every review with
  its approvals, change requests and pipeline state, and `:ReviewStackNext`,
  `:ReviewStackPrev` and `:ReviewStack` move between them.
- Open a stack review in the browser with `:ReviewStackOpen` or the optional
  `stack_open` mapping.
- Hover a truncated stack or commit title to read it in full, with the pipeline
  and approval status on their own coloured lines and the browser shortcut.
- Configure the stack icons with `stack_icons`, and reload stack statuses after
  an approval or a change request.
- Bundle the updated Neovim plugin with native CadencR backends for macOS arm64,
  macOS Intel and Linux x86_64, retaining dependency notices and build evidence.

Requires CadencR 0.16.0+, Neovim 0.11+ and existing Git/provider CLI authentication.
Draft comments remain local until an explicit review.nvim publication command.
The previously published 0.1.7 tag and assets are preserved.
