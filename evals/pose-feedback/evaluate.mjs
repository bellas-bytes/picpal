#!/usr/bin/env node
import {readFile, realpath, stat, writeFile} from 'node:fs/promises';
import {resolve, relative, isAbsolute, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
const check = (condition, message) => { if (!condition) throw new Error(message); };
const strings = value => Array.isArray(value) && value.every(x => typeof x === 'string' && x.length > 0) && new Set(value).size === value.length;
const safePath = p => typeof p === 'string' && p.length > 0 && !isAbsolute(p) && !p.includes('\\') && !p.split('/').some(x => x === '..' || x === '.' || !x);
const details = ['hand_position','head_tilt','head_turn','finger_spread','hand_roll','shoulder_tilt','gesture','palm_direction'];
export function validateManifest(m) {
  check(m.schemaVersion === 1 && ['real','synthetic'].includes(m.datasetKind) && Array.isArray(m.records) && Array.isArray(m.rightsRecords), 'Invalid manifest header');
  const rights = new Map();
  for (const r of m.rightsRecords) {
    check(typeof r.id === 'string' && r.id && !rights.has(r.id) && r.localEvaluation === true && safePath(r.recordAsset), 'Invalid rights record');
    rights.set(r.id,r);
  }
  const ids = new Set(), parents = new Map(), splits = new Map();
  const find = x => { if (!parents.has(x)) parents.set(x,x); if (parents.get(x)!==x) parents.set(x,find(parents.get(x))); return parents.get(x); };
  for (const r of m.records) {
    check(typeof r.id === 'string' && r.id && !ids.has(r.id), 'Invalid/duplicate record id'); ids.add(r.id);
    check(['development','training','calibration','test'].includes(r.split), `Invalid split: ${r.id}`);
    const groups=['participantGroup','sessionGroup','referenceFamily'].map(k=>{check(typeof r[k]==='string'&&r[k],`Missing ${k}`);return `${k}:${r[k]}`;});
    for (const g of groups.slice(1)) parents.set(find(g),find(groups[0]));
    check(safePath(r.referenceAsset)&&safePath(r.liveAsset), `Assets must be private-root relative paths: ${r.id}`);
    check(rights.has(r.rightsRecord), `Missing rights record: ${r.id}`);
    check(['front','back'].includes(r.camera)&&['portrait','portraitUpsideDown','landscapeLeft','landscapeRight'].includes(r.orientation)&&typeof r.mirrored==='boolean'&&Number.isFinite(r.zoom)&&r.zoom>0,`Invalid capture metadata: ${r.id}`);
    check(r.selfieAtMinimumZoom === undefined || typeof r.selfieAtMinimumZoom === 'boolean', `Invalid minimum-zoom flag: ${r.id}`);
    check(strings(r.selectedDetails)&&r.selectedDetails.every(x=>details.slice(0,6).includes(x)),`Invalid selectedDetails: ${r.id}`);
    check(Array.isArray(r.frames)&&r.frames.length>0, `Missing frames: ${r.id}`);
    let previous=-1;
    for(const f of r.frames) {
      check(Number.isFinite(f.timestamp)&&f.timestamp>=0&&f.timestamp>previous,`Invalid frame timestamp: ${r.id}`); previous=f.timestamp;
      for(const key of ['acceptableActions','forbiddenActions','unknownDetails','completedDetails']) check(strings(f[key]),`Invalid ${key}: ${r.id}`);
      check(!f.acceptableActions.some(x=>f.forbiddenActions.includes(x)),`Contradictory action labels: ${r.id}`);
      check(f.unknownDetails.every(x=>details.includes(x))&&f.completedDetails.every(x=>details.includes(x)&&!f.unknownDetails.includes(x)),`Contradictory detail labels: ${r.id}`);
    }
  }
  for(const r of m.records) {const component=find(`participantGroup:${r.participantGroup}`);check(!splits.has(component)||splits.get(component)===r.split,`Split leakage in connected participant/session/reference component: ${r.id}`);splits.set(component,r.split);}
  return m;
}
export async function validateAssets(m, assetRoot) {
  validateManifest(m);
  const root=await realpath(assetRoot), repository=await realpath(resolve(dirname(fileURLToPath(import.meta.url)),'../..'));
  const inside=(base,path)=>{const rel=relative(base,path);return !isAbsolute(rel)&&rel!=='..'&&!rel.startsWith('../');};
  check(!inside(repository,root),'Dataset root must be outside repository');
  for(const path of new Set([...m.records.flatMap(r=>[r.referenceAsset,r.liveAsset]),...m.rightsRecords.map(r=>r.recordAsset)])) {
    const full=await realpath(resolve(root,path));check(inside(root,full)&&!inside(repository,full),`Asset escapes private root: ${path}`);check((await stat(full)).isFile(),`Not a file: ${path}`);
  }
}
export function score(manifest, outputs) {
  const m=validateManifest(manifest), expected=new Map(), seen=new Set(), errors=[];
  for(const r of m.records) for(const f of r.frames) expected.set(`${r.id}:${f.timestamp}`,{r,f});
  let assessable=0, issued=0, correct=0, covered=0;
  const participants={};
  for(const {r,f} of expected.values()) {if(f.acceptableActions.length) assessable++; participants[r.participantGroup]??={expected:0,issued:0,correct:0};participants[r.participantGroup].expected++;}
  for(const o of outputs) {
    const key=`${o.id}:${o.timestamp}`;check(expected.has(key),`Unexpected replay output: ${key}`);check(!seen.has(key),`duplicate output: ${key}`);seen.add(key);
    check((o.action===null||typeof o.action==='string')&&(o.detail===null||details.includes(o.detail))&&strings(o.completedDetails),'Invalid replay action/detail');
    check(typeof o.allowsAutoCapture==='boolean'&&typeof o.referenceMatched==='boolean','Replay capture/match must be boolean');
    const {r,f}=expected.get(key), fail=kind=>errors.push({id:r.id,timestamp:f.timestamp,kind});
    if(o.error) fail('replay_error');
    if(o.action!==null) {
      issued++;participants[r.participantGroup].issued++;if(f.acceptableActions.length) covered++;
      const forbidden=f.forbiddenActions.includes(o.action), unknown=o.detail===null||f.unknownDetails.includes(o.detail);
      if(forbidden) fail('forbidden_action');else if(unknown) fail('unknown_detail_cue');else if(!f.acceptableActions.includes(o.action)) fail('unacceptable_action');
      else if(!o.error) {correct++;participants[r.participantGroup].correct++;}
    }
    for(const d of o.completedDetails) if(!f.completedDetails.includes(d)||f.unknownDetails.includes(d)) fail('false_completion');
    if(o.referenceMatched) fail('false_full_match');
    if(o.allowsAutoCapture) fail('false_capture');
  }
  for(const [key,{r,f}] of expected) if(!seen.has(key)) errors.push({id:r.id,timestamp:f.timestamp,kind:'missing_output'});
  return {schemaVersion:1,datasetKind:m.datasetKind,status:expected.size===0?'incomplete':errors.length?'fail':'scored',expected:expected.size,received:seen.size,assessable,issued,correct,precision:issued?correct/issued:null,coverage:assessable?covered/assessable:null,participants,errors,claim:'Diagnostic scoring only; human review, participant uncertainty, temporal and device gates remain required.'};
}
async function main() {
  const args=process.argv.slice(2), option=k=>{const i=args.indexOf(k);return i<0?undefined:args[i+1];};
  const m=JSON.parse(await readFile(option('--manifest')??new URL('./manifest.json',import.meta.url),'utf8'));
  validateManifest(m);
  if(option('--asset-root')) await validateAssets(m,option('--asset-root'));
  if(args.includes('--validate-only')) {console.log('Manifest valid; '+m.records.length+' records'+(option('--asset-root')?'; private assets verified.':'; asset files not checked.'));return;}
  const lines=option('--decisions')?(await readFile(option('--decisions'),'utf8')).split('\n').filter(x=>x.trim()).map(x=>JSON.parse(x)):[];
  const report=score(m,lines);const text=JSON.stringify(report,null,2)+'\n';if(option('--output'))await writeFile(option('--output'),text);console.log(text);
  if(args.includes('--require-gates')) process.exitCode=report.datasetKind!=='real'||report.expected===0||report.errors.length||!(report.precision>=.9)||!(report.coverage>=.7)?1:0;
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)) main().catch(e=>{console.error(e.message);process.exitCode=1;});
