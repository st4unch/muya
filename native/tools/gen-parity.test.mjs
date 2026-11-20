import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { render, parse, check, mergePreserved, extractEvents } from "./gen-parity.mjs";

const row = (over = {}) => ({
  kind: "command", id: "pty_spawn", source: "src-tauri/src/pty.rs:1", phase: "Faz 1",
  status: "todo", evidence: "", ...over,
});

test("check fails on a done row without evidence", () => {
  const md = render([row({ status: "done" }), row({ id: "other" })]);
  const bad = check(md);
  assert.equal(bad.length, 1);
  assert.equal(bad[0].id, "pty_spawn");
});

test("check fails on a verified row without evidence", () => {
  assert.equal(check(render([row({ status: "verified" })])).length, 1);
});

test("check passes when a done row has evidence", () => {
  const md = render([row({ status: "done", evidence: "tests/pty.rs::spawn_ok" })]);
  assert.equal(check(md).length, 0);
});

test("regeneration preserves status and evidence of surviving rows", () => {
  const old = parse(render([row({ status: "done", evidence: "shots/pty.png" })]));
  const fresh = [row(), row({ id: "brand_new" })];
  const merged = mergePreserved(fresh, old);
  assert.equal(merged[0].status, "done");
  assert.equal(merged[0].evidence, "shots/pty.png");
  assert.equal(merged[1].status, "todo");
});

test("rows whose id disappeared are dropped", () => {
  const old = parse(render([row({ id: "gone", status: "done", evidence: "x" })]));
  assert.equal(mergePreserved([row()], old).length, 1);
});

test("ids containing a pipe survive a render/parse round trip", () => {
  const r = row({ id: "a|b" });
  assert.equal(parse(render([r]))[0].id, "a|b");
});

test("events are found in src-tauri and in native/crates/*/src", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "parity-"));
  fs.mkdirSync(path.join(root, "src-tauri/src"), { recursive: true });
  fs.mkdirSync(path.join(root, "native/crates/muya-core/src"), { recursive: true });
  fs.writeFileSync(path.join(root, "src-tauri/src/a.rs"), 'fn f(){ app.emit("menu:new-file", 1); }');
  fs.writeFileSync(path.join(root, "native/crates/muya-core/src/b.rs"), 'fn g(){ let _ = app.emit(\n "bridge://task-end", 2); }');
  const ev = extractEvents(root);
  assert.deepEqual(ev.map((e) => e.id), ["bridge://task-end", "menu:new-file"]);
  assert.match(ev[0].source, /^native\/crates\/muya-core\/src\/b\.rs:\d+$/);
});

test("regenerating keeps verified status and evidence of event rows", () => {
  const old = parse(render([row({ kind: "event", id: "bridge://task-end", status: "verified", evidence: "t::x" })]));
  const merged = mergePreserved([row({ kind: "event", id: "bridge://task-end" })], old);
  assert.equal(merged[0].status, "verified");
  assert.equal(merged[0].evidence, "t::x");
});
