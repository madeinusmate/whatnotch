import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const root = new URL("..", import.meta.url);
const source = (path) => readFile(new URL(path, root), "utf8");

test("compact harness makes each visible ear a paint boundary", async () => {
  const bridge = await source("App/WidgetRuntime.swift");

  // A generated compact page may use `position: fixed` for a full-width bar.
  // These three declarations make that root relative to, and clipped by, its
  // leading/trailing ear instead of allowing it to paint over the camera gap.
  assert.match(bridge, /grid-template-columns:var\(--compact-leading,0px\) var\(--hardware-notch,0px\) var\(--compact-trailing,0px\)/);
  assert.match(bridge, /\[data-notch-ear\]\{[^\"]*contain:layout paint/);
  assert.match(bridge, /\[data-notch-ear\]\{[^\"]*isolation:isolate/);
  assert.match(bridge, /\[data-notch-ear\]\{[^\"]*transform:translateZ\(0\)/);
});

test("agent compact-widget instructions treat the camera as a hard no-content zone", async () => {
  const instructions = await source("Workspace/AGENTS.md");

  assert.match(instructions, /whatnotch-spec-version: 4/);
  assert.match(instructions, /hard no-content zone/);
  assert.match(instructions, /direct `body` child/);
  assert.match(instructions, /position: fixed/);
  assert.match(instructions, /status-only/);
  assert.match(instructions, /compact\.leadingWidth/);
  assert.match(instructions, /exclude the camera housing/);
});

test("native panel caps and anchors compact expansion per side", async () => {
  const panel = await source("App/NotchPanel.swift");

  assert.match(panel, /maxCompactSideWidth: CGFloat = 160/);
  assert.match(panel, /maxCompactTotalWidth: CGFloat = 320/);
  assert.match(panel, /x: collapsed\.minX - leading/);
  assert.match(panel, /width: collapsed\.width \+ leading \+ trailing/);
  assert.match(panel, /let width = compactLayout == nil \? base\.width \* hoverScale : base\.width/);
});

test("compact width contracts shrink to the rendered status footprint", async () => {
  const bridge = await source("App/WidgetRuntime.swift");
  const shelf = await source("Shelf/shelf.js");
  const model = await source("App/AppModel.swift");

  assert.match(bridge, /source: "notch-compact-size"/);
  assert.match(shelf, /data\?\.source === "notch-compact-size"/);
  assert.match(shelf, /type: "compactSize"/);
  assert.match(model, /case "compactSize"/);
  assert.match(model, /compactMeasured/);
});
