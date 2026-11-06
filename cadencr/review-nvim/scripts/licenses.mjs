import { spawnSync } from "node:child_process";
import { mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));

function go(args) {
  const result = spawnSync("go", ["-C", `${root}/backend`, ...args], { encoding: "utf8" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr);
  return result.stdout.trim();
}

export async function copyNotices(source, destination, fallbackLicense) {
  const entries = await readdir(source, { withFileTypes: true });
  const license = /^(licen[cs]e|copying)([._-].*)?$/i;
  const notices = entries.filter((entry) => (entry.isFile() || entry.isSymbolicLink()) &&
    (license.test(entry.name) || /^(notice|copyright|patents|authors|third[_-]party[_-]notices)([._-].*)?$/i.test(entry.name)));
  if (!notices.some((entry) => license.test(entry.name)) && !fallbackLicense) {
    throw new Error(`No distributable license found in ${source}`);
  }
  await mkdir(destination, { recursive: true });
  for (const entry of notices) {
    const path = join(source, entry.name);
    if (!(await stat(path)).isFile()) throw new Error(`Notice must be a regular file: ${path}`);
    await writeFile(join(destination, entry.name), await readFile(path));
  }
  if (!notices.some((entry) => license.test(entry.name))) {
    await writeFile(join(destination, "LICENSE"), await readFile(fallbackLicense));
  }
}

export async function copyDependencyNotices(moduleIds, destination = `${root}/dist`) {
  const manifest = JSON.parse(await readFile(`${root}/package.json`, "utf8"));
  // Include declared runtime dependencies, actual bundled transitive modules, and
  // Vite's generated module-preload helper. Build/test-only packages are not shipped.
  const packages = new Set([...Object.keys(manifest.dependencies), "vite"]);
  for (const id of moduleIds) {
    const name = id.split("/node_modules/").at(-1);
    if (name === id) continue;
    const parts = name.split("/");
    packages.add(parts[0].startsWith("@") ? parts.slice(0, 2).join("/") : parts[0]);
  }
  const lines = [
    "# Third-party notices", "",
    "These notices accompany the compiled frontend, native backends and bundled Lua runtime.",
    "The gemoji catalogue notice is in `runtime/LICENSES/gemoji.txt`.", "",
    "## Frontend", "",
  ];
  for (const name of [...packages].sort()) {
    const directory = `${root}/node_modules/${name}`;
    const dependency = JSON.parse(await readFile(`${directory}/package.json`, "utf8"));
    await copyNotices(directory, `${destination}/LICENSES/npm/${name}`);
    lines.push(`- \`${name}@${dependency.version}\`: ${dependency.license}; \`LICENSES/npm/${name}/\`.`);
  }
  lines.push("", "## Native backends", "",
    "The registry backend archive format holds one executable. Its accompanying notices",
    "are distributed here in the required web archive, and separately as release evidence.", "");
  const modules = go(["list", "-mod=readonly", "-m", "-f",
    "{{if not .Main}}{{.Path}}\t{{.Version}}\t{{.Dir}}{{end}}", "all"]);
  for (const line of modules.split("\n").filter(Boolean)) {
    const [name, version, directory] = line.split("\t");
    await copyNotices(directory, `${destination}/LICENSES/go/${name}`);
    lines.push(`- \`${name}@${version}\`: \`LICENSES/go/${name}/\`.`);
  }
  const goroot = go(["env", "GOROOT"]);
  // Homebrew installs Go's LICENSE beside libexec rather than inside GOROOT.
  await copyNotices(goroot, `${destination}/LICENSES/go/toolchain`, `${goroot}/../LICENSE`);
  // Go's standard library includes vendored x/* code with separate notices.
  for (const entry of await readdir(`${goroot}/src/vendor/golang.org/x`, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    await copyNotices(`${goroot}/src/vendor/golang.org/x/${entry.name}`,
      `${destination}/LICENSES/go/toolchain/vendor/golang.org/x/${entry.name}`);
  }
  lines.push(`- ${go(["version"])} and its vendored standard-library dependencies: \`LICENSES/go/toolchain/\`.`, "");
  await writeFile(`${destination}/THIRD_PARTY_NOTICES.md`, lines.join("\n"));
}
