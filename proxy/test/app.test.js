import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp } from '../app.js';
const tick = () => new Promise(resolve=>setTimeout(resolve,10));
const form = (valid=true) => { const f=new FormData(); f.set('prompt','Coach'); if(valid) f.set('image',new Blob([new Uint8Array([255,216,255,0])],{type:'image/jpeg'}),'frame.jpg'); return f; };
async function fixture(t, upstream, options={}) {
 const dir=await mkdtemp(join(tmpdir(),'picpal-app-'));
 const app=await createApp({upstream,counterPath:join(dir,'count.json'),maxActive:1,timeoutMs:1000,...options});
 const server=app.listen(0,'127.0.0.1'); await new Promise(resolve=>server.once('listening',resolve));
 const url=`http://127.0.0.1:${server.address().port}`;
 t.after(async()=>{ server.closeAllConnections(); await new Promise(resolve=>server.close(resolve)); await rm(dir,{recursive:true,force:true}); });
 return {url,post:(valid=true,signal)=>fetch(`${url}/analyze`,{method:'POST',body:form(valid),signal}),health:async()=> (await fetch(`${url}/health`)).json()};
}
const reply={content:[{type:'text',text:'Move left.'}],stop_reason:'end_turn'};
test('global admission bounds work, invalid requests release slots without quota',async t=>{
 let release, started=false;
 const f=await fixture(t,async()=>{started=true;await new Promise(r=>release=r);return reply;});
 assert.equal((await f.post(false)).status,400);
 assert.equal((await f.health()).calls,0);
 const first=f.post(); while(!started) await tick();
 const busy=await f.post(); assert.equal(busy.status,503); assert.equal(busy.headers.get('retry-after'),'1');
 assert.equal((await f.health()).activeRequests,1);
 release(); assert.equal((await first).status,200); assert.equal((await f.health()).activeRequests,0);
});
test('concurrent requests cannot overspend persisted ceiling',async t=>{
 let calls=0;const f=await fixture(t,async()=>{calls++;return reply;},{maxActive:10,ceiling:2});
 const responses=await Promise.all(Array.from({length:5},()=>f.post()));
 assert.equal(responses.filter(r=>r.status===200).length,2); assert.equal(calls,2);
 assert.equal((await f.health()).remainingCalls,0);
});
test('timeout aborts upstream and releases admission',async t=>{
 let aborted=false;
 const f=await fixture(t,(_params,{signal})=>new Promise((_resolve,reject)=>signal.addEventListener('abort',()=>{aborted=true;reject(signal.reason);})),{timeoutMs:25});
 assert.equal((await f.post()).status,504); assert.equal(aborted,true); assert.equal((await f.health()).activeRequests,0);
});
test('client disconnect aborts upstream and releases admission',async t=>{
 let signal;
 const f=await fixture(t,(_params,options)=>{signal=options.signal;return new Promise((_resolve,reject)=>signal.addEventListener('abort',()=>reject(signal.reason)));});
 const controller=new AbortController(); const pending=f.post(true,controller.signal).catch(()=>{});
 while(!signal) await tick(); controller.abort();await pending;
 for(let i=0;i<100 && !signal.aborted;i++) await tick();
 assert.equal(signal.aborted,true); assert.equal((await f.health()).activeRequests,0);
});
test('admission includes unfinished uploads and timeout closes them without quota',async t=>{
 const {request}=await import('node:http');
 let calls=0;const f=await fixture(t,async()=>{calls++;return reply;},{timeoutMs:150});
 let finishResponse;
 const completed=new Promise(resolve=>finishResponse=resolve);
 const partial=request(`${f.url}/analyze`,{method:'POST',headers:{'content-type':'multipart/form-data; boundary=test','content-length':'10000'}},response=>{response.resume();response.on('end',()=>finishResponse(response.statusCode));});
 partial.on('error',()=>{});
 partial.write('--test\r\nContent-Disposition: form-data; name="prompt"\r\n\r\n');
 for(let i=0;i<100 && (await f.health()).activeRequests===0;i++) await tick();
 assert.equal((await f.post()).status,503);
 assert.equal(await completed,504);partial.destroy();
 assert.equal(calls,0);assert.equal((await f.health()).calls,0);assert.equal((await f.health()).activeRequests,0);
});
test('upload parser errors and upstream errors release slots; SDK retry option is zero',async t=>{
 const f=await fixture(t,async(_params,options)=>{assert.equal(options.maxRetries,0);throw new Error('Mock unavailable');});
 const body=new FormData();body.set('image',new Blob(['text'],{type:'text/plain'}),'bad.txt');
 assert.equal((await fetch(`${f.url}/analyze`,{method:'POST',body})).status,400);
 assert.equal((await f.health()).calls,0);assert.equal((await f.health()).activeRequests,0);
 assert.equal((await f.post()).status,502);assert.equal((await f.health()).activeRequests,0);
});
test('invalid incomplete upload closes socket after rejection without spending quota',async t=>{
 const {createConnection}=await import('node:net');
 const f=await fixture(t,async()=>reply);
 const socket=createConnection({host:'127.0.0.1',port:Number(new URL(f.url).port)});
 t.after(()=>socket.destroy());
 await new Promise(resolve=>socket.once('connect',resolve));
 let received=''; socket.on('data',chunk=>{received+=chunk;}); socket.on('error',()=>{});
 const closed=new Promise(resolve=>socket.once('close',()=>resolve(true)));
 socket.write('POST /analyze HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=test\r\nContent-Length: 10000\r\n\r\n--test\r\nContent-Disposition: form-data; name="image"; filename="bad.txt"\r\nContent-Type: text/plain\r\n\r\ninvalid');
 const didClose=await Promise.race([closed,new Promise(resolve=>setTimeout(()=>resolve(false),300))]);
 assert.match(received,/400 Bad Request/);
 assert.equal(didClose,true,'Rejected incomplete upload must not retain an open socket');
 assert.equal((await f.health()).calls,0);
 assert.equal((await f.health()).activeRequests,0);
});
