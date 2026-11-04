import { defineConfig } from "vite";
import { copyRuntime, runtimeSources } from "./scripts/runtime.mjs";

export default defineConfig({
  base: "./",
  plugins: [{
    name: "review-nvim-runtime",
    async buildStart() {
      for (const file of await runtimeSources()) this.addWatchFile(file);
    },
    closeBundle: copyRuntime,
  }],
});
