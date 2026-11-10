# CadencR 0.1.6 release procedure

Published tags and assets for earlier versions must remain unchanged.
The source version for this release is `cadencr-v0.1.6`.

## Build evidence

1. Commit all source changes. The clean source includes the workflow, lockfiles,
   license packaging and pinned toolchain configuration.
2. Push the source branch and let `Qualify review.nvim tab` complete. Check all
   three native jobs and the packaging job; a cross-build is insufficient.
3. Tag the exact successful source commit with `cadencr-v0.1.6`. The tag must
   match `tab.json` and the source commit in every receipt.
4. Use the successful **tag run's** `release-candidate` artifact. Preserve its
   run URL/attempt, `build-receipt.json`, native test logs, registry validation
   and GitHub attestations. Do not rebuild locally before uploading.
5. Verify each archive's GitHub attestation with the source repository and
   exact tag/source commit, and compare its digest with `build-receipt.json`.

The workflow hashes Neovim and the registry-qualified CLI before use. Node and
Go versions, the registry base and the download pins are in `ci/toolchains.json`;
npm integrity values and Go module sums are committed in their lockfiles.

## Immutable author release

Publication requires an explicit user instruction.

1. Enable immutable releases in `edjubert/review.nvim` before publication.
2. Create a **draft** release for the already pushed source tag. Upload the
   four `tab*.tar.gz` archives, `marketplace.json`, `build-receipt.json`,
   `native-evidence.tar.gz` and `registry-validation.json` from the tag run.
3. Compare uploaded asset digests, the source tag and build evidence one last
   time, then publish the draft. GitHub locks its tag and assets.
4. Read the published release through GitHub's API and require
   `immutable: true`. Keep its GitHub-generated release attestation.

If an immutable release needs correction, increment the version and make a new
release. Never delete, replace or retag published releases.

## Registry contribution and maintainer actions

The generated `packages/review-nvim-0.1.6.json` and matching
`submissions/review-nvim-0.1.6.json` contain exact source and artifact digests.
Submit those files in a new registry PR after the immutable release is public.
Include the source tag/commit, immutable release URL, tag workflow URL,
attestation verification and native qualification evidence in its description.
The new version supersedes 0.1.5 without changing its published tag or assets.

Author-side candidate validation does not replace the registry's trusted
`inert-metadata` and `contributor-tooling` results for the final candidate/base.
The registry maintainer must approve the workflow if GitHub requires it.

After the technical review is complete, the registry owner must give explicit
admission consent in the reviewer conversation for the final PR, plugin, version
and head commit. The author cannot supply that consent on the owner's behalf.
Do not publish comments or resolve review discussions without an explicit user
instruction.
