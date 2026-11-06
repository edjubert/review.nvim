import { spawnSync } from "node:child_process";
import { mkdir, rename } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const platforms = {
  "darwin-aarch64": ["darwin", "arm64"],
  "darwin-x86_64": ["darwin", "amd64"],
  "linux-x86_64": ["linux", "amd64"],
};
const current = process.platform === "darwin"
  ? `darwin-${process.arch === "arm64" ? "aarch64" : "x86_64"}`
  : "linux-x86_64";
const requested = process.argv.slice(2);
const targets = requested.includes("--all") ? Object.keys(platforms) : requested.length ? requested : [current];
function run(program, args, env = process.env) {
  const result = spawnSync(program, args, { cwd: root, env, stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${program} exited with ${result.status}`);
}
for (const target of targets) {
  if (!platforms[target]) throw new Error(`Unsupported platform: ${target}`);
  const [GOOS, GOARCH] = platforms[target];
  const directory = `${root}/bin/${target}`;
  await mkdir(directory, { recursive: true });
  const temporary = `${directory}/review-nvim.next`;
  run("go", ["-C", "backend", "build", "-mod=readonly", "-trimpath", "-buildvcs=true", "-o", temporary, "."],
    { ...process.env, GOOS, GOARCH, CGO_ENABLED: "0" });
  if (GOOS === "darwin" && GOARCH === "arm64" && process.platform === "darwin") {
    run("codesign", ["--force", "--sign", "-", temporary]);
    run("codesign", ["--verify", "--strict", temporary]);
  }
  // Replace the inode; rewriting a previously run Mach-O breaks its cached signature.
  await rename(temporary, `${directory}/review-nvim`);
  console.log(`Built ${target}`);
}
