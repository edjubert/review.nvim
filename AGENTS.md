# review.nvim

- Lua plugin for Neovim 0.11+. Keep the core UI independent of its providers.
- Run processes with argument arrays through `vim.system`; do not build shell commands.
- Review buffers are virtual. Always load Git content using the explicit repository
  and commit metadata, never by deriving a directory from a review buffer name.
- Load the MR/PR's exact commit list and diff refs from its provider.
- Comments are local drafts. Saving or editing never publishes.
- Only explicit `:ReviewSubmit`, `:ReviewApprove`, and `:ReviewRequestChanges`
  may call their corresponding write endpoints.
- Never publish a real comment, resolve a thread, or send a message during development.
- Never read tokens from configuration files; use authenticated `glab`/`gh`
  commands, or `CODEBERG_TOKEN` from the environment for Codeberg.
- Pass Codeberg credentials to curl through stdin, never process arguments,
  shell commands or temporary files. Send them only to https://codeberg.org.
- Verify line/range mappings and failure behavior with mocked write transports.
- Tests: `nvim --headless -u NONE -i NONE -l tests/run.lua`.
- Keep documentation aligned with implemented commands and supported providers.
- Do not create branches prefixed with `codex/`.
