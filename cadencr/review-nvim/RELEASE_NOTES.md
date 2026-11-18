# review.nvim for CadencR 0.1.10

- Keep one review per Neovim tab. Opening another review no longer closes the
  current one, so two reviews can stay open side by side. Commands target the
  review of the current tab, and `:ReviewClose` closes that review.
- Reuse an untouched empty window for the first review, even when the tab also
  holds a sidebar or another split.
- Name the review tab `Review !123` for GitLab and `Review #123` for GitHub and
  Codeberg.
- Stack navigation still replaces the review it leaves.
- Bundle the updated Neovim plugin with native CadencR backends for macOS arm64,
  macOS Intel and Linux x86_64, retaining dependency notices and build evidence.

Requires CadencR 0.16.0+, Neovim 0.11+ and existing Git/provider CLI authentication.
Draft comments remain local until an explicit review.nvim publication command.
The previously published 0.1.9 tag and assets are preserved.
