// Admin-only terminal utility. Never imported by web/. No credentials are logged.
const url=process.env.SUPABASE_URL,key=process.env.SUPABASE_SERVICE_ROLE_KEY,password=process.env.DEMO_PASSWORD;
if(!url||!key||!password||password.length<16||url.includes('proyecto-de-prueba'))throw Error('Configurá SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY y DEMO_PASSWORD (mínimo 16 caracteres) en .env ignorado por Git.');
const h={apikey:key,Authorization:`Bearer ${key}`,'Content-Type':'application/json'};
async function call(path,body,method='POST',extra={}){const r=await fetch(url+path,{method,headers:{...h,...extra},body:body?JSON.stringify(body):undefined});if(!r.ok)throw Error(`Operación admin falló (${r.status}); revisá configuración y migraciones.`);const text=await r.text();return text?JSON.parse(text):null}
let users=[];for(let page=1;;page++){const r=await call(`/auth/v1/admin/users?page=${page}&per_page=100`,null,'GET');const batch=r.users||[];users.push(...batch);if(batch.length<100)break}
for(const[email,name,role]of[['coordinacion@cota.test','Coordinación Demo','coordinacion'],['recepcion@cota.test','Recepción Demo','recepcion'],['instructor@cota.test','Lara Lagos','instructor']]){
 let u=users.find(u=>u.email===email);if(!u)u=await call('/auth/v1/admin/users',{email,password,email_confirm:true});
 // Existing demo passwords are not silently rotated by reruns.
 await call('/rest/v1/profiles?on_conflict=id',{id:u.id,name,role},'POST',{Prefer:'resolution=merge-duplicates,return=minimal'});
 if(role==='instructor')await call('/rest/v1/instructors?id=eq.00000000-0000-4000-0002-000000000001',{profile_id:u.id},'PATCH',{Prefer:'return=minimal'});
 console.log(`${email} · ${role} · listo`);
}
console.log('Ingresá con DEMO_PASSWORD del archivo local .env. No se envían correos. Borrá SUPABASE_SERVICE_ROLE_KEY del .env al terminar si ya no la necesitás.');
