import test from 'node:test';
import assert from 'node:assert/strict';
import {validateManifest, score} from './evaluate.mjs';
const sample = () => ({schemaVersion:1, datasetKind:'real', rightsRecords:[{id:'consent', localEvaluation:true, recordAsset:'consent/p01.txt'}], records:[{id:'a',split:'test',participantGroup:'p1',sessionGroup:'s1',referenceFamily:'r1',referenceAsset:'r.jpg',liveAsset:'l.jpg',camera:'front',orientation:'portrait',mirrored:true,zoom:1,selectedDetails:['hand_position'],rightsRecord:'consent',frames:[{timestamp:0,acceptableActions:['hand_up'],forbiddenActions:['move_back'],unknownDetails:['palm_direction'],completedDetails:[]}]}]});
const decision = (overrides={}) => ({id:'a',timestamp:0,action:'hand_up',detail:'hand_position',completedDetails:[],allowsAutoCapture:false,referenceMatched:false,...overrides});
test('acceptable action counts as correct',()=>assert.equal(score(sample(),[decision()]).precision,1));
test('abstention reduces coverage',()=>assert.equal(score(sample(),[decision({action:null,detail:null})]).coverage,0));
test('forbidden action is an error',()=>assert.equal(score(sample(),[decision({action:'move_back'})]).errors[0].kind,'forbidden_action'));
test('unknown detail cannot become a cue',()=>assert.equal(score(sample(),[decision({detail:'palm_direction'})]).precision,0));
test('stale completion fails',()=>assert.ok(score(sample(),[decision({completedDetails:['hand_position']})]).errors.some(e=>e.kind==='false_completion')));
test('missing replay output remains in denominator',()=>{const s=score(sample(),[]);assert.equal(s.expected,1);assert.equal(s.coverage,0);assert.equal(s.errors[0].kind,'missing_output');});
test('empty real manifest cannot pass',()=>{const m=sample();m.records=[];assert.equal(score(m,[]).status,'incomplete');});
test('split leakage follows connected sessions and reference families',()=>{const m=sample();m.records.push({...m.records[0],id:'b',participantGroup:'p2',referenceFamily:'r2'}, {...m.records[0],id:'c',participantGroup:'p3',sessionGroup:'s3',referenceFamily:'r2',split:'calibration'});assert.throws(()=>validateManifest(m),/leakage/);});
test('reject missing rights and traversal paths',()=>{const m=sample();m.records[0].rightsRecord='missing';assert.throws(()=>validateManifest(m),/rights/);m.records[0].rightsRecord='consent';m.records[0].liveAsset='../private.jpg';assert.throws(()=>validateManifest(m),/relative/);});
test('duplicate, extra, invalid outputs fail',()=>{assert.throws(()=>score(sample(),[decision(),decision()]),/duplicate/);assert.throws(()=>score(sample(),[decision({timestamp:1})]),/Unexpected/);assert.throws(()=>score(sample(),[decision({allowsAutoCapture:'false'})]),/boolean/);});
test('capture or full match on partial selfie fails',()=>assert.ok(score(sample(),[decision({allowsAutoCapture:true})]).errors.some(e=>e.kind==='false_capture')));
test('private asset validation rejects symlink escapes', async()=>{
  const {mkdtemp,writeFile,symlink,rm}=await import('node:fs/promises');
  const {tmpdir}=await import('node:os'); const {join}=await import('node:path');
  const {validateAssets}=await import('./evaluate.mjs');
  const root=await mkdtemp(join(tmpdir(),'pose-assets-')), outside=await mkdtemp(join(tmpdir(),'pose-outside-'));
  try {await writeFile(join(outside,'r.jpg'),'private');await symlink(join(outside,'r.jpg'),join(root,'r.jpg'));await assert.rejects(validateAssets(sample(),root),/escapes/);}
  finally {await rm(root,{recursive:true,force:true});await rm(outside,{recursive:true,force:true});}
});
