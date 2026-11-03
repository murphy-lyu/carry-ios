import {test} from 'node:test';
import assert from 'node:assert/strict';
import {compilePlan} from './domain.mjs';
const valid=['0001-01-01T00:00:00Z','9999-12-31T23:59:59.999999999Z','2026-11-01T12:34:56Z','2026-11-01T12:34:56.123Z','2026-11-01T12:34:56.123456789+08:00','2024-02-29T12:34:56-05:30','2000-02-29T00:00:00Z','2026-11-01T12:34:56+15:59'];
const invalid=['0001-01-01T00:00:00+15:59','9999-12-31T23:59:59.999-15:59','2026-02-30T12:34:56Z','2026-02-29T12:34:56Z','1900-02-29T00:00:00Z','2026-11-01T24:00:00Z','2026-11-01T12:34:60Z','2026-11-01T12:60:00Z','2026-11-01T12:34Z','2026-11-01T12:34:56','2026-11-01T12:34:56Zgarbage','2026-11-01T12:34:56Z\n','2026-11-01T12:34:56+0800','2026-11-01T12:34:56+23:59','2026-11-01T12:34:56+16:00','2026-11-01T12:34:56+08:60','0000-01-01T00:00:00Z'];
const plan=value=>compilePlan({requestID:crypto.randomUUID(),operations:[{action:'create_trip',fields:{name:'Synthetic date',departureDate:value,days:0}}],entities:[],grant:{scopes:['trips:create','trips:write'],tripIDs:[],createdTripIDs:[]},now:0});
test('AI wire dates preserve valid Gregorian RFC3339 values without rewriting',async()=>{
 for(const value of valid){const p=await plan(value);assert.equal(p.command.mutations[0].fields.departureDate,value);}
});
test('AI rejects non-calendar, normalized, partial, local and trailing dates before creating a plan',async()=>{
 for(const value of invalid) await assert.rejects(plan(value),e=>e.code==='invalid_field',value);
});
