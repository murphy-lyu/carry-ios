import tzLookup from "tz-lookup";
import packingRules from "./packing-rules.json" with { type: "json" };
import { fail, object, text, uuid } from "./security.mjs";

const languages = new Set([
  "en",
  "zh-Hans",
  "zh-Hant",
  "de",
  "es",
  "fr",
  "ja",
  "ko",
  "pt-BR",
]);
const domesticCountries = new Set(["CN", "HK", "MO"]);
const domesticZones = new Set([
  "Asia/Shanghai",
  "Asia/Urumqi",
  "Asia/Hong_Kong",
  "Asia/Macau",
]);
const providerRecord = (value) => {
  if (!value || typeof value !== "object" || Array.isArray(value))
    fail("invalid_query_response", 503);
  return value;
};
const clean = (s, max = 500) => (typeof s === "string" ? s.slice(0, max) : "");
const language = (value) => {
  if (value !== undefined && !languages.has(value)) fail("invalid_language");
  return value ?? "en";
};
const integer = (value, min, max, fallback) => {
  if (value === undefined && fallback !== undefined) return fallback;
  if (!Number.isSafeInteger(value) || value < min || value > max)
    fail("invalid_request");
  return value;
};
const coord = (lat, lon) => {
  if (
    !Number.isFinite(lat) ||
    !Number.isFinite(lon) ||
    lat < -90 ||
    lat > 90 ||
    lon < -180 ||
    lon > 180
  )
    fail("invalid_coordinates");
  return { latitude: lat, longitude: lon };
};
const cc = (value) => {
  if (typeof value !== "string" || !/^[A-Z]{2}$/.test(value))
    fail("invalid_country");
  return value;
};
const zone = (lat, lon, country) =>
  country === "CN" ? "Asia/Shanghai" : tzLookup(lat, lon);
const isDomestic = (country, point) =>
  domesticCountries.has(country) ||
  (point && domesticZones.has(tzLookup(point.latitude, point.longitude)));
const isoDate = (value) => {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value))
    fail("invalid_date");
  const stamp = Date.parse(value + "T00:00:00Z");
  if (
    !Number.isFinite(stamp) ||
    new Date(stamp).toISOString().slice(0, 10) !== value
  )
    fail("invalid_date");
  return value;
};
function endpoint(raw, fallback, loopback) {
  const url = new URL(raw ?? fallback);
  if (
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !["", "/"].includes(url.pathname) ||
    !(
      url.protocol === "https:" ||
      (loopback &&
        url.protocol === "http:" &&
        ["127.0.0.1", "localhost"].includes(url.hostname))
    )
  )
    throw Error("invalid_query_configuration");
  return url.origin;
}

async function requestJSON(
  fetcher,
  url,
  { token, signal, limit = 1024 * 1024 } = {},
) {
  const timeout = AbortSignal.timeout(15000),
    combined = signal ? AbortSignal.any([signal, timeout]) : timeout;
  let response;
  if (signal?.aborted) throw signal.reason;
  try {
    response = await fetcher(url, {
      method: "GET",
      headers: {
        Accept: "application/json",
        ...(token ? { "X-App-Token": token } : {}),
      },
      redirect: "error",
      signal: combined,
    });
  } catch {
    if (signal?.aborted) throw signal.reason;
    fail("query_provider_unavailable", 503);
  }
  if (response.status === 429 || !response.ok) {
    await response.body?.cancel().catch(() => {});
    fail(
      response.status === 429
        ? "query_rate_limited"
        : "query_provider_unavailable",
      response.status === 429 ? 429 : 503,
    );
  }
  if (
    !response.body ||
    Number(response.headers.get("content-length") ?? 0) > limit
  ) {
    await response.body?.cancel();
    fail("invalid_query_response", 503);
  }
  const reader = response.body.getReader(),
    parts = [];
  let total = 0;
  const abort = () => {
    reader.cancel().catch(() => {});
  };
  combined.addEventListener("abort", abort, { once: true });
  try {
    while (true) {
      if (combined.aborted) fail("query_provider_unavailable", 503);
      const { done, value } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > limit) fail("invalid_query_response", 503);
      parts.push(value);
    }
    if (combined.aborted) fail("query_provider_unavailable", 503);
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) {
      bytes.set(part, offset);
      offset += part.length;
    }
    try {
      return providerRecord(
        JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)),
      );
    } catch {
      fail("invalid_query_response", 503);
    }
  } finally {
    combined.removeEventListener("abort", abort);
    await reader.cancel().catch(() => {});
  }
}

let airportPromise;
async function airports() {
  airportPromise ??= import("../../Carry/Resources/airports.json", {
    with: { type: "json" },
  }).then((m) => m.default);
  return airportPromise;
}
function airportScore(a, q) {
  const lower = q.toLowerCase(),
    upper = q.toUpperCase();
  if (a.iata === upper) return 0;
  if (a.iata.startsWith(upper)) return 1;
  if (a.icao && a.icao.startsWith(upper)) return 2;
  if (
    a.city.toLowerCase().startsWith(lower) ||
    (a.cs ?? []).some((s) => s.toLowerCase() === lower)
  )
    return 3;
  if (
    [...Object.values(a.nm ?? {}), ...(a.cs ?? [])].some((s) =>
      s.toLowerCase().includes(lower),
    )
  )
    return 4;
  if (a.city.toLowerCase().includes(lower)) return 5;
  if (a.name.toLowerCase().includes(lower)) return 6;
  return null;
}
export async function searchAirports({ input }) {
  object(input, ["query", "language", "limit"], ["query"]);
  const q = text(input.query, 200).trim(),
    lang = language(input.language),
    limit = integer(input.limit, 1, 100, 20);
  if (!q) return { airports: [], source: "Carry bundled airport catalog" };
  const found = (await airports())
    .map((a) => ({ a, score: airportScore(a, q) }))
    .filter((x) => x.score !== null)
    .sort(
      (a, b) =>
        a.score - b.score ||
        Number(b.a.large) - Number(a.a.large) ||
        a.a.name.localeCompare(b.a.name),
    );
  return {
    source: "Carry bundled airport catalog",
    airports: found.slice(0, limit).map(({ a }) => ({
      iata: a.iata,
      icao: a.icao,
      name: a.nm?.[lang] ?? a.name,
      city: a.city,
      countryCode: a.country,
      latitude: a.lat,
      longitude: a.lon,
      coordinateSystem: "WGS-84",
      timeZoneId: zone(a.lat, a.lon, a.country),
    })),
  };
}

const rad = (n) => (n * Math.PI) / 180;
export function haversine(a, b) {
  const dLat = rad(b.latitude - a.latitude),
    dLon = rad(b.longitude - a.longitude),
    h =
      Math.sin(dLat / 2) ** 2 +
      Math.cos(rad(a.latitude)) *
        Math.cos(rad(b.latitude)) *
        Math.sin(dLon / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.min(1, Math.sqrt(h)));
}
function pathDistance(order, points) {
  let total = 0;
  for (let i = 1; i < order.length; i++)
    total += haversine(points[order[i - 1]], points[order[i]]);
  return total;
}
export function previewRoute({ input, entities = [] }) {
  object(input, ["dayID", "stops"], []);
  if ((input.dayID === undefined) === (input.stops === undefined))
    fail("invalid_request");
  let points;
  if (input.dayID !== undefined) {
    if (!uuid(input.dayID)) fail("invalid_identifier");
    const day = entities.find(
      (e) =>
        e.id === input.dayID.toLowerCase() && e.kind === "day" && !e.deletedAt,
    );
    if (!day) fail("not_found", 404);
    points = entities
      .filter((e) => e.kind === "stop" && e.parentID === day.id && !e.deletedAt)
      .sort(
        (a, b) =>
          (a.fields.sortOrder ?? 0) - (b.fields.sortOrder ?? 0) ||
          a.id.localeCompare(b.id),
      )
      .map((e) => ({
        id: e.id,
        latitude: e.fields.latitude,
        longitude: e.fields.longitude,
      }));
  } else {
    if (!Array.isArray(input.stops)) fail("invalid_request");
    points = input.stops;
  }
  if (points.length > 100) fail("route_too_large");
  const ids = new Set();
  for (const point of points) {
    object(
      point,
      ["id", "latitude", "longitude"],
      ["id", "latitude", "longitude"],
    );
    if (!uuid(point.id) || ids.has(point.id.toLowerCase()))
      fail("invalid_identifier");
    ids.add(point.id.toLowerCase());
    coord(point.latitude, point.longitude);
  }
  const original = points.map((_, i) => i);
  let order = [...original];
  if (points.length >= 3) {
    const available = original.slice(1, -1),
      candidate = [0];
    while (available.length) {
      available.sort(
        (a, b) =>
          haversine(points[candidate.at(-1)], points[a]) -
            haversine(points[candidate.at(-1)], points[b]) || a - b,
      );
      candidate.push(available.shift());
    }
    candidate.push(points.length - 1);
    if (pathDistance(candidate, points) < pathDistance(order, points))
      order = candidate;
    // Bounded deterministic 2-opt; start and end are the native fixed anchors.
    for (let pass = 0; pass < 50; pass++) {
      let changed = false;
      for (let a = 1; a < order.length - 2; a++)
        for (let b = a + 1; b < order.length - 1; b++) {
          const old =
              haversine(points[order[a - 1]], points[order[a]]) +
              haversine(points[order[b]], points[order[b + 1]]),
            next =
              haversine(points[order[a - 1]], points[order[b]]) +
              haversine(points[order[a]], points[order[b + 1]]);
          if (next + 1e-6 < old) {
            order.splice(a, b - a + 1, ...order.slice(a, b + 1).reverse());
            changed = true;
          }
        }
      if (!changed) break;
    }
  }
  const before = pathDistance(original, points),
    after = pathDistance(order, points),
    saved = Math.max(0, before - after);
  return {
    status: "preview_only",
    method: "haversine_nearest_neighbor_2opt",
    distanceBasis: "great_circle_estimate",
    roadDistanceMeters: null,
    durationSeconds: null,
    orderedStopIDs: order.map((i) => points[i].id),
    originalDistanceMeters: before,
    optimizedDistanceMeters: after,
    savedMeters: saved,
    isImprovement: before > 0 && saved > 50 && saved / before > 0.01,
    fixedEndpoints: points.length ? [points[0].id, points.at(-1).id] : [],
  };
}

function supplementary(scenes, existing, mode, limit, lang) {
  const rules = packingRules.surprise,
    seen = new Set(),
    items = [];
  const keys =
    !scenes.length && mode === "manualFirst"
      ? Object.keys(rules.scenes).sort()
      : scenes;
  for (const key of keys)
    for (const item of rules.scenes[key] ?? []) {
      const name = item.name.toLowerCase();
      if (!seen.has(name) && !existing.has(name)) {
        seen.add(name);
        items.push(item);
      }
    }
  function score(item) {
    const name = item.name,
      u = rules.universal[name] ?? 0.62,
      d = rules.delight[name] ?? 0.58,
      s = rules.scene[name] ?? 0.72,
      n = rules.niche[name] ?? 0.2;
    const overlap = [...existing].some((e) =>
      (rules.overlap[name] ?? []).some((k) => e.includes(k)),
    )
      ? 0.22
      : 0;
    return mode === "manualFirst"
      ? u * 0.45 + d * 0.35 + s * 0.2 - n * 0.25 - overlap
      : s * 0.7 + u * 0.2 + d * 0.1 - n * 0.3 - overlap;
  }
  const category = (item) => {
    const i = rules.categoryOrder.indexOf(item.category);
    return i < 0 ? rules.categoryOrder.length : i;
  };
  items.sort(
    (a, b) =>
      score(b) - score(a) ||
      category(a) - category(b) ||
      a.name.localeCompare(b.name, lang, { sensitivity: "base" }),
  );
  let ranked = items;
  if (mode === "sceneFirst" && items.length > 3) {
    const strong = items.filter((x) => (rules.scene[x.name] ?? 0.72) >= 0.88);
    if (strong.length >= 2) {
      const top = strong.slice(0, 2);
      const other = items.find((x) => !top.includes(x));
      if (other) top.push(other);
      ranked = [...top, ...items.filter((x) => !top.includes(x))];
    }
  }
  return ranked.slice(0, limit).map((item) => ({
    ...item,
    displayName: packingRules.labels[item.name]?.[lang] ?? item.name,
    note: packingRules.labels[item.note]?.[lang] ?? item.note,
  }));
}
function inferredScenes(countries, departure) {
  const rules = packingRules.climate,
    month = departure ? Number(isoDate(departure).slice(5, 7)) : null;
  const scenes = new Set();
  for (const country of countries) {
    if (rules.tropicalCountries.includes(country)) scenes.add("tropical");
    if (
      rules.alwaysColdCountries.includes(country) ||
      (month &&
        [11, 12, 1, 2].includes(month) &&
        rules.seasonallyColdNorthernCountries.includes(country))
    )
      scenes.add("winter");
    if (rules.highAltitudeCountries.includes(country))
      scenes.add("high_altitude");
  }
  return [...scenes];
}
function itemsInTrip(entities, tripID) {
  if (!tripID) return [];
  const map = new Map(entities.map((e) => [e.id, e]));
  return entities.filter((e) => {
    let node = e,
      seen = new Set();
    while (node) {
      if (seen.has(node.id)) fail("invalid_graph");
      seen.add(node.id);
      if (node.id === tripID) return true;
      node = map.get(node.parentID);
    }
    return false;
  });
}

export function packingRecommendations({
  input,
  entities = [],
  tripID = null,
}) {
  object(
    input,
    [
      "scenes",
      "tripDays",
      "isInternational",
      "destinationCodes",
      "storefront",
      "language",
      "departureDate",
      "rankingMode",
      "supplementaryLimit",
    ],
    [],
  );
  const trip = tripID
    ? entities.find((e) => e.kind === "trip" && e.id === tripID && !e.deletedAt)
    : null;
  const scenes = input.scenes ?? trip?.fields.selectedSceneKeys ?? [];
  if (
    !Array.isArray(scenes) ||
    scenes.length > 16 ||
    scenes.some((s) => typeof s !== "string")
  )
    fail("invalid_scenes");
  if (scenes.some((s) => s.startsWith("personal_")))
    fail("health_data_not_supported", 403);
  if (scenes.some((s) => !Object.hasOwn(packingRules.scenes, s)))
    fail("invalid_scenes");
  const days = Math.max(
      1,
      integer(input.tripDays ?? trip?.fields.days, 0, 3650, 1),
    ),
    lang = language(input.language);
  const countries = input.destinationCodes ?? [...destinationCountries(trip)];
  if (!Array.isArray(countries) || countries.length > 100)
    fail("invalid_country");
  countries.forEach(cc);
  if (input.storefront !== undefined && !/^[A-Z]{3}$/.test(input.storefront))
    fail("invalid_storefront");
  if (
    input.isInternational !== undefined &&
    typeof input.isInternational !== "boolean"
  )
    fail("invalid_request");
  const merged = new Map();
  for (const item of [
    ...packingRules.base,
    ...scenes.flatMap((s) => packingRules.scenes[s]),
  ]) {
    if (input.isInternational === false && item.internationalOnly) continue;
    const previous = merged.get(item.name);
    merged.set(item.name, {
      ...item,
      isAlert: item.isAlert || previous?.isAlert === true,
    });
  }
  if (input.storefront === "CHN" && countries.length) {
    const hkmo = countries.some((c) => c === "HK" || c === "MO"),
      tw = countries.includes("TW");
    if (hkmo || tw) {
      if (countries.every((c) => ["CN", "HK", "MO", "TW"].includes(c)))
        merged.delete("Passport");
      for (const name of [
        ...(hkmo ? ["HK & Macao permit"] : []),
        ...(tw ? ["Taiwan permit"] : []),
      ])
        merged.set(
          name,
          packingRules.extra.find((x) => x.name === name),
        );
    } else if (countries.every((c) => c === "CN")) {
      merged.delete("Passport");
      merged.set(
        "ID card",
        packingRules.extra.find((x) => x.name === "ID card"),
      );
    }
  }
  const rankingMode = input.rankingMode ?? "sceneFirst";
  if (!["manualFirst", "sceneFirst"].includes(rankingMode))
    fail("invalid_request");
  const supplementaryLimit = integer(input.supplementaryLimit, 0, 100, 10);
  const existing = new Set(
    itemsInTrip(entities, tripID)
      .filter((e) => e.kind === "packingItem" && !e.deletedAt)
      .map((e) => e.fields.name),
  );
  const sections = packingRules.categoryOrder
    .map((title) => ({
      title,
      items: [...merged.values()]
        .filter((x) => x.category === title)
        .map((x) => ({
          name: x.name,
          displayName: packingRules.labels[x.name]?.[lang] ?? x.name,
          quantity: /spare|extra/i.test(x.name)
            ? 1
            : packingRules.dailyNames.includes(x.name.toLowerCase())
              ? Math.min(days, 99)
              : 1,
          isAlert: x.isAlert,
          alreadyPresent: existing.has(x.name),
        })),
    }))
    .filter((x) => x.items.length);
  return {
    status: "recommendations_only",
    source: "Carry native SceneItemMap",
    sourceRevision: packingRules.sourceSHA256,
    sections,
    supplementary: supplementary(
      scenes,
      new Set([...existing].map((x) => x.toLowerCase())),
      rankingMode,
      supplementaryLimit,
      lang,
    ),
    suggestedScenes: inferredScenes(countries, input.departureDate),
    seasonalInferenceDate: input.departureDate ?? null,
    healthDataUsed: false,
    changesApplied: false,
  };
}

function destinationCountries(trip) {
  const destinations = new Set(
    trip?.fields.countryCode ? [cc(trip.fields.countryCode)] : [],
  );
  const encoded = trip?.fields.additionalDestinationsData;
  if (
    typeof encoded === "string" &&
    encoded.length &&
    encoded.length <= 64000
  ) {
    try {
      const raw = Uint8Array.from(atob(encoded), (c) => c.charCodeAt(0));
      const values = JSON.parse(
        new TextDecoder("utf-8", { fatal: true }).decode(raw),
      );
      if (!Array.isArray(values)) fail("invalid_destination_metadata");
      for (const value of values) destinations.add(cc(value.countryCode));
    } catch {
      fail("invalid_destination_metadata");
    }
  }
  return destinations;
}
function targetCountry(input, tripID, entities) {
  const declared =
    input.countryCode === undefined ? null : cc(input.countryCode);
  const trip = tripID
    ? entities.find((e) => e.id === tripID && e.kind === "trip" && !e.deletedAt)
    : null;
  const fromTrip = trip?.fields.countryCode
    ? cc(trip.fields.countryCode)
    : null;
  const destinations = destinationCountries(trip);
  if (destinations.size && declared && !destinations.has(declared))
    fail("destination_country_mismatch");
  const country = declared ?? fromTrip;
  if (!country) fail("destination_country_required");
  return country;
}
function pointFrom(input) {
  if (input.proximity === undefined) return null;
  object(input.proximity, ["latitude", "longitude"], ["latitude", "longitude"]);
  return coord(input.proximity.latitude, input.proximity.longitude);
}
function airportEnd(end) {
  const a = end?.airport ?? {},
    location = a.location ?? {};
  const out = {
    name: clean(a.name),
    iata: clean(a.iata, 3),
    icao: clean(a.icao, 4),
    terminal: clean(end?.terminal),
    countryCode: clean(a.countryCode, 2).toUpperCase(),
    scheduledLocal: clean(end?.scheduledTime?.local, 64),
    scheduledUTC: clean(end?.scheduledTime?.utc, 64),
  };
  if (Number.isFinite(location.lat) && Number.isFinite(location.lon)) {
    const point = coord(location.lat, location.lon);
    Object.assign(out, point, {
      coordinateSystem: "WGS-84",
      timeZoneId: zone(point.latitude, point.longitude, out.countryCode),
    });
  }
  return out;
}

/** Each network request uses a fixed, server-selected endpoint. No bearer,
 * unredacted graph, private notes or itinerary is sent to a search provider. */
export function createAccountQueries({
  fetcher = fetch,
  configuration = {},
  airportSearch = searchAirports,
} = {}) {
  const loopback = configuration.allowLoopback === true;
  const placesOrigin = endpoint(
      configuration.placesOrigin,
      "https://places.nevestudio.app",
      loopback,
    ),
    flightOrigin = endpoint(
      configuration.flightOrigin,
      "https://flight.nevestudio.app",
      loopback,
    );
  const domesticOrigin = endpoint(
    configuration.domesticOrigin,
    "https://restapi.amap.com",
    loopback,
  );
  if (!loopback && new URL(domesticOrigin).hostname !== "restapi.amap.com")
    throw Error("invalid_domestic_provider");
  return {
    search_airports: airportSearch,
    preview_route: previewRoute,
    get_packing_recommendations: packingRecommendations,
    lookup_flight: async ({ input, signal }) => {
      object(input, ["number", "date"], ["number", "date"]);
      const number = text(input.number, 64)
        .trim()
        .toUpperCase()
        .replaceAll(" ", "");
      if (!/^[A-Z0-9]{2,3}\d{1,5}[A-Z]?$/.test(number))
        fail("invalid_flight_number");
      const date = isoDate(input.date);
      if (!configuration.flightToken)
        fail("flight_configuration_required", 503);
      const url = new URL("/flight", flightOrigin);
      url.searchParams.set("number", number);
      url.searchParams.set("date", date);
      const result = await requestJSON(fetcher, url, {
        token: configuration.flightToken,
        signal,
      });
      if (
        !Array.isArray(result.flights) ||
        result.flights.length > 100 ||
        result.flights.some(
          (f) => !f || typeof f !== "object" || Array.isArray(f),
        )
      )
        fail("invalid_query_response", 503);
      return {
        source: "Carry flight proxy / AeroDataBox",
        requestedNumber: number,
        requestedDate: date,
        totalFlights: result.flights.length,
        hasMore: result.flights.length > 30,
        flights: result.flights.slice(0, 30).map((f) => ({
          number: clean(f.number, 20),
          status: clean(f.status, 100),
          airline: clean(f.airline?.name),
          aircraftModel: clean(f.aircraft?.model),
          departure: airportEnd(f.departure),
          arrival: airportEnd(f.arrival),
        })),
        providerResultsAreUntrusted: true,
      };
    },
    search_places: async ({ input, tripID = null, entities = [], signal }) => {
      object(
        input,
        [
          "query",
          "countryCode",
          "proximity",
          "language",
          "city",
          "placeID",
          "session",
          "limit",
        ],
        [],
      );
      if ((input.query === undefined) === (input.placeID === undefined))
        fail("invalid_request");
      const country = targetCountry(input, tripID, entities),
        point = pointFrom(input),
        lang = language(input.language),
        limit = integer(input.limit, 1, 8, 8);
      const domestic = domesticCountries.has(country);
      if (
        point &&
        domesticZones.has(tzLookup(point.latitude, point.longitude)) !==
          domestic
      )
        fail("destination_coordinates_mismatch");
      if (input.placeID !== undefined) {
        if (domestic) fail("domestic_place_lookup_requires_query");
        if (!configuration.placesToken)
          fail("places_configuration_required", 503);
        const id = text(input.placeID, 8000);
        if (!/^(mb:|ga:)/.test(id)) fail("invalid_place_identifier");
        const session =
          input.session === undefined
            ? crypto.randomUUID()
            : text(input.session, 64);
        if (!uuid(session)) fail("invalid_session");
        const url = new URL("/retrieve", placesOrigin);
        url.searchParams.set("id", id);
        url.searchParams.set("session", session);
        const result = await requestJSON(fetcher, url, {
          token: configuration.placesToken,
          signal,
        });
        if (result.disabled)
          return { source: "Carry places proxy", disabled: true, places: [] };
        if (!result.place) return { source: "Carry places proxy", places: [] };
        const p = providerRecord(result.place),
          c = cc(p.country),
          coords = coord(p.latitude, p.longitude);
        if (isDomestic(c, coords) || c !== country)
          fail("place_outside_requested_country", 503);
        return {
          source: "Carry places proxy",
          places: [
            {
              name: clean(p.name),
              address: clean(p.address, 2000),
              phone: clean(p.phone, 100),
              countryCode: c,
              ...coords,
              coordinateSystem: "WGS-84",
              timeZoneId: zone(coords.latitude, coords.longitude, c),
            },
          ],
          providerResultsAreUntrusted: true,
        };
      }
      const query = text(input.query, 200).trim();
      if (!query) fail("invalid_query");
      if (domestic) {
        if (!configuration.amapKey)
          fail("domestic_places_configuration_required", 503);
        const url = new URL("/v3/place/text", domesticOrigin);
        url.searchParams.set("key", configuration.amapKey);
        url.searchParams.set("keywords", query);
        url.searchParams.set("offset", String(limit));
        url.searchParams.set("page", "1");
        url.searchParams.set("extensions", "base");
        if (input.city !== undefined)
          url.searchParams.set("city", text(input.city, 100));
        url.searchParams.set("citylimit", "true");
        const result = await requestJSON(fetcher, url, { signal });
        if (result.status !== "1" || !Array.isArray(result.pois))
          fail("query_provider_unavailable", 503);
        return {
          source: "Amap Web Service",
          coordinateSystem: "GCJ-02",
          places: result.pois.slice(0, limit).map((p) => {
            providerRecord(p);
            const pair =
              typeof p.location === "string"
                ? p.location.split(",").map(Number)
                : [];
            if (pair.length !== 2) fail("invalid_query_response", 503);
            const coords = coord(pair[1], pair[0]);
            const actualZone = tzLookup(coords.latitude, coords.longitude);
            const expectedZones =
              country === "CN"
                ? ["Asia/Shanghai", "Asia/Urumqi"]
                : country === "HK"
                  ? ["Asia/Hong_Kong"]
                  : ["Asia/Macau"];
            if (!expectedZones.includes(actualZone))
              fail("place_outside_requested_country", 503);
            return {
              id: clean(p.id, 100),
              name: clean(p.name),
              address: clean(p.address, 2000),
              countryCode: country,
              ...coords,
              coordinateSystem: "GCJ-02",
              timeZoneId: zone(coords.latitude, coords.longitude, country),
            };
          }),
          providerResultsAreUntrusted: true,
        };
      }
      if (!configuration.placesToken)
        fail("places_configuration_required", 503);
      const session =
        input.session === undefined
          ? crypto.randomUUID()
          : text(input.session, 64);
      if (!uuid(session)) fail("invalid_session");
      const url = new URL("/suggest", placesOrigin);
      url.searchParams.set("q", query);
      url.searchParams.set("session", session);
      url.searchParams.set("language", lang);
      if (point)
        url.searchParams.set(
          "proximity",
          `${point.longitude},${point.latitude}`,
        );
      const result = await requestJSON(fetcher, url, {
        token: configuration.placesToken,
        signal,
      });
      if (result.disabled)
        return {
          source: "Carry places proxy",
          disabled: true,
          suggestions: [],
        };
      if (!Array.isArray(result.suggestions) || result.suggestions.length > 100)
        fail("invalid_query_response", 503);
      return {
        source: "Carry places proxy",
        session,
        suggestions: result.suggestions.slice(0, limit).map((p) => {
          providerRecord(p);
          if (
            typeof p.id !== "string" ||
            (!p.id.startsWith("mb:") && !p.id.startsWith("ga:"))
          )
            fail("invalid_query_response", 503);
          return {
            id: text(p.id, 8000),
            name: clean(p.name),
            secondary: clean(p.secondary, 2000),
          };
        }),
        requiresPlaceRetrieval: true,
        providerResultsAreUntrusted: true,
      };
    },
  };
}
