import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {graphSchema} from './graph-schema.mjs';

test('wire schema covers every native backup field or an explicit relation/asset conversion',async()=>{
  const source=await readFile(new URL('../../Carry/Models/DataBackupManager.swift',import.meta.url),'utf8');
  const models={trip:'BackupTrip',section:'BackupPackingSection',packingItem:'BackupPackingItem',day:'BackupItineraryDay',stop:'BackupItineraryStop',transport:'BackupTransportSegment',lodging:'BackupLodgingStay',photo:'BackupStopPhoto',attachment:'BackupAttachment',libraryItem:'BackupMyItem'};
  const relations={trip:['sections','itineraryDays','lodgingStays'],section:['items'],day:['stops','segments'],stop:['photos','attachments'],transport:['attachments'],lodging:['attachments']};
  const replacements={photo:{thumbnailData:'thumbnailAssetID'},attachment:{thumbnailData:'thumbnailAssetID'}};
  for(const [kind,model]of Object.entries(models)){
    const body=source.match(new RegExp(`struct ${model}: Codable, Sendable \\{([\\s\\S]*?)\\n\\}`))?.[1];assert.ok(body,model);
    const fields=[...body.matchAll(/var (\w+):/g)].map(m=>m[1]);
    for(const key of fields){if(key==='id'||relations[kind]?.includes(key))continue;
      assert.ok(graphSchema[kind].fields[replacements[kind]?.[key]??key],`${model}.${key} must not silently disappear from account sync`);}
  }
});
