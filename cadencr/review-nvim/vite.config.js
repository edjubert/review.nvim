import { defineConfig } from "vite";
import { copyRuntime, runtimeSources } from "./scripts/runtime.mjs";
import { copyDependencyNotices } from "./scripts/licenses.mjs";

export default defineConfig({
  base: "./",
  plugins: [{
    name: "review-nvim-runtime",
    async buildStart() {
      for (const file of await runtimeSources()) this.addWatchFile(file);
    },
    async writeBundle(_, bundle) {
      const modules = Object.values(bundle).flatMap((output) =>
        output.type === "chunk" ? Object.keys(output.modules) : []);
      await copyDependencyNotices(modules);
    },
    async closeBundle() { await copyRuntime(); },
  }],
});
