import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { chromium } from "playwright";
import { host } from "./terminal-host.mjs";

async function until(check) {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    if (await check()) return;
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
  throw new Error("Timed out waiting for Neovim.");
}

async function opened(path) {
  try { return (await readFile(path, "utf8")).trim().split("\n").at(-1); }
  catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

async function browser(t, fixture, viewport = { width: 1200, height: 800 }) {
  const instance = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL || undefined });
  fixture.setBrowser(instance);
  const page = await instance.newPage({ viewport });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  t.after(() => assert.deepEqual(errors, []));
  await fixture.attach(page);
  await page.goto(fixture.address);
  return page;
}

test("conversation URL opens in real Neovim and a webview reload keeps the session", { timeout: 30_000 }, async (t) => {
  const url = "https://github.com/owner/repo/pull/12";
  const fixture = await host(t, url);
  const page = await browser(t, fixture);
  await until(async () => await opened(fixture.opened) === url);
  const beforeReload = fixture.transcript().split("Offline review opened").length;
  await page.reload();
  await until(() => fixture.transcript().split("Offline review opened").length > beforeReload);
  assert.equal((await readFile(fixture.opened, "utf8")).trim(), url,
    "reload keeps the existing review rather than opening another one");
  await page.setViewportSize({ width: 900, height: 600 });
  await page.locator(".xterm-helper-textarea").press("Escape");
  await page.keyboard.type(":qa!");
  await page.keyboard.press("Enter");
  await page.getByRole("button", { name: "Start Neovim", exact: true }).waitFor();
  await page.getByRole("button", { name: "Start Neovim", exact: true }).click();
  await until(async () => (await readFile(fixture.opened, "utf8")).trim().split("\n").length === 2);
  assert.equal(await opened(fixture.opened), url);
});

test("terminal inherits font preferences and refits after a live font change", { timeout: 30_000 }, async (t) => {
  const fixture = await host(t, "https://github.com/owner/repo/pull/19");
  await fixture.setFont("Menlo", 15);
  const page = await browser(t, fixture);
  await until(async () => await opened(fixture.opened) !== null);
  const rows = page.locator(".xterm-rows");
  await until(async () => await rows.evaluate((element) => getComputedStyle(element).fontSize === "15px"));
  assert.match(await rows.evaluate((element) => getComputedStyle(element).fontFamily), /^Menlo,/);
  const before = await rows.evaluate((element) => element.children.length);
  await fixture.setFont("Monaco", 18);
  await until(async () => await rows.evaluate((element) =>
    getComputedStyle(element).fontSize === "18px" && getComputedStyle(element).fontFamily.startsWith("Monaco,")));
  assert.ok(await rows.evaluate((element) => element.children.length) < before,
    "font changes must resize the terminal's row grid");
});

test("a guest mounted in a tiny panel starts and refits when the panel expands", { timeout: 30_000 }, async (t) => {
  const fixture = await host(t, "https://github.com/owner/repo/pull/20");
  const page = await browser(t, fixture, { width: 100, height: 30 });
  await until(async () => await opened(fixture.opened) !== null);
  assert.equal(await page.locator("#error").isVisible(), false);
  await page.setViewportSize({ width: 1200, height: 800 });
  await until(async () => await page.locator(".xterm-rows").evaluate((element) => element.children.length > 2));
  assert.equal(await page.locator("#error").isVisible(), false);
});

test("idle polling stays well below CadencR's shared plugin request budget", { timeout: 30_000 }, async (t) => {
  const fixture = await host(t, "https://github.com/owner/repo/pull/21");
  const page = await browser(t, fixture);
  await until(async () => await opened(fixture.opened) !== null);
  // Neovim's initial output and terminal replies legitimately use fast polling.
  // Measure idle traffic only after both output and input have settled.
  let transcript = fixture.transcript(), quietSince = Date.now();
  await until(() => {
    const output = fixture.transcript();
    if (output !== transcript) {
      transcript = output;
      quietSince = Date.now();
    }
    const lastInput = fixture.attempts().filter((attempt) => attempt.method === "terminal.input").at(-1)?.at ?? 0;
    return Date.now() - Math.max(quietSince, lastInput) >= 1100;
  });
  const initial = fixture.attempts().length;
  await page.waitForTimeout(5000);
  const attempts = fixture.attempts().slice(initial);
  assert.ok(attempts.length <= 20, `An idle guest sent ${attempts.length} requests in five seconds`);
  assert.equal(await page.locator("#error").isVisible(), false);
});

test("HTTP 429 pauses requests and resumes the same Neovim with ordered input exactly once", {
  timeout: 30_000,
}, async (t) => {
  const fixture = await host(t, "https://github.com/owner/repo/pull/22");
  const page = await browser(t, fixture);
  await until(async () => await opened(fixture.opened) !== null);
  const throttle = { code: "HOST_ERROR", message: "HTTP 429", details: { status: 429, retryAfterMs: 1000 } };
  fixture.failNext("terminal.read", throttle);
  await page.getByRole("status").filter({ hasText: "Resuming Neovim automatically" }).waitFor();
  fixture.failNext("terminal.input", throttle);
  await page.locator(".xterm-helper-textarea").focus();
  await page.keyboard.type(":FixtureMark");
  await page.keyboard.press("Enter");
  await until(async () => await opened(fixture.marked) === "marked");
  await page.getByRole("status").filter({ hasText: ":Review opens" }).waitFor();
  assert.equal(await page.locator("#error").isVisible(), false);
  assert.equal((await readFile(fixture.marked, "utf8")).trim(), "marked");
  assert.equal((await readFile(fixture.opened, "utf8")).trim().split("\n").length, 1,
    "recovery must preserve the existing review");
  const attempts = fixture.attempts();
  for (let i = 0; i < attempts.length; i++) {
    if (attempts[i].rejected) {
      // A concurrent request may already be in flight when the 429 arrives.
      const duringHold = attempts.slice(i + 1).filter((attempt) => {
        const delay = attempt.at - attempts[i].at;
        return delay > 50 && delay < 950;
      });
      assert.equal(duringHold.length, 0, "no fresh request is sent during the cooldown");
    }
  }
});

test("other failures remain visible and are not retried automatically", { timeout: 30_000 }, async (t) => {
  const fixture = await host(t, "https://github.com/owner/repo/pull/23");
  const page = await browser(t, fixture);
  await until(async () => await opened(fixture.opened) !== null);
  fixture.failNext("terminal.read", { code: "BAD_REQUEST", message: "Fixture invalid request" });
  await page.getByRole("alert").filter({ hasText: "Fixture invalid request" }).waitFor();
  const count = fixture.attempts().length;
  await page.waitForTimeout(500);
  assert.equal(fixture.attempts().length, count);
});

test("missing conversation URL asks in Telescope, validates input and opens on Enter", {
  timeout: 30_000, skip: !process.env.TELESCOPE_PATH || !process.env.PLENARY_PATH,
}, async (t) => {
  const fixture = await host(t, "");
  const page = await browser(t, fixture);
  await until(() => fixture.transcript().includes("Enter a GitLab MR"));
  assert.equal(await opened(fixture.opened), null);
  const input = page.locator(".xterm-helper-textarea");
  await input.press("Enter");
  assert.equal(await opened(fixture.opened), null);
  const url = "https://gitlab.example.com/group/project/-/merge_requests/123";
  await input.focus();
  await page.keyboard.type(url);
  await until(async () => (await opened(fixture.prompted))?.includes(url));
  if (process.env.REVIEW_UI_SCREENSHOT) {
    await page.screenshot({ path: process.env.REVIEW_UI_SCREENSHOT });
  }
  await page.reload();
  await until(() => fixture.transcript().split("Enter a GitLab MR").length >= 3);
  await page.locator(".xterm-helper-textarea").focus();
  await page.keyboard.press("Enter");
  await until(async () => await opened(fixture.opened) === url);
  assert.equal((await page.locator("#error").isVisible()), false);
});
