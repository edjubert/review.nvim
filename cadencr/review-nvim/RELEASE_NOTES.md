# review.nvim for CadencR 0.1.7

- Browse GitHub pull request pipelines: check suites anchored to the head
  commit, their check runs grouped as jobs, Actions workflow metadata merged
  onto the matching check runs, and raw Actions job logs. The picker, polling
  and log sources are shared with GitLab.
- Split parsed job logs by test campaign, and skip campaign discovery for
  sources that do not need it.
- Open job log sources from the Telescope selection.
- Allow escape sequences in GitHub job logs so raw traces keep their colors.
- Edit and publish the MR/PR description with `:ReviewEditDescription`, with an
  explicit confirmation before the write and the editor kept open on failure.
- Enlarge review document windows to 140x40 on wide editors.
- Bundle the updated Neovim plugin with native CadencR backends for macOS arm64,
  macOS Intel and Linux x86_64, retaining dependency notices and build evidence.

Requires CadencR 0.16.0+, Neovim 0.11+ and existing Git/provider CLI authentication.
Draft comments remain local until an explicit review.nvim publication command.
The previously published 0.1.6 tag and assets are preserved.
