import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";

export const platforms = {
  "darwin-aarch64": ["darwin", "arm64"],
  "darwin-x86_64": ["darwin", "x64"],
  "linux-x86_64": ["linux", "x64"],
};

export async function digest(path) {
  const bytes = await readFile(path);
  return { sha256: createHash("sha256").update(bytes).digest("hex"), size: bytes.length };
}

export async function treeDigests(directory, prefix = "") {
  const files = {};
  for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) =>
    a.name < b.name ? -1 : a.name > b.name ? 1 : 0)) {
    const name = prefix + entry.name;
    if (entry.isDirectory()) Object.assign(files, await treeDigests(join(directory, entry.name), `${name}/`));
    else if (entry.isFile()) files[name] = await digest(join(directory, entry.name));
    else throw new Error(`Release evidence cannot contain a link or special file: ${name}`);
  }
  return files;
}

export async function sourceInputs(root) {
  const inputs = {};
  for (const file of ["package.json", "package-lock.json", "backend/go.mod", "backend/go.sum"]) {
    inputs[file] = await digest(join(root, file));
  }
  return inputs;
}

export async function verifyNativeReceipt(root, source, target, receipt) {
  const [platform, architecture] = platforms[target] ?? [];
  if (!platform || receipt.schema_version !== 1 || receipt.target !== target || receipt.native?.platform !== platform ||
      receipt.native?.architecture !== architecture || receipt.source?.commit !== source.commit ||
      receipt.source?.modified !== false || receipt.source?.repository !== source.repository) {
    throw new Error(`Missing exact-source native qualification for ${target}`);
  }
  if (process.env.GITHUB_RUN_ID && (receipt.workflow?.sha !== source.commit ||
      receipt.workflow?.url !== `https://github.com/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}` ||
      receipt.workflow?.attempt !== Number(process.env.GITHUB_RUN_ATTEMPT))) {
    throw new Error(`Native qualification must come from this exact workflow run for ${target}`);
  }
  const executable = await digest(join(root, `bin/${target}/review-nvim`));
  if (JSON.stringify(receipt.executable) !== JSON.stringify(executable) ||
      JSON.stringify(receipt.inputs) !== JSON.stringify(await sourceInputs(root))) {
    throw new Error(`Native qualification does not match the executable or dependencies for ${target}`);
  }
}
