import { spawnSync } from "node:child_process";
import { repository } from "./metadata.mjs";

export function git(root, args) {
  const result = spawnSync("git", args, { cwd: root, encoding: "utf8" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr || "Unable to establish Git source provenance.");
  return result.stdout.trim();
}

export function sourceState(root) {
  return {
    repository,
    commit: git(root, ["rev-parse", "HEAD"]),
    modified: git(root, ["status", "--porcelain", "--untracked-files=all"]) !== "",
  };
}

export function requireCleanSource(root, bundled) {
  const source = sourceState(root);
  if (source.modified) throw new Error("Release packaging requires a clean, committed source tree.");
  if (!bundled || bundled.modified || bundled.commit !== source.commit ||
      bundled.repository !== source.repository) {
    throw new Error("The bundled runtime must be rebuilt from the exact clean source commit.");
  }
  return source;
}
