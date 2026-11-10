import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { setImmediate } from "node:timers/promises";
import test from "node:test";
import ts from "typescript";

const source = await readFile(new URL("../src/requests.ts", import.meta.url), "utf8");
const { outputText } = ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
});
const { Requests } = await import(`data:text/javascript;base64,${Buffer.from(outputText).toString("base64")}`);

test("a 429 without Retry-After waits a full quota window and holds other requests", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 });
  const holds = [];
  const requests = new Requests((held) => holds.push(held));
  let attempts = 0, otherAttempts = 0;
  const recovered = requests.call(async () => {
    if (++attempts === 1) throw Object.assign(new Error("HTTP 429"), { details: { status: 429 } });
    return "recovered";
  });
  await setImmediate();
  const other = requests.call(async () => { otherAttempts++; return "other"; });
  t.mock.timers.tick(59_999);
  await setImmediate();
  assert.equal(attempts, 1);
  assert.equal(otherAttempts, 0);
  t.mock.timers.tick(1);
  assert.deepEqual(await Promise.all([recovered, other]), ["recovered", "other"]);
  assert.equal(attempts, 2);
  assert.equal(otherAttempts, 1);
  assert.deepEqual(holds, [true, false]);
});

test("a transport timeout is not replayed because input may already have reached Neovim", async () => {
  let attempts = 0;
  const failure = Object.assign(new Error("Request timed out"), { code: "TIMEOUT" });
  const requests = new Requests(() => {});
  await assert.rejects(requests.call(async () => { attempts++; throw failure; }), (error) => error === failure);
  assert.equal(attempts, 1);
});

test("closing the guest cancels a pending cooldown without replaying its request", async (t) => {
  t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: 0 });
  let attempts = 0;
  const requests = new Requests(() => {});
  const pending = requests.call(async () => {
    attempts++;
    throw Object.assign(new Error("HTTP 429"), { code: "RATE_LIMITED" });
  });
  await setImmediate();
  requests.close();
  const closed = assert.rejects(pending, /Review tab closed/);
  t.mock.timers.tick(250);
  await closed;
  assert.equal(attempts, 1);
});
