import{cpSync,mkdirSync,readFileSync,writeFileSync,readdirSync}from'node:fs';
mkdirSync('dist/vendor',{recursive:true});cpSync('web','dist',{recursive:true});
for(const f of readdirSync('node_modules/@electric-sql/pglite/dist'))if(/^(index\.js|chunk-.*\.js|(pglite|initdb)\.(js|wasm|data))$/.test(f))cpSync('node_modules/@electric-sql/pglite/dist/'+f,'dist/vendor/'+f);
for(const [src,dest]of[['scripts/demo-bootstrap.sql','demo-bootstrap.sql'],['supabase/migrations/202611110001_cota.sql','schema.sql'],['supabase/seed.sql','seed.sql'],['scripts/demo-profiles.sql','demo-profiles.sql']])cpSync(src,'dist/'+dest);
writeFileSync('dist/schema.sql',readFileSync('supabase/migrations/202611110001_cota.sql','utf8')+'\n'+readFileSync('supabase/migrations/202611110002_harden.sql','utf8')+'\n'+readFileSync('supabase/migrations/202611110003_daily_board_payment.sql','utf8'));
const url=process.env.VITE_SUPABASE_URL||'',key=process.env.VITE_SUPABASE_ANON_KEY||'';
if(url&&!key)throw Error('Falta VITE_SUPABASE_ANON_KEY');if(key.startsWith('sb_secret_'))throw Error('Nunca uses una clave secreta en el navegador');
try{const payload=JSON.parse(Buffer.from(key.split('.')[1]||'','base64url'));if(payload.role==='service_role')throw Error('service_role prohibida en frontend')}catch(e){if(e.message.includes('prohibida'))throw e}
writeFileSync('dist/config.js','window.COTA_CONFIG='+JSON.stringify({url,key})+';\n');console.log('Build listo en dist/. '+(url?'Supabase configurado.':'Demostración local explícita.'));
