// Wire schema for the account graph, independent of CloudKit and UI projections.
// Binary assets are references, never a silent substitution for an uploaded file.
const string = (max = 2000) => ({ type: 'string', max });
const integer = (min = 0, max = 1000000) => ({ type: 'number', integer: true, min, max });
const number = (min, max) => ({ type: 'number', min, max });
const boolean = { type: 'boolean' };
const date = { type: 'string', format: 'date-time', max: 64 };
const zone = { type: 'string', format: 'timezone', max: 100 };
const asset = { type: 'string', format: 'uuid', max: 36 };
const optional = rule => ({ ...rule, optional: true });
const enumeration = values => ({ type: 'string', values });
const strings = { type: 'array', max: 1000, item: string(500) };
const position = { sortOrder: integer() };
const geo = { latitude: number(-90, 90), longitude: number(-180, 180) };
const cost = { costAmount: optional(number(0, 1e12)), costCurrencyCode: optional({ type: 'string', pattern: '^([A-Z]{3})?$', max: 3 }), costHomeAmount: optional(number(-1, 1e12)) };
const minute = integer(-1, 1439);
const text = names => Object.fromEntries(names.split(' ').map(key => [key, string()]));

export const graphSchema = {
  trip: { parents: [], fields: {
    name: string(500), destinationCity: string(), days: integer(0, 3650), dateRange: string(),
    departureDate: date, isDateless: boolean, createdAt: date,
    selectedSceneKeys: strings, dismissedSurpriseNames: strings,
    sceneCardDismissed: boolean, remindersEnabled: boolean,
    // Small versioned native configuration payloads; full bytes stay lossless.
    reminderConfigData: string(32000), additionalDestinationsData: optional(string(64000)),
    backgroundsData: optional(string(64000)), countryCode: string(2), ...geo,
  } },
  section: { parents: ['trip'], fields: { title: string(500), ...position } },
  packingItem: { parents: ['section'], fields: { name: string(500), quantity: integer(1), isPacked: boolean, isAlert: boolean, ...position } },
  day: { parents: ['trip'], fields: { title: string(500), note: string(16000), ...position } },
  stop: { parents: ['day'], fields: {
    name: string(500), ...geo, address: string(), categoryRaw: string(100),
    plannedStartMinutes: minute, stayMinutes: integer(0, 5256000), note: string(16000),
    ...position, ...cost, fromPhotos: optional(boolean), phone: optional(string(100)), timeZoneId: optional(zone),
  } },
  transport: { parents: ['day'], fields: {
    modeRaw: enumeration(['flight', 'train', 'bus', 'ferry', 'carRental', 'other']),
    ...text('carrier number fromName fromCode fromTerminal toName toCode toTerminal seat confirmationCode'),
    fromLatitude: geo.latitude, fromLongitude: geo.longitude, fromTimeZoneId: zone,
    toLatitude: geo.latitude, toLongitude: geo.longitude, toTimeZoneId: zone,
    departDayOrder: integer(0, 3650), departLocalMinutes: minute,
    arriveDayOrder: integer(0, 3650), arriveLocalMinutes: minute,
    note: string(16000), ...position, ...cost,
    ...Object.fromEntries(Object.entries(text('aircraftType cabinClass eticketNumber routeName coachNumber seatClass serviceType vehicleModel licensePlate fromAddress toAddress phone')).map(([k,v]) => [k, optional(v)])),
    distanceMeters: optional(number(0, 1e10)), durationMinutes: optional(integer(0, 5256000)), remindersMuted: optional(boolean),
  } },
  lodging: { parents: ['trip'], fields: {
    name: string(500), address: string(), ...geo,
    checkInDayOrder: integer(0, 3650), nights: integer(1, 3650),
    checkInMinutes: minute, checkOutMinutes: minute, confirmationCode: string(), note: string(16000),
    ...position, ...cost, phone: optional(string(100)), timeZoneId: optional(zone), remindersMuted: optional(boolean),
  } },
  photo: { parents: ['stop'], fields: {
    assetLocalIdentifier: string(), thumbnailAssetID: asset, timestamp: date, ...geo, ...position,
  } },
  attachment: { parents: ['stop', 'transport', 'lodging'], fields: {
    ...text('kindRaw displayName fileName utiOrExt urlString'),
    thumbnailAssetID: optional(asset), fileAssetID: optional(asset), addedAt: date, ...position,
  } },
  libraryItem: { parents: [], fields: {
    ...text('name collectionName category'), defaultQuantity: integer(1),
    quantityModeRaw: enumeration(['fixed', 'tripDays', 'everyNDays']), quantityIntervalDays: integer(1),
    ...position, createdAt: date, updatedAt: date,
  } },
};

// Generated SQL stores this manifest in a private, read-only function. Keeping it
// as JSON makes native mirror coverage auditable and prevents a JS-only bypass.
export function schemaSQL({ replace = false } = {}) {
  return `create ${replace ? "or replace " : ""}function carry_private.graph_schema() returns jsonb\nlanguage sql immutable security invoker set search_path = '' as $schema$\n select '${JSON.stringify(graphSchema).replaceAll("'", "''")}'::jsonb;\n$schema$;\n`;
}
