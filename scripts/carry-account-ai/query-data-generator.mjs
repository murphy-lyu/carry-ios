// Audited extraction of the existing native scene rules. No model/user data.
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
const root = new URL("../../", import.meta.url);
const strings = (text) =>
  [...text.matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((m) =>
    JSON.parse('"' + m[1] + '"'),
  );
export async function nativePackingRules() {
  const [
    source,
    catalogSource,
    localizationSource,
    surpriseSource,
    climateSource,
  ] = await Promise.all(
    [
      "Carry/Models/SceneItemMap.swift",
      "Carry/Models/ItemCatalog.swift",
      "Carry/Localizable.xcstrings",
      "Carry/Models/SurpriseItemMap.swift",
      "Carry/Models/ClimateInference.swift",
    ].map((p) => readFile(new URL(p, root), "utf8")),
  );
  const aliasesMatch = catalogSource.match(
    /private let itemNameAliases:[^=]+?=\s*\[([^\]]*)\]/s,
  );
  if (!aliasesMatch) throw Error("native_alias_manifest_changed");
  const aliases = Object.fromEntries(
    [...aliasesMatch[1].matchAll(/"([^"]+)"\s*:\s*"([^"]+)"/g)].map((m) => [
      m[1],
      m[2],
    ]),
  );
  const categories = {};
  for (const match of catalogSource.matchAll(
    /ItemPickerCategory\(name: "([^"]+)", items: \[([\s\S]*?)\]\)/g,
  ))
    for (const name of strings(match[2]))
      categories[aliases[name] ?? name] = match[1];
  const parse = (body) =>
    [
      ...body.matchAll(
        /makeSceneItem\("((?:[^"\\]|\\.)*)", isAlert: (true|false)(, internationalOnly: true)?\)/g,
      ),
    ].map((m) => {
      const raw = JSON.parse('"' + m[1] + '"'),
        name = aliases[raw] ?? raw;
      return {
        name,
        category: categories[name] ?? "Essentials",
        isAlert: m[2] === "true",
        internationalOnly: !!m[3],
      };
    });
  const base = source.match(
    /let baseItems: \[SceneItem\] = \[([\s\S]*?)\n\]/,
  )?.[1];
  const sceneBody = source.match(
    /let sceneItemMap: \[String: \[SceneItem\]\] = \[([\s\S]*?)\n\]/,
  )?.[1];
  if (!base || !sceneBody) throw Error("native_scene_manifest_changed");
  const scenes = Object.fromEntries(
    [...sceneBody.matchAll(/"([a-z_]+)": \[([\s\S]*?)\n    \],/g)]
      .filter((m) => !m[1].startsWith("personal_"))
      .map((m) => [m[1], parse(m[2])]),
  );
  if (Object.keys(scenes).length !== 14 || parse(base).length < 5)
    throw Error("native_scene_manifest_changed");
  const quantityBody = source.match(/func defaultQuantity\([\s\S]*?\n\}/)?.[0];
  if (!quantityBody?.includes("return min(days, 99)"))
    throw Error("native_quantity_rules_changed");
  const dailyNames = [...quantityBody.matchAll(/lower == "([^"]+)"/g)].map(
    (m) => m[1],
  );
  const categoryOrder = [
    "Travel Documents",
    "Clothing",
    "Electronics",
    "Travel Accessories",
    "Personal Care",
    "Essentials",
    "Health",
    "Health & Wellness",
  ];
  const extra = ["HK & Macao permit", "Taiwan permit", "ID card"].map(
    (name) => ({
      name,
      category: categories[name] ?? "Essentials",
      isAlert: true,
      internationalOnly: false,
    }),
  );
  const categoryNames = Object.fromEntries(
    [...catalogSource.matchAll(/case ([a-zA-Z]+) = "([^"]+)"/g)].map((m) => [
      m[1],
      m[2],
    ]),
  );
  const surpriseBody = surpriseSource.match(
    /let surpriseItemMap:[^=]+?= \[([\s\S]*?)\n\]/,
  )?.[1];
  if (!surpriseBody) throw Error("native_surprise_manifest_changed");
  const surpriseScenes = Object.fromEntries(
    [...surpriseBody.matchAll(/"([a-z_]+)": \[([\s\S]*?)\n    \],/g)]
      .filter((m) => !m[1].startsWith("personal_"))
      .map((m) => [
        m[1],
        [
          ...m[2].matchAll(
            /SurpriseItem\(name: "((?:[^"\\]|\\.)*)",\s+note: "((?:[^"\\]|\\.)*)",\s+category: \.([a-zA-Z]+)\)/g,
          ),
        ].map((x) => ({
          name: JSON.parse('"' + x[1] + '"'),
          note: JSON.parse('"' + x[2] + '"'),
          category: categoryNames[x[3]] ?? "Essentials",
        })),
      ]),
  );
  const scoreMap = (name) =>
    Object.fromEntries(
      [
        ...(
          surpriseSource.match(
            new RegExp(
              "private let " +
                name +
                ": \\[String: Double\\] = \\[([\\s\\S]*?)\\n\\]",
            ),
          )?.[1] ?? ""
        ).matchAll(/"([^"]+)": ([0-9.]+)/g),
      ].map((m) => [m[1], Number(m[2])]),
    );
  const overlapBody =
    surpriseSource.match(
      /private let surpriseFunctionalOverlapKeywords:[^=]+?= \[([\s\S]*?)\n\]/,
    )?.[1] ?? "";
  const overlap = Object.fromEntries(
    [...overlapBody.matchAll(/"([^"]+)": \[([^\]]+)\]/g)].map((m) => [
      m[1],
      strings(m[2]),
    ]),
  );
  const surpriseCategoryOrder = (
    surpriseSource.match(
      /private let surpriseCategoryOrder:[^=]+?= \[([^\]]+)\]/,
    )?.[1] ?? ""
  )
    .split(",")
    .map((s) => categoryNames[s.trim().slice(1)]);
  const surprise = {
    scenes: surpriseScenes,
    universal: scoreMap("surpriseUniversalScore"),
    delight: scoreMap("surpriseDelightScore"),
    scene: scoreMap("surpriseSceneStrength"),
    niche: scoreMap("surpriseNichePenalty"),
    overlap,
    categoryOrder: surpriseCategoryOrder,
  };
  if (
    Object.keys(surprise.universal).length < 5 ||
    Object.keys(surpriseScenes).length < 10
  )
    throw Error("native_surprise_scores_changed");
  const climate = Object.fromEntries(
    [
      ...climateSource.matchAll(
        /private static let ([a-zA-Z]+): Set<String> = \[([\s\S]*?)\n    \]/g,
      ),
    ].map((m) => [m[1], strings(m[2])]),
  );
  const catalog = JSON.parse(localizationSource).strings,
    labels = {};
  for (const name of new Set(
    [
      ...parse(base),
      ...Object.values(scenes).flat(),
      ...extra,
      ...Object.values(surpriseScenes).flat(),
    ].flatMap((x) => (x.note ? [x.name, x.note] : [x.name])),
  )) {
    labels[name] = { en: name };
    for (const [locale, value] of Object.entries(
      catalog[name]?.localizations ?? {},
    )) {
      const text = value.stringUnit?.value;
      if (text) labels[name][locale] = text;
    }
  }
  return {
    version: 1,
    sourceSHA256: createHash("sha256")
      .update(source)
      .update(catalogSource)
      .update(surpriseSource)
      .update(climateSource)
      .digest("hex"),
    surprise,
    climate,
    base: parse(base),
    scenes,
    dailyNames,
    categoryOrder,
    extra,
    labels,
  };
}
if (process.argv[1] === fileURLToPath(import.meta.url))
  await writeFile(
    new URL("packing-rules.json", import.meta.url),
    JSON.stringify(await nativePackingRules(), null, 2) + "\n",
  );
