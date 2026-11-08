import { test } from "node:test";
import assert from "node:assert/strict";
import {
  previewActions,
  previewFieldKeys,
  previewStrings,
} from "./web-preview.mjs";
import { aiWebStrings } from "./web-strings.mjs";
import { graphSchema } from "../carry-account-service/graph-schema.mjs";
test("review field labels cover every graph field in nine complete languages", () => {
  const fieldSet = new Set(previewFieldKeys);
  for (const r of Object.values(graphSchema))
    for (const k of Object.keys(r.fields)) assert.ok(fieldSet.has(k), k);
  const keys = Object.keys(previewStrings.en).sort();
  for (const [lang, row] of Object.entries(previewStrings)) {
    assert.deepEqual(Object.keys(row).sort(), keys);
    assert.ok(
      Object.values(row).every((v) => v.trim()),
      lang,
    );
  }
});
test("review shows localized field comparison and move destinations without wire JSON or UUIDs", () => {
  const html = previewActions(
    {
      actions: [
        {
          id: crypto.randomUUID(),
          kind: "packingItem",
          action: "patch",
          affectedCount: 1,
          before: { name: "Passport", isPacked: false, quantity: 1 },
          after: { isPacked: true, quantity: 2 },
          parentBefore: null,
          parentAfter: null,
        },
        {
          id: crypto.randomUUID(),
          kind: "stop",
          action: "move",
          affectedCount: 1,
          before: { name: "<script>unsafe</script>" },
          after: {},
          parentBefore: "old-uuid",
          parentAfter: "new-uuid",
          parentBeforeDisplay: { kind: "day", name: "First day", order: 1 },
          parentAfterDisplay: { kind: "day", name: "Last day", order: 3 },
        },
      ],
    },
    "zh-Hans",
    aiWebStrings["zh-Hans"],
  );
  assert.ok(html.includes("已打包"));
  assert.ok(html.includes("数量"));
  assert.ok(html.includes("否"));
  assert.ok(html.includes("是"));
  assert.ok(html.includes("First day"));
  assert.ok(html.includes("Last day"));
  assert.ok(html.includes("&lt;script&gt;unsafe&lt;/script&gt;"));
  for (const raw of [
    "isPacked",
    "parentBefore",
    "old-uuid",
    "new-uuid",
    "<pre>",
    "<script>",
  ])
    assert.ok(!html.includes(raw), raw);
});

test('new planning trips hide placeholder dates and coordinates and empty day titles use a readable fallback', () => {
  const html = previewActions({ actions: [
    { kind: "trip", action: "create", affectedCount: 1, before: null,
      after: { name: "Synthetic planning", isDateless: true, departureDate: "2026-11-08T00:00:00Z", latitude: 0, longitude: 0 } },
    { kind: "day", action: "create", affectedCount: 1, before: null,
      after: { title: "", sortOrder: 0 } },
  ] }, "en", aiWebStrings.en);
  assert.match(html, /Planning trip/);
  assert.match(html, /<h2>Day 1<\/h2>/);
  assert.doesNotMatch(html, /Nov 8, 2026|Latitude|Longitude/);
  const dated = previewActions({ actions: [
    { kind: "trip", action: "patch", affectedCount: 1,
      before: { departureDate: "2026-11-08T00:00:00Z" },
      after: { departureDate: "2026-11-09T00:00:00Z" } },
  ] }, "en", aiWebStrings.en);
  assert.match(dated, /Nov 8, 2026/);
  assert.match(dated, /Nov 9, 2026/);
});
