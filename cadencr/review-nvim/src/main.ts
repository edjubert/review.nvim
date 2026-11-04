import { connect, type CadencrClient, type JsonValue, type ThemeSnapshot } from "@cadencr/tab-sdk";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { Requests } from "./requests";
import "./style.css";

interface Output {
  data: string;
  offset: number;
  reset: boolean;
  exited: boolean;
  status: string;
}

interface Appearance {
  fontFamily: string;
  fontSize: number;
}

function element<T extends HTMLElement>(id: string): T {
  const value = document.getElementById(id);
  if (!value) throw new Error(`Missing #${id}`);
  return value as T;
}

const status = element("status");
const error = element("error");
const retry = element<HTMLButtonElement>("retry");
const container = element("terminal");
const terminal = new Terminal({ cursorBlink: true, fontSize: 13, scrollback: 2000 });
const fit = new FitAddon();
terminal.loadAddon(fit);
terminal.open(container);

let client: CadencrClient | undefined;
let offset = 0;
let replayEnd = 0;
let replaying = false;
let running = false;
let disposed = false;
let generation = 0;
let timer: ReturnType<typeof setTimeout> | undefined;
let input = Promise.resolve();
let resizing = false;
let resizePending = false;
let appearanceRead = 0;
let polling = false;
let lastPoll = 0;
let lastInput = 0;
let pendingKeys = "";
let keyTimer: ReturnType<typeof setTimeout> | undefined;
let sentCols = 0;
let sentRows = 0;
const readyStatus = "review.nvim · :Review opens another review · :ReviewHelp shows available commands";
const requests = new Requests((waiting) => {
  status.textContent = waiting ? "CadencR is busy. Resuming Neovim automatically…" : running ? readyStatus : "Starting Neovim…";
});

function backend<T = unknown>(method: string, params: JsonValue): Promise<T> {
  return requests.call(() => client!.backend.request<T>(method, params));
}

function fitTerminal(): void {
  fit.fit();
  // CadencR can mount the guest before its panel has received its final size.
  // xterm's fit addon permits one row; the PTY contract requires at least two.
  terminal.resize(Math.max(2, Math.min(1000, terminal.cols)), Math.max(2, Math.min(1000, terminal.rows)));
}

async function appearance(): Promise<void> {
  if (!client) return;
  const value = await backend<Appearance>("terminal.appearance", {});
  appearanceRead = Date.now();
  if (disposed) return;
  if (terminal.options.fontFamily === value.fontFamily && terminal.options.fontSize === value.fontSize) return;
  terminal.options.fontFamily = value.fontFamily;
  terminal.options.fontSize = value.fontSize;
  await document.fonts.ready;
  await resize();
}

function report(problem: unknown): void {
  running = false;
  generation++;
  clearTimeout(timer);
  error.textContent = problem instanceof Error ? problem.message : String(problem);
  error.hidden = false;
  retry.hidden = false;
  status.textContent = "Neovim connection interrupted.";
}

function theme(snapshot: ThemeSnapshot): void {
  terminal.options.theme = {
    background: snapshot.tokens.background,
    foreground: snapshot.tokens.foreground,
    cursor: snapshot.tokens.foreground,
    selectionBackground: snapshot.tokens.accent,
  };
}

async function poll(current: number): Promise<void> {
  if (!running || disposed || current !== generation || !client || polling) return;
  polling = true;
  lastPoll = Date.now();
  let delay = 500;
  try {
    if (client.visible) {
      if (Date.now() - appearanceRead >= 5000) await appearance();
      const result = await backend<Output>("terminal.read", { offset });
      if (disposed || current !== generation) return;
      if (result.reset) terminal.reset();
      const bytes = Uint8Array.from(atob(result.data), (character) => character.charCodeAt(0));
      // Wait for xterm's parser so a burst cannot accumulate unbounded writes.
      const history = Math.min(bytes.length, Math.max(0, replayEnd - (result.offset - bytes.length)));
      if (history) {
        replaying = true;
        try {
          await new Promise<void>((done) => terminal.write(bytes.subarray(0, history), done));
        } finally {
          replaying = false;
        }
      }
      if (history < bytes.length) {
        await new Promise<void>((done) => terminal.write(bytes.subarray(history), done));
      }
      offset = result.offset;
      // 40 ms polling alone exceeds CadencR's 1,200/minute plugin allowance.
      // Poll faster only when there is output, leaving room for input and
      // other visible instances of the same plugin.
      if (bytes.length) delay = 100;
      if (result.exited) {
        running = false;
        status.textContent = result.status;
        retry.textContent = "Start Neovim";
        retry.hidden = false;
        return;
      }
    }
    if (Date.now() - lastInput < 1000) delay = 100;
    timer = setTimeout(() => void poll(current), delay);
  } catch (problem) {
    if (!disposed && current === generation) report(problem);
  } finally {
    polling = false;
  }
}

async function resize(): Promise<void> {
  if (!running || !client || !client.visible) return;
  if (resizing) {
    resizePending = true;
    return;
  }
  resizing = true;
  try {
    do {
      resizePending = false;
      fitTerminal();
      if (terminal.cols !== sentCols || terminal.rows !== sentRows) {
        const cols = terminal.cols, rows = terminal.rows;
        await backend("terminal.resize", { cols, rows });
        sentCols = cols;
        sentRows = rows;
      }
    } while (resizePending && running && !disposed);
  } catch (problem) {
    if (!disposed) report(problem);
  } finally {
    resizing = false;
  }
}

async function start(): Promise<void> {
  retry.hidden = true;
  error.hidden = true;
  status.textContent = "Starting Neovim…";
  const current = ++generation;
  clearTimeout(timer);
  try {
    if (!client) {
      client = await connect();
      theme(client.theme);
      client.onThemeChange(theme);
      client.onError(report);
      client.onVisibilityChange((visible) => {
        if (visible) void resize();
      });
      client.onConnectionChange((connected) => {
        if (!connected && !disposed) report(new Error("CadencR disconnected. Reconnect to resume Neovim."));
      });
    }
    const config = await requests.call(() => client!.config.get());
    await appearance();
    fitTerminal();
    const result = await backend<{ exited: boolean; status: string; offset: number }>("terminal.start", {
      url: client.context.pullRequest?.url ?? "",
      nvimPath: typeof config.nvim_path === "string" ? config.nvim_path : "nvim",
      cols: terminal.cols,
      rows: terminal.rows,
    });
    if (disposed || current !== generation) return;
    if (result.exited) throw new Error(result.status);
    terminal.reset();
    offset = 0;
    replayEnd = result.offset;
    sentCols = terminal.cols;
    sentRows = terminal.rows;
    running = true;
    status.textContent = readyStatus;
    await resize();
    terminal.focus();
    void poll(current);
  } catch (problem) {
    if (!disposed && current === generation) report(problem);
  }
}

function flushKeys(): void {
  keyTimer = undefined;
  const data = pendingKeys;
  pendingKeys = "";
  const bytes = new TextEncoder().encode(data);
  // Preserve key order even when the host handles requests concurrently.
  for (let first = 0; first < bytes.length; first += 32 * 1024) {
    const encoded = btoa(String.fromCharCode(...bytes.subarray(first, first + 32 * 1024)));
    input = input.then(async () => {
      if (running && client && !disposed) {
        await backend("terminal.input", { data: encoded });
        lastInput = Date.now();
        if (!polling) {
          clearTimeout(timer);
          timer = setTimeout(() => void poll(generation), Math.max(0, 100 - (Date.now() - lastPoll)));
        }
      }
    }).catch((problem: unknown) => { if (!disposed) report(problem); });
  }
}

terminal.onData((data) => {
  // Replaying old terminal queries must not send their answers into a live picker.
  if (!running || !client || replaying) return;
  pendingKeys += data;
  // Coalesce rapid key events and terminal replies without changing their order.
  keyTimer ??= setTimeout(flushKeys, 20);
});

const observer = new ResizeObserver(() => void resize());
observer.observe(container);
retry.addEventListener("click", () => void start());
window.addEventListener("pagehide", () => {
  disposed = true;
  generation++;
  clearTimeout(timer);
  clearTimeout(keyTimer);
  observer.disconnect();
  requests.close();
  client?.close();
  terminal.dispose();
  // The host owns the backend lifecycle; webview eviction keeps Neovim alive.
});
void start();
