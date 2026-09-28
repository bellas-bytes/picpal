import test from 'node:test';
import assert from 'node:assert/strict';
import { buildAnalysis, validateResult } from '../reference-analysis.js';
const image = { buffer: Buffer.from([0xff, 0xd8, 0xff, 0xd9]) };
test('profile uses only reference and its own token budget', () => {
 const r = buildAnalysis({ operation:'referenceProfile', prompt:'JSON' }, {reference:[image]});
 assert.equal(r.max_tokens,1200); assert.equal(r.content.filter(x=>x.type==='image').length,1);
 assert.equal(r.content[0].text,'Reference photo:');
});
test('comparison requires reference and profile', () => {
 assert.throws(()=>buildAnalysis({operation:'referenceComparison',prompt:'JSON'}, {image:[image]}));
});
test('legacy retains 64 tokens',()=>assert.equal(buildAnalysis({prompt:'Advice'}, {image:[image]}).max_tokens,64));
test('reject malformed structured output',()=>{
 assert.throws(()=>validateResult('referenceComparison','{"schemaVersion":1}'));
 assert.throws(()=>validateResult('referenceProfile','```json\n{}\n```'));
 assert.equal(validateResult('aesthetic','Hold steady'),'Hold steady');
});
const profile = JSON.stringify({schemaVersion:1,summary:'Portrait',features:['framing','pose','viewpoint','lighting','background'].map(d=>({dimension:d,evidence:'Visible',confidence:0.8,applicable:true}))});
const comparison = () => ({schemaVersion:1,dimensions:['framing','pose','viewpoint','lighting','background'].map(d=>({dimension:d,status:'matched',referenceEvidence:'Visible',liveEvidence:'Visible',confidence:0.8})),action:null});
test('comparison labels image order and includes validated profile',()=>{
 const r=buildAnalysis({operation:'referenceComparison',prompt:'JSON',profile},{image:[image],reference:[image]});
 assert.equal(r.max_tokens,1800); assert.equal(r.content[0].text,'Reference photo:'); assert.equal(r.content[2].text,'Current live view:');
 assert.match(r.content[4].text,/Reference profile/);
});
test('reject unknown version, duplicate dimensions, oversized evidence and invalid confidence',()=>{
 for (const mutate of [v=>v.schemaVersion=2,v=>v.dimensions[1].dimension='framing',v=>v.dimensions[0].confidence=1.01,v=>v.dimensions[0].referenceEvidence='x'.repeat(241),v=>v.dimensions[0].status='yes']) {
  const v=comparison(); mutate(v); assert.throws(()=>validateResult('referenceComparison',JSON.stringify(v)));
 }
 assert.doesNotThrow(()=>validateResult('referenceProfile',profile));
 assert.doesNotThrow(()=>validateResult('referenceComparison',JSON.stringify(comparison())));
});
test('unknown and matched dimensions cannot carry corrections',()=>{
 for (const status of ['unknown','matched','notApplicable']) {
 const v=comparison(); v.dimensions[1].status=status;
 v.action={id:'a',dimension:'pose',actor:'subject',direction:'raise-left-arm',instruction:'Raise left arm',expectedChange:'Match reference',confidence:0.8};
 assert.throws(()=>validateResult('referenceComparison',JSON.stringify(v)));
 }
});
test('upload validation rejects fake JPEG and unknown operation before calls',()=>{
 assert.throws(()=>buildAnalysis({prompt:'Advice'},{image:[{buffer:Buffer.from('not jpeg')}]}));
 assert.throws(()=>buildAnalysis({operation:'other',prompt:'Advice'},{image:[image]}));
});
