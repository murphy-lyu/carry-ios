import { graphSchema } from "../carry-account-service/graph-schema.mjs";
import packingRules from "./packing-rules.json" with { type: "json" };
const id = { type: "string", format: "uuid" },
  page = {
    offset: { type: "integer", minimum: 0 },
    limit: { type: "integer", minimum: 1, maximum: 500 },
  };
function wireRule(rule) {
  const output = { type: rule.integer ? "integer" : rule.type };
  if (rule.type === "string" && rule.max !== undefined)
    output.maxLength = rule.max;
  if (rule.type === "object") {
    output.maxProperties = rule.max;
    output.propertyNames = { pattern: rule.keyPattern };
    output.additionalProperties = wireRule(rule.item);
  }
  if (rule.type === "array") {
    output.maxItems = rule.max;
    output.items = wireRule(rule.item);
  }
  if (rule.type === "number") {
    output.minimum = rule.min;
    output.maximum = rule.max;
  }
  if (rule.values) output.enum = rule.values;
  if (rule.pattern) output.pattern = rule.pattern;
  if (["uuid", "date-time"].includes(rule.format)) output.format = rule.format;
  if (rule.format === "timezone")
    output.description =
      "IANA time zone; empty only when genuinely unknown. Do not infer from device locale.";
  return rule.optional ? { anyOf: [output, { type: "null" }] } : output;
}
const allFields = Object.fromEntries(
  Object.values(graphSchema)
    .flatMap((kind) => Object.entries(kind.fields))
    .map(([key, rule]) => [key, wireRule(rule)]),
);
const operations = {
  type: "array",
  minItems: 1,
  maxItems: 20000,
  items: {
    type: "object",
    additionalProperties: false,
    properties: {
      action: {
        type: "string",
        enum: [
          "create_trip",
          "duplicate_trip",
          "create",
          "patch",
          "move",
          "delete",
          "restore",
          "reorder",
        ],
      },
      kind: { type: "string", enum: Object.keys(graphSchema) },
      id,
      parentID: {
        type: "string",
        description:
          "Existing parent UUID or a prior creation ref, e.g. @tokyo or @tokyo/day/0.",
      },
      ref: { type: "string", pattern: "^[A-Za-z][A-Za-z0-9_-]{0,63}$" },
      fields: {
        type: "object",
        properties: allFields,
        additionalProperties: false,
      },
      baseVersion: { type: "integer", minimum: 1 },
      baseSubtreeVersion: { type: "integer", minimum: 1 },
      fieldVersions: {
        type: "object",
        additionalProperties: { type: "integer", minimum: 1 },
      },
      deletionBatch: id,
      ids: { type: "array", items: id, maxItems: 10000 },
      data: {
        type: "object",
        properties: {
          childKind: { type: "string", enum: Object.keys(graphSchema) },
        },
        additionalProperties: false,
      },
    },
    required: ["action"],
  },
};
const tool = (
  name,
  description,
  properties = {},
  required = [],
  readOnly = true,
) => ({
  name,
  description,
  inputSchema: {
    type: "object",
    properties,
    required,
    additionalProperties: false,
  },
  annotations: {
    readOnlyHint: readOnly,
    idempotentHint: true,
    destructiveHint: !readOnly,
    openWorldHint: false,
  },
});
export const TOOLS = [
  tool(
    "list_capabilities",
    "Return account-native supported operations and device boundaries; no phone executor or pairing code.",
  ),
  tool(
    "list_trips",
    "Read only trips covered by this connection. Returns server versions, not device sync claims.",
    page,
  ),
  tool(
    "get_trip",
    "Read a scoped account trip graph and field/subtree versions. Booking details, attachments and preferences need separate scopes.",
    {
      tripID: id,
      ...page,
      expectedSubtreeVersion: { type: "integer", minimum: 1 },
    },
    ["tripID"],
  ),
  tool(
    "get_item_library",
    "Read the separately authorized custom item library.",
    page,
  ),
  tool(
    "apply_changes",
    "Apply ordinary explicit domain operations in one account transaction. Reuse requestID on retry. Destructive, date or large changes require a first-party approved preview. Use create_trip; create/patch/move/delete/restore/reorder cover all graph kinds. A field change requires baseVersion and may include observed fieldVersions.",
    { requestID: id, operations },
    ["requestID", "operations"],
    false,
  ),
  tool(
    "preview_plan",
    "Persist an immutable complete plan preview, bound to this grant, request ID, exact operations and object versions. No travel changes occur. The user approves via the returned first-party page; AI confirmed=true is never accepted.",
    { requestID: id, operations },
    ["requestID", "operations"],
    false,
  ),
  tool(
    "commit_plan",
    "Commit a first-party approved plan atomically. The requestID must equal its preview requestID; retry unchanged after network loss. Returns saved_to_account, never phone-applied.",
    { requestID: id, previewID: id },
    ["requestID", "previewID"],
    false,
  ),
  tool(
    "get_operation",
    "Read only an operation created by this connection. saved_to_account means durable server persistence; devices may be offline.",
    { requestID: id },
    ["requestID"],
  ),
  tool(
    "undo_operation",
    "Prepare a version-bound inverse of one operation made by this connection. Returns a user-approved preview; later edits cause conflict instead of blind rollback.",
    { requestID: id, operationID: id },
    ["requestID", "operationID"],
    false,
  ),
  tool(
    "open_trip",
    "Return a stable Carry deep link. Does not contact a phone or claim a screen opened.",
    { tripID: id, face: { type: "string", enum: ["packing", "itinerary"] } },
    ["tripID"],
  ),
  tool(
    "read_attachment",
    "Read a bounded chunk from an authorized attachment, only with attachments:read. No signed URL is emitted and the grant is rechecked per chunk.",
    {
      tripID: id,
      assetID: id,
      offset: { type: "integer", minimum: 0 },
      limit: { type: "integer", minimum: 1, maximum: 65536 },
    },
    ["tripID", "assetID", "offset", "limit"],
  ),
  ...[
    [
      "search_airports",
      "Search Carry's bundled airport catalog by IATA/ICAO, city, localized name or alias. Returns real coordinates/timezones; no external request.",
      {
        query: { type: "string", maxLength: 200 },
        language: {
          type: "string",
          enum: [
            "en",
            "zh-Hans",
            "zh-Hant",
            "de",
            "es",
            "fr",
            "ja",
            "ko",
            "pt-BR",
          ],
        },
        limit: { type: "integer", minimum: 1, maximum: 100 },
      },
      ["query"],
    ],
    [
      "search_places",
      "Search a structured destination. Supply query plus target countryCode (or a scoped trip's country). Suggestions must be retrieved by placeID and returned session before storing coordinates. CN/HK/MO use Amap only; overseas uses the Carry places proxy. Never invent provider results. Domestic results are GCJ-02; overseas results are WGS-84.",
      {
        query: { type: "string", minLength: 1, maxLength: 200 },
        countryCode: { type: "string", pattern: "^[A-Z]{2}$" },
        city: { type: "string", maxLength: 100 },
        placeID: { type: "string", maxLength: 8000 },
        session: id,
        language: {
          type: "string",
          enum: [
            "en",
            "zh-Hans",
            "zh-Hant",
            "de",
            "es",
            "fr",
            "ja",
            "ko",
            "pt-BR",
          ],
        },
        limit: { type: "integer", minimum: 1, maximum: 8 },
        proximity: {
          type: "object",
          additionalProperties: false,
          required: ["latitude", "longitude"],
          properties: {
            latitude: { type: "number", minimum: -90, maximum: 90 },
            longitude: { type: "number", minimum: -180, maximum: 180 },
          },
        },
      },
      [],
    ],
    [
      "lookup_flight",
      "Look up a real flight via Carry's existing flight proxy. number is IATA/ICAO airline prefix plus digits (e.g. CA8333), date is the local flight date YYYY-MM-DD. Configuration/provider errors remain errors, never fabricated schedules.",
      {
        number: { type: "string", maxLength: 64 },
        date: { type: "string", format: "date" },
      },
      ["number", "date"],
    ],
    [
      "preview_route",
      "Preview native fixed-endpoint route optimization for a scoped dayID or explicitly supplied stops. Distance is great-circle estimate, not road distance or travel duration. No reorder is applied; use an approved account plan to save it.",
      {
        dayID: id,
        stops: {
          type: "array",
          maxItems: 100,
          items: {
            type: "object",
            additionalProperties: false,
            required: ["id", "latitude", "longitude"],
            properties: {
              id,
              latitude: { type: "number", minimum: -90, maximum: 90 },
              longitude: { type: "number", minimum: -180, maximum: 180 },
            },
          },
        },
      },
      [],
    ],
    [
      "get_packing_recommendations",
      "Get native base/scene packing quantities, supplementary suggestions and destination climate scenes without changing a trip. storefront must be actual StoreKit alpha-3 if known (not device locale). departureDate is explicit local YYYY-MM-DD for seasonal inference. Personal health scenes/HealthKit inference are excluded.",
      {
        scenes: {
          type: "array",
          maxItems: 16,
          items: { type: "string", enum: Object.keys(packingRules.scenes) },
        },
        tripDays: { type: "integer", minimum: 0, maximum: 3650 },
        isInternational: { type: "boolean" },
        destinationCodes: {
          type: "array",
          maxItems: 100,
          items: { type: "string", pattern: "^[A-Z]{2}$" },
        },
        storefront: { type: "string", pattern: "^[A-Z]{3}$" },
        language: {
          type: "string",
          enum: [
            "en",
            "zh-Hans",
            "zh-Hant",
            "de",
            "es",
            "fr",
            "ja",
            "ko",
            "pt-BR",
          ],
        },
        departureDate: { type: "string", format: "date" },
        rankingMode: { type: "string", enum: ["manualFirst", "sceneFirst"] },
        supplementaryLimit: { type: "integer", minimum: 0, maximum: 100 },
      },
      [],
    ],
  ].map(([name, description, properties, required]) => {
    const data = {
      type: "object",
      properties,
      required,
      additionalProperties: false,
    };
    if (name === "search_places")
      data.oneOf = [
        { required: ["query"], not: { required: ["placeID"] } },
        { required: ["placeID"], not: { required: ["query"] } },
      ];
    if (name === "preview_route")
      data.oneOf = [
        { required: ["dayID"], not: { required: ["stops"] } },
        { required: ["stops"], not: { required: ["dayID"] } },
      ];
    const result = tool(name, description, { tripID: id, data }, ["data"]);
    result.annotations.openWorldHint = [
      "search_places",
      "lookup_flight",
    ].includes(name);
    return result;
  }),
  ...["export_backup", "share_trip"].map((name) =>
    tool(
      name,
      "Generate an authorized private result using a first-party approved preview. Creating a result does not send it to a third party; no permanent public link.",
      { requestID: id, tripID: id },
      ["requestID", "tripID"],
      false,
    ),
  ),
];
