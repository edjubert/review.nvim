import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile, mkdir, mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));

export async function host(t, url) {
  const state = await mkdtemp(join(tmpdir(), "review-nvim-ui-"));
  const config = join(state, "config", "review-nvim-test");
  const pluginState = join(state, "plugins", "tab-state", "review-nvim");
  const settings = join(state, "settings", "settings.json");
  const alacritty = join(state, ".config", "alacritty", "alacritty.toml");
  const opened = join(state, "opened.txt");
  const prompted = join(state, "prompted.txt");
  const marked = join(state, "marked.txt");
  await mkdir(config, { recursive: true });
  await mkdir(pluginState, { recursive: true });
  await mkdir(join(state, "settings"), { recursive: true });
  await mkdir(join(state, ".config", "alacritty"), { recursive: true });
  await writeFile(settings, JSON.stringify({ mono_font_family: "monospace" }));
  await writeFile(alacritty, "[font]\nsize = 13\n");
  // Use the real picker and terminal, with an offline replacement for review loading.
  await writeFile(join(config, "init.lua"), `
vim.opt.shadafile = "NONE"
vim.api.nvim_create_user_command("FixtureMark", function()
  vim.fn.writefile({ "marked" }, vim.env.REVIEW_TEST_MARKED, "a")
end, {})
vim.api.nvim_create_autocmd("TextChangedI", {
  callback = function()
    if vim.bo.filetype == "TelescopePrompt" then
      vim.fn.writefile(vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.env.REVIEW_TEST_PROMPT)
    end
  end,
})
if vim.env.TELESCOPE_PATH and vim.env.PLENARY_PATH then
  vim.opt.runtimepath:prepend(vim.env.PLENARY_PATH)
  vim.opt.runtimepath:prepend(vim.env.TELESCOPE_PATH)
end
local review = require("review")
local open = review.open
review.open = function(url)
  if not url or vim.trim(url) == "" then return open(url) end
  require("review.history").record(review.config, assert(require("review.url").parse(url)),
    { title = "Offline fixture review" })
  vim.fn.writefile({ url }, vim.env.REVIEW_TEST_OPENED, "a")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Offline review opened", url })
end
`);
  const platform = process.platform === "darwin"
    ? `darwin-${process.arch === "arm64" ? "aarch64" : "x86_64"}` : "linux-x86_64";
  const child = spawn(`${root}/bin/${platform}/review-nvim`, [], {
    cwd: root,
    env: {
      ...process.env,
      HOME: state,
      XDG_CONFIG_HOME: join(state, "config"), XDG_DATA_HOME: join(state, "data"),
      XDG_CACHE_HOME: join(state, "cache"), XDG_STATE_HOME: join(state, "state"),
      NVIM_APPNAME: "review-nvim-test", REVIEW_TEST_OPENED: opened, REVIEW_TEST_PROMPT: prompted,
      REVIEW_TEST_MARKED: marked,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  let next = 0;
  let transcript = "";
  let logs = "";
  const pending = new Map();
  const attempts = [];
  const failures = new Map();
  const lines = createInterface({ input: child.stdout });
  let ready;
  const handshake = new Promise((resolve) => { ready = resolve; });
  child.stderr.on("data", (data) => { logs += data; });
  lines.on("line", (line) => {
    const value = JSON.parse(line);
    if (value.type === "ready") ready();
    else {
      pending.get(value.id)?.(value);
      pending.delete(value.id);
    }
  });
  child.stdin.write(JSON.stringify({
    type: "hello", protocol: 1, worktree: state, state_dir: pluginState, feature_id: 1,
  }) + "\n");
  const call = async (method, params) => {
    const id = String(++next);
    const response = new Promise((resolve) => pending.set(id, resolve));
    child.stdin.write(JSON.stringify({ type: "request", id, method, params }) + "\n");
    const value = await response;
    if (method === "terminal.read" && value.result?.data) {
      transcript += Buffer.from(value.result.data, "base64").toString("utf8");
    }
    return value;
  };
  const server = createServer(async (request, response) => {
    try {
      if (request.url === "/backend") {
        let body = "";
        for await (const part of request) body += part;
        const { method, params } = JSON.parse(body);
        const attempt = { method, at: Date.now(), rejected: false };
        attempts.push(attempt);
        const failure = failures.get(method)?.shift();
        if (failure) {
          attempt.rejected = true;
          response.setHeader("Content-Type", "application/json");
          response.end(JSON.stringify({ transportError: failure }));
          return;
        }
        const result = await call(method, params);
        response.setHeader("Content-Type", "application/json");
        response.end(JSON.stringify(result));
      } else {
        const path = request.url === "/" ? "index.html" : request.url.slice(1);
        if (!/^(index\.html|assets\/[a-zA-Z0-9_.-]+)$/.test(path)) {
          response.writeHead(404).end();
          return;
        }
        response.setHeader("Content-Type", path.endsWith(".js") ? "text/javascript"
          : path.endsWith(".css") ? "text/css" : "text/html");
        response.end(await readFile(join(root, "dist", path)));
      }
    } catch (error) {
      response.writeHead(500).end(String(error));
    }
  });
  await Promise.race([handshake, new Promise((_, reject) =>
    setTimeout(() => reject(new Error(`Backend not ready: ${logs}`)), 5000).unref())]);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  let browser;
  t.after(async () => {
    await browser?.close();
    child.stdin.end();
    await new Promise((resolve) => child.once("exit", resolve));
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    await rm(state, { recursive: true, force: true });
  });
  return {
    address: `http://127.0.0.1:${server.address().port}`,
    opened, prompted, marked, call, transcript: () => transcript, logs: () => logs,
    attempts: () => [...attempts],
    failNext: (method, error) => {
      const queue = failures.get(method) ?? [];
      queue.push(error);
      failures.set(method, queue);
    },
    setBrowser: (value) => { browser = value; },
    setFont: async (family, size) => {
      await writeFile(settings, JSON.stringify({ mono_font_family: family }));
      await writeFile(alacritty, `[font]\nsize = ${size}\n`);
    },
    // Same MessagePort SDK protocol as the CadencR guest preload.
    attach: async (page) => page.addInitScript(({ url, state }) => {
      const channel = new MessageChannel();
      channel.port1.onmessage = async ({ data }) => {
        let result;
        if (data.method === "hello") {
          result = {
            apiVersion: 1, instanceId: "test", plugin: { id: "review-nvim", version: "0.1.0" },
            visible: true, capabilities: ["backend.request"],
            context: {
              project: { id: 1, name: "Fixture", path: state },
              feature: { id: 1, name: "Fixture", branch: null, baseBranch: null, worktreePath: state },
              session: null, pullRequest: url ? { number: 12, url, state: "opened", title: "Fixture" } : null,
            },
            theme: {
              id: "test", appearance: "dark",
              tokens: {
                background: "#101218", foreground: "#e2e4e9", "muted-foreground": "#9297a5",
                secondary: "#272b35", "secondary-foreground": "#e2e4e9", border: "#424655",
                destructive: "#f38ba8", accent: "#343a49",
              },
            },
          };
        } else if (data.method === "config.get") result = { nvim_path: "nvim" };
        else if (data.method === "backend.request") {
          const answer = await fetch("/backend", {
            method: "POST", body: JSON.stringify({ method: data.params.method, params: data.params.params }),
          }).then((response) => response.json());
          if (answer.transportError) {
            channel.port1.postMessage({ v: 1, kind: "response", id: data.id, error: answer.transportError });
            return;
          }
          result = { result: answer.result, error: answer.error };
        } else throw new Error(`Unexpected SDK request: ${data.method}`);
        channel.port1.postMessage({ v: 1, kind: "response", id: data.id, result });
      };
      window.addEventListener("DOMContentLoaded", () => {
        window.postMessage({ type: "cadencr-tab:port" }, "*", [channel.port2]);
      });
    }, { url, state }),
  };
}
