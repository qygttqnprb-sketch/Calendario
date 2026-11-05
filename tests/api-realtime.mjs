// Run only against the disposable LOCAL Supabase stack started by CI.
// Uses Node's built-in fetch/WebSocket. No admin key, real email or persistent data.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';

const config = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const base = config.API_URL;
const key = config.ANON_KEY ?? config.PUBLISHABLE_KEY;
assert(base && key, 'Supabase CLI status must provide API_URL and a public key');
const hostname = new URL(base).hostname;
assert(['127.0.0.1', 'localhost'].includes(hostname), 'This test may only run against local Supabase');
const sockets = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

async function request(path, user, body, expected = null) {
  const response = await fetch(base + path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { apikey:key, Authorization:`Bearer ${user?.access_token ?? key}`, 'Content-Type':'application/json' },
    body:body === undefined ? undefined : JSON.stringify(body),
    signal:AbortSignal.timeout(15000),
  });
  const raw = await response.text();
  let data; try { data = JSON.parse(raw); } catch { data = raw; }
  if (expected === 'failure') { assert(!response.ok, `Expected denied operation: ${path}`); return data; }
  if (expected !== null && expected !== undefined) assert.equal(response.status, expected, `${path}: ${raw}`);
  else assert(response.ok, `${path}: HTTP ${response.status} ${raw}`);
  return data;
}
const rpc = (name, user, params, expected) => request(`/rest/v1/rpc/${name}`, user, params, expected);
async function signup(label) {
  const result = await request('/auth/v1/signup', null, {email:`coppia-${label}-${randomUUID()}@example.com`,password:randomUUID()+'aA1!'});
  assert(result.access_token && result.user?.id, 'Local email confirmation must be disabled for the test');
  return result;
}
async function subscribe(user, couple) {
  const url = new URL(base.replace(/^http/, 'ws') + '/realtime/v1/websocket');
  url.searchParams.set('apikey',key); url.searchParams.set('vsn','1.0.0');
  const socket = new WebSocket(url);
  const messages = [];
  const topic = `realtime:acceptance-${randomUUID()}`;
  let heartbeat;
  sockets.push(() => { clearInterval(heartbeat); socket.close(); });
  await new Promise((resolve,reject) => {
    const timeout = setTimeout(() => reject(new Error('Realtime join timed out')),20000);
    socket.addEventListener('error',() => {clearTimeout(timeout); reject(new Error('Realtime connection failed'));});
    socket.addEventListener('open',() => {
      socket.send(JSON.stringify({topic,event:'phx_join',ref:'1',payload:{
        access_token:user.access_token,
        config:{broadcast:{ack:false,self:false},presence:{key:''},postgres_changes:[{event:'*',schema:'public',table:'couple_changes',filter:`couple_id=eq.${couple}`}],private:false},
      }}));
      let ref=10;
      heartbeat=setInterval(() => {
        if(socket.readyState===WebSocket.OPEN) socket.send(JSON.stringify({topic:'phoenix',event:'heartbeat',payload:{},ref:String(ref++)}));
      },10000);
    });
    socket.addEventListener('message',event => {
      const data=JSON.parse(String(event.data));
      if(data.event==='phx_reply' && data.ref==='1') {
        clearTimeout(timeout);
        if(data.payload.status==='ok') resolve(); else reject(new Error('Realtime join denied'));
      }
      if(data.event==='postgres_changes') messages.push(data.payload);
    });
  });
  return messages;
}
async function eventually(predicate, label) {
  const deadline=Date.now()+20000;
  while(Date.now()<deadline) {if(predicate()) return; await sleep(100);}
  assert.fail(label);
}
try {
  const [alice,bob,eve]=await Promise.all(['alice','bob','eve'].map(signup));
  const couple=await rpc('create_couple',alice,{p_name:'API acceptance',p_display_name:'Alice'});
  const invite=await rpc('create_invite',alice,{p_couple_id:couple});
  assert.equal(await rpc('join_couple',bob,{p_code:invite,p_display_name:'Bob'}),couple);
  await rpc('join_couple',eve,{p_code:invite,p_display_name:'Eve'},'failure');
  const partnerChanges=await subscribe(bob,couple);
  const outsiderChanges=await subscribe(eve,couple);
  await Promise.all(Array.from({length:8},(_,i)=>rpc('ensure_weekly_slots',i%2 ? bob:alice,{p_couple_id:couple})));
  const slots=await request(`/rest/v1/obligation_slots?couple_id=eq.${couple}&select=*`,alice);
  assert.equal(slots.length,4);
  for(const person of [alice,bob]) assert.equal(slots.filter(s=>s.owner_id===person.user.id).length,2);
  console.log('PASS: Auth, one-time invitation and concurrent weekly generation');

  const start=new Date(); const end=new Date(start.getTime()+3600000);
  const input={p_couple_id:couple,p_title:'Shared API moment',p_starts_at:start.toISOString(),p_ends_at:end.toISOString(),p_visibility:'shared',p_partner:true};
  const event=await rpc('save_event',alice,input);
  await eventually(()=>partnerChanges.length>0,'Partner did not receive Realtime invalidation');
  assert(!JSON.stringify(partnerChanges).includes(input.p_title),'Realtime invalidation must not carry event details');
  const range={p_couple_id:couple,p_from:new Date(start.getTime()-60000).toISOString(),p_to:new Date(end.getTime()+60000).toISOString()};
  let calendar=await rpc('calendar_events',bob,range);
  assert(calendar.some(e=>e.id===event && e.title===input.p_title));
  console.log('PASS: Two authenticated accounts observe shared event through Realtime and RPC');

  await rpc('save_event',alice,{...input,p_title:'PRIVATE SECRET',p_visibility:'private'});
  const busy=await rpc('save_event',alice,{...input,p_title:'BUSY SECRET',p_visibility:'busy_only',p_description:'HIDDEN',p_location:'HIDDEN',p_url:'https://example.com/private'});
  calendar=await rpc('calendar_events',bob,range);
  assert.equal(calendar.length,2);
  const hidden=calendar.find(e=>e.id===busy);
  assert.equal(hidden.title,'Occupato'); assert.equal(hidden.description,''); assert.equal(hidden.location_text,''); assert.equal(hidden.external_url,null);
  assert(!JSON.stringify(calendar).includes('SECRET'));
  const direct=await request('/rest/v1/events?select=*',bob);
  assert.equal(direct.length,1);
  for(const table of ['events','obligation_slots','couples','couple_changes']) assert.deepEqual(await request(`/rest/v1/${table}?select=*`,eve),[]);
  await rpc('calendar_events',eve,range,'failure');
  assert.equal(outsiderChanges.length,0);
  console.log('PASS: Private and busy-only details protected; third account isolated');

  const slot=slots.find(s=>s.owner_id===alice.user.id);
  await rpc('assign_obligation',bob,{p_obligation_id:slot.id,p_event_id:event,p_kind:'couple'},'failure');
  await rpc('assign_obligation',alice,{p_obligation_id:slot.id,p_event_id:event,p_kind:'couple'});
  let completion=await rpc('request_completion',alice,{p_obligation_id:slot.id});
  await rpc('review_completion',alice,{p_request_id:completion,p_approve:true},'failure');
  await rpc('review_completion',bob,{p_request_id:completion,p_approve:false});
  let state=await request(`/rest/v1/obligation_slots?id=eq.${slot.id}&select=*`,alice);
  assert.equal(state[0].status,'disputed'); assert.equal(state[0].completed_at,null);
  completion=await rpc('request_completion',alice,{p_obligation_id:slot.id});
  await rpc('review_completion',bob,{p_request_id:completion,p_approve:true});
  state=await request(`/rest/v1/obligation_slots?id=eq.${slot.id}&select=*`,alice);
  assert.equal(state[0].status,'completed'); assert(state[0].completed_at);
  const audit=await request(`/rest/v1/obligation_history?obligation_id=eq.${slot.id}&action=eq.approved&select=*`,alice);
  assert.equal(audit.length,1);
  await sleep(1000);
  assert.equal(outsiderChanges.length,0);
  console.log('PASS: Owner-only assignment, rejection, resubmission, partner approval and audit over HTTP');
} finally {
  for(const close of sockets) close();
}
