import { cp, mkdir } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const destination = resolve(process.argv[2] ?? "staging/review-nvim");
await mkdir(destination, { recursive: true });
for (const entry of ["tab.json", "icon.svg", "dist"]) {
  await cp(`${root}/${entry}`, `${destination}/${entry}`, { recursive: true, force: false, errorOnExist: true });
}
console.log(`Web archive staging: ${destination}`);
