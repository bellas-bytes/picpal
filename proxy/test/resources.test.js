import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createCounter } from '../resources.js';

test('serialized persistent reservations cannot exceed ceiling and survive restart', async () => {
 const dir = await mkdtemp(join(tmpdir(),'picpal-counter-'));
 try {
  const path = join(dir,'counter.json');
  const counter = await createCounter({path, ceiling:3});
  const results = await Promise.allSettled(Array.from({length:10},()=>counter.reserve()));
  assert.equal(results.filter(r=>r.status==='fulfilled').length,3);
  assert.equal(JSON.parse(await readFile(path)).totalCalls,3);
  const restarted = await createCounter({path,ceiling:3});
  await assert.rejects(restarted.reserve());
 } finally { await rm(dir,{recursive:true,force:true}); }
});
test('corrupt counters and persistence failures fail closed', async () => {
 const dir = await mkdtemp(join(tmpdir(),'picpal-counter-'));
 try {
  const path=join(dir,'counter.json');
  for (const raw of ['bad','{"totalCalls":-1}','{"totalCalls":null}','{"totalCalls":1.5}']) {
   await writeFile(path,raw);
   const counter=await createCounter({path,ceiling:3});
   await assert.rejects(counter.reserve()); assert.equal(counter.snapshot().healthy,false);
  }
  const counter=await createCounter({path:join(dir,'absent','counter.json'),ceiling:3});
  await assert.rejects(counter.reserve()); await assert.rejects(counter.reserve());
  assert.equal(counter.snapshot().healthy,false);
 } finally { await rm(dir,{recursive:true,force:true}); }
});
