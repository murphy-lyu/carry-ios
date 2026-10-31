import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import {
  createAccountQueries,
  searchAirports,
  packingRecommendations,
  previewRoute,
} from "./queries.mjs";
import { nativePackingRules } from "./query-data-generator.mjs";
const id = () => crypto.randomUUID(),
  body = (x) => new Response(JSON.stringify(x));
const rejects = (work, code) => assert.rejects(work, (e) => e.code === code),
  throws = (work, code) => assert.throws(work, (e) => e.code === code);
const fixture = { countryCode: "JP", query: "Tokyo", session: id() };
const configured = (fetcher) =>
  createAccountQueries({
    fetcher,
    configuration: {
      placesToken: "synthetic-places",
      flightToken: "synthetic-flight",
      amapKey: "synthetic-amap",
    },
  });
test("native packing rule data is reproducible including categories, quantities and translations", async () => {
  const saved = JSON.parse(
    await readFile(new URL("packing-rules.json", import.meta.url), "utf8"),
  );
  assert.deepEqual(saved, await nativePackingRules());
  assert.equal(Object.keys(saved.scenes).length, 14);
  assert.ok(!Object.keys(saved.scenes).some((k) => k.startsWith("personal_")));
});
test("airport ranking uses actual multilingual native catalog and canonical geographic timezone", async () => {
  const nrt = (
    await searchAirports({
      input: { query: "NRT", language: "zh-Hans", limit: 3 },
    })
  ).airports[0];
  assert.equal(nrt.iata, "NRT");
  assert.equal(nrt.timeZoneId, "Asia/Tokyo");
  assert.equal(nrt.coordinateSystem, "WGS-84");
  assert.ok(
    (
      await searchAirports({ input: { query: "东京", limit: 5 } })
    ).airports.some((a) => ["NRT", "HND"].includes(a.iata)),
  );
  assert.equal(
    (await searchAirports({ input: { query: "URC" } })).airports[0].timeZoneId,
    "Asia/Shanghai",
  );
  assert.equal(
    (await searchAirports({ input: { query: "AAP" } })).airports[0].timeZoneId,
    "Asia/Makassar",
  );
  assert.deepEqual(
    (await searchAirports({ input: { query: " " } })).airports,
    [],
  );
  await rejects(
    searchAirports({ input: { query: "NRT", limit: 101 } }),
    "invalid_request",
  );
});
test("recommendations use native quantities and localization, deduplicate and exclude personal health inference", () => {
  const result = packingRecommendations({
      input: {
        scenes: ["long_haul_flight", "business", "winter"],
        tripDays: 7,
        isInternational: true,
        language: "zh-Hans",
      },
    }),
    items = result.sections.flatMap((s) => s.items);
  assert.equal(items.filter((x) => x.name === "Passport").length, 1);
  assert.equal(items.find((x) => x.name === "Socks").quantity, 7);
  assert.notEqual(items.find((x) => x.name === "Socks").displayName, "Socks");
  assert.equal(result.changesApplied, false);
  assert.equal(result.healthDataUsed, false);
  assert.equal(
    packingRecommendations({ input: { tripDays: 0 } })
      .sections.flatMap((s) => s.items)
      .find((x) => x.name === "Underwear").quantity,
    1,
  );
  throws(
    () => packingRecommendations({ input: { scenes: ["personal_period"] } }),
    "health_data_not_supported",
  );
  throws(
    () => packingRecommendations({ input: { scenes: ["invented"] } }),
    "invalid_scenes",
  );
});
test("document recommendation follows explicitly supplied storefront, never locale", () => {
  const names = (input) =>
    packingRecommendations({ input })
      .sections.flatMap((s) => s.items)
      .map((x) => x.name);
  assert.ok(
    names({ storefront: "CHN", destinationCodes: ["CN"] }).includes("ID card"),
  );
  assert.ok(
    !names({ storefront: "CHN", destinationCodes: ["CN"] }).includes(
      "Passport",
    ),
  );
  const hk = names({ storefront: "CHN", destinationCodes: ["HK", "MO", "TW"] });
  for (const name of ["HK & Macao permit", "Taiwan permit"])
    assert.ok(hk.includes(name));
  assert.ok(!hk.includes("Passport"));
  assert.ok(
    names({ storefront: "USA", destinationCodes: ["HK"] }).includes("Passport"),
  );
  assert.ok(names({ destinationCodes: ["CN"] }).includes("Passport"));
});
test("anchored route preview preserves IDs, improves distance and never invents roads or travel time", () => {
  const stops = [
      [0, 0],
      [0, 8],
      [0, 2],
      [0, 6],
      [0, 10],
    ].map(([latitude, longitude]) => ({ id: id(), latitude, longitude })),
    result = previewRoute({ input: { stops } });
  assert.equal(result.orderedStopIDs[0], stops[0].id);
  assert.equal(result.orderedStopIDs.at(-1), stops.at(-1).id);
  assert.deepEqual(
    new Set(result.orderedStopIDs),
    new Set(stops.map((s) => s.id)),
  );
  assert.ok(result.optimizedDistanceMeters < result.originalDistanceMeters);
  assert.ok(result.isImprovement);
  assert.equal(result.roadDistanceMeters, null);
  assert.equal(result.durationSeconds, null);
  assert.equal(result.status, "preview_only");
  for (let n = 0; n <= 2; n++)
    assert.equal(
      previewRoute({ input: { stops: stops.slice(0, n) } }).orderedStopIDs
        .length,
      n,
    );
  throws(
    () => previewRoute({ input: { stops: [stops[0], stops[0]] } }),
    "invalid_identifier",
  );
  throws(
    () =>
      previewRoute({
        input: { stops: [{ id: id(), latitude: Infinity, longitude: 0 }] },
      }),
    "invalid_coordinates",
  );
  throws(
    () =>
      previewRoute({
        input: {
          stops: Array.from({ length: 101 }, () => ({
            id: id(),
            latitude: 0,
            longitude: 0,
          })),
        },
      }),
    "route_too_large",
  );
});
test("route day only reads the supplied authorized graph and stable native ordering", () => {
  const day = id(),
    other = id(),
    entities = [
      { id: day, kind: "day", fields: {} },
      ...Array.from({ length: 3 }, (_, n) => ({
        id: id(),
        kind: "stop",
        parentID: day,
        fields: { sortOrder: n, latitude: 35, longitude: 139 + n },
      })),
      {
        id: id(),
        kind: "stop",
        parentID: other,
        fields: { latitude: 0, longitude: 0 },
      },
    ];
  assert.equal(
    previewRoute({ input: { dayID: day.toUpperCase() }, entities })
      .orderedStopIDs.length,
    3,
  );
  throws(() => previewRoute({ input: { dayID: id() }, entities }), "not_found");
});
test("flight forwards only validated number and date, sanitized provider values and fixed secret header", async () => {
  let request;
  const query = configured(async (url, opts) => {
    request = { url: new URL(url), opts };
    return body({
      flights: [
        {
          number: "MU5101",
          status: "Expected",
          airline: { name: "China Eastern" },
          departure: {
            airport: {
              iata: "SHA",
              countryCode: "CN",
              location: { lat: 31.2, lon: 121.3 },
            },
            scheduledTime: { local: "2026-11-01T09:00+08:00" },
          },
          secret: "provider-secret",
        },
      ],
    });
  });
  const result = await query.lookup_flight({
    input: { number: "mu 5101", date: "2026-11-01" },
    entities: [{ fields: { confirmationCode: "private" } }],
  });
  assert.equal(request.url.hostname, "flight.nevestudio.app");
  assert.equal(request.url.searchParams.get("number"), "MU5101");
  assert.equal(request.opts.headers["X-App-Token"], "synthetic-flight");
  assert.equal(request.opts.redirect, "error");
  assert.ok(!JSON.stringify(request).includes("private"));
  assert.equal(result.flights[0].departure.timeZoneId, "Asia/Shanghai");
  assert.ok(!JSON.stringify(result).includes("provider-secret"));
  await rejects(
    query.lookup_flight({ input: { number: "MU5101", date: "2026-02-30" } }),
    "invalid_date",
  );
  await rejects(
    query.lookup_flight({
      input: { number: "https://evil.invalid", date: "2026-11-01" },
    }),
    "invalid_flight_number",
  );
});
test("domestic search never uses overseas proxy and trip destination cannot be relabelled", async () => {
  const calls = [],
    query = configured(async (url) => {
      calls.push(new URL(url));
      return body({
        status: "1",
        pois: [
          {
            id: "synthetic",
            name: "北京大学",
            address: "海淀区",
            location: "116.3,39.9",
          },
        ],
      });
    });
  const result = await query.search_places({
    input: { countryCode: "CN", query: "北京大学", city: "北京" },
  });
  assert.equal(calls[0].hostname, "restapi.amap.com");
  assert.equal(result.places[0].coordinateSystem, "GCJ-02");
  assert.equal(result.places[0].timeZoneId, "Asia/Shanghai");
  const trip = id();
  await rejects(
    query.search_places({
      input: fixture,
      tripID: trip,
      entities: [{ id: trip, kind: "trip", fields: { countryCode: "CN" } }],
    }),
    "destination_country_mismatch",
  );
  await rejects(
    query.search_places({
      input: { ...fixture, proximity: { latitude: 39.9, longitude: 116.3 } },
    }),
    "destination_coordinates_mismatch",
  );
  assert.equal(calls.length, 1);
});
test("overseas suggest and retrieve stay fixed-origin and reject domestic results hidden behind fake country", async () => {
  const calls = [],
    query = configured(async (url) => {
      url = new URL(url);
      calls.push(url);
      return url.pathname === "/suggest"
        ? body({
            suggestions: [
              { id: "mb:tokyo", name: "Tokyo", secondary: "Japan" },
            ],
          })
        : body({
            place: {
              name: "Tokyo",
              country: "JP",
              latitude: 35.68,
              longitude: 139.76,
              timeZoneId: "Forged/Zone",
            },
          });
    });
  const suggest = await query.search_places({ input: fixture });
  assert.equal(suggest.session, fixture.session);
  assert.equal(suggest.requiresPlaceRetrieval, true);
  const result = await query.search_places({
    input: {
      countryCode: "JP",
      placeID: suggest.suggestions[0].id,
      session: fixture.session,
    },
  });
  assert.equal(result.places[0].timeZoneId, "Asia/Tokyo");
  assert.equal(calls[0].hostname, "places.nevestudio.app");
  await rejects(
    configured(async () =>
      body({
        place: {
          name: "Fake",
          country: "JP",
          latitude: 39.9,
          longitude: 116.3,
        },
      }),
    ).search_places({ input: { countryCode: "JP", placeID: "ga:forged" } }),
    "place_outside_requested_country",
  );
});
test("upstream limits, outages, malformed JSON and throttling cannot masquerade as empty results", async () => {
  const input = { number: "MU5101", date: "2026-11-01" };
  await rejects(
    configured(async () => new Response("x", { status: 429 })).lookup_flight({
      input,
    }),
    "query_rate_limited",
  );
  await rejects(
    configured(async () => body({ flights: "wrong" })).lookup_flight({ input }),
    "invalid_query_response",
  );
  for (const malformed of [
    null,
    [],
    1,
    { flights: [null] },
    { flights: [[]] },
  ]) {
    await rejects(
      configured(async () => body(malformed)).lookup_flight({ input }),
      "invalid_query_response",
    );
  }
  await rejects(
    configured(async () => new Response("{")).lookup_flight({ input }),
    "invalid_query_response",
  );
  await rejects(
    configured(
      async () =>
        new Response("x", { headers: { "content-length": "2000000" } }),
    ).lookup_flight({ input }),
    "invalid_query_response",
  );
  await rejects(
    configured(async () => {
      throw Error("secret");
    }).lookup_flight({ input }),
    "query_provider_unavailable",
  );
  const query = createAccountQueries({
    fetcher: async () => {
      throw Error("must not fetch");
    },
  });
  await rejects(
    query.lookup_flight({ input }),
    "flight_configuration_required",
  );
  await rejects(
    query.search_places({ input: fixture }),
    "places_configuration_required",
  );
  await rejects(
    query.search_places({ input: { countryCode: "CN", query: "北京" } }),
    "domestic_places_configuration_required",
  );
  assert.throws(
    () =>
      createAccountQueries({
        configuration: { domesticOrigin: "https://evil.invalid" },
      }),
    /invalid_domestic_provider/,
  );
});
test("actual loopback HTTP verifies proxy contract without transmitting private account graph", async () => {
  const requests = [],
    server = createServer((req, res) => {
      requests.push(req.url);
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ flights: [] }));
    });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const query = createAccountQueries({
      configuration: {
        allowLoopback: true,
        flightOrigin: `http://127.0.0.1:${server.address().port}`,
        flightToken: "synthetic",
      },
    });
    assert.deepEqual(
      (
        await query.lookup_flight({
          input: { number: "CA8333", date: "2026-11-01" },
        })
      ).flights,
      [],
    );
    assert.equal(requests.length, 1);
    assert.ok(requests[0].startsWith("/flight?number=CA8333&date="));
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
test("supplementary ranking and destination scene inference reuse native rules without cross-trip suppression", () => {
  const own = id(),
    other = id(),
    s1 = id(),
    s2 = id(),
    entities = [
      { id: own, kind: "trip", fields: { countryCode: "JP", days: 3 } },
      { id: other, kind: "trip", fields: {} },
      { id: s1, kind: "section", parentID: own, fields: {} },
      { id: s2, kind: "section", parentID: other, fields: {} },
      {
        id: id(),
        kind: "packingItem",
        parentID: s2,
        fields: { name: "Socks" },
      },
    ];
  const result = packingRecommendations({
    input: {
      scenes: ["city_break"],
      departureDate: "2026-11-01",
      language: "zh-Hans",
    },
    entities,
    tripID: own,
  });
  assert.deepEqual(result.suggestedScenes, ["winter"]);
  assert.equal(
    result.sections.flatMap((s) => s.items).find((x) => x.name === "Socks")
      .alreadyPresent,
    false,
  );
  assert.ok(result.supplementary.length > 0);
  assert.ok(result.supplementary[0].note);
  const none = packingRecommendations({
    input: { scenes: [], rankingMode: "manualFirst", supplementaryLimit: 5 },
  });
  assert.equal(none.supplementary.length, 5);
  assert.ok(
    !none.supplementary.some((x) =>
      ["Brown sugar ginger tea", "Portable hot water bottle"].includes(x.name),
    ),
  );
  const summer = packingRecommendations({
    input: { destinationCodes: ["TH"], departureDate: "2026-07-01" },
  });
  assert.deepEqual(summer.suggestedScenes, ["tropical"]);
});
test("MCP grants are rechecked before query network IO and no private graph is transmitted", async () => {
  const { createAccountAIHandler } = await import("./worker.mjs");
  const { syntheticStore } = await import("./synthetic-store.mjs");
  const { challenge } = await import("./security.mjs");
  const { defaults } = await import("./domain.mjs");
  const origin = "https://synthetic-query.invalid",
    accountOrigin = "https://synthetic-owner.invalid",
    accountID = id(),
    sessionID = id(),
    tripID = id(),
    other = id(),
    redirect = "http://127.0.0.1:49111/callback";
  const entity = (trip) => ({
    id: trip,
    kind: "trip",
    parentID: null,
    version: 1,
    subtreeVersion: 1,
    fields: {
      ...defaults("trip", Date.now()),
      name: "Private synthetic trip",
      countryCode: "JP",
    },
    fieldVersions: {},
    deletedAt: null,
  });
  const store = syntheticStore({
      accountID,
      sessionID,
      entities: [entity(tripID), entity(other)],
    }),
    outbound = [];
  const queries = createAccountQueries({
    configuration: { placesToken: "synthetic" },
    fetcher: async (url, options) => {
      outbound.push({ url: String(url), options });
      return body({ suggestions: [] });
    },
  });
  const handler = createAccountAIHandler({
    origin,
    accountOrigin,
    store,
    queries,
    synthetic: true,
    firstParty: {
      authenticate: async () => ({ accountID, sessionID }),
      verifyCSRF: async () => {},
    },
  });
  const call = (path, method = "GET", value, token, owner = false) =>
    handler(
      new Request(origin + path, {
        method,
        headers: {
          ...(value ? { "Content-Type": "application/json" } : {}),
          ...(token ? { Authorization: "Bearer " + token } : {}),
          ...(owner ? { Origin: accountOrigin } : {}),
        },
        body: value ? JSON.stringify(value) : undefined,
      }),
    );
  const registration = await call("/oauth/register", "POST", {
    client_name: "Synthetic query",
    redirect_uris: [redirect],
  });
  assert.equal(registration.status, 201);
  const client = (await registration.json()).client_id,
    verifier = "q".repeat(43),
    resource = origin + "/mcp";
  const auth = await call(
    "/oauth/authorize?" +
      new URLSearchParams({
        client_id: client,
        redirect_uri: redirect,
        response_type: "code",
        code_challenge: await challenge(verifier),
        code_challenge_method: "S256",
        scope: "trips:read",
        state: "synthetic",
        resource,
      }),
  );
  const flow = new URL(auth.headers.get("Location")).searchParams.get(
    "authorization_id",
  );
  const approval = await call(
    "/oauth/requests/" + flow,
    "POST",
    {
      decision: "approve",
      csrf: "synthetic-only-proof",
      scopes: ["trips:read"],
      tripIDs: [tripID],
      onlyCreated: false,
    },
    null,
    true,
  );
  assert.equal(approval.status, 303);
  const code = new URL(approval.headers.get("Location")).searchParams.get(
    "code",
  );
  const tokenResponse = await handler(
    new Request(origin + "/oauth/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "authorization_code",
        client_id: client,
        redirect_uri: redirect,
        resource,
        code,
        code_verifier: verifier,
      }),
    }),
  );
  assert.equal(tokenResponse.status, 200);
  const access = (await tokenResponse.json()).access_token;
  const tool = async (trip) =>
    (
      await call(
        "/mcp",
        "POST",
        {
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: {
            name: "search_places",
            arguments: {
              tripID: trip,
              data: { countryCode: "JP", query: "Tokyo" },
            },
          },
        },
        access,
      )
    ).json();
  const denied = await tool(other);
  assert.ok(denied.result?.isError || denied.error);
  assert.equal(outbound.length, 0);
  const accepted = await tool(tripID.toUpperCase());
  assert.deepEqual(accepted.result?.structuredContent?.suggestions, []);
  assert.equal(outbound.length, 1);
  assert.ok(!JSON.stringify(outbound).includes("Private synthetic trip"));
  assert.ok(!JSON.stringify(outbound).includes(access));
});
test("cancelled and oversized chunked requests stop without leaking provider response bodies", async () => {
  const controller = new AbortController();
  controller.abort(new Error("cancelled synthetic"));
  let calls = 0;
  const query = configured(async () => {
    calls++;
    return body({ flights: [] });
  });
  await assert.rejects(
    query.lookup_flight({
      input: { number: "CA8333", date: "2026-11-01" },
      signal: controller.signal,
    }),
    /cancelled synthetic/,
  );
  assert.equal(calls, 0);
  let cancelled = false;
  const overflow = configured(
    async () =>
      new Response(
        new ReadableStream({
          pull(c) {
            c.enqueue(new Uint8Array(64 * 1024));
          },
          cancel() {
            cancelled = true;
          },
        }),
      ),
  );
  await rejects(
    overflow.lookup_flight({ input: { number: "CA8333", date: "2026-11-01" } }),
    "invalid_query_response",
  );
  assert.equal(cancelled, true);
});
test("structured multi-destination country is permitted while unknown country relabelling stays blocked", async () => {
  const trip = id(),
    additional = btoa(
      JSON.stringify([
        {
          countryCode: "JP",
          name: "Tokyo",
          latitude: 35.68,
          longitude: 139.76,
        },
      ]),
    );
  let calls = 0;
  const query = configured(async () => {
    calls++;
    return body({ suggestions: [] });
  });
  const result = await query.search_places({
    input: fixture,
    tripID: trip,
    entities: [
      {
        id: trip,
        kind: "trip",
        fields: { countryCode: "CN", additionalDestinationsData: additional },
      },
    ],
  });
  assert.deepEqual(result.suggestions, []);
  assert.equal(calls, 1);
  await rejects(
    query.search_places({
      input: { ...fixture, countryCode: "GB" },
      tripID: trip,
      entities: [
        {
          id: trip,
          kind: "trip",
          fields: { countryCode: "CN", additionalDestinationsData: additional },
        },
      ],
    }),
    "destination_country_mismatch",
  );
  assert.equal(calls, 1);
});

test("packing uses every structured destination and keeps passport for mixed permit and overseas travel", () => {
  const trip = id();
  for (const additional of [["JP"], ["HK", "JP"], ["HK", "TW"]]) {
    const result = packingRecommendations({
      input: { storefront: "CHN" },
      tripID: trip,
      entities: [
        {
          id: trip,
          kind: "trip",
          fields: {
            countryCode: "CN",
            additionalDestinationsData: btoa(
              JSON.stringify(
                additional.map((countryCode) => ({ countryCode })),
              ),
            ),
          },
        },
      ],
    });
    const names = result.sections.flatMap((s) => s.items).map((i) => i.name);
    assert.equal(names.includes("Passport"), additional.includes("JP"));
    assert.equal(
      names.includes("HK & Macao permit"),
      additional.includes("HK"),
    );
  }
});
test("domestic returned coordinates must match the requested jurisdiction", async () => {
  const query = configured(async () =>
    body({
      status: "1",
      pois: [{ id: "synthetic", name: "Shanghai", location: "121.47,31.23" }],
    }),
  );
  for (const countryCode of ["HK", "MO"])
    await rejects(
      query.search_places({ input: { countryCode, query: "Shanghai" } }),
      "place_outside_requested_country",
    );
});
