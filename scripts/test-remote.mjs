// Optional integration checks against your own disposable Supabase test project.
// Creates only synthetic records and cancels its reservations in finally.
import assert from'node:assert/strict';
const url=process.env.VITE_SUPABASE_URL,key=process.env.VITE_SUPABASE_ANON_KEY,password=process.env.DEMO_PASSWORD;
if(!url||!key||!password||url.includes('proyecto-de-prueba'))throw Error('Configurá primero .env y ejecutá seed:auth.');
async function api(token,path,body){const r=await fetch(url+path,{method:body?'POST':'GET',headers:{apikey:key,Authorization:`Bearer ${token||key}`,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});const j=await r.json();if(!r.ok)throw Error(j.message||j.error_description||'Falló la operación');return j}
async function login(email){return(await api(null,'/auth/v1/token?grant_type=password',{email,password})).access_token}
const coord=await login('coordinacion@cota.test'),reception=await login('recepcion@cota.test'),instructor=await login('instructor@cota.test');
const rpc=(a,p)=>api(coord,'/rest/v1/rpc/mutate',{action:a,p,request_id:crypto.randomUUID()});
assert.deepEqual(await api(reception,'/rest/v1/finances?select=*'),[]);
await assert.rejects(api(reception,'/rest/v1/rpc/financial_day',{d:'2026-08-14'}));
const states=await api(reception,'/rest/v1/rpc/payment_states',{d:'2026-08-14'});assert.ok(states.every(s=>Object.keys(s).sort().join(',')==='class_id,payment'));const own=await api(instructor,'/rest/v1/class_board?select=*');const all=await api(coord,'/rest/v1/classes?select=*');const other=all.find(c=>!own.some(o=>o.id===c.id));assert.ok(other);assert.deepEqual(await api(instructor,`/rest/v1/classes?id=eq.${other.id}&select=*`),[]);
const day=`2099-${String(1+Math.floor(Math.random()*12)).padStart(2,'0')}-${String(1+Math.floor(Math.random()*27)).padStart(2,'0')}`;
const ins=(await api(coord,'/rest/v1/instructors?select=*')).find(i=>i.disciplines.includes('esqui')&&!i.days_off.includes(new Date(day+'T12:00Z').getUTCDay()));
const students=await api(coord,'/rest/v1/students?level=eq.1&select=id&order=id');assert.ok(students.length>=9);
const sector=(await api(coord,'/rest/v1/sectors?name=eq.Alfombra%20Norte&select=id'))[0];const product=(await api(coord,'/rest/v1/products?name=eq.Snowboard%20demo&select=*'))[0];
let cid;const rentals=[];
try{
 const c=await rpc('save_class',{day,start_min:600,duration:120,type:'grupal',discipline:'esqui',language:'es',level:1,instructor_id:ins.id,sector_id:sector.id,student_ids:students.slice(0,7).map(s=>s.id)});assert.ok(c.id,JSON.stringify(c));cid=c.id;
 const race=await Promise.allSettled(students.slice(7,9).map(s=>rpc('enroll',{class_id:cid,version:1,student_id:s.id})));assert.equal(race.filter(r=>r.status==='fulfilled').length,1);assert.equal(race.filter(r=>r.status==='rejected').length,1);
 const roster=await api(coord,`/rest/v1/enrollments?class_id=eq.${cid}&status=eq.confirmada&select=id`);assert.equal(roster.length,8);
 const p={day,student_id:students[0].id,product_id:product.id,quantity:product.stock-1};const initial=await rpc('rent',p);rentals.push(initial.id);
 const stockRace=await Promise.allSettled([rpc('rent',{...p,quantity:1}),rpc('rent',{...p,quantity:1})]);for(const r of stockRace)if(r.status==='fulfilled')rentals.push(r.value.id);assert.equal(stockRace.filter(r=>r.status==='fulfilled').length,1);assert.equal(stockRace.filter(r=>r.status==='rejected').length,1);
 console.log('Auth de los tres roles, RLS por IDs y carreras de última plaza/última unidad: OK.');
}finally{
 for(const rental_id of rentals)await rpc('rental_state',{rental_id,rental_version:1,status:'cancelado'});
 if(cid){const c=(await api(coord,`/rest/v1/classes?id=eq.${cid}&select=version`))[0];await rpc('cancel_class',{class_id:cid,version:c.version,reason:'Prueba automática de concurrencia'})}
}
