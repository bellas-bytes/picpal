#!/usr/bin/env node
import {readFile, writeFile, realpath} from 'node:fs/promises';
import {resolve, dirname, relative, isAbsolute} from 'node:path';
import {fileURLToPath} from 'node:url';
import {validateResult} from '../../proxy/reference-analysis.js';
const root=dirname(fileURLToPath(import.meta.url));
const args=process.argv.slice(2);
const option=(name,fallback)=>{const i=args.indexOf(name);return i<0?fallback:args[i+1];};
const assert=(value,message)=>{if(!value) throw new Error(message);};
const manifest=JSON.parse(await readFile(resolve(option('--manifest',`${root}/manifest.json`)),'utf8'));
const expectedCounts={framing:6,pose:6,viewpoint:4,lighting:4,matching:4,ambiguous:6};
assert(manifest.schemaVersion===1,'Unsupported manifest schema');
assert(manifest.scenarios?.length===30,'Exactly 30 scenarios required');
const byID=new Map(manifest.scenarios.map(s=>[s.id,s]));
assert(byID.size===30,'Duplicate scenario IDs');
for(const [category,count] of Object.entries(expectedCounts)) assert(manifest.scenarios.filter(s=>s.category===category).length===count,`Wrong count: ${category}`);
assert(manifest.scenarios.filter(s=>s.split==='heldOut').length===10,'Ten held-out scenarios required');
assert(manifest.scenarios.filter(s=>s.followUps?.length>=2).length>=10,'Ten follow-up sequences required');
for(const s of manifest.scenarios){
 assert(s.visibleEvidence && s.expected && Array.isArray(s.expected.actionActors) && Array.isArray(s.expected.actionDirections),`Incomplete labels: ${s.id}`);
 assert(typeof s.testImageUploadConsent==='boolean',`Missing explicit consent: ${s.id}`);
 for(const f of s.followUps ?? []) assert(['improved','worsened'].includes(f.expectedChange),`Invalid follow-up: ${s.id}`);
}
assert(manifest.swappedReferenceControls?.length>=3,'Three swapped-reference controls required');
for(const c of manifest.swappedReferenceControls) assert(c.requireDifferentAdvice && c.scenarioIDs.length>=2 && c.scenarioIDs.every(id=>byID.has(id)),`Invalid control: ${c.id}`);
const missingAssets=manifest.scenarios.filter(s=>!s.referenceImage||!s.liveImage||!s.license).map(s=>s.id);
let responses=[];
let controlReviews=[];
if(args.includes('--live')){
 assert(args.includes('--allow-test-image-upload'),'Live mode requires --allow-test-image-upload');
 const proxy=option('--proxy'); assert(proxy,'Explicit --proxy URL required');
 const url=new URL(proxy); assert(['http:','https:'].includes(url.protocol),'Proxy must be HTTP(S)');
 const maxCalls=Number(option('--max-calls','4')); assert(Number.isInteger(maxCalls)&&maxCalls>0&&maxCalls<=60,'max-calls must be 1...60');
 const selected=option('--ids','').split(',').filter(Boolean); assert(selected.length>0,'Live mode requires explicit --ids');
 const assetRoot=await realpath(resolve(option('--asset-root',root))); 
 const prepared=[];
 async function image(path){
  assert(typeof path==='string'&&path.length>0,'Missing test image path');
  const full=await realpath(resolve(assetRoot,path)), rel=relative(assetRoot,full);
  assert(!rel.startsWith('..')&&!isAbsolute(rel),'Image outside approved asset root');
  const bytes=await readFile(full); assert(bytes.length<=5*1024*1024&&bytes[0]===255&&bytes[1]===216&&bytes[2]===255,'Expected JPEG under 5 MB');
  return new Blob([bytes],{type:'image/jpeg'});
 }
 for(const id of selected){
  const s=byID.get(id); assert(s,`Unknown ID: ${id}`);
  assert(s.testImageUploadConsent===true && s.license,`Missing test-image consent/license: ${id}`);
  prepared.push({s,reference:await image(s.referenceImage),live:await image(s.liveImage)});
 }
 assert(prepared.length*2<=maxCalls,'Selected scenarios exceed total profile+comparison request cap');
 // Prompts are extracted from checked-in production source, keeping evaluation tied to the implementation.
 const source=await readFile(resolve(root,'../../picpal/Sources/VLM/ReferenceAnalysisPrompt.swift'),'utf8');
 const extract=name=>{const match=source.match(new RegExp(`static let ${name} = (?:rules \\+ )?"""([\\s\\S]*?)"""`));assert(match,`Cannot extract ${name} prompt`);return match[1];};
 const rules=extract('rules'); let calls=0;
 async function call(operation,prompt,reference,live,profile){
  assert(calls<maxCalls,'Request cap reached');
  const form=new FormData();form.set('operation',operation);form.set('prompt',prompt);form.set('reference',reference,'reference.jpg');
  if(live)form.set('image',live,'live.jpg');if(profile)form.set('profile',JSON.stringify(profile));
  calls++;const started=Date.now();
  const response=await fetch(url,{method:'POST',body:form,redirect:'error',signal:AbortSignal.timeout(30000)});
  assert(response.ok,`Proxy HTTP ${response.status}`);const body=await response.json();
  validateResult(operation,body.result);return {value:JSON.parse(body.result),latencyMs:Date.now()-started};
 }
 for(const {s,reference,live} of prepared){
  try{
   const profile=await call('referenceProfile',rules+extract('profile'),reference);
   const comparison=await call('referenceComparison',rules+extract('comparison'),reference,live,profile.value);
   responses.push({scenarioID:s.id,comparison:comparison.value,latencyMs:comparison.latencyMs,profileLatencyMs:profile.latencyMs,calls:2,human:null,followUps:[]});
  }catch(error){responses.push({scenarioID:s.id,error:error.message});}
 }
 const output=resolve(option('--output',`${root}/results/live-${Date.now()}.json`));
 await writeFile(output,JSON.stringify({schemaVersion:1,calls,responses},null,2)+'\n');
 console.log(`Saved ${calls} calls to ${output}; human review still required.`);
}else if(option('--responses')){
 const saved=JSON.parse(await readFile(resolve(option('--responses')),'utf8'));
 assert(saved.schemaVersion===1&&Array.isArray(saved.responses),'Invalid saved response format');responses=saved.responses; controlReviews=saved.controlReviews ?? [];
}
const seen=new Set();let valid=0,falseMatches=0,wrongDirections=0,assessable=0,grounded=0,reviewedHeldOut=0,followUps=0,correctFollowUps=0,stale=0,accepted=0;
const failures=[],latencies=[];
for(const r of responses){
 const s=byID.get(r.scenarioID);assert(s&&!seen.has(s.id),`Unknown/duplicate result: ${r.scenarioID}`);seen.add(s.id);
 if(r.error){failures.push({id:s.id,error:r.error});continue;}
 try{validateResult('referenceComparison',JSON.stringify(r.comparison));}catch{failures.push({id:s.id,error:'invalid contract'});continue;}
 valid++;
 const c=r.comparison;
 const matched=!c.action&&c.dimensions.every(d=>['matched','notApplicable'].includes(d.status));
 if(matched&&!s.expected.overallMatch)falseMatches++;
 if(c.action&&(!s.expected.actionActors.includes(c.action.actor)||!s.expected.actionDirections.includes(c.action.direction)))wrongDirections++;
 if(s.split==='heldOut'&&r.human?.reviewer){
  reviewedHeldOut++;if(r.human.assessable===true){assessable++;if(r.human.grounded===true&&r.human.actionable===true)grounded++;}
 }
 for(const f of r.followUps??[]){const label=s.followUps.find(x=>x.kind===f.kind);if(label&&f.human?.reviewer){followUps++;if(f.human.recognizedChange===label.expectedChange)correctFollowUps++;}}
 if(Number.isFinite(r.latencyMs))latencies.push(r.latencyMs);
 if(r.accepted===true){accepted++;if(r.ageAtDeliverySeconds>=8||r.contextMatched===false)stale++;}
}
const enough=responses.length===30&&valid===30;
const verifiedControls=manifest.swappedReferenceControls.filter(c=>c.sameLiveImage && controlReviews.some(r=>r.id===c.id && r.reviewer && r.sameLiveVerified===true && r.adviceChangesWithReference===true)).length;
const report={manifest:'valid',scenarioCount:30,missingAssets,results:responses.length,validResponses:valid,failures,
 gates:{swappedReferenceControls:{verified:verifiedControls,total:manifest.swappedReferenceControls.length,status:verifiedControls===manifest.swappedReferenceControls.length?'pass':'incomplete'},zeroFalseOverallMatches:{falseMatches,status:falseMatches?'fail':(enough?'pass':'incomplete')},
 zeroWrongDirections:{wrongDirections,status:wrongDirections?'fail':(enough?'pass':'incomplete')},
 heldOutGroundedActionable:{reviewedHeldOut,grounded,assessable,status:reviewedHeldOut===10&&assessable>0?(grounded/assessable>=.9?'pass':'fail'):'incomplete'},
 followUpRecognition:{correct:correctFollowUps,total:followUps,status:followUps>=20?(correctFollowUps/followUps>=.8?'pass':'fail'):'incomplete'}},
 metrics:{acceptedResponses:accepted,acceptedStaleResponses:stale,withinEightSeconds:latencies.filter(n=>n<8000).length,successfulLatencies:latencies.length,
 observedFreshnessFraction:latencies.length?latencies.filter(n=>n<8000).length/latencies.length:null,
 controlledNetworkFreshness:'requires controlled-network measurement declaration',
 staleDiscardRate:'requires instrumented app run',timeToFirstUsefulAction:'requires instrumented app run',callsPerMinute:'requires timed app run'},
 completion:'incomplete until licensed images, human held-out reviews, swapped-reference controls, instrumented app and phone checks are supplied'};
console.log(JSON.stringify(report,null,2));
if(args.includes('--require-gates'))process.exitCode=missingAssets.length||Object.values(report.gates).some(g=>g.status!=='pass')?1:0;
