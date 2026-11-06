import { cp, mkdir, readdir, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { sourceState } from "./source.mjs";

const source = fileURLToPath(new URL("../../../", import.meta.url));
const target = fileURLToPath(new URL("../dist/runtime/", import.meta.url));

export async function runtimeSources() {
  const files = [
    `${source}/LICENSE`,
    `${source}/cadencr/review-nvim/runtime/bootstrap.lua`,
    `${source}/cadencr/review-nvim/runtime/start.lua`,
  ];
  for (const folder of ["lua", "plugin", "doc", "LICENSES"]) {
    for (const path of await readdir(`${source}/${folder}`, { recursive: true })) {
      if (/\.(lua|txt)$/.test(path)) files.push(`${source}/${folder}/${path}`);
    }
  }
  return files;
}

export async function copyRuntime(destination = target) {
  await mkdir(destination, { recursive: true });
  for (const folder of ["lua", "plugin", "doc", "LICENSES"]) {
    await cp(`${source}/${folder}`, `${destination}/${folder}`, { recursive: true });
  }
  await cp(`${source}/LICENSE`, `${destination}/LICENSE`);
  for (const file of ["bootstrap.lua", "start.lua"]) {
    await cp(`${source}/cadencr/review-nvim/runtime/${file}`, `${destination}/${file}`);
  }
  await writeFile(`${destination}/source.json`, JSON.stringify(sourceState(source), null, 2) + "\n");
}
