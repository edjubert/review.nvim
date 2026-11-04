import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { metadata } from "../scripts/metadata.mjs";

test("marketplace metadata binds the runtime and exact platform archives to CadencR 0.16", async () => {
  const manifest = JSON.parse(await readFile(new URL("../tab.json", import.meta.url)));
  const web = { archive: "https://example.com/tab.tar.gz", sha256: "a".repeat(64), size: 12 };
  const binaries = Object.fromEntries(Object.entries(manifest.backend.binary).map(([platform, cmd]) => [
    platform, {
      archive: `https://example.com/${platform}.tar.gz`, sha256: "b".repeat(64), size: 34,
      cmd, executable_sha256: "c".repeat(64), executable_size: 56,
    },
  ]));
  const document = metadata(manifest, web, binaries);
  assert.equal(document.kind, "tab");
  assert.equal(document.package.host.compatibility.min_app_version, "0.16.0");
  for (const key of ["id", "name", "version", "api_version"]) {
    assert.equal(document.package.tab[key], manifest[key]);
  }
  assert.deepEqual(document.package.tab.backend, {
    protocol: manifest.backend.protocol, reasoning: manifest.backend.reasoning,
  });
  assert.deepEqual(document.package.tab.distribution, {
    archive: web.archive, sha256: web.sha256, binary: binaries,
  });
  assert.deepEqual(manifest.permissions, ["features:read", "forge:read"]);
  assert.equal(manifest.commands, undefined);
});
