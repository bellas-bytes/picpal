import test from 'node:test';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
const run=(...args)=>spawnSync(process.execPath,[new URL('./evaluate.mjs',import.meta.url).pathname,...args],{encoding:'utf8'});
test('offline manifest is valid but missing evidence never passes release',()=>{
 const result=run();assert.equal(result.status,0);const report=JSON.parse(result.stdout);
 assert.equal(report.scenarioCount,30);assert.equal(report.missingAssets.length,30);
 assert.ok(Object.values(report.gates).every(g=>g.status==='incomplete'));
 assert.equal(run('--require-gates').status,1);
});
test('live mode requires explicit upload authorization before network',()=>{
 const result=run('--live');assert.notEqual(result.status,0);assert.match(result.stderr,/requires --allow-test-image-upload/);
});
test('known mismatch falsely marked matched increments false match count',()=>{
 const dir=mkdtempSync(join(tmpdir(),'picpal-eval-test-'));
 try{
  const path=join(dir,'mock-response.json');
  writeFileSync(path,JSON.stringify({schemaVersion:1,responses:[{scenarioID:'same-box-left-arm-low',comparison:{schemaVersion:1,dimensions:['framing','pose','viewpoint','lighting','background'].map(d=>({dimension:d,status:'matched',referenceEvidence:'Mock',liveEvidence:'Mock',confidence:1})),action:null}}]}));
  const result=run('--responses',path);assert.equal(result.status,0);const report=JSON.parse(result.stdout);
  assert.equal(report.gates.zeroFalseOverallMatches.falseMatches,1);
  assert.equal(report.gates.zeroFalseOverallMatches.status,'fail');
 }finally{rmSync(dir,{recursive:true,force:true});}
});
