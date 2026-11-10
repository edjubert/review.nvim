# review.nvim for CadencR 0.1.6

- Resolve GitLab conversations in GraphQL batches of up to 20, with one MR
  revision check before processing, discussion validation before each batch,
  confirmed partial results, and REST fallback for unsupported servers.
- Choose all open conversations or only those started by a selected author.
- Load comment reactions in the background and announce conversation loading
  and confirmed resolution completion without waiting for reactions.
- Show open conversation counts and the running pipeline status.
- Add configurable job log sources, incremental streams and parsers, with
  previews following the highlighted job and log source.
- Send the JSON content type explicitly for authenticated GitLab writes.
- Bundle the updated Neovim plugin with native CadencR backends for macOS arm64,
  macOS Intel and Linux x86_64, retaining dependency notices and build evidence.

Requires CadencR 0.16.0+, Neovim 0.11+ and existing Git/provider CLI authentication.
Draft comments remain local until an explicit review.nvim publication command.
The previously published 0.1.5 tag and assets are preserved.
