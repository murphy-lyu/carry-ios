import { Buffer } from 'node:buffer';
import { fail, hash, canonical, uuid } from './security.mjs';
import { graphIndex, rootOf, privateFields } from './domain.mjs';

const children = {
  trip: { sections: 'section', itineraryDays: 'day', lodgingStays: 'lodging' },
  section: { items: 'packingItem' }, day: { stops: 'stop', segments: 'transport' },
  stop: { photos: 'photo', attachments: 'attachment' }, transport: { attachments: 'attachment' }, lodging: { attachments: 'attachment' },
};
const field = slot => ({ file: 'fileAssetID', thumbnail: 'thumbnailAssetID', original: 'originalAssetID' })[slot];
export function assetReferences(entity) {
  const references = [];
  for (const slot of entity.kind === 'trip' ? [] : entity.kind === 'photo' ? ['thumbnail', 'original'] : entity.kind === 'attachment' ? ['file', 'thumbnail'] : []) {
    const raw = entity.fields[field(slot)];
    if (raw !== undefined && raw !== null && raw !== '') {
      if (!uuid(raw)) fail('invalid_asset_reference', 503);
      references.push({ id: raw.toLowerCase(), entityID: entity.id, kind: entity.kind, slot });
    }
  }
  if (entity.kind === 'trip' && entity.fields.backgroundAssetIDs !== undefined && entity.fields.backgroundAssetIDs !== null) {
    const map = entity.fields.backgroundAssetIDs;
    if (typeof map !== 'object' || Array.isArray(map)) fail('invalid_asset_reference', 503);
    for (const [slot, raw] of Object.entries(map)) {
      if (!/^background:[0-9]{1,4}:[0-9]{1,4}$/.test(slot) || !uuid(raw)) fail('invalid_asset_reference', 503);
      references.push({ id: raw.toLowerCase(), entityID: entity.id, kind: 'trip', slot });
    }
  }
  return references;
}
export async function exportFingerprint(entities, tripID) {
  const map = graphIndex(entities), selected = entities.filter(e => rootOf(map, e.id).id === tripID)
    .sort((a,b) => a.id.localeCompare(b.id));
  return hash(JSON.stringify(canonical(selected)));
}
export function prepareBackup(entities, { tripID, mode, now }) {
  if (!['export_backup', 'share_trip'].includes(mode)) fail('invalid_export');
  const map = graphIndex(entities), root = map.get(tripID);
  if (!root || root.kind !== 'trip' || root.deletedAt) fail('trip_not_found', 404);
  const selected = entities.filter(e => !e.deletedAt && rootOf(map, e.id).id === tripID), full = mode === 'export_backup';
  const byParent = new Map();
  for (const entity of selected) {
    if (entity.parentID) { const list = byParent.get(entity.parentID) ?? []; list.push(entity); byParent.set(entity.parentID, list); }
  }
  const files = [], visited = new Set(), contents = [];
  function file(entity, slot, destination, key) {
    const reference = assetReferences(entity).find(r => r.slot === slot);
    if (!reference) return null;
    files.push({ ...reference, destination, key, label: String(entity.fields.displayName ?? entity.fields.name ?? entity.fields.timestamp ?? key).slice(0,1000) }); return reference;
  }
  function rebuild(entity) {
    if (visited.has(entity.id)) fail('invalid_graph', 503); visited.add(entity.id);
    const fields = structuredClone(entity.fields), object = { id: entity.id, ...fields };
    if(contents.length<100)contents.push(String(fields.name ?? fields.title ?? fields.displayName ?? fields.number ?? fields.timestamp ?? '').slice(0,1000));
    for (const key of ['fileAssetID','thumbnailAssetID','originalAssetID','backgroundAssetIDs']) delete object[key];
    if (!full) {
      for (const key of privateFields) if (Object.hasOwn(object,key)) object[key] = '';
      if (entity.kind === 'trip') { object.sections = []; object.backgroundsData = null; object.remindersEnabled = false; object.reminderConfigData = ''; }
    }
    if (entity.kind === 'photo') {
      if(full&&!fields.originalAssetID)fail('photo_original_required',409);
      object.assetLocalIdentifier = ''; object.thumbnailData = '';
      file(entity, 'thumbnail', 'inline', entity.id);
      file(entity, 'original', 'photoOriginals', entity.id);
    }
    if (entity.kind === 'attachment') {
      object.thumbnailData = '';
      const ext = String(object.utiOrExt ?? '').replace(/^public\./,'');
      object.fileName = fields.fileAssetID ? `${fields.fileAssetID}.${/^[a-zA-Z0-9]{1,12}$/.test(ext) ? ext : 'dat'}` : '';
      file(entity, 'file', 'attachmentFiles', object.fileName);
      file(entity, 'thumbnail', 'inline', entity.id);
      if (fields.fileName && !fields.fileAssetID) fail('missing_asset', 409);
    }
    if (entity.kind === 'trip' && full && fields.backgroundsData) {
      let backgrounds;
      try { backgrounds = JSON.parse(Buffer.from(fields.backgroundsData, 'base64').toString('utf8')); } catch { fail('invalid_background', 503); }
      if (!Array.isArray(backgrounds)) fail('invalid_background', 503);
      const slots = new Set();
      for (let i=0;i<backgrounds.length;i++) if (backgrounds[i].localFileName) {
        const slot = `background:${backgrounds[i].destinationIndex}:${i}`, key = `carry-${entity.id}-${i}.jpg`;
        if (!file(entity, slot, 'backgroundImages', key)) fail('missing_asset', 409);
        slots.add(slot); backgrounds[i].localFileName = key;
      }
      if (assetReferences(entity).some(r => !slots.has(r.slot))) fail('invalid_background',503);
      object.backgroundsData = Buffer.from(JSON.stringify(backgrounds)).toString('base64');
    }
    for (const [key, kind] of Object.entries(children[entity.kind] ?? {})) {
      if (!full && ['section','packingItem','photo','attachment'].includes(kind)) { if (key === 'sections') object.sections = []; else object[key] = null; continue; }
      const list = (byParent.get(entity.id) ?? []).filter(child => child.kind === kind)
        .sort((a,b) => (a.fields.sortOrder ?? 0) - (b.fields.sortOrder ?? 0) || a.id.localeCompare(b.id));
      object[key] = list.map(rebuild);
    }
    return object;
  }
  const trip = rebuild(root), backup = { version: 1, createdAt: new Date(now).toISOString(), trips: [trip], myItems: [],
    backgroundImages: {}, attachmentFiles: {}, photoOriginals: {} };
  const inline = new Map();
  function index(object,kind) {
    inline.set(object.id,object);
    for(const [key,childKind] of Object.entries(children[kind]??{})) for(const child of object[key]??[]) index(child,childKind);
  }
  index(trip,'trip');
  return { backup, files, inline, summary: { tripID, name: root.fields.name, mode,
    destinationCity:root.fields.destinationCity, departureDate:root.fields.departureDate, days:root.fields.days, contents,
    entityCount: visited.size, fileCount: files.length, containsOriginalPhotos: files.some(r=>r.slot==='original'),
    containsPrivateFields: full, containsPackingList: full, excludedDeviceEffects: ['HealthKit','calendar','notificationDelivery','StoreKit'] } };
}

// Count the exact JSON/base64 envelope before opening a provider stream. This
// matches native's bounded whole-JSON importer without materializing file bytes.
export function backupSerializedByteCount(prepared, manifests, {maximumBytes=256*1024*1024}={}) {
  const byID=new Map(manifests.map(file=>[file.id,file]));
  const assetManifest=manifests.map(file=>({entityID:file.entityID,assetID:file.id,slot:file.slot,sha256:file.sha256,byteCount:file.byteCount}));
  let total=Buffer.byteLength(JSON.stringify({...prepared.backup,assetManifest}),'utf8');
  const counts=new Map();
  for(const reference of prepared.files) {
    const file=byID.get(reference.id);if(!file)fail('invalid_export',503);
    total+=4*Math.ceil(file.byteCount/3);
    if(reference.destination!=='inline') {
      const count=counts.get(reference.destination)??0;
      total+=Buffer.byteLength(JSON.stringify(reference.key),'utf8')+3+(count?1:0);
      counts.set(reference.destination,count+1);
    }
    if(total>maximumBytes)fail('export_too_large',413);
  }
  if(total>maximumBytes)fail('export_too_large',413);
  return total;
}

// A valid JSON document is published only if every referenced stream completes
// its immutable-version, byte count and hash verification. A stream failure
// truncates the download rather than returning a parseable partial backup.
export function streamBackup(prepared, { open, authorize, signal }) {
  const cancellation=new AbortController();
  signal=signal?AbortSignal.any([signal,cancellation.signal]):cancellation.signal;
  let activeReader=null;
  const encoder = new TextEncoder();
  async function* base64(ref) {
    signal?.throwIfAborted(); await authorize();
    const stream=await open(ref,{signal}),reader=stream.getReader();activeReader=reader;let remainder=Buffer.alloc(0);
    try {
      while(true) {
        signal?.throwIfAborted();const {done,value}=await reader.read();if(done)break;await authorize();
        const bytes=Buffer.concat([remainder,Buffer.from(value)]),size=bytes.length-bytes.length%3;
        if(size)yield encoder.encode(bytes.subarray(0,size).toString('base64'));
        remainder=bytes.subarray(size);
      }
      if(remainder.length)yield encoder.encode(remainder.toString('base64'));
    } finally {if(activeReader===reader)activeReader=null;await reader.cancel().catch(()=>{});reader.releaseLock();}
  }
  const inline = new Map(prepared.files.filter(r=>r.destination==='inline').map(r=>[r.key,r]));
  async function* value(data) {
    signal?.throwIfAborted();
    if(Array.isArray(data)) {
      yield encoder.encode('[');for(let i=0;i<data.length;i++){if(i)yield encoder.encode(',');yield* value(data[i]);}yield encoder.encode(']');
    } else if(data!==null&&typeof data==='object') {
      yield encoder.encode('{');let first=true;
      for(const [key,v] of Object.entries(data)) {
        if(v===undefined)continue;
        yield encoder.encode(`${first?'':','}${JSON.stringify(key)}:`);first=false;
        if(key==='thumbnailData'&&inline.has(data.id)){yield encoder.encode('"');yield* base64(inline.get(data.id));yield encoder.encode('"');}
        else yield* value(v);
      }
      yield encoder.encode('}');
    } else yield encoder.encode(JSON.stringify(data));
  }
  async function* generate() {
    const { backgroundImages, attachmentFiles, photoOriginals, ...header } = prepared.backup;
    yield encoder.encode('{');let firstHeader=true;
    for(const [key,v]of Object.entries(header)){yield encoder.encode(`${firstHeader?'':','}${JSON.stringify(key)}:`);firstHeader=false;yield* value(v);}
    for (const destination of ['backgroundImages','attachmentFiles','photoOriginals']) {
      yield encoder.encode(`,${JSON.stringify(destination)}:{`); let first=true;
      for(const ref of prepared.files.filter(r=>r.destination===destination)) {
        yield encoder.encode(`${first?'':','}${JSON.stringify(ref.key)}:"`);first=false;
        yield* base64(ref);yield encoder.encode('"');
      }
      yield encoder.encode('}');
    }
    await authorize(); yield encoder.encode('}');
  }
  // Combine small JSON tokens into bounded output chunks. Every byte, including
  // metadata-only shares, passes a fresh owner/grant check before publication.
  // This keeps authorization frequency bounded by output size rather than the
  // number of JSON punctuation tokens.
  async function* chunks() {
    let buffer=new Uint8Array(65536),used=0;
    for await(const part of generate()) {
      let offset=0;
      while(offset<part.length) {
        const count=Math.min(buffer.length-used,part.length-offset);
        buffer.set(part.subarray(offset,offset+count),used);used+=count;offset+=count;
        if(used===buffer.length){yield buffer;buffer=new Uint8Array(65536);used=0;}
      }
    }
    if(used)yield buffer.subarray(0,used);
  }
  const iterator=chunks();
  return new ReadableStream({ async pull(controller) { try { await authorize();const {done,value}=await iterator.next();await authorize();if(done)controller.close();else controller.enqueue(value); } catch { await iterator.return();controller.error(new Error('export_download_failed')); } },async cancel(){cancellation.abort();await activeReader?.cancel().catch(()=>{});await iterator.return();} },{highWaterMark:0});
}
